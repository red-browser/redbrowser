//! SpiderMonkey (Firefox's JavaScript engine) bridge.
//!
//! Deliberately thin: one runtime on the UI thread, one global object per page,
//! and a single native function `__host(op, ...args)` that forwards every DOM /
//! timer / console operation to the Zig side. The DOM itself, its bindings
//! (written in JS on top of `__host`) and the event loop all live in Zig.

use std::cell::{Cell, RefCell};
use std::ffi::{c_char, c_void, CStr};
use std::ptr::{self, NonNull};

use mozjs::context::{JSContext, RawJSContext};
use mozjs::conversions::{ConversionResult, FromJSValConvertible, ToJSValConvertible};
use mozjs::gc::RootedTraceableBox;
use mozjs::jsapi::Heap;
use mozjs::jsapi::{CallArgs, JSObject, OnNewGlobalHookOption, Value};
use mozjs::jsval::{BooleanValue, DoubleValue, NullValue, UndefinedValue};
use mozjs::realm::AutoRealm;
use mozjs::rooted;
use mozjs::rust::wrappers2::{JS_ClearPendingException, JS_DefineFunction, JS_GetPendingException, JS_NewGlobalObject, RunJSMicroTask, RunJobs, SetJobQueue};
use mozjs::rust::{evaluate_script, CompileOptionsWrapper, Handle, JSEngine, RealmOptions, Runtime, SIMPLE_GLOBAL_CLASS};

#[repr(C)]
#[derive(Clone, Copy)]
pub struct ReStr {
    pub ptr: *const u8,
    pub len: usize,
}

impl ReStr {
    fn of(s: &str) -> ReStr {
        ReStr { ptr: s.as_ptr(), len: s.len() }
    }
    unsafe fn as_str(&self) -> &str {
        if self.ptr.is_null() || self.len == 0 {
            return "";
        }
        std::str::from_utf8(std::slice::from_raw_parts(self.ptr, self.len)).unwrap_or("")
    }
}

/// tag: 0 undefined, 1 null, 2 bool (`num != 0`), 3 number, 4 string
#[repr(C)]
pub struct ReJsValue {
    pub tag: u32,
    pub num: f64,
    pub str_: ReStr,
}

pub type HostFn = unsafe extern "C" fn(user: *mut c_void, op: ReStr, args: *const ReStr, argc: u32, out: *mut ReJsValue);

pub struct JsCtx {
    global: RootedTraceableBox<Heap<*mut JSObject>>,
    host: HostFn,
    user: *mut c_void,
}

thread_local! {
    static RUNTIME: Cell<*mut Runtime> = const { Cell::new(ptr::null_mut()) };
    /// Host of the page whose script is running (scripts only run inside `re_js_eval`).
    static CURRENT: Cell<(Option<HostFn>, *mut c_void)> = const { Cell::new((None, ptr::null_mut())) };
    /// Backing store for the string returned from the last `re_js_eval`.
    static RESULT: RefCell<String> = const { RefCell::new(String::new()) };
}

fn runtime() -> Option<&'static mut Runtime> {
    let rt = RUNTIME.with(|r| r.get());
    if rt.is_null() {
        None
    } else {
        Some(unsafe { &mut *rt })
    }
}

/// Start SpiderMonkey on the calling (UI) thread. Idempotent.
#[no_mangle]
pub extern "C" fn re_js_init() -> bool {
    if runtime().is_some() {
        return true;
    }
    let engine = match JSEngine::init() {
        Ok(e) => Box::leak(Box::new(e)),
        Err(_) => return false,
    };
    let rt = Box::leak(Box::new(Runtime::new(engine.handle())));
    // Promise reactions go to SpiderMonkey's microtask queue; this JobQueue
    // drains it whenever we call RunJobs (after every script/event/timer).
    unsafe {
        let traps = mozjs::glue::JobQueueTraps {
            getHostDefinedData: Some(job_host_defined_data),
            getHostDefinedGlobal: Some(job_host_defined_global),
            runJobs: Some(job_run),
            traceNonGCThingMicroTask: Some(job_trace),
        };
        let queue = mozjs::glue::CreateJobQueue(&traps);
        SetJobQueue(rt.cx(), queue as *mut mozjs::jsapi::JobQueue);
    }
    RUNTIME.with(|r| r.set(rt));
    true
}

/// A fresh global (realm) for one page, with `__host` installed.
#[no_mangle]
pub unsafe extern "C" fn re_js_ctx_new(host: HostFn, user: *mut c_void) -> *mut JsCtx {
    let Some(rt) = runtime() else { return ptr::null_mut() };
    let cx = rt.cx();
    let options = RealmOptions::default();
    rooted!(&in(cx) let global = JS_NewGlobalObject(
        cx,
        &SIMPLE_GLOBAL_CLASS,
        ptr::null_mut(),
        OnNewGlobalHookOption::FireOnNewGlobalHook,
        &*options,
    ));
    if global.get().is_null() {
        return ptr::null_mut();
    }
    {
        let mut realm = AutoRealm::new_from_handle(cx, global.handle());
        let (gh, realm) = realm.global_and_reborrow();
        JS_DefineFunction(realm, gh, c"__host".as_ptr(), Some(host_native), 0, 0);
    }
    let root = RootedTraceableBox::from_box(Heap::boxed(global.get()));
    Box::into_raw(Box::new(JsCtx { global: root, host, user }))
}

#[no_mangle]
pub unsafe extern "C" fn re_js_ctx_free(ctx: *mut JsCtx) {
    if !ctx.is_null() {
        drop(Box::from_raw(ctx));
    }
}

/// Evaluate a classic script in the page's global, then drain the promise job
/// queue. On success the completion value is written to `out` (strings stay
/// valid until the next call); on an uncaught exception the host receives an
/// `"error"` op with the message and false is returned.
#[no_mangle]
pub unsafe extern "C" fn re_js_eval(ctx: *mut JsCtx, src: *const u8, len: usize, name: *const c_char, line: u32, out: *mut ReJsValue) -> bool {
    let Some(rt) = runtime() else { return false };
    if ctx.is_null() {
        return false;
    }
    let ctx = &*ctx;
    let prev = CURRENT.with(|c| c.replace((Some(ctx.host), ctx.user)));
    let source = String::from_utf8_lossy(std::slice::from_raw_parts(src, len)).into_owned();
    let filename = if name.is_null() { c"script".to_owned() } else { CStr::from_ptr(name).to_owned() };

    let cx = rt.cx();
    let global = NonNull::new(ctx.global.get()).unwrap();
    let mut realm = AutoRealm::new(cx, global);
    let (gh, realm) = realm.global_and_reborrow();
    rooted!(&in(realm) let mut rval = UndefinedValue());
    let options = CompileOptionsWrapper::new(realm, filename, line.max(1));
    let ok = evaluate_script(realm, gh, &source, rval.handle_mut(), options).is_ok();
    if ok {
        if !out.is_null() {
            write_value(realm, rval.handle(), &mut *out);
        }
    } else {
        report_exception(realm, ctx);
    }
    RunJobs(realm);
    CURRENT.with(|c| c.set(prev));
    ok
}

unsafe extern "C" fn job_host_defined_data(
    _cx: *mut RawJSContext,
    _incumbent: mozjs::jsapi::MutableHandleObject,
    _data: mozjs::jsapi::MutableHandleObject,
) -> bool {
    true
}

unsafe extern "C" fn job_host_defined_global(_cx: *mut RawJSContext, _data: mozjs::jsapi::MutableHandleObject) -> bool {
    true
}

unsafe extern "C" fn job_trace(_trc: *mut mozjs::jsapi::JSTracer, _v: *mut Value) {}

unsafe extern "C" fn job_run(raw: *mut RawJSContext) {
    let mut cx = JSContext::from_ptr(NonNull::new(raw).unwrap());
    let mut budget = 100_000;
    while mozjs::jsapi::HasRegularMicroTasks(raw) && budget > 0 {
        budget -= 1;
        let task = mozjs::jsapi::DequeueNextRegularMicroTask(raw);
        if !mozjs::jsapi::IsJSMicroTask(&task) {
            continue;
        }
        rooted!(&in(cx) let job = mozjs::jsapi::ToUnwrappedJSMicroTask(&task));
        if job.get().is_null() {
            continue;
        }
        if !RunJSMicroTask(&mut cx, job.handle()) {
            let (host, user) = CURRENT.with(|c| c.get());
            report_pending(&mut cx, host, user);
        }
    }
}

unsafe fn report_exception(cx: &mut JSContext, ctx: &JsCtx) {
    report_pending(cx, Some(ctx.host), ctx.user);
}

unsafe fn report_pending(cx: &mut JSContext, host: Option<HostFn>, user: *mut c_void) {
    rooted!(&in(cx) let mut exc = UndefinedValue());
    if !JS_GetPendingException(cx, exc.handle_mut()) {
        return;
    }
    JS_ClearPendingException(cx);
    let mut msg = match String::from_jsval(cx, exc.handle(), ()) {
        Ok(ConversionResult::Success(s)) => s,
        _ => "uncaught exception".to_string(),
    };
    JS_ClearPendingException(cx);
    // Append the stack (where the error came from) when it's an Error object.
    if exc.get().is_object() {
        rooted!(&in(cx) let obj = exc.get().to_object());
        rooted!(&in(cx) let mut stack = UndefinedValue());
        if mozjs::rust::wrappers2::JS_GetProperty(cx, obj.handle(), c"stack".as_ptr(), stack.handle_mut()) && stack.get().is_string() {
            if let Ok(ConversionResult::Success(st)) = String::from_jsval(cx, stack.handle(), ()) {
                msg.push('\n');
                msg.push_str(&st);
            }
        }
        JS_ClearPendingException(cx);
    }
    let Some(host) = host else { return };
    let args = [ReStr::of(&msg)];
    let mut out = ReJsValue { tag: 0, num: 0.0, str_: ReStr { ptr: ptr::null(), len: 0 } };
    host(user, ReStr::of("error"), args.as_ptr(), 1, &mut out);
}

unsafe fn write_value(cx: &mut JSContext, v: Handle<Value>, out: &mut ReJsValue) {
    let val = v.get();
    out.str_ = ReStr { ptr: ptr::null(), len: 0 };
    if val.is_undefined() {
        out.tag = 0;
    } else if val.is_null() {
        out.tag = 1;
    } else if val.is_boolean() {
        out.tag = 2;
        out.num = if val.to_boolean() { 1.0 } else { 0.0 };
    } else if val.is_number() {
        out.tag = 3;
        out.num = val.to_number();
    } else {
        out.tag = 4;
        let s = match String::from_jsval(cx, v, ()) {
            Ok(ConversionResult::Success(s)) => s,
            _ => String::new(),
        };
        JS_ClearPendingException(cx);
        RESULT.with(|r| {
            *r.borrow_mut() = s;
            let b = r.borrow();
            out.str_ = ReStr { ptr: b.as_ptr(), len: b.len() };
        });
    }
}

unsafe extern "C" fn host_native(raw: *mut RawJSContext, argc: u32, vp: *mut Value) -> bool {
    let mut cx = JSContext::from_ptr(NonNull::new(raw).unwrap());
    let args = CallArgs::from_vp(vp, argc);
    let (host, user) = CURRENT.with(|c| c.get());
    let Some(host) = host else {
        args.rval().set(UndefinedValue());
        return true;
    };
    let mut strings: Vec<String> = Vec::with_capacity(argc as usize);
    for i in 0..argc {
        let h = Handle::from_raw(args.get(i));
        let v = h.get();
        let s = if v.is_null_or_undefined() {
            String::new()
        } else {
            match String::from_jsval(&mut cx, h, ()) {
                Ok(ConversionResult::Success(s)) => s,
                _ => return false,
            }
        };
        strings.push(s);
    }
    if strings.is_empty() {
        args.rval().set(UndefinedValue());
        return true;
    }
    let refs: Vec<ReStr> = strings[1..].iter().map(|s| ReStr::of(s)).collect();
    let mut out = ReJsValue { tag: 0, num: 0.0, str_: ReStr { ptr: ptr::null(), len: 0 } };
    host(user, ReStr::of(&strings[0]), refs.as_ptr(), refs.len() as u32, &mut out);
    match out.tag {
        1 => args.rval().set(NullValue()),
        2 => args.rval().set(BooleanValue(out.num != 0.0)),
        3 => args.rval().set(DoubleValue(out.num)),
        4 => {
            let s = out.str_.as_str().to_owned();
            rooted!(&in(cx) let mut v = UndefinedValue());
            s.to_jsval(&mut cx, v.handle_mut());
            args.rval().set(v.get());
        }
        _ => args.rval().set(UndefinedValue()),
    }
    true
}

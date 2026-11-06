//! Page scripting: one SpiderMonkey global per document.
//!
//! The JS side (dom.js) talks to us through `__host(op, ...args)`; every
//! operation is implemented here against the tab's mutable DOM. Timers, network
//! requests and navigation are queued and driven by the app's event loop, so
//! scripts never block on I/O and never navigate from inside a script.

const std = @import("std");
const builtin = @import("builtin");
const ffi = @import("../engine/ffi.zig");
const dom = @import("../engine/dom.zig");
const cascade = @import("../engine/cascade.zig");
const layout = @import("../engine/layout.zig");
const net = @import("net.zig");
const urlz = @import("url.zig");

const prelude = @embedFile("dom.js");

/// Set once by the app: where async fetch results are delivered.
pub var fetch_notify: ?net.FetchNotify = null;

var engine_ready: ?bool = null;

/// Start SpiderMonkey (once, on the UI thread). False if it failed to start.
pub fn engineAvailable() bool {
    if (engine_ready == null) engine_ready = ffi.re_js_init();
    return engine_ready.?;
}

/// Bit set in request ids that load a <script src> rather than serve fetch().
const script_bit: u32 = 0x8000_0000;

pub const Request = union(enum) {
    navigate: struct { url: []u8, replace: bool },
    open: []u8,
    history: i32,
};

const Timer = struct { id: u32, due: i64 };
const Body = struct { body: []u8 };

pub const Script = struct {
    a: std.mem.Allocator,
    ctx: *ffi.JsCtx,
    doc: *dom.Document,
    tab_id: u32,
    generation: u32,
    /// Document URL (pushState/replaceState change it without a load).
    url: []u8,
    base: []u8,
    /// Scratch for strings returned to JS (copied by the bridge immediately).
    out: std.ArrayListUnmanaged(u8) = .{},
    scratch: std.heap.ArenaAllocator,
    timers: std.ArrayListUnmanaged(Timer) = .{},
    bodies: std.AutoHashMapUnmanaged(u32, []u8) = .{},
    /// Script elements already executed (or queued) — run each only once.
    ran: std.AutoHashMapUnmanaged(u32, void) = .{},
    current_script: u32 = dom.none,
    requests: std.ArrayListUnmanaged(Request) = .{},
    title: ?[]u8 = null,
    url_changed: bool = false,
    in_flight: u32 = 0,
    next_req: u32 = 1,
    /// For getBoundingClientRect / innerWidth; refreshed by the tab after layout.
    page: ?*const layout.Page = null,
    viewport: [3]f32 = .{ 1280, 800, 2 },
    errors: u32 = 0,

    pub fn create(a: std.mem.Allocator, doc: *dom.Document, url: []const u8, base: []const u8, tab_id: u32, generation: u32) !*Script {
        if (!engineAvailable()) return error.JsUnavailable;
        const self = try a.create(Script);
        errdefer a.destroy(self);
        self.* = .{
            .a = a,
            .ctx = undefined,
            .doc = doc,
            .tab_id = tab_id,
            .generation = generation,
            .url = try a.dupe(u8, url),
            .base = try a.dupe(u8, base),
            .scratch = std.heap.ArenaAllocator.init(a),
        };
        self.ctx = ffi.re_js_ctx_new(&host, self) orelse return error.JsContext;
        return self;
    }

    pub fn destroy(self: *Script) void {
        const a = self.a;
        ffi.re_js_ctx_free(self.ctx);
        var it = self.bodies.valueIterator();
        while (it.next()) |b| a.free(b.*);
        self.bodies.deinit(a);
        self.ran.deinit(a);
        self.timers.deinit(a);
        for (self.requests.items) |r| freeRequest(a, r);
        self.requests.deinit(a);
        self.out.deinit(a);
        self.scratch.deinit();
        if (self.title) |t| a.free(t);
        a.free(self.url);
        a.free(self.base);
        a.destroy(self);
    }

    fn freeRequest(a: std.mem.Allocator, r: Request) void {
        switch (r) {
            .navigate => |n| a.free(n.url),
            .open => |u| a.free(u),
            .history => {},
        }
    }

    // ---- running code ---------------------------------------------------------------

    pub fn eval(self: *Script, src: []const u8, name: []const u8) bool {
        return self.evalValue(src, name, null);
    }

    fn evalValue(self: *Script, src: []const u8, name: []const u8, out: ?*ffi.JsValue) bool {
        var buf: [512]u8 = undefined;
        const n = std.fmt.bufPrintZ(&buf, "{s}", .{name[0..@min(name.len, 500)]}) catch "script";
        return ffi.re_js_eval(self.ctx, src.ptr, src.len, n.ptr, 1, out);
    }

    fn call(self: *Script, comptime fmt: []const u8, args: anytype) ffi.JsValue {
        var buf: [256]u8 = undefined;
        const src = std.fmt.bufPrint(&buf, fmt, args) catch return .{};
        var v = ffi.JsValue{};
        _ = self.evalValue(src, "redbrowser", &v);
        return v;
    }

    /// Install the DOM bindings, run the page's scripts in order and fire the
    /// DOMContentLoaded / load events.
    pub fn start(self: *Script) void {
        if (!self.eval(prelude, "redbrowser:dom.js")) {
            std.log.err("js: DOM prelude failed; scripts disabled for this page", .{});
            return;
        }
        // Parser-inserted scripts, in document order.
        var list = std.ArrayList(u32).init(self.a);
        defer list.deinit();
        collectScripts(self.doc, 0, &list, 0) catch {};
        for (list.items) |id| {
            if (self.ran.contains(id) or !self.doc.isConnected(id)) continue;
            self.ran.put(self.a, id, {}) catch {};
            const node = self.doc.get(id);
            if (node.attr("src")) |src| {
                if (self.doc.ext_js.get(id)) |code| {
                    self.runScript(id, code, src);
                    _ = self.call("__scriptDone({d}, true)", .{id});
                } else {
                    _ = self.call("__scriptDone({d}, false)", .{id});
                }
            } else {
                const code = self.doc.textContent(self.a, id) catch continue;
                defer self.a.free(code);
                self.runScript(id, code, self.url);
            }
        }
        _ = self.call("__setReadyState('interactive')", .{});
        _ = self.call("__setReadyState('complete')", .{});
    }

    fn collectScripts(doc: *const dom.Document, i: u32, out: *std.ArrayList(u32), depth: u32) !void {
        if (depth > 512) return;
        const n = doc.get(i);
        if (n.kind == .element and n.is("template")) return;
        if (dom.isClassicScript(n)) try out.append(i);
        var it = doc.children(i);
        while (it.next()) |c| try collectScripts(doc, c, out, depth + 1);
    }

    fn runScript(self: *Script, id: u32, code: []const u8, name: []const u8) void {
        const prev = self.current_script;
        self.current_script = id;
        defer self.current_script = prev;
        if (!self.eval(code, name)) self.errors += 1;
    }

    // ---- event loop hooks ----------------------------------------------------------------

    /// Run timers that are due. Returns the time of the next one (or null).
    pub fn fireTimers(self: *Script, now: i64) ?i64 {
        var budget: u32 = 64;
        while (budget > 0) : (budget -= 1) {
            var best: ?usize = null;
            for (self.timers.items, 0..) |t, i| {
                if (t.due <= now and (best == null or t.due < self.timers.items[best.?].due)) best = i;
            }
            const i = best orelse break;
            const t = self.timers.swapRemove(i);
            _ = self.call("__fireTimer({d})", .{t.id});
        }
        var next: ?i64 = null;
        for (self.timers.items) |t| next = if (next) |n| @min(n, t.due) else t.due;
        return next;
    }

    pub fn onFetch(self: *Script, res: *net.FetchResult) void {
        if (self.in_flight > 0) self.in_flight -= 1;
        if (res.req_id & script_bit != 0) {
            const id = res.req_id & ~script_bit;
            if (res.ok and self.doc.valid(id)) {
                self.runScript(id, res.body, res.url);
                _ = self.call("__scriptDone({d}, true)", .{id});
            } else {
                _ = self.call("__scriptDone({d}, false)", .{id});
            }
            return;
        }
        const body = self.a.dupe(u8, res.body) catch return;
        if (self.bodies.fetchPut(self.a, res.req_id, body) catch null) |old| self.a.free(old.value);
        var esc = std.ArrayList(u8).init(self.a);
        defer esc.deinit();
        jsString(esc.writer(), res.url) catch return;
        var esc_type = std.ArrayList(u8).init(self.a);
        defer esc_type.deinit();
        jsString(esc_type.writer(), res.content_type) catch return;
        const src = std.fmt.allocPrint(self.a, "__fetchDone({d}, {}, {d}, {s}, {s})", .{ res.req_id, res.ok, res.status, esc.items, esc_type.items }) catch return;
        defer self.a.free(src);
        _ = self.eval(src, "redbrowser:fetch");
        if (self.bodies.fetchRemove(res.req_id)) |kv| self.a.free(kv.value);
    }

    /// Dispatch a click on `node`; false when a handler called preventDefault().
    pub fn click(self: *Script, node: u32, x: f32, y: f32, mods: u32) bool {
        const v = self.call("__click({d}, {d}, {d}, {d})", .{ node, @as(i32, @intFromFloat(x)), @as(i32, @intFromFloat(y)), mods });
        return !(v.tag == .boolean and v.num == 0);
    }

    /// Run a `javascript:` URL.
    pub fn runUrl(self: *Script, code: []const u8) void {
        const decoded = self.a.dupe(u8, code) catch return;
        defer self.a.free(decoded);
        _ = self.eval(std.Uri.percentDecodeInPlace(decoded), "javascript:");
    }

    pub fn takeRequests(self: *Script) []Request {
        const r = self.requests.toOwnedSlice(self.a) catch return &.{};
        return r;
    }

    pub fn busy(self: *const Script) bool {
        return self.in_flight > 0;
    }

    // ---- __host ------------------------------------------------------------------------------

    const Op = enum {
        kind, name, parent, first, last, next, prev, connected, contains, before,
        getAttr, setAttr, removeAttr, attrs, text, setText,
        create, createText, createComment, createFragment, insert, remove, clone,
        html, setHtml, byId, query, matches, rect, computed,
        timer, clearTimer, fetch, takeBody, loadScript, evalScript, currentScript,
        location, navigate, setUrl, history, open, submit, resolve, resolveAgainst,
        title, write, log, @"error", media, viewport, userAgent, platform, defined, traceDom,
    };

    fn host(user: ?*anyopaque, op_s: ffi.Str, argv: [*]const ffi.Str, argc: u32, out: *ffi.JsValue) callconv(.C) void {
        const self: *Script = @ptrCast(@alignCast(user.?));
        _ = self.scratch.reset(.retain_capacity);
        self.out.clearRetainingCapacity();
        const op = std.meta.stringToEnum(Op, op_s.slice()) orelse return;
        var args: [8][]const u8 = .{""} ** 8;
        for (0..@min(argc, 8)) |i| args[i] = argv[i].slice();
        self.dispatch(op, args[0..@min(argc, 8)], out) catch |err| {
            std.log.debug("js host {s}: {}", .{ @tagName(op), err });
            out.* = .{};
        };
    }

    fn arg(args: []const []const u8, i: usize) []const u8 {
        return if (i < args.len) args[i] else "";
    }

    fn nodeArg(self: *Script, args: []const []const u8, i: usize) ?u32 {
        const s = arg(args, i);
        if (s.len == 0) return null;
        const f = std.fmt.parseFloat(f64, s) catch return null;
        if (f < 0 or f >= @as(f64, @floatFromInt(self.doc.nodes.len))) return null;
        return @intFromFloat(f);
    }

    fn retNode(out: *ffi.JsValue, id: u32) void {
        out.* = if (id == dom.none) .{ .tag = .null } else .{ .tag = .number, .num = @floatFromInt(id) };
    }
    fn retStr(self: *Script, out: *ffi.JsValue, s: []const u8) void {
        self.out.clearRetainingCapacity();
        self.out.appendSlice(self.a, s) catch {};
        out.* = .{ .tag = .string, .str = ffi.Str.of(self.out.items) };
    }
    fn retBool(out: *ffi.JsValue, b: bool) void {
        out.* = .{ .tag = .boolean, .num = if (b) 1 else 0 };
    }
    fn retNum(out: *ffi.JsValue, n: f64) void {
        out.* = .{ .tag = .number, .num = n };
    }

    fn dispatch(self: *Script, op: Op, args: []const []const u8, out: *ffi.JsValue) !void {
        const doc = self.doc;
        const tmp = self.scratch.allocator();
        switch (op) {
            .kind => {
                const id = self.nodeArg(args, 0) orelse return;
                retNum(out, switch (doc.get(id).kind) {
                    .document => 9,
                    .element => 1,
                    .text => 3,
                    .comment => 8,
                    else => 11,
                });
            },
            .name => {
                const id = self.nodeArg(args, 0) orelse return;
                self.retStr(out, doc.get(id).name);
            },
            .parent => retNode(out, doc.get(self.nodeArg(args, 0) orelse return).parent),
            .first => retNode(out, doc.get(self.nodeArg(args, 0) orelse return).first_child),
            .next => retNode(out, doc.get(self.nodeArg(args, 0) orelse return).next_sibling),
            .last => retNode(out, doc.lastChild(self.nodeArg(args, 0) orelse return)),
            .prev => retNode(out, doc.prevSibling(self.nodeArg(args, 0) orelse return)),
            .connected => retBool(out, doc.isConnected(self.nodeArg(args, 0) orelse return)),
            .contains => retBool(out, doc.contains(self.nodeArg(args, 0) orelse return, self.nodeArg(args, 1) orelse return)),
            .before => {
                const a = self.nodeArg(args, 0) orelse return;
                const b = self.nodeArg(args, 1) orelse return;
                retBool(out, precedes(doc, a, b));
            },
            .getAttr => {
                const id = self.nodeArg(args, 0) orelse return;
                if (doc.get(id).attr(arg(args, 1))) |v| self.retStr(out, v) else out.* = .{ .tag = .null };
            },
            .setAttr => try doc.setAttr(self.nodeArg(args, 0) orelse return, arg(args, 1), arg(args, 2)),
            .removeAttr => doc.removeAttr(self.nodeArg(args, 0) orelse return, arg(args, 1)),
            .attrs => {
                const id = self.nodeArg(args, 0) orelse return;
                var w = std.ArrayList(u8).init(tmp);
                try w.append('[');
                for (doc.get(id).attrs, 0..) |at, i| {
                    if (i > 0) try w.append(',');
                    try w.append('[');
                    try jsString(w.writer(), at.name);
                    try w.append(',');
                    try jsString(w.writer(), at.value);
                    try w.append(']');
                }
                try w.append(']');
                self.retStr(out, w.items);
            },
            .text => {
                const id = self.nodeArg(args, 0) orelse return;
                const n = doc.get(id);
                if (n.kind == .text or n.kind == .comment) return self.retStr(out, n.text);
                self.retStr(out, try doc.textContent(tmp, id));
            },
            .setText => try doc.setText(self.nodeArg(args, 0) orelse return, arg(args, 1)),
            .create => retNode(out, try doc.createElement(if (arg(args, 0).len > 0) arg(args, 0) else "div")),
            .createText => retNode(out, try doc.createText(arg(args, 0), .text)),
            .createComment => retNode(out, try doc.createText(arg(args, 0), .comment)),
            .createFragment => retNode(out, try doc.createFragment()),
            .insert => {
                const parent = self.nodeArg(args, 0) orelse return retBool(out, false);
                const child = self.nodeArg(args, 1) orelse return retBool(out, false);
                const ref = self.nodeArg(args, 2) orelse dom.none;
                doc.insertBefore(parent, child, ref) catch return retBool(out, false);
                retBool(out, true);
            },
            .remove => doc.detach(self.nodeArg(args, 0) orelse return),
            .clone => retNode(out, try doc.clone(self.nodeArg(args, 0) orelse return, std.mem.eql(u8, arg(args, 1), "1"))),
            .html => {
                const id = self.nodeArg(args, 0) orelse return;
                var w = std.ArrayList(u8).init(tmp);
                try doc.serialize(w.writer(), id, std.mem.eql(u8, arg(args, 1), "1"));
                self.retStr(out, w.items);
            },
            .setHtml => try doc.setInnerHtml(self.nodeArg(args, 0) orelse return, arg(args, 1)),
            .byId => retNode(out, doc.byId(arg(args, 0)) orelse dom.none),
            .query => {
                const root = self.nodeArg(args, 0) orelse 0;
                var list = std.ArrayList(u32).init(tmp);
                cascade.select(tmp, doc, root, arg(args, 1), std.mem.eql(u8, arg(args, 2), "1"), &list) catch |err| switch (err) {
                    error.SyntaxError => return self.retStr(out, "!"),
                    else => return err,
                };
                if (list.items.len == 0) return self.retStr(out, "");
                var w = std.ArrayList(u8).init(tmp);
                for (list.items, 0..) |id, i| {
                    if (i > 0) try w.append(',');
                    try w.writer().print("{d}", .{id});
                }
                self.retStr(out, w.items);
            },
            .matches => {
                const id = self.nodeArg(args, 0) orelse return retBool(out, false);
                const m = cascade.matches(tmp, doc, id, arg(args, 1)) catch |err| switch (err) {
                    error.SyntaxError => return self.retStr(out, "!"),
                    else => return err,
                };
                retBool(out, m);
            },
            .rect => {
                const id = self.nodeArg(args, 0) orelse return;
                const page = self.page orelse return;
                if (page.boxOf(id)) |r| {
                    const s = try std.fmt.allocPrint(tmp, "{d},{d},{d},{d}", .{ r[0], r[1], r[2], r[3] });
                    self.retStr(out, s);
                }
            },
            .computed => {
                // Only `display` is answered; enough for visibility checks.
                const id = self.nodeArg(args, 0) orelse return;
                if (std.mem.eql(u8, arg(args, 1), "display")) {
                    const page = self.page;
                    const shown = if (page) |p| p.boxOf(id) != null else true;
                    self.retStr(out, if (shown) "block" else "none");
                }
            },
            .timer => {
                const id = std.fmt.parseInt(u32, arg(args, 0), 10) catch return;
                const ms = std.fmt.parseFloat(f64, arg(args, 1)) catch 0;
                const due = std.time.milliTimestamp() + @as(i64, @intFromFloat(@min(@max(ms, 0), 1e9)));
                for (self.timers.items) |*t| if (t.id == id) {
                    t.due = due;
                    return;
                };
                try self.timers.append(self.a, .{ .id = id, .due = due });
            },
            .clearTimer => {
                const id = std.fmt.parseInt(u32, arg(args, 0), 10) catch return;
                for (self.timers.items, 0..) |t, i| if (t.id == id) {
                    _ = self.timers.swapRemove(i);
                    return;
                };
            },
            .fetch => {
                const id = std.fmt.parseInt(u32, arg(args, 0), 10) catch return;
                try self.startFetch(id, arg(args, 1), arg(args, 2), arg(args, 3), arg(args, 4));
            },
            .takeBody => {
                const id = std.fmt.parseInt(u32, arg(args, 0), 10) catch return;
                if (self.bodies.get(id)) |b| self.retStr(out, b);
            },
            .loadScript => {
                const id = self.nodeArg(args, 0) orelse return;
                if (self.ran.contains(id)) return;
                try self.ran.put(self.a, id, {});
                const url = arg(args, 1);
                if (url.len == 0) return;
                try self.startFetch(id | script_bit, url, "GET", "", "");
            },
            .evalScript => {
                const id = self.nodeArg(args, 0) orelse return;
                if (self.ran.contains(id)) return;
                try self.ran.put(self.a, id, {});
                const code = try doc.textContent(self.a, id);
                defer self.a.free(code);
                self.runScript(id, code, self.url);
            },
            .currentScript => retNode(out, self.current_script),
            .location => self.retStr(out, self.url),
            .navigate => {
                const url = try self.a.dupe(u8, arg(args, 0));
                try self.requests.append(self.a, .{ .navigate = .{ .url = url, .replace = std.mem.eql(u8, arg(args, 1), "1") } });
            },
            .setUrl => {
                const u = try self.a.dupe(u8, arg(args, 0));
                self.a.free(self.url);
                self.url = u;
                self.url_changed = true;
            },
            .history => {
                const n = std.fmt.parseInt(i32, arg(args, 0), 10) catch 0;
                if (n != 0) try self.requests.append(self.a, .{ .history = n });
            },
            .open => try self.requests.append(self.a, .{ .open = try self.a.dupe(u8, arg(args, 0)) }),
            .submit => try self.submitForm(self.nodeArg(args, 0) orelse return),
            .resolve => self.retStr(out, try urlz.resolve(tmp, self.base, arg(args, 0))),
            .resolveAgainst => {
                const base = if (arg(args, 0).len > 0) arg(args, 0) else self.base;
                const r = urlz.resolve(tmp, base, arg(args, 1)) catch return;
                if (urlz.scheme(r) == null) return;
                self.retStr(out, r);
            },
            .title => {
                if (self.title) |t| self.a.free(t);
                self.title = try self.a.dupe(u8, arg(args, 0));
            },
            .write => try self.documentWrite(arg(args, 0)),
            .log => {
                const level = arg(args, 0);
                const msg = arg(args, 1);
                if (std.mem.eql(u8, level, "error") or std.mem.eql(u8, level, "warn")) {
                    std.log.info("console.{s}: {s}", .{ level, msg[0..@min(msg.len, 400)] });
                } else std.log.debug("console.{s}: {s}", .{ level, msg[0..@min(msg.len, 400)] });
            },
            .@"error" => {
                self.errors += 1;
                const msg = arg(args, 0);
                std.log.info("js error: {s}", .{msg[0..@min(msg.len, 600)]});
            },
            .media => {
                const q = try std.ascii.allocLowerString(tmp, arg(args, 0));
                retBool(out, cascade.mediaMatches(q, self.viewport[0], self.viewport[1]));
            },
            .viewport => {
                const i = std.fmt.parseInt(usize, arg(args, 0), 10) catch 0;
                retNum(out, self.viewport[@min(i, 2)]);
            },
            .userAgent => self.retStr(out, net.user_agent),
            .platform => self.retStr(out, switch (builtin.os.tag) {
                .macos => "MacIntel",
                .windows => "Win32",
                else => "Linux x86_64",
            }),
            .defined => {},
            .traceDom => retBool(out, std.posix.getenv("REDBROWSER_TRACE_DOM") != null),
        }
    }

    fn startFetch(self: *Script, id: u32, url: []const u8, method: []const u8, body: []const u8, ct: []const u8) !void {
        const notify = fetch_notify orelse return error.NoFetch;
        const abs = try urlz.resolve(self.scratch.allocator(), self.base, url);
        try net.fetchAsync(self.a, .{ .url = abs, .method = method, .body = body, .content_type = ct, .tab_id = self.tab_id, .generation = self.generation, .req_id = id }, notify);
        self.in_flight += 1;
    }

    fn documentWrite(self: *Script, html: []const u8) !void {
        const doc = self.doc;
        const cs = self.current_script;
        if (cs != dom.none and doc.get(cs).parent != dom.none) {
            try doc.insertHtml(doc.get(cs).parent, doc.get(cs).next_sibling, html);
        } else if (doc.find("body")) |b| {
            try doc.insertHtml(b, dom.none, html);
        }
    }

    /// GET form submission: build the query string from named controls.
    fn submitForm(self: *Script, form: u32) !void {
        const doc = self.doc;
        const tmp = self.scratch.allocator();
        var q = std.ArrayList(u8).init(tmp);
        var list = std.ArrayList(u32).init(tmp);
        cascade.select(tmp, doc, form, "input[name],select[name],textarea[name]", false, &list) catch {};
        for (list.items) |id| {
            const n = doc.get(id);
            if (n.attr("disabled") != null) continue;
            const ty = n.attr("type") orelse "";
            if ((std.ascii.eqlIgnoreCase(ty, "checkbox") or std.ascii.eqlIgnoreCase(ty, "radio")) and n.attr("checked") == null) continue;
            if (std.ascii.eqlIgnoreCase(ty, "submit") or std.ascii.eqlIgnoreCase(ty, "button")) continue;
            const value = n.attr("value") orelse (if (n.is("textarea")) try doc.textContent(tmp, id) else "");
            if (q.items.len > 0) try q.append('&');
            try formEncode(q.writer(), n.attr("name").?);
            try q.append('=');
            try formEncode(q.writer(), value);
        }
        const action = doc.get(form).attr("action") orelse "";
        const target = try urlz.resolve(tmp, self.base, action);
        const no_query = if (std.mem.indexOfAny(u8, target, "?#")) |i| target[0..i] else target;
        const url = try std.fmt.allocPrint(self.a, "{s}?{s}", .{ no_query, q.items });
        try self.requests.append(self.a, .{ .navigate = .{ .url = url, .replace = false } });
    }
};

fn formEncode(w: anytype, s: []const u8) !void {
    for (s) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.' or ch == '*') {
            try w.writeByte(ch);
        } else if (ch == ' ') {
            try w.writeByte('+');
        } else try w.print("%{X:0>2}", .{ch});
    }
}

/// Write `s` as a JS/JSON string literal.
pub fn jsString(w: anytype, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |ch| switch (ch) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        0...8, 11, 12, 14...0x1f => try w.print("\\u{x:0>4}", .{ch}),
        else => try w.writeByte(ch),
    };
    try w.writeByte('"');
}

/// Document order: does `a` come before `b`?
fn precedes(doc: *const dom.Document, a: u32, b: u32) bool {
    var path_a: [512]u32 = undefined;
    var path_b: [512]u32 = undefined;
    const la = ancestors(doc, a, &path_a);
    const lb = ancestors(doc, b, &path_b);
    // walk down from the root while the paths agree
    var i: usize = 1;
    while (i <= la and i <= lb and path_a[la - i] == path_b[lb - i]) i += 1;
    if (i == 1) return a < b; // different trees (detached): any stable order
    if (i > la) return true; // a is an ancestor of b
    if (i > lb) return false;
    const ca = path_a[la - i];
    const cb = path_b[lb - i];
    var c = doc.get(path_a[la - i + 1]).first_child;
    while (c != dom.none) : (c = doc.get(c).next_sibling) {
        if (c == ca) return true;
        if (c == cb) return false;
    }
    return false;
}

fn ancestors(doc: *const dom.Document, i: u32, out: *[512]u32) usize {
    var n: usize = 0;
    var cur = i;
    while (cur != dom.none and n < out.len) : (cur = doc.get(cur).parent) {
        out[n] = cur;
        n += 1;
    }
    return n;
}

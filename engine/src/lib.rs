//! redengine — thin C ABI between RedBrowser (Zig) and Mozilla/Servo engine crates.
//!
//! * Rendering: WebRender (Firefox's GPU renderer). Zig issues draw primitives
//!   (rects, rounded rects, borders, shadows, text, clips) in logical pixels;
//!   this crate turns them into a WebRender display list and renders a frame
//!   into the GL context that Zig/SDL owns.
//! * Parsing: html5ever (Servo's spec-compliant HTML5 parser). The DOM is
//!   flattened into an index-addressed array that Zig walks for style + layout.
//!
//! Everything browser-shaped (UI, layout, networking, tabs, input) lives in Zig.
//! Keep this file a bridge: no browser logic here.

mod js;

use std::collections::HashMap;
use std::ffi::{c_char, c_void, CStr};
use std::rc::Rc;
use std::sync::{Arc, Condvar, Mutex};
use std::time::Duration;

use gleam::gl;
use html5ever::tendril::TendrilSink;
use markup5ever_rcdom::{Handle, NodeData, RcDom};
use webrender::api::units::*;
use webrender::api::*;
use webrender::{create_webrender_instance, RenderApi, Renderer, Transaction, WebRenderOptions};

// ---------------------------------------------------------------------------
// Frame notifier: lets `re_end_frame` block until WebRender has built a frame.
// ---------------------------------------------------------------------------

#[derive(Clone)]
struct Notifier {
    ready: Arc<(Mutex<bool>, Condvar)>,
}

impl RenderNotifier for Notifier {
    fn clone(&self) -> Box<dyn RenderNotifier> {
        Box::new(Clone::clone(self))
    }
    fn wake_up(&self, _composite_needed: bool) {
        self.signal();
    }
    fn new_frame_ready(&self, _: DocumentId, _: FramePublishId, _: &FrameReadyParams) {
        self.signal();
    }
}

impl Notifier {
    fn signal(&self) {
        let (lock, cv) = &*self.ready;
        *lock.lock().unwrap() = true;
        cv.notify_all();
    }
    fn wait(&self, timeout: Duration) {
        let (lock, cv) = &*self.ready;
        let mut ready = lock.lock().unwrap();
        if !*ready {
            ready = cv.wait_timeout(ready, timeout).unwrap().0;
        }
        *ready = false;
    }
}

// ---------------------------------------------------------------------------
// Engine
// ---------------------------------------------------------------------------

struct Font {
    bytes: Arc<Vec<u8>>,
    index: u32,
    key: FontKey,
    units_per_em: f32,
    ascender: f32,
    descender: f32,
    line_gap: f32,
}

pub struct Engine {
    renderer: Option<Renderer>,
    api: RenderApi,
    document: DocumentId,
    pipeline: PipelineId,
    notifier: Notifier,
    epoch: u32,
    frame_id: u64,
    device_w: i32,
    device_h: i32,
    scale: f32,
    builder: Option<DisplayListBuilder>,
    clip_stack: Vec<(ClipChainId, LayoutRect)>,
    txn: Transaction,
    fonts: Vec<Font>,
    /// Fonts searched (in order) for characters the requested font lacks.
    fallbacks: Vec<u32>,
    images: Vec<Option<ImageKey>>,
    instances: HashMap<(u32, u32), FontInstanceKey>,
}

pub type GetProcAddress = extern "C" fn(name: *const c_char) -> *const c_void;

#[repr(C)]
#[derive(Clone, Copy)]
pub struct ReColor {
    pub r: f32,
    pub g: f32,
    pub b: f32,
    pub a: f32,
}

/// WebRender asserts that every channel is in 0..=1 (and panics on its scene
/// builder thread otherwise), so sanitise whatever the Zig side computed.
fn unit(v: f32) -> f32 {
    if v.is_nan() { 0.0 } else { v.clamp(0.0, 1.0) }
}

impl From<ReColor> for ColorF {
    fn from(c: ReColor) -> Self {
        ColorF::new(unit(c.r), unit(c.g), unit(c.b), unit(c.a))
    }
}

impl Engine {
    fn rect(&self, x: f32, y: f32, w: f32, h: f32) -> LayoutRect {
        let s = self.scale;
        LayoutRect::from_origin_and_size(
            LayoutPoint::new(x * s, y * s),
            LayoutSize::new(w.max(0.0) * s, h.max(0.0) * s),
        )
    }

    fn common(&self, bounds: LayoutRect) -> CommonItemProperties {
        let (clip_chain_id, _) = *self.clip_stack.last().unwrap();
        CommonItemProperties {
            clip_rect: bounds,
            clip_chain_id,
            spatial_id: SpatialId::root_scroll_node(self.pipeline),
            flags: PrimitiveFlags::default(),
        }
    }

    fn visible(&self, r: &LayoutRect) -> bool {
        let (_, clip) = self.clip_stack.last().unwrap();
        r.intersects(clip) || r.is_empty()
    }

    fn font_instance(&mut self, font: u32, size: f32) -> Option<FontInstanceKey> {
        let device_size = (size * self.scale * 4.0).round() as u32; // quarter-pixel buckets
        if let Some(k) = self.instances.get(&(font, device_size)) {
            return Some(*k);
        }
        let f = self.fonts.get(font as usize)?;
        let key = self.api.generate_font_instance_key();
        self.txn.add_font_instance(
            key,
            f.key,
            device_size as f32 / 4.0,
            None,
            None,
            Vec::new(),
        );
        self.instances.insert((font, device_size), key);
        Some(key)
    }
}

fn with_engine<R>(e: *mut Engine, default: R, f: impl FnOnce(&mut Engine) -> R) -> R {
    if e.is_null() {
        return default;
    }
    f(unsafe { &mut *e })
}

unsafe fn bytes<'a>(ptr: *const u8, len: usize) -> &'a [u8] {
    if ptr.is_null() || len == 0 {
        &[]
    } else {
        std::slice::from_raw_parts(ptr, len)
    }
}

/// Create a WebRender instance on the GL context that is current on this thread.
#[no_mangle]
pub extern "C" fn re_engine_new(
    get_proc: GetProcAddress,
    device_w: i32,
    device_h: i32,
    scale: f32,
) -> *mut Engine {
    let gl: Rc<dyn gl::Gl> = unsafe {
        gl::GlFns::load_with(|name| {
            let cname = std::ffi::CString::new(name).unwrap();
            get_proc(cname.as_ptr())
        })
    };

    let notifier = Notifier { ready: Arc::new((Mutex::new(false), Condvar::new())) };
    let opts = WebRenderOptions {
        // Transparent so the shell can draw a rounded window on a transparent surface.
        clear_color: ColorF::new(0.0, 0.0, 0.0, 0.0),
        ..WebRenderOptions::default()
    };
    let (renderer, sender) =
        match create_webrender_instance(gl, Box::new(Clone::clone(&notifier)), opts, None) {
            Ok(v) => v,
            Err(err) => {
                eprintln!("redengine: failed to create WebRender: {:?}", err);
                return std::ptr::null_mut();
            }
        };
    let api = sender.create_api();
    let document = api.add_document(DeviceIntSize::new(device_w, device_h));
    let pipeline = PipelineId(0, 0);

    let mut txn = Transaction::new();
    txn.set_root_pipeline(pipeline);
    txn.set_document_view(DeviceIntRect::from_size(DeviceIntSize::new(device_w, device_h)));

    Box::into_raw(Box::new(Engine {
        renderer: Some(renderer),
        api,
        document,
        pipeline,
        notifier,
        epoch: 0,
        frame_id: 0,
        device_w,
        device_h,
        scale,
        builder: None,
        clip_stack: Vec::new(),
        txn,
        fonts: Vec::new(),
        fallbacks: Vec::new(),
        images: Vec::new(),
        instances: HashMap::new(),
    }))
}

#[no_mangle]
pub extern "C" fn re_engine_free(e: *mut Engine) {
    if e.is_null() {
        return;
    }
    let mut engine = unsafe { Box::from_raw(e) };
    engine.api.shut_down(true);
    if let Some(r) = engine.renderer.take() {
        r.deinit();
    }
}

#[no_mangle]
pub extern "C" fn re_engine_resize(e: *mut Engine, device_w: i32, device_h: i32, scale: f32) {
    with_engine(e, (), |e| {
        e.device_w = device_w.max(1);
        e.device_h = device_h.max(1);
        if (e.scale - scale).abs() > f32::EPSILON {
            e.instances.clear(); // font instances are per device size
        }
        e.scale = scale;
        e.txn.set_document_view(DeviceIntRect::from_size(DeviceIntSize::new(
            e.device_w, e.device_h,
        )));
    })
}

/// Load a TrueType/OpenType font (or a face of a .ttc collection). Returns a font id, or -1.
#[no_mangle]
pub extern "C" fn re_font_load(e: *mut Engine, path: *const c_char, index: u32) -> i32 {
    with_engine(e, -1, |e| {
        if path.is_null() {
            return -1;
        }
        // WebRender's Core Text backend only accepts the first face of raw font data.
        if cfg!(target_os = "macos") && index != 0 {
            return -1;
        }
        let path = unsafe { CStr::from_ptr(path) }.to_string_lossy().into_owned();
        let data = match std::fs::read(&path) {
            Ok(d) => d,
            Err(_) => return -1,
        };
        let (upem, asc, desc, gap) = match ttf_parser::Face::parse(&data, index) {
            Ok(face) => (
                face.units_per_em() as f32,
                face.ascender() as f32,
                face.descender() as f32,
                face.line_gap() as f32,
            ),
            Err(_) => return -1,
        };
        let key = e.api.generate_font_key();
        e.txn.add_raw_font(key, data.clone(), index);
        e.fonts.push(Font {
            bytes: Arc::new(data),
            index,
            key,
            units_per_em: upem,
            ascender: asc,
            descender: desc,
            line_gap: gap,
        });
        (e.fonts.len() - 1) as i32
    })
}

#[repr(C)]
pub struct ReFontMetrics {
    pub ascent: f32,
    pub descent: f32,
    pub line_gap: f32,
}

#[no_mangle]
pub extern "C" fn re_font_metrics(e: *mut Engine, font: u32, size: f32, out: *mut ReFontMetrics) -> bool {
    with_engine(e, false, |e| {
        let Some(f) = e.fonts.get(font as usize) else { return false };
        if out.is_null() {
            return false;
        }
        let k = size / f.units_per_em;
        unsafe {
            *out = ReFontMetrics {
                ascent: f.ascender * k,
                descent: -f.descender * k,
                line_gap: f.line_gap * k,
            };
        }
        true
    })
}

/// Shape UTF-8 text with simple cmap + advance shaping and per-character font
/// fallback. Calls `sink(font_id, glyph, x)` for each glyph; returns the width.
fn shape(e: &Engine, font: u32, size: f32, text: &[u8], mut sink: impl FnMut(u32, u16, f32)) -> f32 {
    let mut chain: Vec<(u32, ttf_parser::Face, f32)> = Vec::with_capacity(1 + e.fallbacks.len());
    for id in std::iter::once(font).chain(e.fallbacks.iter().copied()) {
        if chain.iter().any(|(i, _, _)| *i == id) {
            continue;
        }
        let Some(f) = e.fonts.get(id as usize) else { continue };
        if let Ok(face) = ttf_parser::Face::parse(&f.bytes, f.index) {
            chain.push((id, face, size / f.units_per_em));
        }
    }
    if chain.is_empty() {
        return 0.0;
    }
    let mut x = 0.0f32;
    for ch in String::from_utf8_lossy(text).chars() {
        let ch = if ch == '\t' || ch == '\n' || ch == '\r' { ' ' } else { ch };
        let found = chain.iter().find_map(|(id, face, k)| face.glyph_index(ch).map(|g| (*id, face, *k, g)));
        let found = found.or_else(|| {
            let (id, face, k) = &chain[0];
            face.glyph_index('?').map(|g| (*id, face, *k, g))
        });
        let Some((id, face, k, gid)) = found else { continue };
        let adv = face.glyph_hor_advance(gid).unwrap_or(0) as f32 * k;
        sink(id, gid.0, x);
        x += adv;
    }
    x
}

/// Register a fallback font (searched in registration order).
#[no_mangle]
pub extern "C" fn re_font_add_fallback(e: *mut Engine, font: u32) {
    with_engine(e, (), |e| {
        if (font as usize) < e.fonts.len() && !e.fallbacks.contains(&font) {
            e.fallbacks.push(font);
        }
    })
}

/// Width of `text` in logical pixels.
#[no_mangle]
pub extern "C" fn re_text_width(e: *mut Engine, font: u32, size: f32, text: *const u8, len: usize) -> f32 {
    with_engine(e, 0.0, |e| {
        shape(e, font, size, unsafe { bytes(text, len) }, |_, _, _| {})
    })
}

// ---------------------------------------------------------------------------
// Display list primitives (logical px; scaled to device px here)
// ---------------------------------------------------------------------------

#[no_mangle]
pub extern "C" fn re_begin_frame(e: *mut Engine) {
    with_engine(e, (), |e| {
        let mut b = DisplayListBuilder::new(e.pipeline);
        b.begin();
        let space = SpaceAndClipInfo::root_scroll(e.pipeline);
        b.push_simple_stacking_context(space.spatial_id, PrimitiveFlags::IS_BACKFACE_VISIBLE);
        e.builder = Some(b);
        e.clip_stack.clear();
        let full = LayoutRect::from_size(LayoutSize::new(e.device_w as f32, e.device_h as f32));
        e.clip_stack.push((ClipChainId::INVALID, full));
    })
}

#[no_mangle]
pub extern "C" fn re_rect(e: *mut Engine, x: f32, y: f32, w: f32, h: f32, color: ReColor) {
    with_engine(e, (), |e| {
        let r = e.rect(x, y, w, h);
        if !e.visible(&r) {
            return;
        }
        let common = e.common(r);
        if let Some(b) = e.builder.as_mut() {
            b.push_rect(&common, r, color.into());
        }
    })
}

#[no_mangle]
pub extern "C" fn re_rounded_rect(e: *mut Engine, x: f32, y: f32, w: f32, h: f32, radius: f32, color: ReColor) {
    with_engine(e, (), |e| {
        if radius <= 0.0 {
            return re_rect(e, x, y, w, h, color);
        }
        let r = e.rect(x, y, w, h);
        if !e.visible(&r) {
            return;
        }
        let parent = e.clip_stack.last().unwrap().0;
        let spatial = SpatialId::root_scroll_node(e.pipeline);
        let radii = BorderRadius::uniform(radius * e.scale);
        let Some(b) = e.builder.as_mut() else { return };
        let clip = b.define_clip_rounded_rect(spatial, ComplexClipRegion::new(r, radii, ClipMode::Clip));
        let parent = if parent == ClipChainId::INVALID { None } else { Some(parent) };
        let chain = b.define_clip_chain(parent, [clip]);
        let common = CommonItemProperties {
            clip_rect: r,
            clip_chain_id: chain,
            spatial_id: spatial,
            flags: PrimitiveFlags::default(),
        };
        b.push_rect(&common, r, color.into());
    })
}

#[no_mangle]
pub extern "C" fn re_border(e: *mut Engine, x: f32, y: f32, w: f32, h: f32, width: f32, radius: f32, color: ReColor) {
    with_engine(e, (), |e| {
        let r = e.rect(x, y, w, h);
        if !e.visible(&r) {
            return;
        }
        let common = e.common(r);
        let side = BorderSide { color: color.into(), style: BorderStyle::Solid };
        let details = BorderDetails::Normal(NormalBorder {
            left: side,
            right: side,
            top: side,
            bottom: side,
            radius: BorderRadius::uniform(radius * e.scale),
            do_aa: true,
        });
        let wpx = width * e.scale;
        if let Some(b) = e.builder.as_mut() {
            b.push_border(&common, r, LayoutSideOffsets::new_all_same(wpx), details);
        }
    })
}

#[no_mangle]
pub extern "C" fn re_shadow(e: *mut Engine, x: f32, y: f32, w: f32, h: f32, radius: f32, blur: f32, offset_y: f32, color: ReColor) {
    with_engine(e, (), |e| {
        let r = e.rect(x, y, w, h);
        let s = e.scale;
        let area = r.inflate(blur * 2.0 * s, blur * 2.0 * s).translate(LayoutVector2D::new(0.0, offset_y * s));
        if !e.visible(&area) {
            return;
        }
        let common = e.common(area);
        if let Some(b) = e.builder.as_mut() {
            b.push_box_shadow(
                &common,
                r,
                LayoutVector2D::new(0.0, offset_y * s),
                color.into(),
                blur * s,
                0.0,
                BorderRadius::uniform(radius * s),
                BorderRadius::uniform(radius * s),
                BoxShadowClipMode::Outset,
            );
        }
    })
}

impl Engine {
    /// Clip chain for a (possibly rounded) rect nested in the current clip.
    fn rounded_chain(&mut self, r: LayoutRect, radius: f32) -> ClipChainId {
        let parent = self.clip_stack.last().unwrap().0;
        let spatial = SpatialId::root_scroll_node(self.pipeline);
        let radius = radius * self.scale;
        let b = self.builder.as_mut().unwrap();
        let clip = if radius > 0.0 {
            b.define_clip_rounded_rect(spatial, ComplexClipRegion::new(r, BorderRadius::uniform(radius), ClipMode::Clip))
        } else {
            b.define_clip_rect(spatial, r)
        };
        let parent = if parent == ClipChainId::INVALID { None } else { Some(parent) };
        b.define_clip_chain(parent, [clip])
    }
}

/// Decode an image file (png, jpeg, webp, gif, bmp) and upload it to WebRender.
/// Returns an image id (> 0) and its size, or 0 on failure.
#[no_mangle]
pub extern "C" fn re_image_load(e: *mut Engine, path: *const c_char, out_w: *mut u32, out_h: *mut u32) -> u32 {
    with_engine(e, 0, |e| {
        if path.is_null() {
            return 0;
        }
        let path = unsafe { CStr::from_ptr(path) }.to_string_lossy().into_owned();
        // Detect the format from the contents (the profile copy has no extension).
        let decoded = image::ImageReader::open(&path)
            .and_then(|r| r.with_guessed_format())
            .map_err(image::ImageError::IoError)
            .and_then(|r| r.decode());
        let img = match decoded {
            Ok(i) => i,
            Err(err) => {
                eprintln!("redengine: image {path}: {err}");
                return 0;
            }
        };
        // Keep within GPU texture limits.
        let img = if img.width() > 4096 || img.height() > 4096 { img.thumbnail(4096, 4096) } else { img };
        let rgba = img.to_rgba8();
        let (w, h) = rgba.dimensions();
        let mut bgra = rgba.into_raw();
        for px in bgra.chunks_exact_mut(4) {
            let a = px[3] as u32;
            let (r, g, b) = (px[0] as u32, px[1] as u32, px[2] as u32);
            px[0] = (b * a / 255) as u8;
            px[1] = (g * a / 255) as u8;
            px[2] = (r * a / 255) as u8;
        }
        let key = e.api.generate_image_key();
        let desc = ImageDescriptor::new(w as i32, h as i32, ImageFormat::BGRA8, ImageDescriptorFlags::empty());
        e.txn.add_image(key, desc, ImageData::new(bgra), None);
        e.images.push(Some(key));
        unsafe {
            if !out_w.is_null() { *out_w = w; }
            if !out_h.is_null() { *out_h = h; }
        }
        e.images.len() as u32
    })
}

#[no_mangle]
pub extern "C" fn re_image_free(e: *mut Engine, id: u32) {
    with_engine(e, (), |e| {
        if let Some(slot) = e.images.get_mut((id as usize).wrapping_sub(1)) {
            if let Some(key) = slot.take() {
                e.txn.delete_image(key);
            }
        }
    })
}

#[no_mangle]
pub extern "C" fn re_image(e: *mut Engine, id: u32, x: f32, y: f32, w: f32, h: f32) {
    with_engine(e, (), |e| {
        let Some(Some(key)) = e.images.get((id as usize).wrapping_sub(1)).copied() else { return };
        let r = e.rect(x, y, w, h);
        if !e.visible(&r) {
            return;
        }
        let common = e.common(r);
        if let Some(b) = e.builder.as_mut() {
            b.push_image(&common, r, ImageRendering::Auto, AlphaType::PremultipliedAlpha, key, ColorF::WHITE);
        }
    })
}

/// Frosted glass: blur + saturate whatever has been drawn underneath, clipped to a
/// rounded rect (WebRender's backdrop-filter, as used for CSS `backdrop-filter`).
#[no_mangle]
pub extern "C" fn re_glass(e: *mut Engine, x: f32, y: f32, w: f32, h: f32, radius: f32, blur: f32, saturate: f32) {
    with_engine(e, (), |e| {
        if e.builder.is_none() {
            return;
        }
        let r = e.rect(x, y, w, h);
        if !e.visible(&r) {
            return;
        }
        let chain = e.rounded_chain(r, radius);
        let common = CommonItemProperties {
            clip_rect: r,
            clip_chain_id: chain,
            spatial_id: SpatialId::root_scroll_node(e.pipeline),
            flags: PrimitiveFlags::default(),
        };
        let blur = blur * e.scale;
        let filters = [FilterOp::Blur(blur, blur), FilterOp::Saturate(saturate)];
        e.builder.as_mut().unwrap().push_backdrop_filter(&common, &filters, &[]);
    })
}

/// Vertical linear gradient from `top` to `bottom`, clipped to a rounded rect.
#[no_mangle]
pub extern "C" fn re_gradient(e: *mut Engine, x: f32, y: f32, w: f32, h: f32, radius: f32, top: ReColor, bottom: ReColor) {
    with_engine(e, (), |e| {
        if e.builder.is_none() {
            return;
        }
        let r = e.rect(x, y, w, h);
        if !e.visible(&r) {
            return;
        }
        let chain = e.rounded_chain(r, radius);
        let common = CommonItemProperties {
            clip_rect: r,
            clip_chain_id: chain,
            spatial_id: SpatialId::root_scroll_node(e.pipeline),
            flags: PrimitiveFlags::default(),
        };
        let b = e.builder.as_mut().unwrap();
        let stops = vec![
            GradientStop { offset: 0.0, color: top.into() },
            GradientStop { offset: 1.0, color: bottom.into() },
        ];
        let g = b.create_gradient(LayoutPoint::new(0.0, 0.0), LayoutPoint::new(0.0, r.height()), stops, ExtendMode::Clamp);
        b.push_gradient(&common, r, g, r.size(), LayoutSize::zero());
    })
}

/// Draw a single line of text with its baseline at `y`. Returns the advance width.
/// Glyphs coming from fallback fonts are emitted as separate text items.
#[no_mangle]
pub extern "C" fn re_text(e: *mut Engine, font: u32, size: f32, x: f32, y: f32, text: *const u8, len: usize, color: ReColor) -> f32 {
    with_engine(e, 0.0, |e| {
        let text = unsafe { bytes(text, len) };
        let Some(f) = e.fonts.get(font as usize) else { return 0.0 };
        let k = size / f.units_per_em;
        let (asc, desc) = (f.ascender * k, -f.descender * k);
        let s = e.scale;

        let mut runs: Vec<(u32, Vec<GlyphInstance>, f32, f32)> = Vec::new(); // font, glyphs, x0, x1
        let width = shape(e, font, size, text, |fid, gid, gx| {
            let g = GlyphInstance { index: gid as u32, point: LayoutPoint::new((x + gx) * s, y * s) };
            match runs.last_mut() {
                Some(r) if r.0 == fid => {
                    r.1.push(g);
                    r.3 = gx;
                }
                _ => runs.push((fid, vec![g], gx, gx)),
            }
        });
        let bounds = e.rect(x, y - asc, width, asc + desc);
        if runs.is_empty() || !e.visible(&bounds) {
            return width;
        }
        let common = e.common(bounds);
        for (fid, glyphs, _, _) in runs {
            let Some(inst) = e.font_instance(fid, size) else { continue };
            if let Some(b) = e.builder.as_mut() {
                b.push_text(&common, bounds, &glyphs, inst, color.into(), None);
            }
        }
        width
    })
}

/// Push a (optionally rounded) clip; everything until the matching pop is clipped to it.
#[no_mangle]
pub extern "C" fn re_push_clip(e: *mut Engine, x: f32, y: f32, w: f32, h: f32, radius: f32) {
    with_engine(e, (), |e| {
        let r = e.rect(x, y, w, h);
        let (parent, parent_rect) = *e.clip_stack.last().unwrap();
        let spatial = SpatialId::root_scroll_node(e.pipeline);
        let radius = radius * e.scale;
        let Some(b) = e.builder.as_mut() else { return };
        let clip = if radius > 0.0 {
            b.define_clip_rounded_rect(
                spatial,
                ComplexClipRegion::new(r, BorderRadius::uniform(radius), ClipMode::Clip),
            )
        } else {
            b.define_clip_rect(spatial, r)
        };
        let parent = if parent == ClipChainId::INVALID { None } else { Some(parent) };
        let chain = b.define_clip_chain(parent, [clip]);
        let visible = r.intersection(&parent_rect).unwrap_or(LayoutRect::zero());
        e.clip_stack.push((chain, visible));
    })
}

#[no_mangle]
pub extern "C" fn re_pop_clip(e: *mut Engine) {
    with_engine(e, (), |e| {
        if e.clip_stack.len() > 1 {
            e.clip_stack.pop();
        }
    })
}

/// Finish the display list, hand it to WebRender and render into the current
/// GL framebuffer. The caller swaps buffers afterwards.
#[no_mangle]
pub extern "C" fn re_end_frame(e: *mut Engine) {
    with_engine(e, (), |e| {
        let Some(mut b) = e.builder.take() else { return };
        b.pop_stacking_context();
        let dl = b.end();
        e.epoch += 1;
        e.frame_id += 1;

        let mut txn = std::mem::replace(&mut e.txn, Transaction::new());
        txn.set_display_list(Epoch(e.epoch), dl);
        txn.generate_frame(e.frame_id, true, false, RenderReasons::SCENE);
        e.api.send_transaction(e.document, txn);

        e.notifier.wait(Duration::from_millis(250));
        e.render();
    })
}

/// Re-render the last frame (e.g. after an expose event) without rebuilding.
#[no_mangle]
pub extern "C" fn re_render(e: *mut Engine) {
    with_engine(e, (), |e| e.render())
}

impl Engine {
    fn render(&mut self) {
        let size = DeviceIntSize::new(self.device_w, self.device_h);
        if let Some(r) = self.renderer.as_mut() {
            r.update();
            if let Err(errs) = r.render(size, 0) {
                eprintln!("redengine: render errors: {:?}", errs);
            }
        }
    }
}

/// `name=version;` pairs for the linked engine crates and rustc (see build.rs).
#[no_mangle]
pub extern "C" fn re_engine_versions() -> *const c_char {
    concat!(env!("REDENGINE_VERSIONS"), "\0").as_ptr() as *const c_char
}

// ---------------------------------------------------------------------------
// HTML parsing (html5ever) → flat node array
// ---------------------------------------------------------------------------

pub const RE_NODE_DOCUMENT: u8 = 0;
pub const RE_NODE_ELEMENT: u8 = 1;
pub const RE_NODE_TEXT: u8 = 2;
pub const RE_NODE_COMMENT: u8 = 3;

struct FlatNode {
    kind: u8,
    parent: i32,
    first_child: i32,
    next_sibling: i32,
    name: String,
    text: String,
    attrs: Vec<(String, String)>,
}

pub struct Doc {
    nodes: Vec<FlatNode>,
}

#[repr(C)]
pub struct ReNode {
    pub kind: u8,
    pub parent: i32,
    pub first_child: i32,
    pub next_sibling: i32,
    pub name: *const u8,
    pub name_len: usize,
    pub text: *const u8,
    pub text_len: usize,
    pub attr_count: u32,
}

fn flatten(handle: &Handle, parent: i32, out: &mut Vec<FlatNode>) -> i32 {
    let idx = out.len() as i32;
    let (kind, name, text, attrs) = match &handle.data {
        NodeData::Document => (RE_NODE_DOCUMENT, String::new(), String::new(), Vec::new()),
        NodeData::Element { name, attrs, .. } => (
            RE_NODE_ELEMENT,
            name.local.to_string(),
            String::new(),
            attrs
                .borrow()
                .iter()
                .map(|a| (a.name.local.to_string(), a.value.to_string()))
                .collect(),
        ),
        NodeData::Text { contents } => (RE_NODE_TEXT, String::new(), contents.borrow().to_string(), Vec::new()),
        NodeData::Comment { contents } => (RE_NODE_COMMENT, String::new(), contents.to_string(), Vec::new()),
        _ => return -1,
    };
    out.push(FlatNode { kind, parent, first_child: -1, next_sibling: -1, name, text, attrs });

    // <template> contents live outside children in rcdom; ignored on purpose.
    let mut prev: i32 = -1;
    for child in handle.children.borrow().iter() {
        let c = flatten(child, idx, out);
        if c < 0 {
            continue;
        }
        if prev < 0 {
            out[idx as usize].first_child = c;
        } else {
            out[prev as usize].next_sibling = c;
        }
        prev = c;
    }
    idx
}

fn parse_opts(scripting: bool) -> html5ever::ParseOpts {
    html5ever::ParseOpts {
        tree_builder: html5ever::tree_builder::TreeBuilderOpts {
            scripting_enabled: scripting,
            ..Default::default()
        },
        ..Default::default()
    }
}

/// Parse an HTML document (bytes are decoded as UTF-8, lossily). With
/// `scripting` off (JavaScript disabled), <noscript> content becomes markup.
#[no_mangle]
pub extern "C" fn re_html_parse2(input: *const u8, len: usize, scripting: bool) -> *mut Doc {
    let src = String::from_utf8_lossy(unsafe { bytes(input, len) }).into_owned();
    let dom = html5ever::parse_document(RcDom::default(), parse_opts(scripting))
        .from_utf8()
        .read_from(&mut src.as_bytes())
        .unwrap_or_default();
    let mut nodes = Vec::new();
    flatten(&dom.document, -1, &mut nodes);
    Box::into_raw(Box::new(Doc { nodes }))
}

#[no_mangle]
pub extern "C" fn re_html_parse(input: *const u8, len: usize) -> *mut Doc {
    re_html_parse2(input, len, false)
}

/// Parse an HTML fragment as if it were the content of a <body> (innerHTML).
/// The result is a document whose first element (<html>) holds the nodes.
#[no_mangle]
pub extern "C" fn re_html_parse_fragment(input: *const u8, len: usize) -> *mut Doc {
    let src = String::from_utf8_lossy(unsafe { bytes(input, len) }).into_owned();
    let ctx = html5ever::QualName::new(None, html5ever::ns!(html), html5ever::local_name!("body"));
    let dom = html5ever::parse_fragment(RcDom::default(), parse_opts(true), ctx, vec![], false)
        .from_utf8()
        .read_from(&mut src.as_bytes())
        .unwrap_or_default();
    let mut nodes = Vec::new();
    flatten(&dom.document, -1, &mut nodes);
    Box::into_raw(Box::new(Doc { nodes }))
}

#[no_mangle]
pub extern "C" fn re_doc_free(doc: *mut Doc) {
    if !doc.is_null() {
        drop(unsafe { Box::from_raw(doc) });
    }
}

#[no_mangle]
pub extern "C" fn re_doc_len(doc: *const Doc) -> u32 {
    if doc.is_null() {
        return 0;
    }
    unsafe { &*doc }.nodes.len() as u32
}

/// Fill `out` with node `i`. Pointers stay valid until `re_doc_free`.
#[no_mangle]
pub extern "C" fn re_doc_node(doc: *const Doc, i: u32, out: *mut ReNode) -> bool {
    if doc.is_null() || out.is_null() {
        return false;
    }
    let Some(n) = unsafe { &*doc }.nodes.get(i as usize) else { return false };
    unsafe {
        *out = ReNode {
            kind: n.kind,
            parent: n.parent,
            first_child: n.first_child,
            next_sibling: n.next_sibling,
            name: n.name.as_ptr(),
            name_len: n.name.len(),
            text: n.text.as_ptr(),
            text_len: n.text.len(),
            attr_count: n.attrs.len() as u32,
        };
    }
    true
}

/// Get attribute `j` of node `i` (name and value). Pointers valid until `re_doc_free`.
#[no_mangle]
pub extern "C" fn re_doc_attr(
    doc: *const Doc,
    i: u32,
    j: u32,
    name: *mut *const u8,
    name_len: *mut usize,
    value: *mut *const u8,
    value_len: *mut usize,
) -> bool {
    if doc.is_null() {
        return false;
    }
    let Some(n) = unsafe { &*doc }.nodes.get(i as usize) else { return false };
    let Some((k, v)) = n.attrs.get(j as usize) else { return false };
    unsafe {
        *name = k.as_ptr();
        *name_len = k.len();
        *value = v.as_ptr();
        *value_len = v.len();
    }
    true
}

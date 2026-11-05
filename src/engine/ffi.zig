//! Raw C ABI exported by the Rust `redengine` crate (engine/src/lib.rs).
//! WebRender for drawing, html5ever for parsing. Keep in sync with lib.rs.

pub const Engine = opaque {};
pub const Doc = opaque {};

pub const Color = extern struct {
    r: f32,
    g: f32,
    b: f32,
    a: f32,
};

pub const FontMetrics = extern struct {
    ascent: f32,
    descent: f32,
    line_gap: f32,
};

pub const NodeKind = enum(u8) { document = 0, element = 1, text = 2, comment = 3, _ };

pub const Node = extern struct {
    kind: NodeKind,
    parent: i32,
    first_child: i32,
    next_sibling: i32,
    name: [*]const u8,
    name_len: usize,
    text: [*]const u8,
    text_len: usize,
    attr_count: u32,
};

pub const GetProcAddress = *const fn (name: [*:0]const u8) callconv(.C) ?*const anyopaque;

// Renderer (WebRender)
pub extern fn re_engine_new(get_proc: GetProcAddress, device_w: i32, device_h: i32, scale: f32) ?*Engine;
pub extern fn re_engine_free(e: *Engine) void;
pub extern fn re_engine_resize(e: *Engine, device_w: i32, device_h: i32, scale: f32) void;
pub extern fn re_font_load(e: *Engine, path: [*:0]const u8, index: u32) i32;
pub extern fn re_font_add_fallback(e: *Engine, font: u32) void;
pub extern fn re_font_metrics(e: *Engine, font: u32, size: f32, out: *FontMetrics) bool;
pub extern fn re_text_width(e: *Engine, font: u32, size: f32, text: [*]const u8, len: usize) f32;
pub extern fn re_begin_frame(e: *Engine) void;
pub extern fn re_end_frame(e: *Engine) void;
pub extern fn re_render(e: *Engine) void;
pub extern fn re_rect(e: *Engine, x: f32, y: f32, w: f32, h: f32, color: Color) void;
pub extern fn re_rounded_rect(e: *Engine, x: f32, y: f32, w: f32, h: f32, radius: f32, color: Color) void;
pub extern fn re_border(e: *Engine, x: f32, y: f32, w: f32, h: f32, width: f32, radius: f32, color: Color) void;
pub extern fn re_shadow(e: *Engine, x: f32, y: f32, w: f32, h: f32, radius: f32, blur: f32, offset_y: f32, color: Color) void;
pub extern fn re_image_load(e: *Engine, path: [*:0]const u8, w: *u32, h: *u32) u32;
pub extern fn re_image_free(e: *Engine, id: u32) void;
pub extern fn re_image(e: *Engine, id: u32, x: f32, y: f32, w: f32, h: f32) void;
pub extern fn re_glass(e: *Engine, x: f32, y: f32, w: f32, h: f32, radius: f32, blur: f32, saturate: f32) void;
pub extern fn re_gradient(e: *Engine, x: f32, y: f32, w: f32, h: f32, radius: f32, top: Color, bottom: Color) void;
pub extern fn re_text(e: *Engine, font: u32, size: f32, x: f32, y: f32, text: [*]const u8, len: usize, color: Color) f32;
pub extern fn re_push_clip(e: *Engine, x: f32, y: f32, w: f32, h: f32, radius: f32) void;
pub extern fn re_pop_clip(e: *Engine) void;

// HTML parser (html5ever)
pub extern fn re_html_parse(input: [*]const u8, len: usize) ?*Doc;
pub extern fn re_doc_free(doc: *Doc) void;
pub extern fn re_doc_len(doc: *const Doc) u32;
pub extern fn re_doc_node(doc: *const Doc, i: u32, out: *Node) bool;
pub extern fn re_doc_attr(doc: *const Doc, i: u32, j: u32, name: *[*]const u8, name_len: *usize, value: *[*]const u8, value_len: *usize) bool;

//! Zig-side drawing API over the WebRender bridge. All coordinates are logical px.

const std = @import("std");
const builtin = @import("builtin");
const ffi = @import("ffi.zig");

pub const Color = ffi.Color;

pub fn rgba(r: u8, g: u8, b: u8, a: f32) Color {
    return .{
        .r = @as(f32, @floatFromInt(r)) / 255.0,
        .g = @as(f32, @floatFromInt(g)) / 255.0,
        .b = @as(f32, @floatFromInt(b)) / 255.0,
        .a = std.math.clamp(a, 0, 1),
    };
}

pub fn hex(v: u24) Color {
    return rgba(@truncate(v >> 16), @truncate(v >> 8), @truncate(v), 1.0);
}

pub fn withAlpha(c: Color, a: f32) Color {
    return .{ .r = c.r, .g = c.g, .b = c.b, .a = std.math.clamp(a, 0, 1) };
}

pub const Font = enum(u8) {
    sans,
    sans_bold,
    sans_italic,
    sans_bold_italic,
    serif,
    serif_bold,
    mono,
    mono_bold,
    ui,
    ui_bold,
    /// Home-screen wordmark: Times New Roman (regular weight).
    title,
    symbols,

    pub fn pick(mono: bool, bold: bool, italic: bool) Font {
        if (mono) return if (bold) .mono_bold else .mono;
        if (bold and italic) return .sans_bold_italic;
        if (bold) return .sans_bold;
        if (italic) return .sans_italic;
        return .sans;
    }
};

/// A font candidate. `asset` paths are relative to the app's asset directories
/// (bundled fonts make the browser chrome look identical on every OS).
const FontFile = struct { path: [:0]const u8, index: u32 = 0, asset: bool = false };

const jb_regular = FontFile{ .path = "fonts/JetBrainsMono-Regular.ttf", .asset = true };
const jb_bold = FontFile{ .path = "fonts/JetBrainsMono-Bold.ttf", .asset = true };

/// Candidate files per font slot, first existing one wins.
fn candidates(f: Font) []const FontFile {
    switch (f) {
        // Chrome + monospace page text: bundled JetBrains Mono everywhere.
        .ui, .mono => return &.{ jb_regular, .{ .path = "/System/Library/Fonts/Menlo.ttc" }, .{ .path = "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf" }, .{ .path = "C:\\Windows\\Fonts\\consola.ttf" } },
        .ui_bold, .mono_bold => return &.{ jb_bold, jb_regular },
        else => {},
    }
    switch (builtin.os.tag) {
        .macos => {
            const sup = "/System/Library/Fonts/Supplemental/";
            return switch (f) {
                .sans => &.{ .{ .path = sup ++ "Arial.ttf" }, .{ .path = "/System/Library/Fonts/Helvetica.ttc" } },
                .sans_bold => &.{ .{ .path = sup ++ "Arial Bold.ttf" }, .{ .path = sup ++ "Arial.ttf" } },
                .sans_italic => &.{ .{ .path = sup ++ "Arial Italic.ttf" }, .{ .path = sup ++ "Arial.ttf" } },
                .sans_bold_italic => &.{ .{ .path = sup ++ "Arial Bold Italic.ttf" }, .{ .path = sup ++ "Arial Bold.ttf" } },
                .serif => &.{ .{ .path = sup ++ "Georgia.ttf" }, .{ .path = sup ++ "Times New Roman.ttf" } },
                .serif_bold => &.{ .{ .path = sup ++ "Georgia Bold.ttf" }, .{ .path = sup ++ "Times New Roman Bold.ttf" } },
                .title => &.{ .{ .path = sup ++ "Times New Roman.ttf" }, .{ .path = "/Library/Fonts/Times New Roman.ttf" }, .{ .path = sup ++ "Georgia.ttf" } },
                .symbols => &.{ .{ .path = sup ++ "Arial Unicode.ttf" }, .{ .path = "/System/Library/Fonts/Apple Symbols.ttf" } },
                else => unreachable,
            };
        },
        .windows => {
            const w = "C:\\Windows\\Fonts\\";
            return switch (f) {
                .sans => &.{.{ .path = w ++ "arial.ttf" }},
                .sans_bold => &.{ .{ .path = w ++ "arialbd.ttf" }, .{ .path = w ++ "arial.ttf" } },
                .sans_italic => &.{ .{ .path = w ++ "ariali.ttf" }, .{ .path = w ++ "arial.ttf" } },
                .sans_bold_italic => &.{ .{ .path = w ++ "arialbi.ttf" }, .{ .path = w ++ "arialbd.ttf" } },
                .serif => &.{ .{ .path = w ++ "georgia.ttf" }, .{ .path = w ++ "times.ttf" } },
                .serif_bold => &.{ .{ .path = w ++ "georgiab.ttf" }, .{ .path = w ++ "timesbd.ttf" } },
                .title => &.{ .{ .path = w ++ "times.ttf" }, .{ .path = w ++ "georgia.ttf" } },
                .symbols => &.{ .{ .path = w ++ "seguisym.ttf" }, .{ .path = w ++ "arial.ttf" } },
                else => unreachable,
            };
        },
        else => {
            const dv = "/usr/share/fonts/truetype/dejavu/";
            const dv2 = "/usr/share/fonts/TTF/";
            return switch (f) {
                .sans, .sans_italic, .symbols => &.{ .{ .path = dv ++ "DejaVuSans.ttf" }, .{ .path = dv2 ++ "DejaVuSans.ttf" } },
                .sans_bold, .sans_bold_italic => &.{ .{ .path = dv ++ "DejaVuSans-Bold.ttf" }, .{ .path = dv2 ++ "DejaVuSans-Bold.ttf" } },
                .serif => &.{ .{ .path = dv ++ "DejaVuSerif.ttf" }, .{ .path = dv2 ++ "DejaVuSerif.ttf" } },
                .serif_bold => &.{ .{ .path = dv ++ "DejaVuSerif-Bold.ttf" }, .{ .path = dv2 ++ "DejaVuSerif-Bold.ttf" } },
                // Liberation Serif is metric-compatible with Times New Roman.
                .title => &.{ .{ .path = "/usr/share/fonts/truetype/msttcorefonts/Times_New_Roman.ttf" }, .{ .path = "/usr/share/fonts/truetype/liberation/LiberationSerif-Regular.ttf" }, .{ .path = "/usr/share/fonts/liberation/LiberationSerif-Regular.ttf" }, .{ .path = dv ++ "DejaVuSerif.ttf" } },
                else => unreachable,
            };
        },
    }
}

pub const Metrics = struct { ascent: f32, descent: f32, line_gap: f32 };

pub const Gfx = struct {
    engine: *ffi.Engine,
    font_ids: [@typeInfo(Font).@"enum".fields.len]u32 = undefined,

    /// `asset_dirs`: directories (with trailing separator) searched for bundled fonts.
    pub fn init(get_proc: ffi.GetProcAddress, device_w: i32, device_h: i32, scale: f32, asset_dirs: []const []const u8) !Gfx {
        const engine = ffi.re_engine_new(get_proc, device_w, device_h, scale) orelse return error.WebRenderInitFailed;
        var g = Gfx{ .engine = engine };
        var fallback: ?u32 = null;
        inline for (@typeInfo(Font).@"enum".fields) |field| {
            const f: Font = @enumFromInt(field.value);
            var id: i32 = -1;
            search: for (candidates(f)) |cand| {
                if (cand.asset) {
                    for (asset_dirs) |dir| {
                        var buf: [1024]u8 = undefined;
                        const p = std.fmt.bufPrintZ(&buf, "{s}{s}", .{ dir, cand.path }) catch continue;
                        id = ffi.re_font_load(engine, p.ptr, cand.index);
                        if (id >= 0) break :search;
                    }
                } else {
                    id = ffi.re_font_load(engine, cand.path.ptr, cand.index);
                    if (id >= 0) break :search;
                }
            }
            if (id >= 0) {
                g.font_ids[field.value] = @intCast(id);
                if (fallback == null) fallback = @intCast(id);
            } else {
                g.font_ids[field.value] = fallback orelse {
                    std.log.err("no usable font found for {s}", .{field.name});
                    return error.NoFonts;
                };
            }
        }
        // Glyphs missing from a font (✓, ❯, arrows, CJK...) come from these.
        ffi.re_font_add_fallback(engine, g.font_ids[@intFromEnum(Font.symbols)]);
        ffi.re_font_add_fallback(engine, g.font_ids[@intFromEnum(Font.ui)]);
        ffi.re_font_add_fallback(engine, g.font_ids[@intFromEnum(Font.sans)]);
        return g;
    }

    pub fn deinit(self: *Gfx) void {
        ffi.re_engine_free(self.engine);
    }

    pub fn resize(self: *Gfx, device_w: i32, device_h: i32, scale: f32) void {
        ffi.re_engine_resize(self.engine, device_w, device_h, scale);
    }

    fn fid(self: *const Gfx, f: Font) u32 {
        return self.font_ids[@intFromEnum(f)];
    }

    pub fn metrics(self: *const Gfx, f: Font, size: f32) Metrics {
        var m: ffi.FontMetrics = undefined;
        if (!ffi.re_font_metrics(self.engine, self.fid(f), size, &m)) return .{ .ascent = size * 0.8, .descent = size * 0.2, .line_gap = 0 };
        return .{ .ascent = m.ascent, .descent = m.descent, .line_gap = m.line_gap };
    }

    pub fn measure(self: *const Gfx, f: Font, size: f32, s: []const u8) f32 {
        if (s.len == 0) return 0;
        return ffi.re_text_width(self.engine, self.fid(f), size, s.ptr, s.len);
    }

    pub fn begin(self: *Gfx) void {
        ffi.re_begin_frame(self.engine);
    }

    pub fn end(self: *Gfx) void {
        ffi.re_end_frame(self.engine);
    }

    pub fn redraw(self: *Gfx) void {
        ffi.re_render(self.engine);
    }

    pub fn rect(self: *Gfx, x: f32, y: f32, w: f32, h: f32, c: Color) void {
        ffi.re_rect(self.engine, x, y, w, h, c);
    }

    pub fn roundRect(self: *Gfx, x: f32, y: f32, w: f32, h: f32, r: f32, c: Color) void {
        ffi.re_rounded_rect(self.engine, x, y, w, h, r, c);
    }

    pub fn border(self: *Gfx, x: f32, y: f32, w: f32, h: f32, width: f32, r: f32, c: Color) void {
        ffi.re_border(self.engine, x, y, w, h, width, r, c);
    }

    pub fn shadow(self: *Gfx, x: f32, y: f32, w: f32, h: f32, r: f32, blur: f32, dy: f32, c: Color) void {
        ffi.re_shadow(self.engine, x, y, w, h, r, blur, dy, c);
    }

    pub const Image = struct { id: u32, w: f32, h: f32 };

    pub fn loadImage(self: *Gfx, path: [:0]const u8) ?Image {
        var w: u32 = 0;
        var h: u32 = 0;
        const id = ffi.re_image_load(self.engine, path.ptr, &w, &h);
        if (id == 0) return null;
        return .{ .id = id, .w = @floatFromInt(w), .h = @floatFromInt(h) };
    }

    pub fn freeImage(self: *Gfx, img: Image) void {
        ffi.re_image_free(self.engine, img.id);
    }

    pub fn image(self: *Gfx, img: Image, x: f32, y: f32, w: f32, h: f32) void {
        ffi.re_image(self.engine, img.id, x, y, w, h);
    }

    /// Draw `img` scaled to cover the rect (cropping the overflow), like `object-fit: cover`.
    pub fn imageCover(self: *Gfx, img: Image, x: f32, y: f32, w: f32, h: f32) void {
        const k = @max(w / img.w, h / img.h);
        const dw = img.w * k;
        const dh = img.h * k;
        self.pushClip(x, y, w, h, 0);
        self.image(img, x + (w - dw) / 2, y + (h - dh) / 2, dw, dh);
        self.popClip();
    }

    /// Frosted-glass backdrop (blurs what is already drawn beneath).
    pub fn glass(self: *Gfx, x: f32, y: f32, w: f32, h: f32, r: f32, blur: f32, saturate: f32) void {
        ffi.re_glass(self.engine, x, y, w, h, r, blur, saturate);
    }

    pub fn vgradient(self: *Gfx, x: f32, y: f32, w: f32, h: f32, r: f32, top: Color, bottom: Color) void {
        ffi.re_gradient(self.engine, x, y, w, h, r, top, bottom);
    }

    /// Draw text with its baseline at `y`; returns advance width.
    pub fn text(self: *Gfx, f: Font, size: f32, x: f32, y: f32, s: []const u8, c: Color) f32 {
        if (s.len == 0) return 0;
        return ffi.re_text(self.engine, self.fid(f), size, x, y, s.ptr, s.len, c);
    }

    /// Draw text vertically centred in a box of height `h` starting at `top`.
    pub fn textCentered(self: *Gfx, f: Font, size: f32, x: f32, top: f32, h: f32, s: []const u8, c: Color) f32 {
        const m = self.metrics(f, size);
        const baseline = top + (h - (m.ascent + m.descent)) / 2.0 + m.ascent;
        return self.text(f, size, x, @round(baseline), s, c);
    }

    pub fn pushClip(self: *Gfx, x: f32, y: f32, w: f32, h: f32, r: f32) void {
        ffi.re_push_clip(self.engine, x, y, w, h, r);
    }

    pub fn popClip(self: *Gfx) void {
        ffi.re_pop_clip(self.engine);
    }

    /// Byte length of the longest prefix of `s` (on a UTF-8 boundary) that fits in `max_w`.
    pub fn fitPrefix(self: *const Gfx, f: Font, size: f32, s: []const u8, max_w: f32) usize {
        if (self.measure(f, size, s) <= max_w) return s.len;
        var lo: usize = 0;
        var hi: usize = s.len;
        while (lo < hi) {
            var mid = (lo + hi + 1) / 2;
            while (mid > 0 and mid < s.len and (s[mid] & 0xC0) == 0x80) mid -= 1;
            if (mid <= lo) break;
            if (self.measure(f, size, s[0..mid]) <= max_w) lo = mid else hi = mid - 1;
        }
        return lo;
    }
};

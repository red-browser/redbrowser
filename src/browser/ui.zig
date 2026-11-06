//! Browser chrome: a self-drawn title bar with flat tabs, a prompt-style
//! address line with a block cursor, monospace type (bundled JetBrains Mono)
//! and colour schemes. The window is borderless and everything is drawn by us,
//! so it looks the same on macOS, Linux and Windows.
//!
//!   ╭─[1 Hacker News ×]─[2 Example]─ + ───────────────────────── — □ × ╮  title bar (drag)
//!   │ ← → ↻  ❯ https://news.ycombinator.com/                     ◐ ≡  │  prompt row
//!   ╰────────────────────────────────────────────────────────────────────╯
//!   page content scrolls underneath with a light background blur.

const std = @import("std");
const gfx = @import("../engine/gfx.zig");
const Tab = @import("tab.zig").Tab;
const settings = @import("settings.zig");

const Gfx = gfx.Gfx;
const Color = gfx.Color;
const rgba = gfx.rgba;
const hex = gfx.hex;

pub const ThemeMode = enum {
    system,
    light,
    dark,

    pub fn next(m: ThemeMode) ThemeMode {
        return switch (m) {
            .system => .light,
            .light => .dark,
            .dark => .system,
        };
    }
};

pub const Palette = struct {
    dark: bool,
    bg: Color, // title bar
    surface: Color, // prompt row, active tab
    border: Color,
    label: Color,
    secondary: Color,
    disabled: Color,
    accent: Color,
    on_accent: Color,
    selection: Color,
    link: Color,
    ink: Color, // hover fills (black on light, white on dark)
    page_bg: Color,

    pub fn from(sc: settings.Scheme, accent: u24) Palette {
        const a = hex(accent);
        return .{
            .dark = sc.dark,
            .bg = hex(sc.bg),
            .surface = hex(sc.surface),
            .border = hex(sc.border),
            .label = hex(sc.fg),
            .secondary = hex(sc.muted),
            .disabled = gfx.withAlpha(hex(sc.muted), 0.45),
            .accent = a,
            .on_accent = hex(sc.surface),
            .selection = gfx.withAlpha(a, if (sc.dark) 0.35 else 0.25),
            .link = hex(sc.link),
            .ink = if (sc.dark) hex(0xffffff) else hex(0x000000),
            .page_bg = hex(sc.surface),
        };
    }
};

/// Active palette. The UI is single-threaded; the app swaps this on theme changes.
pub var pal: Palette = blk: {
    const sc = settings.schemes[settings.schemeIndex("gruvbox-dark").?];
    break :blk Palette.from(sc, sc.accent);
};
pub const window_radius: f32 = 10;

fn ink(a: f32) Color {
    return gfx.withAlpha(pal.ink, a);
}

pub const title_h: f32 = 38;
pub const prompt_h: f32 = 40;
pub const chrome_h: f32 = title_h + prompt_h;

pub fn chromeH(ntabs: usize) f32 {
    _ = ntabs;
    return chrome_h;
}

pub const Hit = union(enum) {
    none,
    titlebar, // empty title bar: drags the window
    tab: usize,
    tab_close: usize,
    new_tab,
    back,
    forward,
    reload,
    menu,
    theme,
    url_bar,
    win_min,
    win_max,
    win_close,
    content,
};

pub const Rect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    pub fn contains(r: Rect, px: f32, py: f32) bool {
        return px >= r.x and px < r.x + r.w and py >= r.y and py < r.y + r.h;
    }
};

// ---------------------------------------------------------------------------
// Springs
// ---------------------------------------------------------------------------

pub const Anim = struct {
    const cap = 256;
    keys: [cap]u64 = undefined,
    vals: [cap]f32 = undefined,
    touched: [cap]bool = undefined,
    n: usize = 0,
    dt: f32 = 1.0 / 60.0,
    animating: bool = false,

    pub fn begin(self: *Anim, dt: f32) void {
        self.dt = std.math.clamp(dt, 0.001, 0.05);
        self.animating = false;
        @memset(self.touched[0..self.n], false);
    }

    /// Drop values not used this frame.
    pub fn end(self: *Anim) void {
        var w: usize = 0;
        for (0..self.n) |i| {
            if (!self.touched[i]) continue;
            self.keys[w] = self.keys[i];
            self.vals[w] = self.vals[i];
            self.touched[w] = true;
            w += 1;
        }
        self.n = w;
    }

    /// Move the value for `key` towards `target`; `speed` ≈ 1/time-constant.
    pub fn get(self: *Anim, k_: u64, target: f32, speed: f32, initial: f32) f32 {
        var idx: ?usize = null;
        for (self.keys[0..self.n], 0..) |k, i| {
            if (k == k_) {
                idx = i;
                break;
            }
        }
        const i = idx orelse blk: {
            if (self.n == cap) return target;
            self.keys[self.n] = k_;
            self.vals[self.n] = initial;
            self.n += 1;
            break :blk self.n - 1;
        };
        self.touched[i] = true;
        var v = self.vals[i];
        v += (target - v) * (1 - @exp(-speed * self.dt));
        if (@abs(target - v) < 0.0015 * @max(1, @abs(target))) v = target else self.animating = true;
        self.vals[i] = v;
        return v;
    }

    pub fn peek(self: *const Anim, k_: u64) ?f32 {
        for (self.keys[0..self.n], 0..) |k, i| {
            if (k == k_) return self.vals[i];
        }
        return null;
    }
};

pub fn key(comptime tag: u16, a: u64) u64 {
    return (@as(u64, tag) << 48) ^ a;
}

fn hitKey(h: Hit) u64 {
    return switch (h) {
        .tab, .tab_close => |i| key(1, i * 2 + @intFromBool(h == .tab_close)),
        else => key(2, @intFromEnum(h)),
    };
}

// ---------------------------------------------------------------------------
// Geometry
// ---------------------------------------------------------------------------

const ctl_w: f32 = 44; // window control button width
const btn: f32 = 30; // toolbar button size
const pad: f32 = 8;

pub const Geo = struct {
    w: f32,
    ntabs: usize,

    pub fn winClose(g: Geo) Rect {
        return .{ .x = g.w - ctl_w, .y = 0, .w = ctl_w, .h = title_h };
    }
    pub fn winMax(g: Geo) Rect {
        return .{ .x = g.w - 2 * ctl_w, .y = 0, .w = ctl_w, .h = title_h };
    }
    pub fn winMin(g: Geo) Rect {
        return .{ .x = g.w - 3 * ctl_w, .y = 0, .w = ctl_w, .h = title_h };
    }
    fn tabsRight(g: Geo) f32 {
        return g.w - 3 * ctl_w - pad - 32;
    }
    fn tabW(g: Geo) f32 {
        const n: f32 = @floatFromInt(@max(g.ntabs, 1));
        return std.math.clamp((g.tabsRight() - pad) / n, 72, 230);
    }
    pub fn tab(g: Geo, i: usize) Rect {
        const w = g.tabW();
        return .{ .x = pad + @as(f32, @floatFromInt(i)) * w, .y = 6, .w = w, .h = title_h - 6 };
    }
    pub fn tabClose(g: Geo, i: usize) Rect {
        const t = g.tab(i);
        return .{ .x = t.x + t.w - 26, .y = t.y + 6, .w = 20, .h = 20 };
    }
    pub fn newTab(g: Geo) Rect {
        const last = g.tab(g.ntabs);
        return .{ .x = last.x + 4, .y = 6, .w = 28, .h = 26 };
    }
    fn row(i: f32) Rect {
        return .{ .x = pad + i * (btn + 2), .y = title_h + 5, .w = btn, .h = btn };
    }
    pub fn back(_: Geo) Rect {
        return row(0);
    }
    pub fn forward(_: Geo) Rect {
        return row(1);
    }
    pub fn reload(_: Geo) Rect {
        return row(2);
    }
    pub fn theme(g: Geo) Rect {
        return .{ .x = g.w - pad - 2 * btn - 2, .y = title_h + 5, .w = btn, .h = btn };
    }
    pub fn menu(g: Geo) Rect {
        return .{ .x = g.w - pad - btn, .y = title_h + 5, .w = btn, .h = btn };
    }
    pub fn pill(g: Geo) Rect {
        const x = row(3).x + 6;
        return .{ .x = x, .y = title_h + 5, .w = @max(80, g.theme().x - 8 - x), .h = btn };
    }
    pub fn textX(g: Geo) f32 {
        return g.pill().x + 30;
    }
};

pub fn hitTest(geo: Geo, x: f32, y: f32) Hit {
    if (y >= chrome_h) return .content;
    if (y < title_h) {
        if (geo.winClose().contains(x, y)) return .win_close;
        if (geo.winMax().contains(x, y)) return .win_max;
        if (geo.winMin().contains(x, y)) return .win_min;
        for (0..geo.ntabs) |i| {
            if (geo.tab(i).contains(x, y)) {
                return if (geo.tabClose(i).contains(x, y)) .{ .tab_close = i } else .{ .tab = i };
            }
        }
        if (geo.newTab().contains(x, y)) return .new_tab;
        return .titlebar;
    }
    if (geo.back().contains(x, y)) return .back;
    if (geo.forward().contains(x, y)) return .forward;
    if (geo.reload().contains(x, y)) return .reload;
    if (geo.theme().contains(x, y)) return .theme;
    if (geo.menu().contains(x, y)) return .menu;
    if (geo.pill().contains(x, y)) return .url_bar;
    return .none;
}

// ---------------------------------------------------------------------------
// Address bar editing
// ---------------------------------------------------------------------------

pub const font_size: f32 = 13;

pub const AddressBar = struct {
    buf: std.ArrayListUnmanaged(u8) = .{},
    cursor: usize = 0,
    anchor: usize = 0,
    focused: bool = false,
    scroll_x: f32 = 0,

    pub fn deinit(self: *AddressBar, a: std.mem.Allocator) void {
        self.buf.deinit(a);
    }

    pub fn text(self: *const AddressBar) []const u8 {
        return self.buf.items;
    }

    pub fn set(self: *AddressBar, a: std.mem.Allocator, s: []const u8) !void {
        self.buf.clearRetainingCapacity();
        try self.buf.appendSlice(a, s);
        self.cursor = s.len;
        self.anchor = s.len;
        self.scroll_x = 0;
    }

    pub fn selectAll(self: *AddressBar) void {
        self.anchor = 0;
        self.cursor = self.buf.items.len;
    }

    fn selRange(self: *const AddressBar) [2]usize {
        return .{ @min(self.cursor, self.anchor), @max(self.cursor, self.anchor) };
    }

    pub fn selection(self: *const AddressBar) []const u8 {
        const r = self.selRange();
        return self.buf.items[r[0]..r[1]];
    }

    pub fn deleteSelection(self: *AddressBar) bool {
        const r = self.selRange();
        if (r[0] == r[1]) return false;
        const items = self.buf.items;
        std.mem.copyForwards(u8, items[r[0]..], items[r[1]..]);
        self.buf.items.len -= r[1] - r[0];
        self.cursor = r[0];
        self.anchor = r[0];
        return true;
    }

    pub fn insert(self: *AddressBar, a: std.mem.Allocator, s: []const u8) !void {
        _ = self.deleteSelection();
        for (s) |ch| {
            if (ch == '\n' or ch == '\r') continue;
            try self.buf.insert(a, self.cursor, ch);
            self.cursor += 1;
        }
        self.anchor = self.cursor;
    }

    fn prevBoundary(self: *const AddressBar, i: usize) usize {
        if (i == 0) return 0;
        var j = i - 1;
        while (j > 0 and (self.buf.items[j] & 0xC0) == 0x80) j -= 1;
        return j;
    }

    fn nextBoundary(self: *const AddressBar, i: usize) usize {
        const n = self.buf.items.len;
        if (i >= n) return n;
        var j = i + 1;
        while (j < n and (self.buf.items[j] & 0xC0) == 0x80) j += 1;
        return j;
    }

    fn wordLeft(self: *const AddressBar, i: usize) usize {
        var j = i;
        const s = self.buf.items;
        while (j > 0 and !isWordChar(s[j - 1])) j -= 1;
        while (j > 0 and isWordChar(s[j - 1])) j -= 1;
        return j;
    }

    fn wordRight(self: *const AddressBar, i: usize) usize {
        var j = i;
        const s = self.buf.items;
        while (j < s.len and !isWordChar(s[j])) j += 1;
        while (j < s.len and isWordChar(s[j])) j += 1;
        return j;
    }

    pub const Move = enum { left, right, word_left, word_right, home, end };

    pub fn move(self: *AddressBar, m: Move, extend: bool) void {
        const r = self.selRange();
        const collapsed = r[0] == r[1];
        self.cursor = switch (m) {
            .left => if (!extend and !collapsed) r[0] else self.prevBoundary(self.cursor),
            .right => if (!extend and !collapsed) r[1] else self.nextBoundary(self.cursor),
            .word_left => self.wordLeft(self.cursor),
            .word_right => self.wordRight(self.cursor),
            .home => 0,
            .end => self.buf.items.len,
        };
        if (!extend) self.anchor = self.cursor;
    }

    pub fn backspace(self: *AddressBar, word: bool) void {
        if (self.deleteSelection()) return;
        self.anchor = self.cursor;
        self.cursor = if (word) self.wordLeft(self.cursor) else self.prevBoundary(self.cursor);
        _ = self.deleteSelection();
    }

    pub fn deleteForward(self: *AddressBar) void {
        if (self.deleteSelection()) return;
        self.anchor = self.nextBoundary(self.cursor);
        _ = self.deleteSelection();
    }

    /// Place the caret from a click at screen x; `text_x` is where the text starts.
    pub fn clickAt(self: *AddressBar, g: *const Gfx, size: f32, text_x: f32, x: f32, extend: bool) void {
        const rel = x - text_x + self.scroll_x;
        const s = self.buf.items;
        var best: usize = 0;
        var best_w: f32 = 0;
        var i: usize = 0;
        while (true) {
            const w = g.measure(.ui, size, s[0..i]);
            if (w > rel) {
                if (w - rel < rel - best_w) best = i;
                break;
            }
            best = i;
            best_w = w;
            if (i >= s.len) break;
            i = self.nextBoundary(i);
        }
        self.cursor = best;
        if (!extend) self.anchor = best;
    }
};

fn isWordChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch >= 0x80;
}

// ---------------------------------------------------------------------------
// Drawing
// ---------------------------------------------------------------------------

pub const View = struct {
    geo: Geo,
    win_h: f32,
    tabs: []const *Tab,
    active: usize,
    bar: *AddressBar,
    hover: Hit,
    pressed: Hit,
    now_ms: i64,
    theme_mode: ThemeMode,
    maximized: bool,
    focused_window: bool,
};

const spinner = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };

fn hoverAmount(an: *Anim, v: View, hit: Hit) f32 {
    const target: f32 = if (std.meta.eql(v.hover, hit)) (if (std.meta.eql(v.pressed, hit)) 1.7 else 1) else 0;
    return an.get(hitKey(hit), target, 20, 0);
}

fn glyphButton(g: *Gfx, an: *Anim, v: View, r: Rect, hit: Hit, glyph: []const u8, size: f32, enabled: bool) void {
    const h = if (enabled) hoverAmount(an, v, hit) else 0;
    if (h > 0.01) g.roundRect(r.x, r.y, r.w, r.h, 6, ink(0.07 * h));
    const w = g.measure(.ui, size, glyph);
    _ = g.textCentered(.ui, size, @round(r.x + (r.w - w) / 2), r.y, r.h, glyph, if (enabled) pal.label else pal.disabled);
}

pub fn drawChrome(g: *Gfx, an: *Anim, v: View) void {
    const geo = v.geo;
    const tab = v.tabs[v.active];

    // Slightly translucent chrome, blurred over the page.
    g.glass(0, 0, geo.w, chrome_h, 0, 18, 1.3);
    g.rect(0, 0, geo.w, title_h, gfx.withAlpha(pal.bg, 0.94));
    g.rect(0, title_h, geo.w, prompt_h, gfx.withAlpha(pal.surface, 0.94));
    g.rect(0, chrome_h - 1, geo.w, 1, pal.border);

    drawTabs(g, an, v);
    drawWindowControls(g, an, v);

    // navigation
    glyphButton(g, an, v, geo.back(), .back, "←", 15, tab.canGoBack());
    glyphButton(g, an, v, geo.forward(), .forward, "→", 15, tab.canGoForward());
    glyphButton(g, an, v, geo.reload(), .reload, if (tab.loading) "✕" else "↻", if (tab.loading) 12 else 15, true);
    const theme_glyph = switch (v.theme_mode) {
        .system => "◐",
        .light => "☀",
        .dark => "☾",
    };
    const spin = an.get(key(11, @intFromEnum(v.theme_mode)), 1, 9, 0);
    if (spin < 0.99) g.roundRect(geo.theme().x, geo.theme().y, btn, btn, 6, gfx.withAlpha(pal.accent, 0.25 * (1 - spin)));
    glyphButton(g, an, v, geo.theme(), .theme, theme_glyph, 14, true);
    glyphButton(g, an, v, geo.menu(), .menu, "≡", 16, true);

    drawPrompt(g, an, v);

    // load progress along the bottom edge of the chrome
    const pkey = key(5, (@as(u64, tab.id) << 32) | tab.generation);
    const progress = an.get(pkey, if (tab.loading) 0.9 else 1.0, if (tab.loading) 1.2 else 10, if (tab.loading) 0.05 else 1.0);
    const fade = an.get(pkey ^ 1, if (tab.loading or progress < 0.995) 1 else 0, 6, 0);
    if (fade > 0.01) g.rect(0, chrome_h - 2, geo.w * progress, 2, gfx.withAlpha(pal.accent, fade));
}

fn drawTabs(g: *Gfx, an: *Anim, v: View) void {
    const geo = v.geo;
    const act = geo.tab(v.active);
    // Active tab: a "folder tab" in the prompt-row colour, joined to the row below.
    const ix = an.get(key(6, 0), act.x, 22, act.x);
    const iw = an.get(key(6, 1), act.w, 22, act.w);
    g.roundRect(ix, act.y, iw, act.h + 8, 8, pal.surface);
    g.rect(ix + 10, act.y, iw - 20, 2, pal.accent);

    for (v.tabs, 0..) |tab, i| {
        const r = geo.tab(i);
        const active = i == v.active;
        const hovered = std.meta.eql(v.hover, Hit{ .tab = i }) or std.meta.eql(v.hover, Hit{ .tab_close = i });
        const hov = an.get(hitKey(.{ .tab = i }), if (hovered and !active) 1 else 0, 18, 0);
        if (hov > 0.01) g.roundRect(r.x + 2, r.y + 2, r.w - 4, r.h - 6, 6, ink(0.05 * hov));
        if (!active and i + 1 != v.active and i + 1 < v.tabs.len) g.rect(r.x + r.w - 0.5, r.y + 8, 1, r.h - 16, pal.border);

        const size: f32 = 12;
        // index / spinner like a terminal tab
        var idx_buf: [4]u8 = undefined;
        const lead: []const u8 = if (tab.loading)
            spinner[@intCast(@mod(@divFloor(v.now_ms, 80), spinner.len))]
        else if (i < 9)
            std.fmt.bufPrint(&idx_buf, "{d}", .{i + 1}) catch ""
        else
            "";
        _ = g.textCentered(.ui, size, r.x + 12, r.y, r.h, lead, if (tab.loading) pal.accent else pal.disabled);

        const title = if (tab.title.len > 0) tab.title else "new tab";
        const tx = r.x + 28;
        const max_w = r.w - 28 - 30;
        const fit = g.fitPrefix(.ui, size, title, max_w);
        g.pushClip(tx, r.y, @max(0, max_w), r.h, 0);
        _ = g.textCentered(if (active) .ui_bold else .ui, size, tx, r.y, r.h, title[0..fit], if (active) pal.label else pal.secondary);
        g.popClip();

        const close_hit = Hit{ .tab_close = i };
        const ca = an.get(hitKey(close_hit), if (hovered or active) (if (std.meta.eql(v.hover, close_hit)) 1.0 else 0.55) else 0, 18, 0);
        if (ca > 0.01) {
            const cr = geo.tabClose(i);
            if (ca > 0.8) g.roundRect(cr.x, cr.y, cr.w, cr.h, 5, ink(0.09));
            const w = g.measure(.ui, 11, "×");
            _ = g.textCentered(.ui, 11, @round(cr.x + (cr.w - w) / 2), cr.y, cr.h, "×", gfx.withAlpha(pal.secondary, @min(1, ca * 1.3)));
        }
    }

    const nr = geo.newTab();
    const h = hoverAmount(an, v, .new_tab);
    if (h > 0.01) g.roundRect(nr.x, nr.y, nr.w, nr.h, 6, ink(0.07 * h));
    const w = g.measure(.ui, 16, "+");
    _ = g.textCentered(.ui, 16, @round(nr.x + (nr.w - w) / 2), nr.y, nr.h, "+", pal.secondary);
}

fn drawWindowControls(g: *Gfx, an: *Anim, v: View) void {
    const geo = v.geo;
    const items = [_]struct { r: Rect, hit: Hit, glyph: []const u8 }{
        .{ .r = geo.winMin(), .hit = .win_min, .glyph = "—" },
        .{ .r = geo.winMax(), .hit = .win_max, .glyph = if (v.maximized) "❐" else "□" },
        .{ .r = geo.winClose(), .hit = .win_close, .glyph = "×" },
    };
    for (items) |it| {
        const h = hoverAmount(an, v, it.hit);
        const is_close = it.hit == .win_close;
        if (h > 0.01) {
            g.rect(it.r.x, it.r.y, it.r.w, it.r.h, if (is_close) gfx.withAlpha(pal.accent, 0.9 * @min(h, 1)) else ink(0.07 * h));
        }
        const color = if (is_close and h > 0.5) pal.on_accent else if (v.focused_window) pal.label else pal.secondary;
        const size: f32 = if (is_close) 18 else 13;
        const w = g.measure(.ui, size, it.glyph);
        _ = g.textCentered(.ui, size, @round(it.r.x + (it.r.w - w) / 2), it.r.y, it.r.h, it.glyph, color);
    }
}

fn drawPrompt(g: *Gfx, an: *Anim, v: View) void {
    const geo = v.geo;
    const tab = v.tabs[v.active];
    const bar = v.bar;
    const r = geo.pill();
    const hov = an.get(hitKey(.url_bar), if (std.meta.eql(v.hover, .url_bar)) 1 else 0, 16, 0);
    const foc = an.get(key(4, 0), if (bar.focused) 1 else 0, 18, 0);

    // inset "terminal" field
    g.roundRect(r.x, r.y, r.w, r.h, 6, pal.bg);
    g.border(r.x, r.y, r.w, r.h, 1, 6, if (foc > 0.01) gfx.withAlpha(pal.accent, 0.35 + 0.65 * foc) else gfx.withAlpha(pal.border, 0.6 + 0.4 * hov));

    // prompt glyph
    _ = g.textCentered(.ui_bold, font_size + 3, r.x + 10, r.y - 1, r.h, "❯", if (tab.loading) pal.accent else gfx.withAlpha(pal.accent, 0.6 + 0.4 * foc));

    const text_x = geo.textX();
    const inner_w = r.w - 30 - 12;
    g.pushClip(text_x - 2, r.y, inner_w + 4, r.h, 0);
    defer g.popClip();
    const m = g.metrics(.ui, font_size);
    const baseline = @round(r.y + (r.h - (m.ascent + m.descent)) / 2 + m.ascent);

    if (bar.focused) {
        drawEditing(g, bar, text_x, inner_w, r, baseline, font_size, "search or enter address", v.now_ms);
        return;
    }

    const is_home = tab.url.len == 0 or std.mem.startsWith(u8, tab.url, "about:home");
    if (is_home) {
        _ = g.text(.ui, font_size, text_x, baseline, "search or enter address", pal.disabled);
        return;
    }
    // scheme dim, host bright, rest muted
    const u = tab.url;
    var x = text_x;
    var host_start: usize = 0;
    if (std.mem.indexOf(u8, u, "://")) |i| {
        host_start = i + 3;
        x += g.text(.ui, font_size, x, baseline, u[0..host_start], pal.disabled);
    }
    const host_end = std.mem.indexOfAnyPos(u8, u, host_start, "/?#") orelse u.len;
    x += g.text(.ui_bold, font_size, x, baseline, u[host_start..host_end], pal.label);
    _ = g.text(.ui, font_size, x, baseline, u[host_end..], pal.secondary);
}

pub fn drawScrollbar(g: *Gfx, an: *Anim, win_w: f32, win_h: f32, top: f32, scroll: f32, page_h: f32, hot: bool) void {
    const view_h = win_h - top;
    if (page_h <= view_h + 1) return;
    const track_h = view_h - 8;
    const thumb_h = @max(36, track_h * view_h / page_h);
    const y = top + 4 + (track_h - thumb_h) * (scroll / (page_h - view_h));
    const w = an.get(key(7, 0), if (hot) 8 else 5, 16, 5);
    g.roundRect(win_w - w - 3, y, w, thumb_h, w / 2, gfx.withAlpha(pal.secondary, if (hot) 0.7 else 0.45));
}

pub fn drawStatus(g: *Gfx, an: *Anim, win_w: f32, win_h: f32, text_: []const u8) void {
    const a = an.get(key(8, 0), if (text_.len > 0) 1 else 0, 20, 0);
    if (a < 0.01 or text_.len == 0) return;
    const size: f32 = 11.5;
    const fit = g.fitPrefix(.ui, size, text_, win_w * 0.6);
    const w = g.measure(.ui, size, text_[0..fit]) + 20;
    const h: f32 = 24;
    const y = win_h - h - 8 + (1 - a) * 6;
    g.roundRect(8, y, w, h, 5, gfx.withAlpha(pal.surface, 0.96 * a));
    g.border(8, y, w, h, 1, 5, gfx.withAlpha(pal.border, a));
    _ = g.textCentered(.ui, size, 18, y, h, text_[0..fit], gfx.withAlpha(pal.secondary, a));
}

/// Editable single-line text with selection, placeholder and a blinking block cursor.
fn drawEditing(g: *Gfx, bar: *AddressBar, text_x: f32, inner_w: f32, _: Rect, baseline: f32, size: f32, placeholder: []const u8, now_ms: i64) void {
    const s = bar.text();
    const caret_x = g.measure(.ui, size, s[0..bar.cursor]);
    const cell_w = g.measure(.ui, size, "M");
    if (caret_x + cell_w - bar.scroll_x > inner_w) bar.scroll_x = caret_x + cell_w - inner_w;
    if (caret_x < bar.scroll_x) bar.scroll_x = caret_x;
    const ox = text_x - bar.scroll_x;
    const sel = [2]usize{ @min(bar.cursor, bar.anchor), @max(bar.cursor, bar.anchor) };
    if (sel[0] != sel[1]) {
        const sx = g.measure(.ui, size, s[0..sel[0]]);
        const ex = g.measure(.ui, size, s[0..sel[1]]);
        g.rect(ox + sx, @round(baseline - size * 1.0), ex - sx, @round(size * 1.35), pal.selection);
    }
    if (s.len == 0) _ = g.text(.ui, size, text_x + cell_w + 4, baseline, placeholder, pal.disabled);
    _ = g.text(.ui, size, ox, baseline, s, pal.label);
    // block cursor (blinks; inverts the cell under it)
    if (sel[0] == sel[1] and @mod(@divFloor(now_ms, 600), 2) == 0) {
        const end = blk: {
            var j = bar.cursor + 1;
            while (j < s.len and (s[j] & 0xC0) == 0x80) j += 1;
            break :blk @min(j, s.len);
        };
        const ch = if (bar.cursor < s.len) s[bar.cursor..end] else "";
        const cw = if (ch.len > 0) g.measure(.ui, size, ch) else cell_w;
        g.rect(@round(ox + caret_x), @round(baseline - size * 0.95), cw, @round(size * 1.25), pal.accent);
        if (ch.len > 0) _ = g.text(.ui, size, ox + caret_x, baseline, ch, pal.on_accent);
    }
}

// ---------------------------------------------------------------------------
// New-tab home screen: wallpaper, "RED", search box
// ---------------------------------------------------------------------------

pub const home_font: f32 = 15;

pub fn homeSearchRect(win_w: f32, win_h: f32) Rect {
    const w = @min(620, win_w - 64);
    const area_h = win_h - chrome_h;
    return .{ .x = @round((win_w - w) / 2), .y = @round(chrome_h + area_h * 0.5 + 10), .w = w, .h = 50 };
}

pub const Wallpaper = union(enum) { none, gradient, image: gfx.Gfx.Image };

/// Background for the whole window (drawn first, under the translucent chrome).
pub fn drawHomeBackground(g: *Gfx, wp: Wallpaper, w: f32, h: f32) void {
    switch (wp) {
        .none => g.rect(0, 0, w, h, pal.page_bg),
        .gradient => {
            g.rect(0, 0, w, h, pal.bg);
            g.vgradient(0, 0, w, h, 0, gfx.withAlpha(pal.accent, if (pal.dark) 0.30 else 0.22), gfx.withAlpha(pal.link, if (pal.dark) 0.10 else 0.08));
        },
        .image => |img| {
            g.rect(0, 0, w, h, pal.bg);
            g.imageCover(img, 0, 0, w, h);
            g.rect(0, 0, w, h, rgba(0, 0, 0, 0.22)); // keep text legible
        },
    }
}

pub fn drawHome(g: *Gfx, an: *Anim, wp: Wallpaper, bar: *AddressBar, hover: bool, win_w: f32, win_h: f32, now_ms: i64) void {
    const on_image = wp == .image;
    // RED
    const area_h = win_h - chrome_h;
    const size = std.math.clamp(@min(win_w * 0.16, area_h * 0.28), 48, 190);
    const word = "RED";
    const tw = g.measure(.title, size, word);
    const m = g.metrics(.title, size);
    const baseline = @round(chrome_h + area_h * 0.5 - 28);
    const tx = @round((win_w - tw) / 2);
    if (on_image) _ = g.text(.title, size, tx + 2, baseline + 3, word, rgba(0, 0, 0, 0.35));
    _ = g.text(.title, size, tx, baseline, word, if (on_image) hex(0xffffff) else pal.accent);
    _ = m;

    // search box
    const r = homeSearchRect(win_w, win_h);
    const foc = an.get(key(12, 0), if (bar.focused) 1 else 0, 18, 0);
    const hov = an.get(key(12, 1), if (hover) 1 else 0, 18, 0);
    g.shadow(r.x, r.y, r.w, r.h, 12, 18, 6, rgba(0, 0, 0, if (pal.dark or on_image) 0.35 else 0.12));
    g.glass(r.x, r.y, r.w, r.h, 12, 16, 1.4);
    g.roundRect(r.x, r.y, r.w, r.h, 12, gfx.withAlpha(pal.surface, 0.82 + 0.1 * hov));
    g.border(r.x, r.y, r.w, r.h, 1, 12, if (foc > 0.01) gfx.withAlpha(pal.accent, 0.4 + 0.6 * foc) else gfx.withAlpha(pal.border, 0.7 + 0.3 * hov));
    _ = g.textCentered(.ui_bold, home_font + 4, r.x + 18, r.y - 1, r.h, "❯", pal.accent);

    const text_x = homeTextX(win_w, win_h);
    const inner_w = r.w - (text_x - r.x) - 18;
    const fm = g.metrics(.ui, home_font);
    const tb = @round(r.y + (r.h - (fm.ascent + fm.descent)) / 2 + fm.ascent);
    g.pushClip(text_x - 2, r.y, inner_w + 4, r.h, 0);
    defer g.popClip();
    if (bar.focused) {
        drawEditing(g, bar, text_x, inner_w, r, tb, home_font, "search the web or enter an address", now_ms);
    } else {
        _ = g.text(.ui, home_font, text_x, tb, "search the web or enter an address", pal.disabled);
    }
}

pub fn homeTextX(win_w: f32, win_h: f32) f32 {
    return homeSearchRect(win_w, win_h).x + 44;
}

/// Rounded window outline (drawn last, when not maximized).
pub fn drawWindowFrame(g: *Gfx, w: f32, h: f32) void {
    g.border(0, 0, w, h, 1, window_radius, gfx.withAlpha(pal.border, 0.9));
}

/// Shown over pages that render nothing because they are built by JavaScript.
pub fn drawScriptNotice(g: *Gfx, win_w: f32, top: f32, win_h: f32, host: []const u8) void {
    const w = @min(560, win_w - 48);
    const h: f32 = 132;
    const x = @round((win_w - w) / 2);
    const y = @round(top + (win_h - top - h) / 2);
    g.shadow(x, y, w, h, 12, 24, 8, rgba(0, 0, 0, if (pal.dark) 0.45 else 0.15));
    g.roundRect(x, y, w, h, 12, pal.surface);
    g.border(x, y, w, h, 1, 12, pal.border);
    g.roundRect(x, y, 4, h, 2, pal.accent);
    var buf: [160]u8 = undefined;
    const title = std.fmt.bufPrint(&buf, "{s} needs JavaScript", .{if (host.len > 0) host else "this page"}) catch "this page needs JavaScript";
    _ = g.text(.ui_bold, 15, x + 24, y + 38, title, pal.fg);
    _ = g.text(.ui, 13, x + 24, y + 68, "This page is built by scripts in the browser, and", pal.muted);
    _ = g.text(.ui, 13, x + 24, y + 88, "Red Browser doesn't run JavaScript yet. The HTML it", pal.muted);
    _ = g.text(.ui, 13, x + 24, y + 108, "sent has no content to show.", pal.muted);
}

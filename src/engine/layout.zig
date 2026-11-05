//! Layout: turns a styled DOM into a positioned list of paint items.
//!
//! Supports block flow with (simplified) margin collapsing, inline formatting with
//! word wrapping and text alignment, preformatted text, lists with markers,
//! auto-sized tables (colspan, cellpadding, valign) and atomic inline boxes for
//! form controls and images. Coordinates are page-relative logical pixels.

const std = @import("std");
const gfx = @import("gfx.zig");
const dom = @import("dom.zig");
const css = @import("style.zig");

const Style = css.Style;
const Color = gfx.Color;

pub const Item = union(enum) {
    rect: struct { x: f32, y: f32, w: f32, h: f32, color: Color, radius: f32 = 0 },
    border: struct { x: f32, y: f32, w: f32, h: f32, width: f32, radius: f32, color: Color },
    text: struct { x: f32, y: f32, font: gfx.Font, size: f32, str: []const u8, color: Color },

    fn shift(self: *Item, dy: f32) void {
        switch (self.*) {
            inline else => |*v| v.y += dy,
        }
    }

    fn top(self: *const Item) f32 {
        return switch (self.*) {
            .rect => |r| r.y,
            .border => |b| b.y,
            .text => |t| t.y - t.size,
        };
    }

    fn bottom(self: *const Item) f32 {
        return switch (self.*) {
            .rect => |r| r.y + r.h,
            .border => |b| b.y + b.h,
            .text => |t| t.y + t.size * 0.4,
        };
    }
};

pub const Link = struct { x: f32, y: f32, w: f32, h: f32, href: []const u8 };

pub const Page = struct {
    arena: std.heap.ArenaAllocator,
    items: std.ArrayListUnmanaged(Item) = .{},
    links: std.ArrayListUnmanaged(Link) = .{},
    width: f32 = 0,
    height: f32 = 0,
    background: Color = gfx.hex(0xffffff),

    pub fn deinit(self: *Page) void {
        self.arena.deinit();
    }

    pub fn linkAt(self: *const Page, x: f32, y: f32) ?[]const u8 {
        var i = self.links.items.len;
        while (i > 0) {
            i -= 1;
            const l = self.links.items[i];
            if (x >= l.x and x < l.x + l.w and y >= l.y and y < l.y + l.h) return l.href;
        }
        return null;
    }

    /// Paint items intersecting the viewport. (`ox`,`oy`) is where page (0,0) lands
    /// on screen after scrolling.
    pub fn paint(self: *const Page, g: *gfx.Gfx, ox: f32, oy: f32, view_h: f32, scroll: f32) void {
        const lo = scroll - 50;
        const hi = scroll + view_h + 50;
        for (self.items.items) |*it| {
            if (it.bottom() < lo or it.top() > hi) continue;
            switch (it.*) {
                .rect => |r| g.roundRect(ox + r.x, oy + r.y, r.w, r.h, r.radius, r.color),
                .border => |b| g.border(ox + b.x, oy + b.y, b.w, b.h, b.width, b.radius, b.color),
                .text => |t| _ = g.text(t.font, t.size, ox + t.x, oy + t.y, t.str, t.color),
            }
        }
    }
};

const BoxKind = enum { image, text_input, button, checkbox, radio, textarea };

const Run = struct {
    style: *const Style,
    href: ?[]const u8,
    x: f32,
    w: f32,
    text: std.ArrayListUnmanaged(u8) = .{},
    box: ?struct { kind: BoxKind, h: f32, label: []const u8 } = null,
};

const Marker = struct { x: f32, text: []const u8, style: *const Style };

const Ctx = struct {
    g: *const gfx.Gfx,
    doc: *const dom.Document,
    a: std.mem.Allocator,
    page: *Page,
    marker: ?Marker = null,
    depth: u32 = 0,

    fn item(self: *Ctx, it: Item) !void {
        try self.page.items.append(self.a, it);
    }
    fn slot(self: *Ctx) !usize {
        try self.page.items.append(self.a, .{ .rect = .{ .x = 0, .y = 0, .w = 0, .h = 0, .color = gfx.rgba(0, 0, 0, 0) } });
        return self.page.items.items.len - 1;
    }
};

/// Inline formatting state of one block container.
const Flow = struct {
    ctx: *Ctx,
    x0: f32,
    width: f32,
    y: f32,
    text_align: css.Align,
    pending_margin: f32 = 0,
    runs: std.ArrayListUnmanaged(Run) = .{},
    line_x: f32 = 0,
    pending_space: bool = false,
    last_style: *const Style,

    fn advanceMargin(self: *Flow) void {
        self.y += self.pending_margin;
        self.pending_margin = 0;
    }

    fn runFor(self: *Flow, s: *const Style, href: ?[]const u8) !*Run {
        if (self.runs.items.len > 0) {
            const last = &self.runs.items[self.runs.items.len - 1];
            if (last.box == null and last.style == s and eqlOpt(last.href, href)) return last;
        }
        try self.runs.append(self.ctx.a, .{ .style = s, .href = href, .x = self.line_x, .w = 0 });
        return &self.runs.items[self.runs.items.len - 1];
    }

    fn addWord(self: *Flow, s: *const Style, href: ?[]const u8, word: []const u8) !void {
        const g = self.ctx.g;
        const f = s.font();
        const w = g.measure(f, s.font_size, word);
        const space = if (self.pending_space and self.runs.items.len > 0) g.measure(f, s.font_size, " ") else 0;
        if (self.runs.items.len > 0 and self.line_x + space + w > self.width) {
            try self.flushLine(false);
            return self.addWord(s, href, word);
        }
        if (self.runs.items.len == 0 and self.pending_margin > 0) self.advanceMargin();
        if (space > 0) {
            // Keep the space inside the previous run when styles match so that
            // text and underlines stay continuous; otherwise it's just a gap.
            const prev = &self.runs.items[self.runs.items.len - 1];
            if (prev.box == null and prev.style == s and eqlOpt(prev.href, href)) {
                try prev.text.append(self.ctx.a, ' ');
                prev.w += space;
            }
            self.line_x += space;
        }
        const run = try self.runFor(s, href);
        try run.text.appendSlice(self.ctx.a, word);
        run.w += w;
        self.line_x += w;
        self.pending_space = false;
        self.last_style = s;
    }

    fn addBox(self: *Flow, s: *const Style, href: ?[]const u8, kind: BoxKind, w: f32, h: f32, label: []const u8) !void {
        const space = if (self.pending_space and self.runs.items.len > 0) self.ctx.g.measure(s.font(), s.font_size, " ") else 0;
        if (self.runs.items.len > 0 and self.line_x + space + w > self.width) try self.flushLine(false);
        if (self.runs.items.len == 0 and self.pending_margin > 0) self.advanceMargin();
        if (self.runs.items.len > 0) self.line_x += space;
        try self.runs.append(self.ctx.a, .{ .style = s, .href = href, .x = self.line_x, .w = w, .box = .{ .kind = kind, .h = h, .label = label } });
        self.line_x += w;
        self.pending_space = false;
    }

    fn flushLine(self: *Flow, force: bool) !void {
        const ctx = self.ctx;
        const g = ctx.g;
        if (self.runs.items.len == 0) {
            if (force) {
                self.advanceMargin();
                self.y += @round(self.last_style.font_size * self.last_style.line_height);
            }
            self.pending_space = false;
            return;
        }
        self.advanceMargin();

        var asc: f32 = 0;
        var desc: f32 = 0;
        for (self.runs.items) |r| {
            const m = g.metrics(r.style.font(), r.style.font_size);
            if (r.box) |b| {
                asc = @max(asc, b.h);
                desc = @max(desc, m.descent);
            } else {
                const lh = r.style.font_size * r.style.line_height;
                const half = (lh - (m.ascent + m.descent)) / 2;
                asc = @max(asc, m.ascent + half);
                desc = @max(desc, m.descent + half);
            }
        }
        const line_h = @ceil(asc + desc);
        const baseline = @round(self.y + asc);
        const free = @max(0, self.width - self.line_x);
        const off: f32 = switch (self.text_align) {
            .left => 0,
            .center => @round(free / 2),
            .right => free,
        };

        if (ctx.marker) |mk| {
            const s = mk.style;
            const mw = g.measure(s.font(), s.font_size, mk.text);
            try ctx.item(.{ .text = .{ .x = mk.x - mw - 6, .y = baseline, .font = s.font(), .size = s.font_size, .str = mk.text, .color = s.color } });
            ctx.marker = null;
        }

        for (self.runs.items) |r| {
            const s = r.style;
            const rx = self.x0 + off + r.x;
            if (r.box) |b| {
                try paintBox(ctx, s, b.kind, rx, baseline - b.h, r.w, b.h, b.label);
            } else {
                // trim trailing space from painted width (kept for spacing only)
                var str = r.text.items;
                var w = r.w;
                if (str.len > 0 and str[str.len - 1] == ' ') {
                    str = str[0 .. str.len - 1];
                    w -= g.measure(s.font(), s.font_size, " ");
                }
                if (s.background) |bg| try ctx.item(.{ .rect = .{ .x = rx, .y = self.y, .w = w, .h = line_h, .color = bg } });
                if (!s.hidden) {
                    try ctx.item(.{ .text = .{ .x = rx, .y = baseline, .font = s.font(), .size = s.font_size, .str = str, .color = s.color } });
                    const t = @max(1, @round(s.font_size / 16));
                    if (s.underline) try ctx.item(.{ .rect = .{ .x = rx, .y = baseline + @round(s.font_size * 0.12), .w = w, .h = t, .color = s.color } });
                    if (s.strike) try ctx.item(.{ .rect = .{ .x = rx, .y = baseline - @round(s.font_size * 0.3), .w = w, .h = t, .color = s.color } });
                }
            }
            if (r.href) |h| try ctx.page.links.append(ctx.a, .{ .x = rx, .y = self.y, .w = r.w, .h = line_h, .href = h });
        }

        self.y += line_h;
        self.runs.clearRetainingCapacity();
        self.line_x = 0;
        self.pending_space = false;
    }
};

fn eqlOpt(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return a.?.ptr == b.?.ptr;
}

fn paintBox(ctx: *Ctx, s: *const Style, kind: BoxKind, x: f32, y: f32, w: f32, h: f32, label: []const u8) !void {
    const fg = s.font();
    switch (kind) {
        .image => {
            try ctx.item(.{ .rect = .{ .x = x, .y = y, .w = w, .h = h, .color = gfx.hex(0xf0f0f4) } });
            try ctx.item(.{ .border = .{ .x = x, .y = y, .w = w, .h = h, .width = 1, .radius = 0, .color = gfx.hex(0xcfcfd8) } });
            if (label.len > 0 and h >= s.font_size) {
                const fit = ctx.g.fitPrefix(fg, s.font_size * 0.85, label, w - 8);
                try ctx.item(.{ .text = .{ .x = x + 4, .y = y + s.font_size, .font = fg, .size = s.font_size * 0.85, .str = label[0..fit], .color = gfx.hex(0x5b5b66) } });
            }
        },
        .text_input, .textarea => {
            try ctx.item(.{ .rect = .{ .x = x, .y = y, .w = w, .h = h, .color = gfx.hex(0xffffff), .radius = 4 } });
            try ctx.item(.{ .border = .{ .x = x, .y = y, .w = w, .h = h, .width = 1, .radius = 4, .color = gfx.hex(0x8f8f9d) } });
            if (label.len > 0) {
                const size = s.font_size * 0.875;
                const fit = ctx.g.fitPrefix(.sans, size, label, w - 10);
                try ctx.item(.{ .text = .{ .x = x + 5, .y = y + @round(size + (if (kind == .textarea) 4 else (h - size) / 2 - 2)), .font = .sans, .size = size, .str = label[0..fit], .color = gfx.hex(0x6b6b78) } });
            }
        },
        .button => {
            try ctx.item(.{ .rect = .{ .x = x, .y = y, .w = w, .h = h, .color = gfx.hex(0xe9e9ed), .radius = 4 } });
            try ctx.item(.{ .border = .{ .x = x, .y = y, .w = w, .h = h, .width = 1, .radius = 4, .color = gfx.hex(0x8f8f9d) } });
            const size = s.font_size * 0.875;
            try ctx.item(.{ .text = .{ .x = x + 8, .y = y + @round((h + size * 0.7) / 2), .font = .sans, .size = size, .str = label, .color = gfx.hex(0x15141a) } });
        },
        .checkbox, .radio => {
            const r: f32 = if (kind == .radio) h / 2 else 2;
            try ctx.item(.{ .rect = .{ .x = x, .y = y, .w = w, .h = h, .color = gfx.hex(0xffffff), .radius = r } });
            try ctx.item(.{ .border = .{ .x = x, .y = y, .w = w, .h = h, .width = 1, .radius = r, .color = gfx.hex(0x8f8f9d) } });
        },
    }
}

fn isBlockLevel(d: css.Display) bool {
    return switch (d) {
        .block, .list_item, .table, .table_row, .table_cell => true,
        else => false,
    };
}

/// Lay out a whole document at the given viewport width.
pub fn layoutDocument(allocator: std.mem.Allocator, g: *const gfx.Gfx, doc: *const dom.Document, width: f32) !Page {
    var page = Page{ .arena = std.heap.ArenaAllocator.init(allocator), .width = width };
    errdefer page.deinit();
    var ctx = Ctx{ .g = g, .doc = doc, .a = page.arena.allocator(), .page = &page };

    const root_style = try ctx.a.create(Style);
    root_style.* = .{ .display = .block };

    // Canvas background comes from <body> or <html>.
    for ([_][]const u8{ "html", "body" }) |tag| {
        if (doc.find(tag)) |i| {
            const s = css.compute(doc, doc.get(i), root_style);
            if (s.background) |bg| page.background = bg;
        }
    }

    var flow = Flow{ .ctx = &ctx, .x0 = 0, .width = width, .y = 0, .text_align = .left, .last_style = root_style };
    var it = doc.children(0);
    while (it.next()) |c| try layoutNode(&ctx, &flow, c, root_style, null);
    try flow.flushLine(false);
    page.height = flow.y + flow.pending_margin;
    return page;
}

fn layoutNode(ctx: *Ctx, flow: *Flow, idx: u32, parent: *const Style, href: ?[]const u8) anyerror!void {
    const node = ctx.doc.get(idx);
    switch (node.kind) {
        .text => return layoutText(ctx, flow, node.text, parent, href),
        .element => {},
        else => return,
    }
    if (ctx.depth > 256) return;
    ctx.depth += 1;
    defer ctx.depth -= 1;

    const s = try ctx.a.create(Style);
    s.* = css.compute(ctx.doc, node, parent);
    if (s.display == .none) return;
    // The canvas already painted these.
    if (node.is("html") or node.is("body")) s.background = null;

    var link = href;
    if (node.is("a")) {
        if (node.attr("href")) |h| link = h;
    }

    if (node.is("br")) return flow.flushLine(true);
    if (try layoutReplaced(ctx, flow, node, s, link)) return;

    if (isBlockLevel(s.display)) {
        try flow.flushLine(false);
        return layoutBlock(ctx, flow, idx, s, link);
    }

    var it = ctx.doc.children(idx);
    while (it.next()) |c| try layoutNode(ctx, flow, c, s, link);
}

fn layoutText(ctx: *Ctx, flow: *Flow, text: []const u8, s: *const Style, href: ?[]const u8) !void {
    if (s.pre) {
        var lines = std.mem.splitScalar(u8, text, '\n');
        var first = true;
        while (lines.next()) |line| {
            if (!first) try flow.flushLine(true);
            first = false;
            if (line.len == 0) continue;
            var buf = std.ArrayListUnmanaged(u8){};
            for (line) |ch| {
                if (ch == '\t') {
                    try buf.appendNTimes(ctx.a, ' ', 8 - (buf.items.len % 8));
                } else if (ch != '\r') try buf.append(ctx.a, ch);
            }
            const run = try flow.runFor(s, href);
            const w = ctx.g.measure(s.font(), s.font_size, buf.items);
            if (flow.runs.items.len == 1 and run.text.items.len == 0 and flow.pending_margin > 0) flow.advanceMargin();
            try run.text.appendSlice(ctx.a, buf.items);
            run.w += w;
            flow.line_x += w;
            flow.last_style = s;
        }
        return;
    }
    if (text.len > 0 and std.ascii.isWhitespace(text[0])) flow.pending_space = true;
    var words = std.mem.tokenizeAny(u8, text, " \t\r\n\x0c");
    while (words.next()) |w| {
        try flow.addWord(s, href, w);
        flow.pending_space = true;
    }
    if (text.len > 0 and !std.ascii.isWhitespace(text[text.len - 1])) flow.pending_space = false;
}

/// Form controls and images: atomic inline boxes. Returns true if handled.
fn layoutReplaced(ctx: *Ctx, flow: *Flow, node: *const dom.Node, s: *const Style, href: ?[]const u8) !bool {
    const fs = s.font_size;
    const lh = @round(fs * 1.5);
    if (node.is("img")) {
        const w = attrNum(node, "width");
        const h = attrNum(node, "height");
        const alt = node.attr("alt") orelse "";
        if (w == null and h == null) {
            if (alt.len > 0) try layoutText(ctx, flow, alt, s, href);
            return true;
        }
        const bw = @min(w orelse h.?, flow.width);
        const bh = h orelse w.?;
        if (bw >= 1 and bh >= 1) try flow.addBox(s, href, .image, bw, bh, alt);
        return true;
    }
    if (node.is("input")) {
        const ty = node.attr("type") orelse "text";
        if (std.ascii.eqlIgnoreCase(ty, "hidden")) return true;
        if (std.ascii.eqlIgnoreCase(ty, "checkbox")) {
            try flow.addBox(s, href, .checkbox, 13, 13, "");
        } else if (std.ascii.eqlIgnoreCase(ty, "radio")) {
            try flow.addBox(s, href, .radio, 13, 13, "");
        } else if (std.ascii.eqlIgnoreCase(ty, "submit") or std.ascii.eqlIgnoreCase(ty, "button") or std.ascii.eqlIgnoreCase(ty, "reset")) {
            const label = node.attr("value") orelse (if (std.ascii.eqlIgnoreCase(ty, "reset")) "Reset" else "Submit");
            try flow.addBox(s, href, .button, ctx.g.measure(.sans, fs * 0.875, label) + 16, lh, label);
        } else {
            const label = node.attr("value") orelse node.attr("placeholder") orelse "";
            const size = attrNum(node, "size") orelse 20;
            try flow.addBox(s, href, .text_input, @min(flow.width, size * fs * 0.5 + 10), lh, label);
        }
        return true;
    }
    if (node.is("button")) {
        const label = std.mem.trim(u8, try ctx.doc.textContent(ctx.a, @intCast(nodeIndex(ctx.doc, node))), " \n\t\r");
        try flow.addBox(s, href, .button, ctx.g.measure(.sans, fs * 0.875, label) + 16, lh, label);
        return true;
    }
    if (node.is("textarea")) {
        const cols = attrNum(node, "cols") orelse 20;
        const rows = attrNum(node, "rows") orelse 2;
        const label = node.attr("placeholder") orelse "";
        try flow.addBox(s, href, .textarea, @min(flow.width, cols * fs * 0.55 + 10), rows * fs * 1.2 + 8, label);
        return true;
    }
    if (node.is("select")) {
        var label: []const u8 = "";
        const i = nodeIndex(ctx.doc, node);
        if (firstDescendant(ctx.doc, i, "option")) |o| {
            label = std.mem.trim(u8, try ctx.doc.textContent(ctx.a, o), " \n\t\r");
        }
        const w = @max(60, ctx.g.measure(.sans, fs * 0.875, label) + 32);
        try flow.addBox(s, href, .button, w, lh, label);
        return true;
    }
    return false;
}

fn nodeIndex(doc: *const dom.Document, node: *const dom.Node) u32 {
    return @intCast((@intFromPtr(node) - @intFromPtr(doc.nodes.ptr)) / @sizeOf(dom.Node));
}

fn firstDescendant(doc: *const dom.Document, i: u32, tag: []const u8) ?u32 {
    var it = doc.children(i);
    while (it.next()) |c| {
        if (doc.get(c).is(tag)) return c;
        if (firstDescendant(doc, c, tag)) |d| return d;
    }
    return null;
}

fn attrNum(node: *const dom.Node, name: []const u8) ?f32 {
    const v = node.attr(name) orelse return null;
    if (std.mem.endsWith(u8, v, "%")) return null;
    const t = std.mem.trimRight(u8, std.mem.trim(u8, v, " "), "px");
    return std.fmt.parseFloat(f32, t) catch null;
}

fn layoutBlock(ctx: *Ctx, flow: *Flow, idx: u32, s: *Style, href: ?[]const u8) anyerror!void {
    const node = ctx.doc.get(idx);
    flow.y += @max(flow.pending_margin, s.margin.top);
    flow.pending_margin = 0;

    const bw = s.border_width;
    const horiz_extra = s.padding.left + s.padding.right + 2 * bw;
    var w = flow.width - s.margin.left - s.margin.right;
    if (s.width) |cw| w = @min(w, cw + horiz_extra);
    if (s.max_width) |mw| w = @min(w, mw + horiz_extra);
    w = @max(w, 0);
    var x = flow.x0 + s.margin.left;
    if (s.margin_auto and w < flow.width) x = flow.x0 + @round((flow.width - w) / 2);

    const has_bg = s.background != null;
    const bg_slot = if (has_bg) try ctx.slot() else 0;
    const y0 = flow.y;
    const cx = x + bw + s.padding.left;
    const cw = @max(0, w - horiz_extra);
    const cy = y0 + bw + s.padding.top;

    var h: f32 = 0;
    if (node.is("hr")) {
        try ctx.item(.{ .rect = .{ .x = x, .y = cy, .w = w, .h = 1, .color = gfx.hex(0xcfcfd8) } });
        h = 1;
    } else if (s.display == .table) {
        h = try layoutTable(ctx, idx, s, cx, cw, cy, href);
    } else {
        if (s.display == .list_item) {
            ctx.marker = .{ .x = cx, .text = try markerText(ctx, flow, s), .style = s };
        }
        h = try layoutChildren(ctx, idx, s, cx, cw, cy, href);
        if (s.display == .list_item) ctx.marker = null;
    }

    const total = h + 2 * bw + s.padding.top + s.padding.bottom;
    if (has_bg) ctx.page.items.items[bg_slot] = .{ .rect = .{ .x = x, .y = y0, .w = w, .h = total, .color = s.background.?, .radius = s.radius } };
    if (bw > 0 and !node.is("hr")) try ctx.item(.{ .border = .{ .x = x, .y = y0, .w = w, .h = total, .width = bw, .radius = s.radius, .color = s.border_color } });

    flow.y = y0 + total;
    flow.pending_margin = s.margin.bottom;
    flow.last_style = s;
}

fn markerText(ctx: *Ctx, flow: *Flow, s: *const Style) ![]const u8 {
    _ = flow;
    return switch (s.list_style) {
        .none => "",
        .disc => "•",
        .circle => "◦",
        .square => "▪",
        .decimal => try std.fmt.allocPrint(ctx.a, "{d}.", .{listCounterValue()}),
    };
}

fn layoutChildren(ctx: *Ctx, idx: u32, s: *const Style, x: f32, w: f32, y: f32, href: ?[]const u8) anyerror!f32 {
    var flow = Flow{ .ctx = ctx, .x0 = x, .width = w, .y = y, .text_align = s.text_align, .last_style = s };
    const saved_counter = list_counter;
    if (ctx.doc.get(idx).is("ol")) {
        list_counter = 0;
        if (ctx.doc.get(idx).attr("start")) |st| list_counter = (std.fmt.parseInt(i32, st, 10) catch 1) - 1;
    }
    defer {
        if (ctx.doc.get(idx).is("ol")) list_counter = saved_counter;
    }
    var it = ctx.doc.children(idx);
    while (it.next()) |c| {
        if (ctx.doc.get(c).is("li")) list_counter += 1;
        try layoutNode(ctx, &flow, c, s, href);
    }
    try flow.flushLine(false);
    return flow.y + flow.pending_margin - y;
}

// Ordered-list counter for the list currently being laid out (layout is single-threaded).
threadlocal var list_counter: i32 = 0;

fn listCounterValue() i32 {
    return list_counter;
}

// ---------------------------------------------------------------------------
// Tables
// ---------------------------------------------------------------------------

const Cell = struct { node: u32, style: *Style, col: usize, span: usize };
const Row = struct { node: u32, style: *Style, cells: std.ArrayListUnmanaged(Cell) = .{} };

fn collectRows(ctx: *Ctx, idx: u32, s: *const Style, rows: *std.ArrayListUnmanaged(Row), pad: ?f32) !void {
    var it = ctx.doc.children(idx);
    while (it.next()) |c| {
        const n = ctx.doc.get(c);
        if (n.kind != .element) continue;
        const cs = try ctx.a.create(Style);
        cs.* = css.compute(ctx.doc, n, s);
        if (cs.display == .none) continue;
        if (n.is("tr")) {
            var row = Row{ .node = c, .style = cs };
            var col: usize = 0;
            var ci = ctx.doc.children(c);
            while (ci.next()) |cc| {
                const cn = ctx.doc.get(cc);
                if (!(cn.is("td") or cn.is("th"))) continue;
                const cell_s = try ctx.a.create(Style);
                cell_s.* = css.compute(ctx.doc, cn, cs);
                if (cell_s.display == .none) continue;
                if (pad) |p| {
                    const st = cn.attr("style") orelse "";
                    if (std.mem.indexOf(u8, st, "padding") == null) cell_s.padding = .{ .top = p, .right = p, .bottom = p, .left = p };
                }
                const span: usize = @intFromFloat(std.math.clamp(attrNum(cn, "colspan") orelse 1, 1, 64));
                try row.cells.append(ctx.a, .{ .node = cc, .style = cell_s, .col = col, .span = span });
                col += span;
            }
            try rows.append(ctx.a, row);
        } else if (n.is("tbody") or n.is("thead") or n.is("tfoot")) {
            try collectRows(ctx, c, cs, rows, pad);
        }
    }
}

const Intrinsic = struct { min: f32 = 0, pref: f32 = 0, cur: f32 = 0 };

fn intrinsic(ctx: *Ctx, idx: u32, s: *const Style, acc: *Intrinsic, depth: u32) !void {
    if (depth > 64) return;
    var it = ctx.doc.children(idx);
    while (it.next()) |c| {
        const n = ctx.doc.get(c);
        if (n.kind == .text) {
            var words = std.mem.tokenizeAny(u8, n.text, " \t\r\n");
            const space = ctx.g.measure(s.font(), s.font_size, " ");
            while (words.next()) |wd| {
                const ww = ctx.g.measure(s.font(), s.font_size, wd);
                acc.min = @max(acc.min, ww);
                acc.cur += ww + space;
            }
        } else if (n.kind == .element) {
            var cs = css.compute(ctx.doc, n, s);
            if (cs.display == .none) continue;
            if (n.is("img") or n.is("input") or n.is("textarea")) {
                const ww = attrNum(n, "width") orelse 120;
                acc.min = @max(acc.min, ww);
                acc.cur += ww;
                continue;
            }
            if (cs.width) |ww| acc.min = @max(acc.min, ww);
            const block = isBlockLevel(cs.display) and cs.display != .table_cell;
            if (block or n.is("br")) {
                acc.pref = @max(acc.pref, acc.cur);
                acc.cur = 0;
            }
            const extra = cs.padding.left + cs.padding.right + cs.margin.left + cs.margin.right;
            acc.cur += extra;
            try intrinsic(ctx, c, &cs, acc, depth + 1);
            if (block) {
                acc.pref = @max(acc.pref, acc.cur);
                acc.cur = 0;
            }
        }
    }
}

fn layoutTable(ctx: *Ctx, idx: u32, s: *const Style, x: f32, avail: f32, y0: f32, href: ?[]const u8) !f32 {
    const node = ctx.doc.get(idx);
    const spacing: f32 = attrNum(node, "cellspacing") orelse 2;
    const pad = attrNum(node, "cellpadding");
    var rows = std.ArrayListUnmanaged(Row){};
    try collectRows(ctx, idx, s, &rows, pad);

    var ncols: usize = 0;
    for (rows.items) |r| {
        for (r.cells.items) |c| ncols = @max(ncols, c.col + c.span);
    }
    var y = y0;
    // caption
    if (firstChildTag(ctx.doc, idx, "caption")) |cap| {
        const cs = try ctx.a.create(Style);
        cs.* = css.compute(ctx.doc, ctx.doc.get(cap), s);
        cs.text_align = .center;
        y += try layoutChildren(ctx, cap, cs, x, avail, y, href);
    }
    if (ncols == 0) return y - y0;

    // column widths
    const mins = try ctx.a.alloc(f32, ncols);
    const prefs = try ctx.a.alloc(f32, ncols);
    @memset(mins, 0);
    @memset(prefs, 0);
    for (rows.items) |r| {
        for (r.cells.items) |c| {
            if (c.span != 1) continue;
            var acc = Intrinsic{};
            try intrinsic(ctx, c.node, c.style, &acc, 0);
            const pad_x = c.style.padding.left + c.style.padding.right;
            var pref = @max(acc.pref, acc.cur) + pad_x;
            const minw = acc.min + pad_x;
            if (attrNum(ctx.doc.get(c.node), "width")) |fixed| pref = @max(fixed, minw);
            mins[c.col] = @max(mins[c.col], minw);
            prefs[c.col] = @max(prefs[c.col], @max(pref, minw));
        }
    }
    const inner = avail - spacing * @as(f32, @floatFromInt(ncols + 1));
    var sum_min: f32 = 0;
    var sum_pref: f32 = 0;
    for (mins, prefs) |m, p| {
        sum_min += m;
        sum_pref += p;
    }
    var target = inner;
    const pct_full = if (node.attr("width")) |wa| std.mem.endsWith(u8, wa, "%") else false;
    if (s.width) |tw| target = @min(inner, tw - spacing * @as(f32, @floatFromInt(ncols + 1)));
    if (!pct_full and s.width == null) target = @min(inner, sum_pref);
    if (pct_full) {
        const pct = std.fmt.parseFloat(f32, std.mem.trimRight(u8, node.attr("width").?, "%")) catch 100;
        target = @min(inner, avail * pct / 100 - spacing * @as(f32, @floatFromInt(ncols + 1)));
    }
    const widths = try ctx.a.alloc(f32, ncols);
    if (sum_pref <= target) {
        const extra = target - sum_pref;
        for (widths, prefs) |*w, p| w.* = p + (if (sum_pref > 0) extra * p / sum_pref else extra / @as(f32, @floatFromInt(ncols)));
    } else if (sum_min >= target) {
        for (widths, mins) |*w, m| w.* = if (sum_min > 0) m * target / sum_min else target / @as(f32, @floatFromInt(ncols));
    } else {
        const extra = target - sum_min;
        const flex = sum_pref - sum_min;
        for (widths, mins, prefs) |*w, m, p| w.* = m + (if (flex > 0) extra * (p - m) / flex else 0);
    }
    var table_w = spacing;
    for (widths) |w| table_w += w + spacing;
    var tx = x;
    if (s.text_align == .center or s.margin_auto) tx = x + @max(0, (avail - table_w) / 2);

    const col_x = try ctx.a.alloc(f32, ncols + 1);
    col_x[0] = tx + spacing;
    for (widths, 0..) |w, i| col_x[i + 1] = col_x[i] + w + spacing;

    y += spacing;
    for (rows.items) |r| {
        const row_bg_slot = if (r.style.background != null) try ctx.slot() else null;
        var row_h: f32 = 0;
        const CellPos = struct { start: usize, end: usize, links_start: usize, links_end: usize, h: f32, slot: ?usize };
        const pos = try ctx.a.alloc(CellPos, r.cells.items.len);
        for (r.cells.items, 0..) |c, i| {
            const cs = c.style;
            const slot = if (cs.background != null) try ctx.slot() else null;
            const cx = col_x[c.col];
            const end_col = @min(c.col + c.span, ncols);
            const cw = col_x[end_col] - spacing - cx;
            const start = ctx.page.items.items.len;
            const lstart = ctx.page.links.items.len;
            const ch = try layoutChildren(ctx, c.node, cs, cx + cs.padding.left + cs.border_width, @max(0, cw - cs.padding.left - cs.padding.right), y + cs.padding.top, href);
            const total = ch + cs.padding.top + cs.padding.bottom;
            pos[i] = .{ .start = start, .end = ctx.page.items.items.len, .links_start = lstart, .links_end = ctx.page.links.items.len, .h = total, .slot = slot };
            row_h = @max(row_h, total);
            if (attrNum(ctx.doc.get(c.node), "height")) |hh| row_h = @max(row_h, hh);
        }
        if (row_bg_slot) |sl| ctx.page.items.items[sl] = .{ .rect = .{ .x = col_x[0] - spacing, .y = y, .w = table_w, .h = row_h, .color = r.style.background.? } };
        for (r.cells.items, pos) |c, p| {
            const cx = col_x[c.col];
            const end_col = @min(c.col + c.span, ncols);
            const cw = col_x[end_col] - spacing - cx;
            const valign = ctx.doc.get(c.node).attr("valign") orelse (ctx.doc.get(r.node).attr("valign") orelse "middle");
            const dy: f32 = if (std.ascii.eqlIgnoreCase(valign, "top")) 0 else if (std.ascii.eqlIgnoreCase(valign, "bottom")) row_h - p.h else @round((row_h - p.h) / 2);
            if (dy != 0) {
                for (ctx.page.items.items[p.start..p.end]) |*it| it.shift(dy);
                for (ctx.page.links.items[p.links_start..p.links_end]) |*l| l.y += dy;
            }
            if (p.slot) |sl| ctx.page.items.items[sl] = .{ .rect = .{ .x = cx, .y = y, .w = cw, .h = row_h, .color = c.style.background.? } };
            if (s.border_width > 0) try ctx.item(.{ .border = .{ .x = cx, .y = y, .w = cw, .h = row_h, .width = 1, .radius = 0, .color = s.border_color } });
        }
        y += row_h + spacing;
    }
    return y - y0;
}

fn firstChildTag(doc: *const dom.Document, idx: u32, tag: []const u8) ?u32 {
    var it = doc.children(idx);
    while (it.next()) |c| {
        if (doc.get(c).is(tag)) return c;
    }
    return null;
}

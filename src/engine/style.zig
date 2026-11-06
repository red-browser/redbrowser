//! Computed style: user-agent defaults per tag, inheritance, legacy presentational
//! attributes, author stylesheets (see cascade.zig) and inline `style="..."`.

const std = @import("std");
const gfx = @import("gfx.zig");
const dom = @import("dom.zig");
const cascade = @import("cascade.zig");

pub const Color = gfx.Color;

pub const Display = enum { block, inline_, inline_block, list_item, none, table, table_row, table_cell };
pub const Align = enum { left, center, right };
pub const ListStyle = enum { none, disc, circle, square, decimal };
pub const Justify = enum { start, center, end, space_between, space_around };
pub const Position = enum { static, relative, absolute, fixed, sticky };

pub const Edges = struct {
    top: f32 = 0,
    right: f32 = 0,
    bottom: f32 = 0,
    left: f32 = 0,
};

pub const Style = struct {
    display: Display = .inline_,
    // inherited
    font_size: f32 = 16,
    bold: bool = false,
    italic: bool = false,
    mono: bool = false,
    color: Color = gfx.hex(0x15141a),
    text_align: Align = .left,
    pre: bool = false,
    underline: bool = false,
    strike: bool = false,
    list_style: ListStyle = .disc,
    line_height: f32 = 1.25,
    /// visibility:hidden / opacity:0 — laid out but not painted.
    hidden: bool = false,
    /// Custom properties in scope.
    vars: ?*const cascade.Vars = null,
    // not inherited
    background: ?Color = null,
    margin: Edges = .{},
    /// `margin-left/right: auto` → centre the block horizontally.
    margin_auto: bool = false,
    padding: Edges = .{},
    border_width: f32 = 0,
    border_color: Color = gfx.hex(0x8f8f9d),
    radius: f32 = 0,
    width: ?f32 = null,
    max_width: ?f32 = null,
    /// Percentage widths (0..1 of the containing block).
    width_pct: ?f32 = null,
    max_width_pct: ?f32 = null,
    height: ?f32 = null,
    position: Position = .static,
    offset_left: ?f32 = null,
    offset_top: ?f32 = null,
    overflow_hidden: bool = false,
    clipped: bool = false,
    // flexbox (row direction only; column flex is plain block flow)
    flex: bool = false,
    flex_column: bool = false,
    flex_wrap: bool = false,
    flex_grow: f32 = 0,
    gap_x: f32 = 0,
    gap_y: f32 = 0,
    justify: Justify = .start,
    align_center: bool = false,
    // grid (raw values; parsed by layout)
    grid: bool = false,
    grid_columns: []const u8 = "",
    grid_areas: []const u8 = "",
    grid_area: []const u8 = "",
    grid_column: []const u8 = "",

    pub fn flexRow(self: *const Style) bool {
        return self.flex and !self.flex_column;
    }

    pub fn font(self: *const Style) gfx.Font {
        return gfx.Font.pick(self.mono, self.bold, self.italic);
    }

    /// Start a child's style: inherited properties copied, the rest reset.
    pub fn inherit(parent: *const Style) Style {
        return .{
            .font_size = parent.font_size,
            .bold = parent.bold,
            .italic = parent.italic,
            .mono = parent.mono,
            .color = parent.color,
            .text_align = parent.text_align,
            .pre = parent.pre,
            .underline = parent.underline,
            .strike = parent.strike,
            .list_style = parent.list_style,
            .line_height = parent.line_height,
            .hidden = parent.hidden,
            .vars = parent.vars,
        };
    }
};

pub const link_color = gfx.hex(0x0060df);

fn eq(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

fn anyOf(tag: []const u8, comptime list: []const []const u8) bool {
    inline for (list) |t| {
        if (std.mem.eql(u8, tag, t)) return true;
    }
    return false;
}

const hidden_tags = [_][]const u8{ "head", "script", "style", "title", "meta", "link", "template", "svg", "iframe", "object", "embed", "canvas", "video", "audio", "map", "area", "datalist", "dialog" };
const block_tags = [_][]const u8{ "html", "body", "div", "p", "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "dl", "dt", "dd", "pre", "blockquote", "hr", "address", "article", "aside", "footer", "header", "main", "nav", "section", "figure", "figcaption", "form", "fieldset", "legend", "details", "summary", "center", "menu", "caption", "hgroup", "search", "tbody", "thead", "tfoot", "picture" };

/// Compute the style of element `node` given its parent's computed style.
pub fn compute(doc: *const dom.Document, node: *const dom.Node, parent: *const Style) Style {
    var s = Style.inherit(parent);
    const tag = node.name;
    const em = parent.font_size;

    // --- user agent stylesheet --------------------------------------------
    if (anyOf(tag, &hidden_tags) or (doc.scripting and std.mem.eql(u8, tag, "noscript"))) {
        s.display = .none;
    } else if (anyOf(tag, &block_tags)) {
        s.display = .block;
    }

    if (std.mem.eql(u8, tag, "body")) {
        s.margin = .{ .top = 8, .right = 8, .bottom = 8, .left = 8 };
    } else if (std.mem.eql(u8, tag, "p") or std.mem.eql(u8, tag, "dl") or std.mem.eql(u8, tag, "figure")) {
        s.margin.top = em;
        s.margin.bottom = em;
    } else if (tag.len == 2 and tag[0] == 'h' and tag[1] >= '1' and tag[1] <= '6') {
        const sizes = [_]f32{ 2.0, 1.5, 1.17, 1.0, 0.83, 0.67 };
        const margins = [_]f32{ 0.67, 0.83, 1.0, 1.33, 1.67, 2.33 };
        const k = tag[1] - '1';
        s.font_size = em * sizes[k];
        s.bold = true;
        s.margin.top = s.font_size * margins[k];
        s.margin.bottom = s.font_size * margins[k];
    } else if (std.mem.eql(u8, tag, "ul") or std.mem.eql(u8, tag, "ol") or std.mem.eql(u8, tag, "menu")) {
        const nested = parent.display == .list_item;
        if (!nested) {
            s.margin.top = em;
            s.margin.bottom = em;
        }
        s.padding.left = 40;
        s.list_style = if (std.mem.eql(u8, tag, "ol")) .decimal else if (nested) .circle else .disc;
    } else if (std.mem.eql(u8, tag, "li")) {
        s.display = .list_item;
    } else if (std.mem.eql(u8, tag, "dd")) {
        s.margin.left = 40;
    } else if (std.mem.eql(u8, tag, "blockquote")) {
        s.margin = .{ .top = em, .bottom = em, .left = 40, .right = 40 };
    } else if (std.mem.eql(u8, tag, "pre")) {
        s.mono = true;
        s.pre = true;
        s.font_size = em * 0.8125;
        s.margin.top = em;
        s.margin.bottom = em;
    } else if (anyOf(tag, &.{ "code", "kbd", "samp", "tt", "var" })) {
        s.mono = true;
        s.font_size = em * 0.8125;
    } else if (anyOf(tag, &.{ "b", "strong", "th", "dt", "legend", "summary" })) {
        s.bold = true;
    } else if (anyOf(tag, &.{ "i", "em", "cite", "dfn", "address" })) {
        s.italic = true;
    } else if (anyOf(tag, &.{ "u", "ins" })) {
        s.underline = true;
    } else if (anyOf(tag, &.{ "s", "strike", "del" })) {
        s.strike = true;
    } else if (std.mem.eql(u8, tag, "small")) {
        s.font_size = em * 0.83;
    } else if (std.mem.eql(u8, tag, "big")) {
        s.font_size = em * 1.17;
    } else if (std.mem.eql(u8, tag, "sub") or std.mem.eql(u8, tag, "sup")) {
        s.font_size = em * 0.83;
    } else if (std.mem.eql(u8, tag, "mark")) {
        s.background = gfx.hex(0xffff00);
    } else if (std.mem.eql(u8, tag, "center")) {
        s.text_align = .center;
    } else if (std.mem.eql(u8, tag, "hr")) {
        s.margin.top = em * 0.5;
        s.margin.bottom = em * 0.5;
        s.border_width = 1;
    } else if (std.mem.eql(u8, tag, "a")) {
        if (node.attr("href") != null) {
            s.color = link_color;
            s.underline = true;
        }
    } else if (std.mem.eql(u8, tag, "table")) {
        s.display = .table;
    } else if (std.mem.eql(u8, tag, "tr")) {
        s.display = .table_row;
    } else if (std.mem.eql(u8, tag, "td") or std.mem.eql(u8, tag, "th")) {
        s.display = .table_cell;
        s.padding = .{ .top = 1, .right = 4, .bottom = 1, .left = 4 };
    } else if (anyOf(tag, &.{ "button", "input", "select", "textarea", "img" })) {
        s.display = .inline_block;
    } else if (std.mem.eql(u8, tag, "fieldset")) {
        s.margin = .{ .left = 2, .right = 2, .top = 0, .bottom = 0 };
        s.padding = .{ .top = 6, .right = 12, .bottom = 10, .left = 12 };
        s.border_width = 1;
    }

    // --- presentational attributes ----------------------------------------
    if (node.attr("hidden") != null) s.display = .none;
    if (node.attr("align")) |a| {
        if (eq(a, "center") or eq(a, "middle")) s.text_align = .center else if (eq(a, "right")) s.text_align = .right;
    }
    if (node.attr("bgcolor")) |v| {
        if (parseColor(v)) |c| s.background = c;
    }
    if (std.mem.eql(u8, tag, "font")) {
        if (node.attr("color")) |v| {
            if (parseColor(v)) |c| s.color = c;
        }
        if (node.attr("face")) |v| {
            if (std.ascii.indexOfIgnoreCase(v, "mono") != null or std.ascii.indexOfIgnoreCase(v, "courier") != null) s.mono = true;
        }
        if (node.attr("size")) |v| {
            const n = std.fmt.parseInt(i32, std.mem.trim(u8, v, " +"), 10) catch 3;
            const table = [_]f32{ 10, 13, 16, 18, 24, 32, 48 };
            const rel = if (v.len > 0 and (v[0] == '+' or v[0] == '-')) 3 + (if (v[0] == '-') -n else n) else n;
            s.font_size = table[@intCast(std.math.clamp(rel, 1, 7) - 1)];
        }
    }
    if (std.mem.eql(u8, tag, "body")) {
        if (node.attr("text")) |v| {
            if (parseColor(v)) |c| s.color = c;
        }
    }
    if (node.attr("width")) |v| {
        if (!std.mem.endsWith(u8, v, "%")) {
            if (std.fmt.parseFloat(f32, v) catch null) |w| s.width = w;
        }
    }
    if (std.mem.eql(u8, tag, "table")) {
        if (node.attr("border")) |v| {
            s.border_width = std.fmt.parseFloat(f32, v) catch 1;
        }
    }

    // Quirk shared by all engines: tables don't inherit `text-align` from
    // <center>/align=center; the table box itself is centred instead.
    if (std.mem.eql(u8, tag, "table")) {
        if (s.text_align == .center) s.margin_auto = true;
        if (node.attr("align")) |a| {
            if (eq(a, "center")) s.margin_auto = true;
        }
        s.text_align = .left;
    }

    // --- author stylesheets + inline style="" --------------------------------
    if (doc.sheet) |sheet| {
        applyAuthor(&s, parent, sheet, doc, node);
    } else if (node.attr("style")) |decls| applyDeclarations(&s, parent, decls);

    // Common "visually hidden" / off-screen patterns. Without real positioning
    // these would otherwise show up as stray text in the flow.
    if (s.position == .absolute or s.position == .fixed) {
        if ((s.offset_left orelse 0) <= -500 or (s.offset_top orelse 0) <= -500 or s.clipped) s.display = .none;
        // Out-of-flow and invisible (closed dropdowns, tooltips): takes no space.
        if (s.hidden and !parent.hidden) s.display = .none;
    }
    if (s.width != null and s.height != null and s.width.? <= 1 and s.height.? <= 1) s.display = .none;
    if (s.overflow_hidden and s.height != null and s.height.? < 1) s.display = .none;
    return s;
}

/// Matched author rules then inline declarations, normal before `!important`,
/// with custom properties collected first so `var()` sees this element's values.
fn applyAuthor(s: *Style, parent: *const Style, sheet: *cascade.Sheet, doc: *const dom.Document, node: *const dom.Node) void {
    const a = sheet.scratchAllocator();
    const rules = sheet.matching(doc, doc.indexOf(node));
    var inline_decls = std.ArrayListUnmanaged(cascade.Decl){};
    if (node.attr("style")) |st| cascade.parseDecls(a, st, &inline_decls) catch {};
    if (rules.len == 0 and inline_decls.items.len == 0) return;

    var names = std.ArrayListUnmanaged([]const u8){};
    var values = std.ArrayListUnmanaged([]const u8){};
    for ([_]bool{ false, true }) |important| {
        for (rules) |r| for (r.decls) |d| {
            if (d.important == important and std.mem.startsWith(u8, d.prop, "--")) {
                names.append(a, d.prop) catch return;
                values.append(a, d.val) catch return;
            }
        };
        for (inline_decls.items) |d| {
            if (d.important == important and std.mem.startsWith(u8, d.prop, "--")) {
                names.append(a, d.prop) catch return;
                values.append(a, d.val) catch return;
            }
        }
    }
    if (names.items.len > 0) {
        const scope = a.create(cascade.Vars) catch return;
        scope.* = .{ .parent = s.vars, .names = names.items, .values = values.items };
        s.vars = scope;
    }

    for ([_]bool{ false, true }) |important| {
        for (rules) |r| for (r.decls) |d| {
            if (d.important == important and !std.mem.startsWith(u8, d.prop, "--")) applyValue(s, parent, a, d.prop, d.val);
        };
        for (inline_decls.items) |d| {
            if (d.important == important and !std.mem.startsWith(u8, d.prop, "--")) applyValue(s, parent, a, d.prop, d.val);
        }
    }
}

fn applyValue(s: *Style, parent: *const Style, a: std.mem.Allocator, prop: []const u8, val: []const u8) void {
    const v = cascade.substitute(a, val, s.vars) orelse return;
    applyOne(s, parent, prop, std.mem.trim(u8, v, " \t\r\n"));
}

/// Apply `prop: value; ...` declarations.
pub fn applyDeclarations(s: *Style, parent: *const Style, decls: []const u8) void {
    var it = std.mem.splitScalar(u8, decls, ';');
    while (it.next()) |decl| {
        const colon = std.mem.indexOfScalar(u8, decl, ':') orelse continue;
        const prop = std.mem.trim(u8, decl[0..colon], " \t\r\n");
        var val = std.mem.trim(u8, decl[colon + 1 ..], " \t\r\n");
        if (std.ascii.endsWithIgnoreCase(val, "!important")) val = std.mem.trim(u8, val[0 .. val.len - 10], " ");
        applyOne(s, parent, prop, val);
    }
}

fn applyOne(s: *Style, parent: *const Style, prop: []const u8, val: []const u8) void {
    const em = parent.font_size;
    if (eq(prop, "display")) {
        s.flex = eq(val, "flex") or eq(val, "inline-flex") or eq(val, "block flex") or eq(val, "inline flex");
        s.grid = eq(val, "grid") or eq(val, "inline-grid");
        if (eq(val, "none")) s.display = .none else if (eq(val, "block") or eq(val, "flex") or eq(val, "grid") or eq(val, "flow-root") or eq(val, "block flex") or eq(val, "block flow")) s.display = .block else if (eq(val, "inline") or eq(val, "contents")) s.display = .inline_ else if (eq(val, "inline-block") or eq(val, "inline-flex") or eq(val, "inline-grid")) s.display = .inline_block else if (eq(val, "list-item")) s.display = .list_item else if (eq(val, "table")) s.display = .table else if (eq(val, "table-row")) s.display = .table_row else if (eq(val, "table-cell")) s.display = .table_cell;
    } else if (eq(prop, "grid-template-columns")) {
        s.grid_columns = val;
    } else if (eq(prop, "grid-template-areas")) {
        s.grid_areas = val;
    } else if (eq(prop, "grid-template")) {
        // `rows / columns` or `"areas" rows / columns`
        if (std.mem.lastIndexOfScalar(u8, val, '/')) |slash| s.grid_columns = std.mem.trim(u8, val[slash + 1 ..], " ");
        if (std.mem.indexOfScalar(u8, val, '"') != null or std.mem.indexOfScalar(u8, val, '\'') != null) s.grid_areas = val;
    } else if (eq(prop, "grid-area")) {
        s.grid_area = val;
    } else if (eq(prop, "grid-column")) {
        s.grid_column = val;
    } else if (eq(prop, "flex-direction")) {
        s.flex_column = std.ascii.startsWithIgnoreCase(val, "column");
    } else if (eq(prop, "flex-wrap")) {
        s.flex_wrap = !eq(val, "nowrap");
    } else if (eq(prop, "flex-flow")) {
        s.flex_column = std.ascii.indexOfIgnoreCase(val, "column") != null;
        s.flex_wrap = std.ascii.indexOfIgnoreCase(val, "wrap") != null and std.ascii.indexOfIgnoreCase(val, "nowrap") == null;
    } else if (eq(prop, "flex-grow")) {
        s.flex_grow = std.fmt.parseFloat(f32, val) catch s.flex_grow;
    } else if (eq(prop, "flex")) {
        var parts = std.mem.tokenizeScalar(u8, val, ' ');
        const first = parts.next() orelse "";
        if (eq(first, "auto")) s.flex_grow = 1 else if (eq(first, "none")) s.flex_grow = 0 else s.flex_grow = std.fmt.parseFloat(f32, first) catch s.flex_grow;
    } else if (eq(prop, "gap") or eq(prop, "grid-gap")) {
        var parts = std.mem.tokenizeScalar(u8, val, ' ');
        const r = parseLength(parts.next() orelse "", s.font_size, 0) orelse 0;
        s.gap_y = r;
        s.gap_x = if (parts.next()) |c| parseLength(c, s.font_size, 0) orelse r else r;
    } else if (eq(prop, "column-gap")) {
        s.gap_x = parseLength(val, s.font_size, 0) orelse s.gap_x;
    } else if (eq(prop, "row-gap")) {
        s.gap_y = parseLength(val, s.font_size, 0) orelse s.gap_y;
    } else if (eq(prop, "justify-content")) {
        s.justify = if (eq(val, "center")) .center else if (eq(val, "flex-end") or eq(val, "end") or eq(val, "right")) .end else if (eq(val, "space-between")) .space_between else if (eq(val, "space-around") or eq(val, "space-evenly")) .space_around else .start;
    } else if (eq(prop, "align-items")) {
        s.align_center = eq(val, "center");
    } else if (eq(prop, "visibility")) {
        s.hidden = eq(val, "hidden") or eq(val, "collapse");
    } else if (eq(prop, "opacity")) {
        if (std.fmt.parseFloat(f32, val) catch null) |o| {
            if (o <= 0.01) s.hidden = true;
        }
    } else if (eq(prop, "position")) {
        inline for (@typeInfo(Position).@"enum".fields) |f| {
            if (eq(val, f.name)) s.position = @enumFromInt(f.value);
        }
    } else if (eq(prop, "left") or eq(prop, "right")) {
        if (parseLength(val, s.font_size, 0)) |v| s.offset_left = @min(v, s.offset_left orelse v);
    } else if (eq(prop, "top")) {
        if (parseLength(val, s.font_size, 0)) |v| s.offset_top = v;
    } else if (eq(prop, "overflow") or eq(prop, "overflow-y") or eq(prop, "overflow-x")) {
        s.overflow_hidden = eq(val, "hidden") or eq(val, "clip");
    } else if (eq(prop, "clip")) {
        s.clipped = std.mem.indexOf(u8, val, "rect(0") != null or std.mem.indexOf(u8, val, "rect(1px") != null;
    } else if (eq(prop, "clip-path")) {
        s.clipped = std.mem.indexOf(u8, val, "inset(50%") != null or std.mem.indexOf(u8, val, "inset(100%") != null;
    } else if (eq(prop, "height")) {
        if (!std.mem.endsWith(u8, val, "%")) s.height = parseLength(val, s.font_size, 0);
    } else if (eq(prop, "color")) {
        if (parseColor(val)) |c| s.color = c;
    } else if (eq(prop, "background-color") or eq(prop, "background")) {
        var parts = std.mem.tokenizeScalar(u8, val, ' ');
        while (parts.next()) |p| {
            if (parseColor(p)) |c| {
                s.background = c;
                break;
            }
        }
    } else if (eq(prop, "font-size")) {
        if (eq(val, "small")) s.font_size = 13 else if (eq(val, "medium")) s.font_size = 16 else if (eq(val, "large")) s.font_size = 18 else if (eq(val, "x-large")) s.font_size = 24 else if (eq(val, "xx-large")) s.font_size = 32 else if (eq(val, "smaller")) s.font_size = em * 0.83 else if (eq(val, "larger")) s.font_size = em * 1.2 else if (parseLength(val, em, em)) |v| s.font_size = std.math.clamp(v, 4, 200);
    } else if (eq(prop, "font-weight")) {
        const n = std.fmt.parseInt(u32, val, 10) catch 0;
        s.bold = eq(val, "bold") or eq(val, "bolder") or n >= 600;
    } else if (eq(prop, "font-style")) {
        s.italic = eq(val, "italic") or eq(val, "oblique");
    } else if (eq(prop, "font-family")) {
        s.mono = std.ascii.indexOfIgnoreCase(val, "mono") != null or std.ascii.indexOfIgnoreCase(val, "courier") != null;
    } else if (eq(prop, "text-align")) {
        if (eq(val, "center")) s.text_align = .center else if (eq(val, "right") or eq(val, "end")) s.text_align = .right else s.text_align = .left;
    } else if (eq(prop, "text-decoration") or eq(prop, "text-decoration-line")) {
        s.underline = std.ascii.indexOfIgnoreCase(val, "underline") != null;
        s.strike = std.ascii.indexOfIgnoreCase(val, "line-through") != null;
    } else if (eq(prop, "white-space")) {
        s.pre = std.ascii.startsWithIgnoreCase(val, "pre");
    } else if (eq(prop, "line-height")) {
        if (std.fmt.parseFloat(f32, val) catch null) |k| s.line_height = k else if (parseLength(val, s.font_size, s.font_size)) |px| s.line_height = px / s.font_size;
    } else if (eq(prop, "list-style-type") or eq(prop, "list-style")) {
        if (std.ascii.indexOfIgnoreCase(val, "none") != null) s.list_style = .none else if (std.ascii.indexOfIgnoreCase(val, "decimal") != null) s.list_style = .decimal else if (std.ascii.indexOfIgnoreCase(val, "square") != null) s.list_style = .square else if (std.ascii.indexOfIgnoreCase(val, "circle") != null) s.list_style = .circle else if (std.ascii.indexOfIgnoreCase(val, "disc") != null) s.list_style = .disc;
    } else if (eq(prop, "margin")) {
        parseBox(&s.margin, val, s.font_size);
        var parts = std.mem.tokenizeScalar(u8, val, ' ');
        var n: usize = 0;
        var auto_h = false;
        while (parts.next()) |p| : (n += 1) {
            if (eq(p, "auto") and (n == 1 or n == 3 or (n == 0 and std.mem.indexOfScalar(u8, std.mem.trim(u8, val, " "), ' ') == null))) auto_h = true;
        }
        s.margin_auto = auto_h;
    } else if (eq(prop, "margin-left") or eq(prop, "margin-right")) {
        if (eq(val, "auto")) s.margin_auto = true else if (parseLength(val, s.font_size, 0)) |v| setEdge(&s.margin, prop[7..], v);
    } else if (eq(prop, "padding")) {
        parseBox(&s.padding, val, s.font_size);
    } else if (std.ascii.startsWithIgnoreCase(prop, "margin-")) {
        if (parseLength(val, s.font_size, 0)) |v| setEdge(&s.margin, prop[7..], v);
    } else if (std.ascii.startsWithIgnoreCase(prop, "padding-")) {
        if (parseLength(val, s.font_size, 0)) |v| setEdge(&s.padding, prop[8..], @max(v, 0));
    } else if (eq(prop, "border")) {
        var parts = std.mem.tokenizeScalar(u8, val, ' ');
        while (parts.next()) |p| {
            if (eq(p, "none")) s.border_width = 0 else if (parseColor(p)) |c| s.border_color = c else if (parseLength(p, s.font_size, 0)) |w| s.border_width = w;
        }
    } else if (eq(prop, "border-radius")) {
        if (parseLength(val, s.font_size, 0)) |v| s.radius = v;
    } else if (eq(prop, "width")) {
        if (pct(val)) |p| {
            s.width_pct = p;
            s.width = null;
        } else if (parseLength(val, s.font_size, 0)) |v| {
            s.width = v;
            s.width_pct = null;
        } else if (eq(val, "auto")) {
            s.width = null;
            s.width_pct = null;
        }
    } else if (eq(prop, "max-width")) {
        if (pct(val)) |p| {
            s.max_width_pct = p;
            s.max_width = null;
        } else if (parseLength(val, s.font_size, 0)) |v| {
            s.max_width = v;
            s.max_width_pct = null;
        } else if (eq(val, "none")) {
            s.max_width = null;
            s.max_width_pct = null;
        }
    }
}

/// `NN%` → 0..1
fn pct(val: []const u8) ?f32 {
    if (!std.mem.endsWith(u8, val, "%")) return null;
    const n = std.fmt.parseFloat(f32, std.mem.trim(u8, val[0 .. val.len - 1], " ")) catch return null;
    return n / 100;
}

fn setEdge(e: *Edges, side: []const u8, v: f32) void {
    if (eq(side, "top")) e.top = v else if (eq(side, "right")) e.right = v else if (eq(side, "bottom")) e.bottom = v else if (eq(side, "left")) e.left = v;
}

fn parseBox(e: *Edges, val: []const u8, em: f32) void {
    var vals: [4]f32 = undefined;
    var n: usize = 0;
    var parts = std.mem.tokenizeScalar(u8, val, ' ');
    while (parts.next()) |p| {
        if (n == 4) break;
        vals[n] = parseLength(p, em, 0) orelse 0;
        n += 1;
    }
    switch (n) {
        1 => e.* = .{ .top = vals[0], .right = vals[0], .bottom = vals[0], .left = vals[0] },
        2 => e.* = .{ .top = vals[0], .right = vals[1], .bottom = vals[0], .left = vals[1] },
        3 => e.* = .{ .top = vals[0], .right = vals[1], .bottom = vals[2], .left = vals[1] },
        4 => e.* = .{ .top = vals[0], .right = vals[1], .bottom = vals[2], .left = vals[3] },
        else => {},
    }
}

/// Parse a CSS length. Percentages resolve against `percent_base`. `auto` → null.
pub fn parseLength(val: []const u8, em: f32, percent_base: f32) ?f32 {
    const v = std.mem.trim(u8, val, " ");
    if (v.len == 0 or eq(v, "auto")) return null;
    const units = [_]struct { s: []const u8, k: f32, rel: enum { abs, em, rem, pct } }{
        .{ .s = "px", .k = 1, .rel = .abs },
        .{ .s = "rem", .k = 16, .rel = .rem },
        .{ .s = "em", .k = 1, .rel = .em },
        .{ .s = "pt", .k = 4.0 / 3.0, .rel = .abs },
        .{ .s = "%", .k = 0.01, .rel = .pct },
        .{ .s = "vh", .k = 8, .rel = .abs },
        .{ .s = "vw", .k = 12.8, .rel = .abs },
    };
    for (units) |u| {
        if (std.ascii.endsWithIgnoreCase(v, u.s)) {
            const n = std.fmt.parseFloat(f32, v[0 .. v.len - u.s.len]) catch return null;
            return switch (u.rel) {
                .abs => n * u.k,
                .rem => n * u.k,
                .em => n * em,
                .pct => n * u.k * percent_base,
            };
        }
    }
    return std.fmt.parseFloat(f32, v) catch null;
}

const Named = struct { name: []const u8, v: u24 };
const named_colors = [_]Named{
    .{ .name = "black", .v = 0x000000 },       .{ .name = "white", .v = 0xffffff },
    .{ .name = "red", .v = 0xff0000 },         .{ .name = "green", .v = 0x008000 },
    .{ .name = "blue", .v = 0x0000ff },        .{ .name = "yellow", .v = 0xffff00 },
    .{ .name = "orange", .v = 0xffa500 },      .{ .name = "purple", .v = 0x800080 },
    .{ .name = "gray", .v = 0x808080 },        .{ .name = "grey", .v = 0x808080 },
    .{ .name = "silver", .v = 0xc0c0c0 },      .{ .name = "maroon", .v = 0x800000 },
    .{ .name = "navy", .v = 0x000080 },        .{ .name = "teal", .v = 0x008080 },
    .{ .name = "olive", .v = 0x808000 },       .{ .name = "lime", .v = 0x00ff00 },
    .{ .name = "aqua", .v = 0x00ffff },        .{ .name = "cyan", .v = 0x00ffff },
    .{ .name = "fuchsia", .v = 0xff00ff },     .{ .name = "magenta", .v = 0xff00ff },
    .{ .name = "pink", .v = 0xffc0cb },        .{ .name = "brown", .v = 0xa52a2a },
    .{ .name = "darkred", .v = 0x8b0000 },     .{ .name = "darkblue", .v = 0x00008b },
    .{ .name = "darkgreen", .v = 0x006400 },   .{ .name = "darkgray", .v = 0xa9a9a9 },
    .{ .name = "lightgray", .v = 0xd3d3d3 },   .{ .name = "lightgrey", .v = 0xd3d3d3 },
    .{ .name = "whitesmoke", .v = 0xf5f5f5 },  .{ .name = "gold", .v = 0xffd700 },
    .{ .name = "crimson", .v = 0xdc143c },     .{ .name = "tomato", .v = 0xff6347 },
    .{ .name = "steelblue", .v = 0x4682b4 },   .{ .name = "slategray", .v = 0x708090 },
    .{ .name = "beige", .v = 0xf5f5dc },       .{ .name = "ivory", .v = 0xfffff0 },
    .{ .name = "lightblue", .v = 0xadd8e6 },   .{ .name = "lightyellow", .v = 0xffffe0 },
    .{ .name = "indigo", .v = 0x4b0082 },      .{ .name = "violet", .v = 0xee82ee },
    .{ .name = "dimgray", .v = 0x696969 },     .{ .name = "gainsboro", .v = 0xdcdcdc },
    .{ .name = "rebeccapurple", .v = 0x663399 },
};

pub fn parseColor(raw: []const u8) ?Color {
    const v = std.mem.trim(u8, raw, " \t\r\n");
    if (v.len == 0) return null;
    if (eq(v, "transparent")) return gfx.rgba(0, 0, 0, 0);
    if (v[0] == '#') return parseHex(v[1..]);
    if (std.ascii.startsWithIgnoreCase(v, "rgb")) {
        const open = std.mem.indexOfScalar(u8, v, '(') orelse return null;
        const close = std.mem.lastIndexOfScalar(u8, v, ')') orelse return null;
        var comps: [4]f32 = .{ 0, 0, 0, 1 };
        var n: usize = 0;
        var it = std.mem.tokenizeAny(u8, v[open + 1 .. close], ", /");
        while (it.next()) |p| {
            if (n == 4) break;
            if (std.mem.endsWith(u8, p, "%")) {
                const f = std.fmt.parseFloat(f32, p[0 .. p.len - 1]) catch return null;
                comps[n] = if (n == 3) f / 100 else f * 2.55;
            } else {
                comps[n] = std.fmt.parseFloat(f32, p) catch return null;
            }
            n += 1;
        }
        if (n < 3) return null;
        return .{ .r = comps[0] / 255, .g = comps[1] / 255, .b = comps[2] / 255, .a = std.math.clamp(comps[3], 0, 1) };
    }
    for (named_colors) |nc| {
        if (eq(v, nc.name)) return gfx.hex(nc.v);
    }
    // Legacy attribute colors are often written without '#'.
    if (v.len == 6) return parseHex(v);
    return null;
}

fn parseHex(h: []const u8) ?Color {
    switch (h.len) {
        3, 4 => {
            var c: [4]u8 = .{ 0, 0, 0, 15 };
            for (h, 0..) |ch, i| c[i] = std.fmt.charToDigit(ch, 16) catch return null;
            return gfx.rgba(c[0] * 17, c[1] * 17, c[2] * 17, @as(f32, @floatFromInt(c[3])) / 15.0);
        },
        6, 8 => {
            const n = std.fmt.parseInt(u32, h, 16) catch return null;
            if (h.len == 6) return gfx.hex(@intCast(n));
            return gfx.rgba(@truncate(n >> 24), @truncate(n >> 16), @truncate(n >> 8), @as(f32, @floatFromInt(n & 0xff)) / 255.0);
        },
        else => return null,
    }
}

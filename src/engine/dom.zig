//! DOM produced by html5ever (via redengine), exposed as a Zig-friendly tree.
//!
//! Nodes live in one growable array addressed by index; the tree is linked with
//! parent / first_child / next_sibling indices. Scripts mutate it through the
//! methods below (strings they create live in `arena`); every mutation bumps
//! `version` so the tab knows to lay the page out again.

const std = @import("std");
const ffi = @import("ffi.zig");
const cascade = @import("cascade.zig");

pub const Kind = ffi.NodeKind;
/// DocumentFragment (not produced by the parser; created by scripts).
pub const fragment_kind: Kind = @enumFromInt(11);
pub const none: u32 = std.math.maxInt(u32);

pub const Attr = struct { name: []const u8, value: []const u8 };

pub const Node = struct {
    kind: Kind,
    parent: u32,
    first_child: u32,
    next_sibling: u32,
    /// Lower-case local name for elements, empty otherwise.
    name: []const u8,
    /// Text content for text/comment nodes.
    text: []const u8,
    attrs: []Attr,

    pub fn attr(self: *const Node, name: []const u8) ?[]const u8 {
        for (self.attrs) |a| {
            if (std.ascii.eqlIgnoreCase(a.name, name)) return a.value;
        }
        return null;
    }

    pub fn is(self: *const Node, tag: []const u8) bool {
        return self.kind == .element and std.mem.eql(u8, self.name, tag);
    }
};

const void_tags = [_][]const u8{ "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr" };

pub const Document = struct {
    raw: *ffi.Doc,
    /// View of `buf.items`; re-sliced whenever nodes are added.
    nodes: []Node,
    buf: std.ArrayListUnmanaged(Node),
    attrs: []Attr,
    allocator: std.mem.Allocator,
    /// Strings and attribute lists created after parsing.
    arena: *std.heap.ArenaAllocator,
    /// Author stylesheets (<style> and fetched <link rel=stylesheet>), if any.
    sheet: ?*cascade.Sheet = null,
    /// CSS / JS fetched for <link rel=stylesheet> and <script src>, by node index.
    ext_css: std.AutoHashMapUnmanaged(u32, []u8) = .{},
    ext_js: std.AutoHashMapUnmanaged(u32, []u8) = .{},
    /// Bumped on every mutation; `styles_dirty` when a <style> changed.
    version: u32 = 0,
    styles_dirty: bool = false,
    /// Parsed with scripting enabled: <noscript> is hidden.
    scripting: bool = false,

    /// Parse `html` with html5ever. Strings in the result point into Rust-owned memory
    /// that lives until `deinit`. `scripting` mirrors whether JavaScript is on
    /// (it decides whether <noscript> content is markup or raw text).
    pub fn parse(allocator: std.mem.Allocator, html: []const u8) !Document {
        return parseOpts(allocator, html, false);
    }

    pub fn parseOpts(allocator: std.mem.Allocator, html: []const u8, scripting: bool) !Document {
        const raw = ffi.re_html_parse2(html.ptr, html.len, scripting) orelse return error.ParseFailed;
        errdefer ffi.re_doc_free(raw);

        const n = ffi.re_doc_len(raw);
        var buf = try std.ArrayListUnmanaged(Node).initCapacity(allocator, n + 64);
        errdefer buf.deinit(allocator);

        var total_attrs: usize = 0;
        var tmp: ffi.Node = undefined;
        for (0..n) |i| {
            _ = ffi.re_doc_node(raw, @intCast(i), &tmp);
            total_attrs += tmp.attr_count;
        }
        const attrs = try allocator.alloc(Attr, total_attrs);
        errdefer allocator.free(attrs);

        var ai: usize = 0;
        for (0..n) |i| {
            _ = ffi.re_doc_node(raw, @intCast(i), &tmp);
            const start = ai;
            for (0..tmp.attr_count) |j| {
                var np: [*]const u8 = undefined;
                var nl: usize = 0;
                var vp: [*]const u8 = undefined;
                var vl: usize = 0;
                if (ffi.re_doc_attr(raw, @intCast(i), @intCast(j), &np, &nl, &vp, &vl)) {
                    attrs[ai] = .{ .name = np[0..nl], .value = vp[0..vl] };
                    ai += 1;
                }
            }
            buf.appendAssumeCapacity(.{
                .kind = tmp.kind,
                .parent = idx(tmp.parent),
                .first_child = idx(tmp.first_child),
                .next_sibling = idx(tmp.next_sibling),
                .name = tmp.name[0..tmp.name_len],
                .text = tmp.text[0..tmp.text_len],
                .attrs = attrs[start..ai],
            });
        }
        const arena = try allocator.create(std.heap.ArenaAllocator);
        arena.* = std.heap.ArenaAllocator.init(allocator);
        return .{ .raw = raw, .nodes = buf.items, .buf = buf, .attrs = attrs, .allocator = allocator, .arena = arena, .scripting = scripting };
    }

    fn idx(v: i32) u32 {
        return if (v < 0) none else @intCast(v);
    }

    pub fn deinit(self: *Document) void {
        if (self.sheet) |sh| sh.destroy(self.allocator);
        inline for (.{ &self.ext_css, &self.ext_js }) |m| {
            var it = m.valueIterator();
            while (it.next()) |v| self.allocator.free(v.*);
            m.deinit(self.allocator);
        }
        self.buf.deinit(self.allocator);
        self.allocator.free(self.attrs);
        self.arena.deinit();
        self.allocator.destroy(self.arena);
        ffi.re_doc_free(self.raw);
    }

    pub fn get(self: *const Document, i: u32) *const Node {
        return &self.nodes[i];
    }

    pub fn valid(self: *const Document, i: u32) bool {
        return i < self.nodes.len;
    }

    pub fn indexOf(self: *const Document, node: *const Node) u32 {
        return @intCast((@intFromPtr(node) - @intFromPtr(self.nodes.ptr)) / @sizeOf(Node));
    }

    /// Build the author stylesheet from <style> elements and fetched external
    /// sheets (`ext_css`), in document order. Replaces any previous sheet.
    pub fn buildSheet(self: *Document) !void {
        const sheet = try cascade.Sheet.create(self.allocator);
        errdefer sheet.destroy(self.allocator);
        try self.addSheets(sheet, 0, 0);
        if (self.sheet) |old| old.destroy(self.allocator);
        self.sheet = sheet;
        self.styles_dirty = false;
    }

    fn addSheets(self: *Document, sheet: *cascade.Sheet, i: u32, depth: u32) !void {
        if (depth > 256) return;
        const n = &self.nodes[i];
        if (n.kind == .element) {
            if (n.is("style")) {
                if (!mediaAllowsScreen(n.attr("media"))) return;
                if (n.attr("type")) |t| if (t.len > 0 and !std.ascii.eqlIgnoreCase(t, "text/css")) return;
                const text = try self.textContent(self.allocator, i);
                defer self.allocator.free(text);
                sheet.addCss(text);
                return;
            }
            if (n.is("link")) {
                if (self.ext_css.get(i)) |css_text| sheet.addCss(css_text);
                return;
            }
            if (n.is("template")) return;
        }
        var it = self.children(i);
        while (it.next()) |c| try self.addSheets(sheet, c, depth + 1);
    }

    pub const ChildIterator = struct {
        doc: *const Document,
        cur: u32,
        pub fn next(it: *ChildIterator) ?u32 {
            if (it.cur == none) return null;
            const r = it.cur;
            it.cur = it.doc.nodes[r].next_sibling;
            return r;
        }
    };

    pub fn children(self: *const Document, i: u32) ChildIterator {
        return .{ .doc = self, .cur = self.nodes[i].first_child };
    }

    /// First element with the given tag in document order (connected nodes only).
    pub fn find(self: *const Document, tag: []const u8) ?u32 {
        return self.findIn(0, tag, 0);
    }

    fn findIn(self: *const Document, i: u32, tag: []const u8, depth: u32) ?u32 {
        if (depth > 512) return null;
        if (self.nodes[i].is(tag)) return i;
        var it = self.children(i);
        while (it.next()) |c| {
            if (self.findIn(c, tag, depth + 1)) |r| return r;
        }
        return null;
    }

    /// Concatenated text content of a subtree (caller frees).
    pub fn textContent(self: *const Document, allocator: std.mem.Allocator, i: u32) ![]u8 {
        var out = std.ArrayList(u8).init(allocator);
        try self.collectText(i, &out, 0);
        return out.toOwnedSlice();
    }

    fn collectText(self: *const Document, i: u32, out: *std.ArrayList(u8), depth: u32) !void {
        if (depth > 512) return;
        const n = &self.nodes[i];
        if (n.kind == .text) try out.appendSlice(n.text);
        var it = self.children(i);
        while (it.next()) |c| try self.collectText(c, out, depth + 1);
    }

    // ---- tree queries ----------------------------------------------------------

    pub fn lastChild(self: *const Document, i: u32) u32 {
        var last: u32 = none;
        var it = self.children(i);
        while (it.next()) |c| last = c;
        return last;
    }

    pub fn prevSibling(self: *const Document, i: u32) u32 {
        const p = self.nodes[i].parent;
        if (p == none) return none;
        var prev: u32 = none;
        var it = self.children(p);
        while (it.next()) |c| {
            if (c == i) return prev;
            prev = c;
        }
        return none;
    }

    /// In the document tree (as opposed to detached / in a fragment)?
    pub fn isConnected(self: *const Document, i: u32) bool {
        var cur = i;
        var guard: u32 = 0;
        while (cur != none and guard < 4096) : (guard += 1) {
            if (cur == 0) return true;
            cur = self.nodes[cur].parent;
        }
        return false;
    }

    pub fn contains(self: *const Document, ancestor: u32, i: u32) bool {
        var cur = i;
        var guard: u32 = 0;
        while (cur != none and guard < 4096) : (guard += 1) {
            if (cur == ancestor) return true;
            cur = self.nodes[cur].parent;
        }
        return false;
    }

    pub fn byId(self: *const Document, id: []const u8) ?u32 {
        return self.byIdIn(0, id, 0);
    }

    fn byIdIn(self: *const Document, i: u32, id: []const u8, depth: u32) ?u32 {
        if (depth > 512) return null;
        const n = &self.nodes[i];
        if (n.kind == .element) {
            if (n.attr("id")) |v| if (std.mem.eql(u8, v, id)) return i;
        }
        var it = self.children(i);
        while (it.next()) |c| {
            if (self.byIdIn(c, id, depth + 1)) |r| return r;
        }
        return null;
    }

    // ---- mutation ------------------------------------------------------------------

    fn touched(self: *Document, i: u32) void {
        self.version +%= 1;
        // A change inside a <style> (or adding/removing one) affects the cascade.
        var cur = i;
        var guard: u32 = 0;
        while (cur != none and guard < 3) : (guard += 1) {
            const n = &self.nodes[cur];
            if (n.is("style") or n.is("link")) {
                self.styles_dirty = true;
                return;
            }
            cur = n.parent;
        }
    }

    fn newNode(self: *Document, node: Node) !u32 {
        try self.buf.append(self.allocator, node);
        self.nodes = self.buf.items;
        return @intCast(self.nodes.len - 1);
    }

    pub fn createElement(self: *Document, tag: []const u8) !u32 {
        const a = self.arena.allocator();
        const name = try std.ascii.allocLowerString(a, tag);
        return self.newNode(.{ .kind = .element, .parent = none, .first_child = none, .next_sibling = none, .name = name, .text = "", .attrs = &.{} });
    }

    pub fn createText(self: *Document, text: []const u8, kind: Kind) !u32 {
        const owned = try self.arena.allocator().dupe(u8, text);
        return self.newNode(.{ .kind = kind, .parent = none, .first_child = none, .next_sibling = none, .name = "", .text = owned, .attrs = &.{} });
    }

    pub fn createFragment(self: *Document) !u32 {
        return self.newNode(.{ .kind = fragment_kind, .parent = none, .first_child = none, .next_sibling = none, .name = "#document-fragment", .text = "", .attrs = &.{} });
    }

    /// Unlink `child` from its parent (it stays valid, detached).
    pub fn detach(self: *Document, child: u32) void {
        const p = self.nodes[child].parent;
        if (p == none) return;
        self.touched(child);
        if (self.nodes[p].first_child == child) {
            self.nodes[p].first_child = self.nodes[child].next_sibling;
        } else {
            const prev = self.prevSibling(child);
            if (prev != none) self.nodes[prev].next_sibling = self.nodes[child].next_sibling;
        }
        self.nodes[child].parent = none;
        self.nodes[child].next_sibling = none;
        self.touched(p);
    }

    /// Insert `child` into `parent` before `ref` (or at the end when `ref` is none).
    /// Fragments are emptied into the parent. Fails on cycles.
    pub fn insertBefore(self: *Document, parent: u32, child: u32, ref: u32) !void {
        if (self.contains(child, parent)) return error.HierarchyRequest;
        if (self.nodes[child].kind == fragment_kind) {
            while (self.nodes[child].first_child != none) {
                const c = self.nodes[child].first_child;
                try self.insertBefore(parent, c, ref);
            }
            return;
        }
        if (ref != none and self.nodes[ref].parent != parent) return error.NotFound;
        if (child == ref) return;
        self.detach(child);
        self.nodes[child].parent = parent;
        if (ref == none) {
            const last = self.lastChild(parent);
            if (last == none) self.nodes[parent].first_child = child else self.nodes[last].next_sibling = child;
            self.nodes[child].next_sibling = none;
        } else {
            if (self.nodes[parent].first_child == ref) {
                self.nodes[parent].first_child = child;
            } else {
                const prev = self.prevSibling(ref);
                self.nodes[prev].next_sibling = child;
            }
            self.nodes[child].next_sibling = ref;
        }
        self.touched(child);
    }

    pub fn appendChild(self: *Document, parent: u32, child: u32) !void {
        return self.insertBefore(parent, child, none);
    }

    pub fn removeChildren(self: *Document, i: u32) void {
        while (self.nodes[i].first_child != none) self.detach(self.nodes[i].first_child);
    }

    pub fn setAttr(self: *Document, i: u32, name: []const u8, value: []const u8) !void {
        const a = self.arena.allocator();
        const v = try a.dupe(u8, value);
        const n = &self.nodes[i];
        for (n.attrs) |*at| {
            if (std.ascii.eqlIgnoreCase(at.name, name)) {
                at.value = v;
                self.touched(i);
                return;
            }
        }
        const list = try a.alloc(Attr, n.attrs.len + 1);
        @memcpy(list[0..n.attrs.len], n.attrs);
        list[n.attrs.len] = .{ .name = try std.ascii.allocLowerString(a, name), .value = v };
        n.attrs = list;
        self.touched(i);
    }

    pub fn removeAttr(self: *Document, i: u32, name: []const u8) void {
        const n = &self.nodes[i];
        for (n.attrs, 0..) |at, k| {
            if (std.ascii.eqlIgnoreCase(at.name, name)) {
                // shift the rest down; the slice is ours or parser-owned, both writable
                var j = k;
                while (j + 1 < n.attrs.len) : (j += 1) n.attrs[j] = n.attrs[j + 1];
                n.attrs = n.attrs[0 .. n.attrs.len - 1];
                self.touched(i);
                return;
            }
        }
    }

    /// Text/comment data, or for elements: replace children with one text node.
    pub fn setText(self: *Document, i: u32, text: []const u8) !void {
        const n = &self.nodes[i];
        if (n.kind == .text or n.kind == .comment) {
            n.text = try self.arena.allocator().dupe(u8, text);
            self.touched(i);
            return;
        }
        self.removeChildren(i);
        if (text.len > 0) try self.appendChild(i, try self.createText(text, .text));
        self.touched(i);
    }

    /// Parse `html` as a fragment and append the nodes to `parent` (before `ref`).
    pub fn insertHtml(self: *Document, parent: u32, ref: u32, html: []const u8) !void {
        const raw = ffi.re_html_parse_fragment(html.ptr, html.len) orelse return error.ParseFailed;
        defer ffi.re_doc_free(raw);
        const n = ffi.re_doc_len(raw);
        if (n == 0) return;
        // Copy every raw node, then graft the children of the context <html> root.
        const map = try self.allocator.alloc(u32, n);
        defer self.allocator.free(map);
        const a = self.arena.allocator();
        var tmp: ffi.Node = undefined;
        for (0..n) |i| {
            _ = ffi.re_doc_node(raw, @intCast(i), &tmp);
            const attrs = try a.alloc(Attr, tmp.attr_count);
            var ai: usize = 0;
            for (0..tmp.attr_count) |j| {
                var np: [*]const u8 = undefined;
                var nl: usize = 0;
                var vp: [*]const u8 = undefined;
                var vl: usize = 0;
                if (ffi.re_doc_attr(raw, @intCast(i), @intCast(j), &np, &nl, &vp, &vl)) {
                    attrs[ai] = .{ .name = try a.dupe(u8, np[0..nl]), .value = try a.dupe(u8, vp[0..vl]) };
                    ai += 1;
                }
            }
            map[i] = try self.newNode(.{
                .kind = tmp.kind,
                .parent = none,
                .first_child = none,
                .next_sibling = none,
                .name = try a.dupe(u8, tmp.name[0..tmp.name_len]),
                .text = try a.dupe(u8, tmp.text[0..tmp.text_len]),
                .attrs = attrs[0..ai],
            });
        }
        // Rebuild links in the copies.
        for (0..n) |i| {
            _ = ffi.re_doc_node(raw, @intCast(i), &tmp);
            const node = &self.nodes[map[i]];
            node.parent = if (tmp.parent < 0) none else map[@intCast(tmp.parent)];
            node.first_child = if (tmp.first_child < 0) none else map[@intCast(tmp.first_child)];
            node.next_sibling = if (tmp.next_sibling < 0) none else map[@intCast(tmp.next_sibling)];
        }
        // Raw node 0 is the document; its first element child is the context <html>.
        var root: u32 = none;
        var it = self.children(map[0]);
        while (it.next()) |c| {
            if (self.nodes[c].kind == .element) {
                root = c;
                break;
            }
        }
        if (root == none) return;
        while (self.nodes[root].first_child != none) {
            const c = self.nodes[root].first_child;
            try self.insertBefore(parent, c, ref);
        }
    }

    pub fn setInnerHtml(self: *Document, i: u32, html: []const u8) !void {
        self.removeChildren(i);
        try self.insertHtml(i, none, html);
        self.touched(i);
    }

    /// Deep or shallow copy of a node (detached).
    pub fn clone(self: *Document, i: u32, deep: bool) !u32 {
        const src = self.nodes[i];
        const a = self.arena.allocator();
        const attrs = try a.dupe(Attr, src.attrs);
        const copy = try self.newNode(.{ .kind = src.kind, .parent = none, .first_child = none, .next_sibling = none, .name = src.name, .text = src.text, .attrs = attrs });
        if (deep) {
            var c = self.nodes[i].first_child;
            while (c != none) : (c = self.nodes[c].next_sibling) {
                const cc = try self.clone(c, true);
                try self.appendChild(copy, cc);
            }
        }
        return copy;
    }

    // ---- serialization ----------------------------------------------------------------

    pub fn serialize(self: *const Document, w: anytype, i: u32, include_self: bool) !void {
        const n = &self.nodes[i];
        switch (n.kind) {
            .text => {
                const raw_parent = n.parent != none and (self.nodes[n.parent].is("script") or self.nodes[n.parent].is("style"));
                if (raw_parent) try w.writeAll(n.text) else try escape(w, n.text, false);
                return;
            },
            .comment => {
                try w.print("<!--{s}-->", .{n.text});
                return;
            },
            .element => if (include_self) {
                try w.print("<{s}", .{n.name});
                for (n.attrs) |at| {
                    try w.print(" {s}=\"", .{at.name});
                    try escape(w, at.value, true);
                    try w.writeByte('"');
                }
                try w.writeByte('>');
                for (void_tags) |v| if (std.mem.eql(u8, v, n.name)) return;
            },
            else => {},
        }
        var it = self.children(i);
        while (it.next()) |c| try self.serialize(w, c, true);
        if (include_self and n.kind == .element) try w.print("</{s}>", .{n.name});
    }
};

fn escape(w: anytype, s: []const u8, attr: bool) !void {
    for (s) |ch| switch (ch) {
        '&' => try w.writeAll("&amp;"),
        '<' => try w.writeAll(if (attr) "<" else "&lt;"),
        '>' => try w.writeAll(if (attr) ">" else "&gt;"),
        '"' => try w.writeAll(if (attr) "&quot;" else "\""),
        0xa0 => try w.writeAll("&nbsp;"),
        else => try w.writeByte(ch),
    };
}

/// Whether a `media` attribute applies to a screen at all (width checks happen later).
pub fn mediaAllowsScreen(media: ?[]const u8) bool {
    const m = media orelse return true;
    const t = std.mem.trim(u8, m, " ");
    if (t.len == 0) return true;
    return std.ascii.indexOfIgnoreCase(t, "print") == null or std.ascii.indexOfIgnoreCase(t, "screen") != null or std.ascii.indexOfIgnoreCase(t, "all") != null;
}

/// <link> elements that load a stylesheet we should fetch.
pub fn isStylesheetLink(n: *const Node) bool {
    if (!n.is("link")) return false;
    const rel = n.attr("rel") orelse return false;
    var it = std.mem.tokenizeAny(u8, rel, " \t\r\n");
    var sheet = false;
    while (it.next()) |r| {
        if (std.ascii.eqlIgnoreCase(r, "stylesheet")) sheet = true;
        if (std.ascii.eqlIgnoreCase(r, "alternate")) return false;
    }
    return sheet and n.attr("href") != null and n.attr("disabled") == null and mediaAllowsScreen(n.attr("media"));
}

/// Classic scripts we execute (not modules, JSON, templates, …).
pub fn isClassicScript(n: *const Node) bool {
    if (!n.is("script")) return false;
    const ty = n.attr("type") orelse return true;
    const t = std.mem.trim(u8, ty, " ");
    if (t.len == 0) return true;
    const js_types = [_][]const u8{ "text/javascript", "application/javascript", "text/ecmascript", "application/ecmascript", "application/x-javascript", "text/jscript" };
    for (js_types) |j| if (std.ascii.eqlIgnoreCase(t, j)) return true;
    return false;
}

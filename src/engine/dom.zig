//! DOM produced by html5ever (via redengine), exposed as a Zig-friendly tree.

const std = @import("std");
const ffi = @import("ffi.zig");

pub const Kind = ffi.NodeKind;
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

pub const Document = struct {
    raw: *ffi.Doc,
    nodes: []Node,
    attrs: []Attr,
    allocator: std.mem.Allocator,

    /// Parse `html` with html5ever. Strings in the result point into Rust-owned memory
    /// that lives until `deinit`.
    pub fn parse(allocator: std.mem.Allocator, html: []const u8) !Document {
        const raw = ffi.re_html_parse(html.ptr, html.len) orelse return error.ParseFailed;
        errdefer ffi.re_doc_free(raw);

        const n = ffi.re_doc_len(raw);
        const nodes = try allocator.alloc(Node, n);
        errdefer allocator.free(nodes);

        var total_attrs: usize = 0;
        var tmp: ffi.Node = undefined;
        for (0..n) |i| {
            _ = ffi.re_doc_node(raw, @intCast(i), &tmp);
            total_attrs += tmp.attr_count;
        }
        const attrs = try allocator.alloc(Attr, total_attrs);

        var ai: usize = 0;
        for (nodes, 0..) |*node, i| {
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
            node.* = .{
                .kind = tmp.kind,
                .parent = idx(tmp.parent),
                .first_child = idx(tmp.first_child),
                .next_sibling = idx(tmp.next_sibling),
                .name = tmp.name[0..tmp.name_len],
                .text = tmp.text[0..tmp.text_len],
                .attrs = attrs[start..ai],
            };
        }
        return .{ .raw = raw, .nodes = nodes, .attrs = attrs, .allocator = allocator };
    }

    fn idx(v: i32) u32 {
        return if (v < 0) none else @intCast(v);
    }

    pub fn deinit(self: *Document) void {
        self.allocator.free(self.nodes);
        self.allocator.free(self.attrs);
        ffi.re_doc_free(self.raw);
    }

    pub fn get(self: *const Document, i: u32) *const Node {
        return &self.nodes[i];
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

    /// First element with the given tag in document order.
    pub fn find(self: *const Document, tag: []const u8) ?u32 {
        for (self.nodes, 0..) |*n, i| {
            if (n.is(tag)) return @intCast(i);
        }
        return null;
    }

    /// Concatenated text content of a subtree (caller frees).
    pub fn textContent(self: *const Document, allocator: std.mem.Allocator, i: u32) ![]u8 {
        var out = std.ArrayList(u8).init(allocator);
        try self.collectText(i, &out);
        return out.toOwnedSlice();
    }

    fn collectText(self: *const Document, i: u32, out: *std.ArrayList(u8)) !void {
        const n = &self.nodes[i];
        if (n.kind == .text) try out.appendSlice(n.text);
        var it = self.children(i);
        while (it.next()) |c| try self.collectText(c, out);
    }
};

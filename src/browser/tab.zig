//! A browser tab: navigation history, load state, parsed document and its layout.

const std = @import("std");
const dom = @import("../engine/dom.zig");
const layout = @import("../engine/layout.zig");
const gfx = @import("../engine/gfx.zig");
const net = @import("net.zig");
const urlz = @import("url.zig");

pub const Tab = struct {
    allocator: std.mem.Allocator,
    id: u32,
    /// URL of the current document (or the one being loaded).
    url: []u8,
    title: []u8,
    history: std.ArrayListUnmanaged([]u8) = .{},
    history_index: usize = 0,
    /// Increments on every navigation; stale load results are dropped.
    generation: u32 = 0,
    loading: bool = false,
    load_started_ms: i64 = 0,
    doc: ?dom.Document = null,
    page: ?layout.Page = null,
    base_url: []u8,
    /// Scroll target; `view_scroll` eases towards it every frame.
    scroll: f32 = 0,
    view_scroll: f32 = 0,
    pending_fragment: ?[]u8 = null,

    pub fn init(allocator: std.mem.Allocator, id: u32) !Tab {
        return .{
            .allocator = allocator,
            .id = id,
            .url = try allocator.dupe(u8, ""),
            .title = try allocator.dupe(u8, "New Tab"),
            .base_url = try allocator.dupe(u8, ""),
        };
    }

    pub fn deinit(self: *Tab) void {
        const a = self.allocator;
        if (self.page) |*p| p.deinit();
        if (self.doc) |*d| d.deinit();
        for (self.history.items) |h| a.free(h);
        self.history.deinit(a);
        a.free(self.url);
        a.free(self.title);
        a.free(self.base_url);
        if (self.pending_fragment) |f| a.free(f);
    }

    fn setOwned(self: *Tab, field: *[]u8, value: []const u8) !void {
        const v = try self.allocator.dupe(u8, value);
        self.allocator.free(field.*);
        field.* = v;
    }

    /// Start loading `url`. `record` adds a history entry (normal navigation).
    pub fn navigate(self: *Tab, url: []const u8, record: bool, notify: net.Notify) !void {
        const a = self.allocator;
        if (record) {
            // drop forward history
            while (self.history.items.len > 0 and self.history.items.len > self.history_index + 1) {
                a.free(self.history.pop().?);
            }
            try self.history.append(a, try a.dupe(u8, url));
            self.history_index = self.history.items.len - 1;
        }
        try self.setOwned(&self.url, url);
        self.generation +%= 1;
        self.loading = true;
        self.load_started_ms = std.time.milliTimestamp();
        try net.start(a, url, self.id, self.generation, notify);
    }

    pub fn canGoBack(self: *const Tab) bool {
        return self.history_index > 0;
    }

    pub fn canGoForward(self: *const Tab) bool {
        return self.history_index + 1 < self.history.items.len;
    }

    pub fn back(self: *Tab, notify: net.Notify) !void {
        if (!self.canGoBack()) return;
        self.history_index -= 1;
        try self.navigate(self.history.items[self.history_index], false, notify);
    }

    pub fn forward(self: *Tab, notify: net.Notify) !void {
        if (!self.canGoForward()) return;
        self.history_index += 1;
        try self.navigate(self.history.items[self.history_index], false, notify);
    }

    pub fn reload(self: *Tab, notify: net.Notify) !void {
        if (self.url.len == 0) return;
        const u = try self.allocator.dupe(u8, self.url);
        defer self.allocator.free(u);
        try self.navigate(u, false, notify);
    }

    pub fn stop(self: *Tab) void {
        self.generation +%= 1;
        self.loading = false;
    }

    /// Install a finished load. Returns false if the result was stale.
    pub fn finishLoad(self: *Tab, res: *net.Result) !bool {
        if (res.generation != self.generation) return false;
        const a = self.allocator;
        self.loading = false;

        var doc = if (res.doc) |d| blk: {
            res.doc = null;
            break :blk d;
        } else try dom.Document.parse(a, res.body);
        errdefer doc.deinit();

        if (self.page) |*p| p.deinit();
        self.page = null;
        if (self.doc) |*d| d.deinit();
        self.doc = doc;

        // Keep the address the user navigated to (with its #fragment), but follow redirects.
        const keep_fragment = std.mem.indexOfScalar(u8, self.url, '#');
        if (!std.mem.eql(u8, urlNoFragment(self.url), urlNoFragment(res.url))) {
            try self.setOwned(&self.url, res.url);
            if (self.history.items.len > 0) {
                const slot = &self.history.items[self.history_index];
                a.free(slot.*);
                slot.* = try a.dupe(u8, res.url);
            }
        }
        if (self.pending_fragment) |f| a.free(f);
        self.pending_fragment = if (keep_fragment) |i| try a.dupe(u8, self.url[i + 1 ..]) else null;

        // <base href>, <title>
        try self.setOwned(&self.base_url, self.url);
        if (doc.find("base")) |bi| {
            if (doc.get(bi).attr("href")) |h| {
                const resolved = try urlz.resolve(a, self.url, h);
                a.free(self.base_url);
                self.base_url = resolved;
            }
        }
        var title: []const u8 = "";
        var title_buf: ?[]u8 = null;
        defer if (title_buf) |t| a.free(t);
        if (doc.find("title")) |ti| {
            title_buf = try doc.textContent(a, ti);
            title = collapse(title_buf.?);
        }
        if (title.len == 0) title = if (urlz.host(self.url).len > 0) urlz.host(self.url) else self.url;
        try self.setOwned(&self.title, title);
        self.scroll = 0;
        self.view_scroll = 0;
        return true;
    }

    /// (Re)layout for the given content width when needed.
    pub fn ensureLayout(self: *Tab, g: *const gfx.Gfx, width: f32) !void {
        const doc = &(self.doc orelse return);
        if (self.page) |*p| {
            if (p.width == width) return;
            p.deinit();
            self.page = null;
        }
        self.page = try layout.layoutDocument(self.allocator, g, doc, width);
        if (self.pending_fragment) |frag| {
            self.scroll = self.fragmentOffset(frag) orelse 0;
            self.view_scroll = self.scroll;
            self.allocator.free(frag);
            self.pending_fragment = null;
        }
    }

    fn fragmentOffset(self: *Tab, frag: []const u8) ?f32 {
        const doc = &(self.doc orelse return null);
        const page = &(self.page orelse return null);
        // Find the element; use the first link box at or after it as an approximate position.
        for (doc.nodes) |*n| {
            const id = n.attr("id") orelse n.attr("name") orelse continue;
            if (!std.mem.eql(u8, id, frag)) continue;
            // Approximation until layout boxes keep node ids: search for its text in items.
            const i: u32 = @intCast((@intFromPtr(n) - @intFromPtr(doc.nodes.ptr)) / @sizeOf(dom.Node));
            const txt = doc.textContent(self.allocator, i) catch return null;
            defer self.allocator.free(txt);
            var words = std.mem.tokenizeAny(u8, txt, " \n\t\r");
            const first = words.next() orelse return null;
            for (page.items.items) |it| {
                if (it == .text and std.mem.indexOf(u8, it.text.str, first) != null) return @max(0, it.text.y - it.text.size - 8);
            }
            return null;
        }
        return null;
    }

    pub fn maxScroll(self: *const Tab, view_h: f32) f32 {
        const p = self.page orelse return 0;
        return @max(0, p.height - view_h);
    }

    pub fn scrollBy(self: *Tab, dy: f32, view_h: f32) void {
        self.scroll = std.math.clamp(self.scroll + dy, 0, self.maxScroll(view_h));
    }
};

fn urlNoFragment(u: []const u8) []const u8 {
    return if (std.mem.indexOfScalar(u8, u, '#')) |i| u[0..i] else u;
}

/// Collapse whitespace runs in place-ish (returns a trimmed slice of the buffer).
fn collapse(buf: []u8) []const u8 {
    var w: usize = 0;
    var space = false;
    for (buf) |ch| {
        if (std.ascii.isWhitespace(ch)) {
            space = w > 0;
        } else {
            if (space) {
                buf[w] = ' ';
                w += 1;
                space = false;
            }
            buf[w] = ch;
            w += 1;
        }
    }
    return buf[0..w];
}

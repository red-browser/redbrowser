//! Resource loading (http, https, file, about) on background threads.

const std = @import("std");
const pages = @import("pages.zig");
const urlz = @import("url.zig");

pub const user_agent = "Mozilla/5.0 (" ++ platform ++ ") RedBrowser/0.1 (WebRender; html5ever)";
const platform = switch (@import("builtin").os.tag) {
    .macos => "Macintosh; Mac OS X",
    .linux => "X11; Linux",
    else => "Unknown",
};

const max_body = 32 * 1024 * 1024;

pub const Result = struct {
    allocator: std.mem.Allocator,
    tab_id: u32,
    generation: u32,
    /// Final URL after redirects.
    url: []u8,
    body: []u8,
    content_type: []u8,
    status: u16,

    pub fn deinit(self: *Result) void {
        self.allocator.free(self.url);
        self.allocator.free(self.body);
        self.allocator.free(self.content_type);
        self.allocator.destroy(self);
    }

    pub fn isHtml(self: *const Result) bool {
        return self.content_type.len == 0 or std.ascii.indexOfIgnoreCase(self.content_type, "html") != null;
    }
};

/// Called on the loader thread when a load completes; must be thread-safe.
pub const Notify = *const fn (result: *Result) void;

pub fn start(allocator: std.mem.Allocator, url: []const u8, tab_id: u32, generation: u32, notify: Notify) !void {
    const owned = try allocator.dupe(u8, url);
    errdefer allocator.free(owned);
    const t = try std.Thread.spawn(.{}, worker, .{ allocator, owned, tab_id, generation, notify });
    t.detach();
}

fn worker(allocator: std.mem.Allocator, url: []u8, tab_id: u32, generation: u32, notify: Notify) void {
    defer allocator.free(url);
    const res = allocator.create(Result) catch return;
    res.* = .{ .allocator = allocator, .tab_id = tab_id, .generation = generation, .url = &.{}, .body = &.{}, .content_type = &.{}, .status = 0 };
    load(allocator, url, res) catch |err| {
        allocator.free(res.url);
        allocator.free(res.body);
        allocator.free(res.content_type);
        res.url = allocator.dupe(u8, url) catch &.{};
        res.body = pages.errorPage(allocator, url, @errorName(err)) catch &.{};
        res.content_type = allocator.dupe(u8, "text/html") catch &.{};
        res.status = 0;
    };
    notify(res);
}

fn load(a: std.mem.Allocator, url: []const u8, res: *Result) !void {
    const sc = urlz.scheme(url) orelse return error.InvalidUrl;
    if (std.ascii.eqlIgnoreCase(sc, "about")) {
        res.url = try a.dupe(u8, url);
        res.body = try pages.about(a, url[6..]);
        res.content_type = try a.dupe(u8, "text/html");
        res.status = 200;
        return;
    }
    if (std.ascii.eqlIgnoreCase(sc, "file")) {
        var path = url[5..];
        if (std.mem.startsWith(u8, path, "//")) path = path[2..];
        const decoded = try a.dupe(u8, path);
        defer a.free(decoded);
        const p = std.Uri.percentDecodeInPlace(decoded);
        res.url = try a.dupe(u8, url);
        res.body = try std.fs.cwd().readFileAlloc(a, p, max_body);
        const html = std.mem.endsWith(u8, p, ".html") or std.mem.endsWith(u8, p, ".htm");
        res.content_type = try a.dupe(u8, if (html) "text/html" else "text/plain");
        res.status = 200;
        return;
    }
    if (!(std.ascii.eqlIgnoreCase(sc, "http") or std.ascii.eqlIgnoreCase(sc, "https"))) return error.UnsupportedScheme;

    var client = std.http.Client{ .allocator = a };
    defer client.deinit();

    const uri = try std.Uri.parse(url);
    var header_buf: [32 * 1024]u8 = undefined;
    var req = try client.open(.GET, uri, .{
        .server_header_buffer = &header_buf,
        .redirect_behavior = @enumFromInt(8),
        .keep_alive = false,
        .headers = .{ .user_agent = .{ .override = user_agent } },
        .extra_headers = &.{
            .{ .name = "accept", .value = "text/html,application/xhtml+xml,text/plain;q=0.9,*/*;q=0.5" },
            .{ .name = "accept-language", .value = "en-US,en;q=0.8" },
        },
    });
    defer req.deinit();
    try req.send();
    try req.finish();
    try req.wait();

    res.status = @intFromEnum(req.response.status);
    res.url = try std.fmt.allocPrint(a, "{;@+/?#}", .{req.uri});
    res.content_type = try a.dupe(u8, req.response.content_type orelse "");
    res.body = try req.reader().readAllAlloc(a, max_body);
}

//! Resource loading (http, https, file, about) on background threads.

const std = @import("std");
const pages = @import("pages.zig");
const urlz = @import("url.zig");
const dom = @import("../engine/dom.zig");

pub const user_agent = "Mozilla/5.0 (" ++ platform ++ ") RedBrowser/0.1 (WebRender; html5ever)";
const platform = switch (@import("builtin").os.tag) {
    .macos => "Macintosh; Mac OS X",
    .linux => "X11; Linux",
    else => "Unknown",
};

const max_body = 32 * 1024 * 1024;
const max_css = 8 * 1024 * 1024;
const max_sheets = 32;

pub const Result = struct {
    allocator: std.mem.Allocator,
    tab_id: u32,
    generation: u32,
    /// Final URL after redirects.
    url: []u8,
    body: []u8,
    content_type: []u8,
    status: u16,
    /// Parsed document with its stylesheets, built on the loader thread.
    doc: ?dom.Document = null,

    pub fn deinit(self: *Result) void {
        if (self.doc) |*d| d.deinit();
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
    prepareDocument(allocator, res) catch |err| std.log.warn("preparing {s}: {}", .{ res.url, err });
    notify(res);
}

/// Whether pages get JavaScript (set from settings by the UI thread).
pub var javascript_enabled = std.atomic.Value(bool).init(true);

const max_scripts = 96;
const max_js = 24 * 1024 * 1024;

/// Turn the response into a parsed document: wrap non-HTML in a viewer page,
/// parse, then fetch the page's stylesheets (and scripts, when JS is on) in
/// parallel and attach them to the document.
fn prepareDocument(a: std.mem.Allocator, res: *Result) !void {
    const html = if (res.isHtml())
        try a.dupe(u8, res.body)
    else if (std.ascii.startsWithIgnoreCase(res.content_type, "text/") or std.ascii.indexOfIgnoreCase(res.content_type, "json") != null or std.ascii.indexOfIgnoreCase(res.content_type, "xml") != null)
        try pages.plainText(a, res.url, res.body)
    else
        try pages.unsupported(a, res.url, res.content_type);
    defer a.free(html);

    const remote = std.ascii.startsWithIgnoreCase(res.url, "http:") or std.ascii.startsWithIgnoreCase(res.url, "https:");
    const local = std.ascii.startsWithIgnoreCase(res.url, "file:");
    const scripting = (remote or local) and res.isHtml() and javascript_enabled.load(.monotonic);

    var doc = try dom.Document.parseOpts(a, html, scripting);
    errdefer doc.deinit();

    if ((remote or local) and res.isHtml()) {
        var base: []const u8 = res.url;
        var base_buf: ?[]u8 = null;
        defer if (base_buf) |b| a.free(b);
        if (doc.find("base")) |bi| {
            if (doc.get(bi).attr("href")) |h| {
                base_buf = try urlz.resolve(a, res.url, h);
                base = base_buf.?;
            }
        }
        var jobs = std.ArrayList(Job).init(a);
        defer {
            for (jobs.items) |j| a.free(j.url);
            jobs.deinit();
        }
        var css_count: usize = 0;
        var js_count: usize = 0;
        for (doc.nodes, 0..) |*n, i| {
            if (dom.isStylesheetLink(n) and css_count < max_sheets) {
                css_count += 1;
                try jobs.append(.{ .node = @intCast(i), .css = true, .url = try urlz.resolve(a, base, n.attr("href").?) });
            } else if (scripting and dom.isClassicScript(n) and n.attr("src") != null and js_count < max_scripts) {
                js_count += 1;
                try jobs.append(.{ .node = @intCast(i), .css = false, .url = try urlz.resolve(a, base, n.attr("src").?) });
            }
        }
        fetchAll(a, jobs.items);
        for (jobs.items) |*j| {
            const body = j.body orelse continue;
            if (j.css) try doc.ext_css.put(a, j.node, body) else try doc.ext_js.put(a, j.node, body);
            j.body = null;
        }
    }
    try doc.buildSheet();
    res.doc = doc;
}

const Job = struct { node: u32, css: bool, url: []u8, body: ?[]u8 = null };

/// Fetch subresources with a few parallel workers (each with its own client).
fn fetchAll(a: std.mem.Allocator, jobs: []Job) void {
    if (jobs.len == 0) return;
    var next = std.atomic.Value(usize).init(0);
    const Worker = struct {
        fn run(alloc: std.mem.Allocator, list: []Job, cursor: *std.atomic.Value(usize)) void {
            var client = std.http.Client{ .allocator = alloc };
            defer client.deinit();
            while (true) {
                const k = cursor.fetchAdd(1, .monotonic);
                if (k >= list.len) return;
                const j = &list[k];
                if (std.ascii.startsWithIgnoreCase(j.url, "file:")) {
                    j.body = readFileUrl(alloc, j.url) catch null;
                    continue;
                }
                j.body = (if (j.css) fetchCss(alloc, &client, j.url, 0) else get(alloc, &client, j.url, "*/*", max_js)) catch |err| blk: {
                    std.log.debug("subresource {s}: {}", .{ j.url, err });
                    break :blk null;
                };
            }
        }
    };
    var threads: [6]?std.Thread = .{null} ** 6;
    const n = @min(threads.len, jobs.len);
    for (threads[0..n]) |*t| t.* = std.Thread.spawn(.{}, Worker.run, .{ a, jobs, &next }) catch null;
    // If spawning failed entirely, do the work here.
    var any = false;
    for (threads[0..n]) |t| any = any or t != null;
    if (!any) Worker.run(a, jobs, &next);
    for (threads[0..n]) |t| if (t) |th| th.join();
}

fn readFileUrl(a: std.mem.Allocator, url: []const u8) ![]u8 {
    var path = url[5..];
    if (std.mem.startsWith(u8, path, "//")) path = path[2..];
    const decoded = try a.dupe(u8, path);
    defer a.free(decoded);
    return std.fs.cwd().readFileAlloc(a, std.Uri.percentDecodeInPlace(decoded), max_js);
}

// ---- async fetch for scripts (fetch(), XMLHttpRequest, dynamic <script>) ----

pub const FetchResult = struct {
    allocator: std.mem.Allocator,
    tab_id: u32,
    generation: u32,
    req_id: u32,
    status: u16,
    url: []u8,
    content_type: []u8,
    body: []u8,
    ok: bool,

    pub fn deinit(self: *FetchResult) void {
        self.allocator.free(self.url);
        self.allocator.free(self.content_type);
        self.allocator.free(self.body);
        self.allocator.destroy(self);
    }
};

pub const FetchNotify = *const fn (res: *FetchResult) void;

pub const FetchRequest = struct {
    url: []const u8,
    method: []const u8 = "GET",
    body: []const u8 = "",
    content_type: []const u8 = "",
    tab_id: u32,
    generation: u32,
    req_id: u32,
};

pub fn fetchAsync(a: std.mem.Allocator, req: FetchRequest, notify: FetchNotify) !void {
    const owned = FetchRequest{
        .url = try a.dupe(u8, req.url),
        .method = try a.dupe(u8, req.method),
        .body = try a.dupe(u8, req.body),
        .content_type = try a.dupe(u8, req.content_type),
        .tab_id = req.tab_id,
        .generation = req.generation,
        .req_id = req.req_id,
    };
    const t = try std.Thread.spawn(.{}, fetchWorker, .{ a, owned, notify });
    t.detach();
}

fn fetchWorker(a: std.mem.Allocator, req: FetchRequest, notify: FetchNotify) void {
    defer {
        a.free(req.url);
        a.free(req.method);
        a.free(req.body);
        a.free(req.content_type);
    }
    const res = a.create(FetchResult) catch return;
    res.* = .{ .allocator = a, .tab_id = req.tab_id, .generation = req.generation, .req_id = req.req_id, .status = 0, .url = &.{}, .content_type = &.{}, .body = &.{}, .ok = false };
    doFetch(a, req, res) catch |err| {
        std.log.debug("fetch {s}: {}", .{ req.url, err });
        res.ok = false;
    };
    if (res.url.len == 0) res.url = a.dupe(u8, req.url) catch &.{};
    notify(res);
}

fn doFetch(a: std.mem.Allocator, req: FetchRequest, res: *FetchResult) !void {
    if (std.ascii.startsWithIgnoreCase(req.url, "file:")) {
        res.body = try readFileUrl(a, req.url);
        res.status = 200;
        res.ok = true;
        return;
    }
    if (!(std.ascii.startsWithIgnoreCase(req.url, "http:") or std.ascii.startsWithIgnoreCase(req.url, "https:"))) return error.UnsupportedScheme;
    var client = std.http.Client{ .allocator = a };
    defer client.deinit();
    const uri = try std.Uri.parse(req.url);
    const method = std.meta.stringToEnum(std.http.Method, req.method) orelse .GET;
    var header_buf: [32 * 1024]u8 = undefined;
    var extra: [1]std.http.Header = undefined;
    var extra_n: usize = 0;
    if (req.content_type.len > 0) {
        extra[0] = .{ .name = "content-type", .value = req.content_type };
        extra_n = 1;
    }
    var r = try client.open(method, uri, .{
        .server_header_buffer = &header_buf,
        .redirect_behavior = if (method == .GET) @enumFromInt(8) else .unhandled,
        .headers = .{ .user_agent = .{ .override = user_agent } },
        .extra_headers = extra[0..extra_n],
    });
    defer r.deinit();
    if (method.requestHasBody()) r.transfer_encoding = .{ .content_length = req.body.len };
    try r.send();
    if (method.requestHasBody()) try r.writeAll(req.body);
    try r.finish();
    try r.wait();
    res.status = @intFromEnum(r.response.status);
    res.url = try std.fmt.allocPrint(a, "{;@+/?#}", .{r.uri});
    res.content_type = try a.dupe(u8, r.response.content_type orelse "");
    res.body = try r.reader().readAllAlloc(a, max_js);
    res.ok = res.status >= 200 and res.status < 300;
}

/// GET a stylesheet; `@import`ed sheets (one level deep) are inlined in front.
fn fetchCss(a: std.mem.Allocator, client: *std.http.Client, url: []const u8, depth: u32) ![]u8 {
    const body = try get(a, client, url, "text/css,*/*;q=0.1", max_css);
    if (depth > 0 or std.mem.indexOf(u8, body, "@import") == null) return body;
    defer a.free(body);
    var out = std.ArrayList(u8).init(a);
    errdefer out.deinit();
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, body, i, "@import")) |at| {
        const semi = std.mem.indexOfScalarPos(u8, body, at, ';') orelse break;
        const stmt = body[at + 7 .. semi];
        i = semi + 1;
        const target = importTarget(stmt) orelse continue;
        const abs = urlz.resolve(a, url, target) catch continue;
        defer a.free(abs);
        const sub = fetchCss(a, client, abs, depth + 1) catch continue;
        defer a.free(sub);
        try out.appendSlice(sub);
        try out.append('\n');
    }
    try out.appendSlice(body);
    return out.toOwnedSlice();
}

fn importTarget(stmt: []const u8) ?[]const u8 {
    var t = std.mem.trim(u8, stmt, " \t\r\n");
    if (std.mem.startsWith(u8, t, "url(")) {
        const close = std.mem.indexOfScalar(u8, t, ')') orelse return null;
        t = std.mem.trim(u8, t[4..close], " ");
    } else {
        // `"x.css" screen` → keep only the quoted part
        if (t.len == 0) return null;
        const q = t[0];
        if (q != '"' and q != '\'') return null;
        const end = std.mem.indexOfScalarPos(u8, t, 1, q) orelse return null;
        return t[1..end];
    }
    if (t.len >= 2 and (t[0] == '"' or t[0] == '\'')) t = t[1 .. t.len - 1];
    return if (t.len > 0) t else null;
}

/// Simple GET returning the body (follows redirects; errors on non-2xx).
fn get(a: std.mem.Allocator, client: *std.http.Client, url: []const u8, accept: []const u8, limit: usize) ![]u8 {
    const uri = try std.Uri.parse(url);
    var header_buf: [32 * 1024]u8 = undefined;
    var req = try client.open(.GET, uri, .{
        .server_header_buffer = &header_buf,
        .redirect_behavior = @enumFromInt(8),
        .headers = .{ .user_agent = .{ .override = user_agent } },
        .extra_headers = &.{.{ .name = "accept", .value = accept }},
    });
    defer req.deinit();
    try req.send();
    try req.finish();
    try req.wait();
    const status = @intFromEnum(req.response.status);
    if (status < 200 or status >= 300) return error.HttpStatus;
    return req.reader().readAllAlloc(a, limit);
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

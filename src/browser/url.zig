//! URL helpers: turning address-bar input into URLs and resolving relative links.

const std = @import("std");

pub fn scheme(url: []const u8) ?[]const u8 {
    const colon = std.mem.indexOfScalar(u8, url, ':') orelse return null;
    if (colon == 0) return null;
    for (url[0..colon]) |ch| {
        if (!(std.ascii.isAlphanumeric(ch) or ch == '+' or ch == '-' or ch == '.')) return null;
    }
    return url[0..colon];
}

/// Interpret what the user typed: a URL, a bare host, a local path, or a search query.
pub fn fromInput(a: std.mem.Allocator, raw: []const u8) ![]u8 {
    const input = std.mem.trim(u8, raw, " \t\r\n");
    if (input.len == 0) return a.dupe(u8, "about:home");
    if (scheme(input)) |sc| {
        const known = [_][]const u8{ "http", "https", "file", "about" };
        for (known) |k| {
            if (std.ascii.eqlIgnoreCase(sc, k)) return a.dupe(u8, input);
        }
    }
    if (input[0] == '/') return std.fmt.allocPrint(a, "file://{s}", .{input});
    const has_space = std.mem.indexOfAny(u8, input, " \t") != null;
    const looks_like_host = !has_space and (std.mem.indexOfScalar(u8, input, '.') != null or
        std.mem.startsWith(u8, input, "localhost"));
    if (looks_like_host) {
        if (std.mem.startsWith(u8, input, "localhost") or std.mem.startsWith(u8, input, "127.")) return std.fmt.allocPrint(a, "http://{s}", .{input});
        return std.fmt.allocPrint(a, "https://{s}", .{input});
    }
    return searchUrl(a, input);
}

pub fn searchUrl(a: std.mem.Allocator, query: []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(a);
    try out.appendSlice("https://lite.duckduckgo.com/lite/?q=");
    try percentEncode(&out, query);
    return out.toOwnedSlice();
}

fn percentEncode(out: *std.ArrayList(u8), s: []const u8) !void {
    for (s) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.' or ch == '~') {
            try out.append(ch);
        } else if (ch == ' ') {
            try out.append('+');
        } else {
            try out.writer().print("%{X:0>2}", .{ch});
        }
    }
}

const Parts = struct {
    scheme: []const u8, // "https"
    authority: []const u8, // "//host:port" or ""
    path: []const u8, // "/a/b"
    query: []const u8, // "?x" or ""
};

fn split(url: []const u8) Parts {
    const sc = scheme(url) orelse "";
    var rest = url[if (sc.len > 0) sc.len + 1 else 0..];
    if (std.mem.indexOfScalar(u8, rest, '#')) |h| rest = rest[0..h];
    var authority: []const u8 = "";
    if (std.mem.startsWith(u8, rest, "//")) {
        const end = std.mem.indexOfAnyPos(u8, rest, 2, "/?") orelse rest.len;
        authority = rest[0..end];
        rest = rest[end..];
    }
    const q = std.mem.indexOfScalar(u8, rest, '?') orelse rest.len;
    return .{ .scheme = sc, .authority = authority, .path = rest[0..q], .query = rest[q..] };
}

/// Resolve `href` against `base` (RFC 3986, simplified). Caller owns the result.
pub fn resolve(a: std.mem.Allocator, base: []const u8, href_raw: []const u8) ![]u8 {
    const href = std.mem.trim(u8, href_raw, " \t\r\n");
    if (scheme(href) != null) return a.dupe(u8, href);
    const b = split(base);
    if (href.len == 0) return a.dupe(u8, base);
    if (std.mem.startsWith(u8, href, "//")) return std.fmt.allocPrint(a, "{s}:{s}", .{ b.scheme, href });
    if (href[0] == '#') {
        const no_frag = if (std.mem.indexOfScalar(u8, base, '#')) |h| base[0..h] else base;
        return std.fmt.allocPrint(a, "{s}{s}", .{ no_frag, href });
    }
    if (href[0] == '?') return std.fmt.allocPrint(a, "{s}:{s}{s}{s}", .{ b.scheme, b.authority, if (b.path.len == 0) "/" else b.path, href });

    var path = std.ArrayList(u8).init(a);
    defer path.deinit();
    if (href[0] == '/') {
        try path.appendSlice(href);
    } else {
        const dir_end = if (std.mem.lastIndexOfScalar(u8, b.path, '/')) |i| i + 1 else 0;
        if (dir_end == 0) try path.append('/');
        try path.appendSlice(b.path[0..dir_end]);
        try path.appendSlice(href);
    }
    // split off query/fragment from the joined path before normalising
    var tail: []const u8 = "";
    if (std.mem.indexOfAny(u8, path.items, "?#")) |i| tail = path.items[i..];
    const norm = try normalize(a, path.items[0 .. path.items.len - tail.len]);
    defer a.free(norm);
    return std.fmt.allocPrint(a, "{s}:{s}{s}{s}", .{ b.scheme, b.authority, norm, tail });
}

fn normalize(a: std.mem.Allocator, path: []const u8) ![]u8 {
    var segs = std.ArrayList([]const u8).init(a);
    defer segs.deinit();
    var it = std.mem.splitScalar(u8, path, '/');
    _ = it.next(); // leading empty segment
    var trailing = false;
    while (it.next()) |seg| {
        trailing = false;
        if (std.mem.eql(u8, seg, ".")) {
            trailing = true;
        } else if (std.mem.eql(u8, seg, "..")) {
            if (segs.items.len > 0) _ = segs.pop();
            trailing = true;
        } else {
            try segs.append(seg);
        }
    }
    var out = std.ArrayList(u8).init(a);
    for (segs.items) |s| {
        try out.append('/');
        try out.appendSlice(s);
    }
    if (out.items.len == 0 or trailing) try out.append('/');
    return out.toOwnedSlice();
}

/// Host part of a URL for display (e.g. tab tooltips, titles).
pub fn host(url: []const u8) []const u8 {
    const p = split(url);
    var h = p.authority;
    if (std.mem.startsWith(u8, h, "//")) h = h[2..];
    if (std.mem.lastIndexOfScalar(u8, h, '@')) |i| h = h[i + 1 ..];
    return h;
}

test "resolve" {
    const a = std.testing.allocator;
    const cases = [_][3][]const u8{
        .{ "https://a.com/x/y.html", "z.html", "https://a.com/x/z.html" },
        .{ "https://a.com/x/y.html", "/r", "https://a.com/r" },
        .{ "https://a.com/x/y/", "../q?a=1", "https://a.com/x/q?a=1" },
        .{ "https://a.com", "item?id=3", "https://a.com/item?id=3" },
        .{ "https://a.com/p?q", "//b.org/c", "https://b.org/c" },
        .{ "https://a.com/p?q", "?z", "https://a.com/p?z" },
        .{ "https://a.com/p#x", "#y", "https://a.com/p#y" },
        .{ "file:///tmp/a.html", "b.html", "file:///tmp/b.html" },
    };
    for (cases) |c| {
        const r = try resolve(a, c[0], c[1]);
        defer a.free(r);
        try std.testing.expectEqualStrings(c[2], r);
    }
}

test "fromInput" {
    const a = std.testing.allocator;
    const r1 = try fromInput(a, "example.com");
    defer a.free(r1);
    try std.testing.expectEqualStrings("https://example.com", r1);
    const r2 = try fromInput(a, "zig lang");
    defer a.free(r2);
    try std.testing.expectEqualStrings("https://lite.duckduckgo.com/lite/?q=zig+lang", r2);
}

//! Built-in pages (about:*). They are plain HTML rendered by the same engine as the web.

const std = @import("std");

const settings = @import("settings.zig");

/// Snapshot of the appearance used to render built-in pages. Written by the UI
/// thread, read by loader threads.
pub const PageTheme = struct {
    colors: Colors = .{},
    prefs: settings.Settings = .{},
    dark: bool = true,
};
var theme_lock: std.Thread.Mutex = .{};
var theme: PageTheme = .{};

pub fn setTheme(t: PageTheme) void {
    theme_lock.lock();
    defer theme_lock.unlock();
    theme = t;
}

fn currentTheme() PageTheme {
    theme_lock.lock();
    defer theme_lock.unlock();
    return theme;
}

/// Page colours (0xRRGGBB).
pub const Colors = struct { bg: u24 = 0x282c34, card: u24 = 0x1e2127, text: u24 = 0xe6e6e6, muted: u24 = 0x8b919e, brand: u24 = 0xff5a5f, link: u24 = 0x61afef };

/// Substitute {bg} {card} {text} {muted} {brand} {link} with the active palette.
fn themed(a: std.mem.Allocator, template: []const u8) ![]u8 {
    const c = currentTheme().colors;
    var out = std.ArrayList(u8).init(a);
    var i: usize = 0;
    outer: while (i < template.len) {
        if (template[i] == '{') {
            inline for (@typeInfo(Colors).@"struct".fields) |f| {
                const tok = "{" ++ f.name ++ "}";
                if (std.mem.startsWith(u8, template[i..], tok)) {
                    try out.writer().print("#{x:0>6}", .{@field(c, f.name)});
                    i += tok.len;
                    continue :outer;
                }
            }
        }
        try out.append(template[i]);
        i += 1;
    }
    return out.toOwnedSlice();
}

/// The new-tab screen itself (wallpaper, "RED", search box) is drawn natively
/// by the shell; this document only provides the tab title.
const home = "<html><head><title>New Tab</title></head><body bgcolor=\"{bg}\"></body></html>";

const about_page =
    \\<!doctype html>
    \\<html><head><title>About Red Browser</title></head>
    \\<body style="margin:0" bgcolor="{bg}" text="{text}">
    \\<div style="max-width:720px; margin:0 auto; padding:40px 24px">
    \\<h1 style="color:{brand}">About Red Browser</h1>
    \\<h3>Architecture</h3>
    \\<ul>
    \\  <li><b>Browser shell (Zig)</b>: window, tabs, address bar, history, input, networking, style and layout.</li>
    \\  <li><b>Renderer (Rust bridge)</b>: <a style="color:{link}" href="https://github.com/servo/webrender">WebRender</a>, the GPU renderer that ships in Firefox.</li>
    \\  <li><b>HTML parser (Rust bridge)</b>: <a style="color:{link}" href="https://github.com/servo/html5ever">html5ever</a>, Servo's spec-compliant HTML5 parser.</li>
    \\  <li><b>Axolotl</b>: the in-house engine bindings are still available in <code>rust-piston-bindings</code>.</li>
    \\</ul>
    \\<h3>Keyboard shortcuts</h3>
    \\<table cellpadding="4">
    \\<tr><td><code>Cmd/Ctrl+T</code></td><td>New tab</td></tr>
    \\<tr><td><code>Cmd/Ctrl+W</code></td><td>Close tab</td></tr>
    \\<tr><td><code>Cmd/Ctrl+L</code></td><td>Focus address bar</td></tr>
    \\<tr><td><code>Cmd/Ctrl+,</code></td><td>Settings (theme &amp; accent colour)</td></tr>
    \\<tr><td><code>Cmd/Ctrl+R</code></td><td>Reload</td></tr>
    \\<tr><td><code>Cmd/Ctrl+[ / ]</code></td><td>Back / Forward</td></tr>
    \\<tr><td><code>Ctrl+Tab</code>, <code>Cmd/Ctrl+1..9</code></td><td>Switch tabs</td></tr>
    \\<tr><td><code>Cmd/Ctrl+click</code></td><td>Open link in new tab</td></tr>
    \\<tr><td><code>Space</code>, arrows, <code>Home/End</code></td><td>Scroll</td></tr>
    \\</table>
    \\<h3>Not yet supported</h3>
    \\<p>Author stylesheets (CSS files and &lt;style&gt;), images, JavaScript and form submission.</p>
    \\</div></body></html>
;

pub fn about(a: std.mem.Allocator, which: []const u8) ![]u8 {
    if (std.mem.eql(u8, which, "home") or std.mem.eql(u8, which, "newtab")) return themed(a, home);
    if (std.mem.eql(u8, which, "redbrowser")) return themed(a, about_page);
    if (std.mem.startsWith(u8, which, "settings")) return settingsPage(a);
    if (std.mem.eql(u8, which, "blank")) return themed(a, "<html><head><title>about:blank</title></head><body bgcolor=\"{bg}\"></body></html>");
    return errorPage(a, which, "UnknownAboutPage");
}

pub fn errorPage(a: std.mem.Allocator, url: []const u8, err: []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(a);
    const w = out.writer();
    try w.writeAll(
        \\<html><head><title>Problem loading page</title></head>
        \\<body bgcolor="{bg}" text="{text}" style="margin:0"><div style="max-width:560px; margin:0 auto; padding:96px 24px">
        \\<h1>Hmm. We're having trouble finding that site.</h1>
        \\<p style="color:{muted}">Red Browser couldn't load <b>
    );
    try escape(w, url);
    try w.writeAll("</b>.</p><p style=\"color:{muted}\">Error: <code>");
    try escape(w, err);
    try w.writeAll(
        \\</code></p>
        \\<ul style="color:{muted}"><li>Check the address for typing errors.</li>
        \\<li>Check your network connection.</li></ul>
        \\</div></body></html>
    );
    defer out.deinit();
    return themed(a, out.items);
}

/// Wrap non-HTML text so it renders as preformatted text.
pub fn plainText(a: std.mem.Allocator, title: []const u8, body: []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(a);
    const w = out.writer();
    try w.writeAll("<html><head><title>");
    try escape(w, title);
    try w.writeAll("</title></head><body><pre style=\"font-size:13px\">");
    try escape(w, body);
    try w.writeAll("</pre></body></html>");
    return out.toOwnedSlice();
}

pub fn unsupported(a: std.mem.Allocator, url: []const u8, content_type: []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(a);
    const w = out.writer();
    try w.writeAll("<html><head><title>");
    try escape(w, url);
    try w.writeAll("</title></head><body bgcolor=\"{bg}\" text=\"{text}\"><div style=\"padding:64px 24px\" align=\"center\"><h2>Can't display this file yet</h2><p style=\"color:{muted}\">Content type: <code>");
    try escape(w, content_type);
    try w.writeAll("</code></p></div></body></html>");
    defer out.deinit();
    return themed(a, out.items);
}

fn escape(w: anytype, s: []const u8) !void {
    for (s) |ch| switch (ch) {
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        '&' => try w.writeAll("&amp;"),
        '"' => try w.writeAll("&quot;"),
        else => try w.writeByte(ch),
    };
}

/// about:settings — plain links drive it (no JS): the app intercepts
/// `about:settings?key=value`, applies + saves, then reloads this page.
fn settingsPage(a: std.mem.Allocator) ![]u8 {
    const t = currentTheme();
    const prefs = t.prefs;

    var out = std.ArrayList(u8).init(a);
    defer out.deinit();
    const w = out.writer();
    try w.writeAll(
        \\<html><head><title>Settings</title></head>
        \\<body bgcolor="{bg}" text="{text}" style="margin:0">
        \\<div style="max-width:760px; margin:0 auto; padding:40px 24px">
        \\<h1 style="color:{brand}; margin-bottom:4px; font-family:monospace">❯ settings</h1>
        \\<p style="color:{muted}; margin-top:0">Changes apply instantly and are remembered.</p>
        \\<h3 style="margin-top:32px; font-family:monospace">appearance</h3>
        \\<table cellspacing="6" cellpadding="10"><tr>
    );
    const modes = [_][2][]const u8{ .{ "system", "Automatic" }, .{ "light", "Light" }, .{ "dark", "Dark" } };
    for (modes, 0..) |m, i| {
        const sel = i == @intFromEnum(prefs.theme);
        try w.print("<td bgcolor=\"{s}\"><a href=\"about:settings?theme={s}\" style=\"color:{s}; text-decoration:none; font-weight:{s}\">{s}{s}</a></td>", .{
            if (sel) "{brand}" else "{card}", m[0], if (sel) "{card}" else "{text}", if (sel) "bold" else "normal", if (sel) "✓ " else "", m[1],
        });
    }
    try w.writeAll("</tr></table>");

    inline for (.{ true, false }) |want_dark| {
        try w.print("<h3 style=\"margin-top:32px; font-family:monospace\">{s} theme</h3><table cellspacing=\"6\" cellpadding=\"12\"><tr>", .{if (want_dark) "dark" else "light"});
        const current = if (want_dark) prefs.dark_scheme else prefs.light_scheme;
        for (settings.schemes, 0..) |sc, i| {
            if (sc.dark != want_dark) continue;
            const sel = i == current;
            try w.print("<td bgcolor=\"#{x:0>6}\"><a href=\"about:settings?{s}_theme={s}\" style=\"color:#{x:0>6}; text-decoration:none; font-weight:{s}\">{s}{s}</a><br><small style=\"color:#{x:0>6}\">● </small><small style=\"color:#{x:0>6}\">● </small><small style=\"color:#{x:0>6}\">●</small></td>", .{
                sc.surface, if (want_dark) "dark" else "light", sc.id, sc.fg, if (sel) "bold" else "normal", if (sel) "✓ " else "", sc.name, sc.accent, sc.link, sc.muted,
            });
        }
        try w.writeAll("</tr></table>");
    }

    try w.writeAll(
        \\<h3 style="margin-top:32px; font-family:monospace">accent</h3>
        \\<p style="color:{muted}; margin-top:0">Overrides the theme's accent: focus ring, cursor, progress, selection.</p>
        \\<table cellspacing="6" cellpadding="12"><tr>
    );
    {
        const sel = prefs.accent == null;
        try w.print("<td bgcolor=\"{s}\"><a href=\"about:settings?accent=theme\" style=\"color:{s}; text-decoration:none; font-weight:{s}\">{s}Theme default</a></td></tr><tr>", .{
            if (sel) "{brand}" else "{card}", if (sel) "{card}" else "{text}", if (sel) "bold" else "normal", if (sel) "✓ " else "",
        });
    }
    for (settings.accents, 0..) |acc, i| {
        if (i == 5) try w.writeAll("</tr><tr>");
        const sel = prefs.accent != null and prefs.accent.? == i;
        const hex = if (t.dark) acc.dark else acc.light;
        try w.print("<td bgcolor=\"#{x:0>6}\" align=\"center\"><a href=\"about:settings?accent={s}\" style=\"color:#ffffff; text-decoration:none; font-weight:{s}\">{s}{s}</a></td>", .{
            hex, acc.id, if (sel) "bold" else "normal", if (sel) "✓ " else "", acc.name,
        });
    }
    try w.writeAll(
        \\</tr></table>
        \\<h3 style="margin-top:32px; font-family:monospace">new tab wallpaper</h3>
        \\<table cellspacing="6" cellpadding="10"><tr>
        \\{wallpaper}
        \\</tr></table>
        \\<p style="color:{muted}">Tip: you can also drag &amp; drop an image onto the window.</p>
        \\<h3 style="margin-top:32px; font-family:monospace">about</h3>
        \\<p><a href="about:redbrowser" style="color:{link}">Engine &amp; keyboard shortcuts</a></p>
        \\</div></body></html>
    );
    // wallpaper chips
    var chips = std.ArrayList(u8).init(a);
    defer chips.deinit();
    const wopts = [_][3][]const u8{ .{ "none", "None", "wallpaper=none" }, .{ "gradient", "Gradient", "wallpaper=gradient" }, .{ "custom", "Choose image…", "wallpaper=choose" } };
    for (wopts) |o| {
        const sel = std.mem.eql(u8, @tagName(prefs.wallpaper), o[0]);
        try chips.writer().print("<td bgcolor=\"{s}\"><a href=\"about:settings?{s}\" style=\"color:{s}; text-decoration:none; font-weight:{s}\">{s}{s}</a></td>", .{
            if (sel) "{brand}" else "{card}", o[2], if (sel) "{card}" else "{text}", if (sel) "bold" else "normal", if (sel) "✓ " else "", o[1],
        });
    }
    const page = try std.mem.replaceOwned(u8, a, out.items, "{wallpaper}", chips.items);
    defer a.free(page);
    return themed(a, page);
}

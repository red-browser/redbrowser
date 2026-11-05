//! User preferences: appearance mode, a colour scheme for light and one for
//! dark, an optional accent override and the new-tab wallpaper. Persisted as
//! `key=value` lines in SDL's per-user preference directory.

const std = @import("std");
const c = @import("sdl.zig").c;
const ui = @import("ui.zig");

pub const Accent = struct {
    id: []const u8,
    name: []const u8,
    light: u24, // on light surfaces
    dark: u24, // brighter variant for dark surfaces
};

pub const Scheme = struct {
    id: []const u8,
    name: []const u8,
    dark: bool,
    bg: u24, // window / title bar
    surface: u24, // toolbar row, active tab, cards
    border: u24,
    fg: u24,
    muted: u24,
    accent: u24,
    link: u24,
};

pub const schemes = [_]Scheme{
    // dark
    .{ .id = "catppuccin-mocha", .name = "Catppuccin Mocha", .dark = true, .bg = 0x181825, .surface = 0x1e1e2e, .border = 0x45475a, .fg = 0xcdd6f4, .muted = 0x9399b2, .accent = 0xcba6f7, .link = 0x89b4fa },
    .{ .id = "red-dark", .name = "Red Dark", .dark = true, .bg = 0x1e2127, .surface = 0x282c34, .border = 0x3a3f4b, .fg = 0xe6e6e6, .muted = 0x8b919e, .accent = 0xff5a5f, .link = 0x61afef },
    .{ .id = "tokyo-night", .name = "Tokyo Night", .dark = true, .bg = 0x16161e, .surface = 0x1a1b26, .border = 0x2f3549, .fg = 0xc0caf5, .muted = 0x787c99, .accent = 0x7aa2f7, .link = 0x7dcfff },
    .{ .id = "gruvbox-dark", .name = "Gruvbox Dark", .dark = true, .bg = 0x1d2021, .surface = 0x282828, .border = 0x504945, .fg = 0xebdbb2, .muted = 0xa89984, .accent = 0xfe8019, .link = 0x83a598 },
    .{ .id = "nord", .name = "Nord", .dark = true, .bg = 0x2a2f3a, .surface = 0x2e3440, .border = 0x434c5e, .fg = 0xeceff4, .muted = 0x9aa5b8, .accent = 0x88c0d0, .link = 0x81a1c1 },
    // light
    .{ .id = "catppuccin-latte", .name = "Catppuccin Latte", .dark = false, .bg = 0xe6e9ef, .surface = 0xeff1f5, .border = 0xccd0da, .fg = 0x4c4f69, .muted = 0x7c7f93, .accent = 0x8839ef, .link = 0x1e66f5 },
    .{ .id = "red-light", .name = "Red Light", .dark = false, .bg = 0xe9e9ec, .surface = 0xf7f7f8, .border = 0xd4d4d9, .fg = 0x1d1d1f, .muted = 0x6e6e73, .accent = 0xe5484d, .link = 0x0060df },
    .{ .id = "solarized-light", .name = "Solarized Light", .dark = false, .bg = 0xeee8d5, .surface = 0xfdf6e3, .border = 0xd9d2bd, .fg = 0x073642, .muted = 0x839496, .accent = 0xcb4b16, .link = 0x268bd2 },
    .{ .id = "gruvbox-light", .name = "Gruvbox Light", .dark = false, .bg = 0xebdbb2, .surface = 0xfbf1c7, .border = 0xd5c4a1, .fg = 0x3c3836, .muted = 0x7c6f64, .accent = 0xaf3a03, .link = 0x076678 },
    .{ .id = "github-light", .name = "GitHub Light", .dark = false, .bg = 0xf6f8fa, .surface = 0xffffff, .border = 0xd0d7de, .fg = 0x1f2328, .muted = 0x656d76, .accent = 0x0969da, .link = 0x0969da },
};

pub fn schemeIndex(id: []const u8) ?usize {
    for (schemes, 0..) |sc, i| {
        if (std.mem.eql(u8, sc.id, id)) return i;
    }
    return null;
}

pub const accents = [_]Accent{
    .{ .id = "red", .name = "Red", .light = 0xe5484d, .dark = 0xff5a5f },
    .{ .id = "orange", .name = "Orange", .light = 0xf76b15, .dark = 0xff8b3e },
    .{ .id = "amber", .name = "Amber", .light = 0xd99a00, .dark = 0xffc53d },
    .{ .id = "green", .name = "Green", .light = 0x30a46c, .dark = 0x3dd68c },
    .{ .id = "teal", .name = "Teal", .light = 0x12a594, .dark = 0x0bd8b6 },
    .{ .id = "blue", .name = "Blue", .light = 0x0a84ff, .dark = 0x4ea8ff },
    .{ .id = "indigo", .name = "Indigo", .light = 0x5e5ce6, .dark = 0x8e8cff },
    .{ .id = "purple", .name = "Purple", .light = 0xa550d8, .dark = 0xc77dff },
    .{ .id = "pink", .name = "Pink", .light = 0xe93d82, .dark = 0xff6fa8 },
    .{ .id = "graphite", .name = "Graphite", .light = 0x6e6e73, .dark = 0xa1a1a8 },
};

pub const Wallpaper = enum { none, gradient, custom };

pub const Settings = struct {
    theme: ui.ThemeMode = .dark,
    dark_scheme: usize = schemeIndex("gruvbox-dark").?,
    light_scheme: usize = schemeIndex("gruvbox-light").?,
    wallpaper: Wallpaper = .gradient,
    /// null = use the colour scheme's own accent
    accent: ?usize = null,

    pub fn scheme(self: Settings, dark: bool) Scheme {
        return schemes[if (dark) self.dark_scheme else self.light_scheme];
    }

    pub fn accentColor(self: Settings, dark: bool) u24 {
        const i = self.accent orelse return self.scheme(dark).accent;
        return if (dark) accents[i].dark else accents[i].light;
    }

    /// Apply one `key=value` pair (from the settings file or an about:settings link).
    pub fn set(self: *Settings, key: []const u8, value: []const u8) bool {
        if (std.mem.eql(u8, key, "theme")) {
            inline for (@typeInfo(ui.ThemeMode).@"enum".fields) |f| {
                if (std.mem.eql(u8, value, f.name)) {
                    self.theme = @enumFromInt(f.value);
                    return true;
                }
            }
        } else if (std.mem.eql(u8, key, "wallpaper")) {
            inline for (@typeInfo(Wallpaper).@"enum".fields) |f| {
                if (std.mem.eql(u8, value, f.name)) {
                    self.wallpaper = @enumFromInt(f.value);
                    return true;
                }
            }
        } else if (std.mem.eql(u8, key, "dark_theme") or std.mem.eql(u8, key, "light_theme")) {
            const i = schemeIndex(value) orelse return false;
            if (schemes[i].dark) self.dark_scheme = i else self.light_scheme = i;
            return true;
        } else if (std.mem.eql(u8, key, "accent")) {
            if (std.mem.eql(u8, value, "theme")) {
                self.accent = null;
                return true;
            }
            for (accents, 0..) |a, i| {
                if (std.mem.eql(u8, value, a.id)) {
                    self.accent = i;
                    return true;
                }
            }
        }
        return false;
    }

    /// Apply a query string like `accent=blue&theme=dark`. Returns true if anything changed.
    pub fn applyQuery(self: *Settings, query: []const u8) bool {
        var changed = false;
        var it = std.mem.splitScalar(u8, query, '&');
        while (it.next()) |pair| {
            const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
            if (self.set(pair[0..eq], pair[eq + 1 ..])) changed = true;
        }
        return changed;
    }

    fn prefFile(buf: []u8, name: []const u8) ?[:0]const u8 {
        const dir = c.SDL_GetPrefPath("redbrowser", "Red Browser") orelse return null;
        defer c.SDL_free(dir);
        return std.fmt.bufPrintZ(buf, "{s}{s}", .{ std.mem.span(dir), name }) catch null;
    }

    fn path(buf: []u8) ?[]const u8 {
        return prefFile(buf, "settings");
    }

    /// Where the custom wallpaper is kept (a private copy of the chosen image).
    pub fn wallpaperPath(buf: []u8) ?[:0]const u8 {
        return prefFile(buf, "wallpaper");
    }

    pub fn load() Settings {
        var s = Settings{};
        var pbuf: [1024]u8 = undefined;
        const p = path(&pbuf) orelse return s;
        var dbuf: [4096]u8 = undefined;
        const data = std.fs.cwd().readFile(p, &dbuf) catch return s;
        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |line| {
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            _ = s.set(std.mem.trim(u8, line[0..eq], " \r"), std.mem.trim(u8, line[eq + 1 ..], " \r"));
        }
        return s;
    }

    pub fn save(self: Settings) void {
        var pbuf: [1024]u8 = undefined;
        const p = path(&pbuf) orelse return;
        var dbuf: [512]u8 = undefined;
        const data = std.fmt.bufPrint(&dbuf, "theme={s}\ndark_theme={s}\nlight_theme={s}\naccent={s}\nwallpaper={s}\n", .{
            @tagName(self.theme),
            schemes[self.dark_scheme].id,
            schemes[self.light_scheme].id,
            if (self.accent) |i| accents[i].id else "theme",
            @tagName(self.wallpaper),
        }) catch return;
        std.fs.cwd().writeFile(.{ .sub_path = p, .data = data }) catch |err| std.log.warn("saving settings: {}", .{err});
    }
};

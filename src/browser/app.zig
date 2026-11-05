//! Application: SDL window + GL context, event loop, input dispatch, frame drawing.

const std = @import("std");
const builtin = @import("builtin");
const c = @import("sdl.zig").c;
const gfx = @import("../engine/gfx.zig");
const ffi = @import("../engine/ffi.zig");
const ui = @import("ui.zig");
const net = @import("net.zig");
const urlz = @import("url.zig");
const Tab = @import("tab.zig").Tab;
const pages = @import("pages.zig");
const Settings = @import("settings.zig").Settings;

const home_url = "about:home";

/// SDL event type used by loader threads to hand results to the UI thread.
var load_event_type: u32 = 0;
/// SDL event type carrying a wallpaper path chosen in the file dialog.
var wallpaper_event_type: u32 = 0;

fn onWallpaperChosen(userdata: ?*anyopaque, filelist: [*c]const [*c]const u8, filter: c_int) callconv(.C) void {
    _ = userdata;
    _ = filter;
    if (filelist == null or filelist[0] == null) return;
    const path = c.SDL_strdup(filelist[0]) orelse return;
    var ev: c.SDL_Event = std.mem.zeroes(c.SDL_Event);
    ev.type = wallpaper_event_type;
    ev.user.data1 = path;
    if (!c.SDL_PushEvent(&ev)) c.SDL_free(path);
}

fn onLoadComplete(res: *net.Result) void {
    var ev: c.SDL_Event = std.mem.zeroes(c.SDL_Event);
    ev.type = load_event_type;
    ev.user.data1 = res;
    if (!c.SDL_PushEvent(&ev)) res.deinit();
}

fn getProcAddress(name: [*:0]const u8) callconv(.C) ?*const anyopaque {
    return @ptrCast(c.SDL_GL_GetProcAddress(name));
}

pub const Options = struct {
    initial_url: ?[]const u8 = null,
    /// Debug aid: render, save a PNG of the window to this path once loads finish, then exit.
    screenshot_path: ?[:0]const u8 = null,
};

pub const App = struct {
    a: std.mem.Allocator,
    window: *c.SDL_Window,
    gl: c.SDL_GLContext,
    g: gfx.Gfx,
    tabs: std.ArrayListUnmanaged(*Tab) = .{},
    active: usize = 0,
    next_tab_id: u32 = 1,
    bar: ui.AddressBar = .{},
    /// Search box on the new-tab screen.
    home_bar: ui.AddressBar = .{},
    selecting_home: bool = false,
    wallpaper: ?gfx.Gfx.Image = null,
    win_w: f32 = 1280,
    win_h: f32 = 800,
    mouse_x: f32 = 0,
    mouse_y: f32 = 0,
    anim: ui.Anim = .{},
    settings: Settings = .{},
    last_frame_ms: i64 = 0,
    hover: ui.Hit = .none,
    hover_home: bool = false,
    pressed: ui.Hit = .none,
    hover_link: ?[]u8 = null,
    selecting_url: bool = false,
    running: bool = true,
    dirty: bool = true,
    cursor_default: ?*c.SDL_Cursor = null,
    cursor_pointer: ?*c.SDL_Cursor = null,
    cursor_text: ?*c.SDL_Cursor = null,
    current_cursor: ?*c.SDL_Cursor = null,
    opts: Options,
    frames_since_idle: u32 = 0,
    pending_debug_scroll: ?f32 = null,

    pub fn init(a: std.mem.Allocator, opts: Options) !*App {
        if (!c.SDL_Init(c.SDL_INIT_VIDEO)) {
            std.log.err("SDL_Init: {s}", .{c.SDL_GetError()});
            return error.SDLInitFailed;
        }
        load_event_type = c.SDL_RegisterEvents(2);
        wallpaper_event_type = load_event_type + 1;

        _ = c.SDL_GL_SetAttribute(c.SDL_GL_CONTEXT_MAJOR_VERSION, 3);
        _ = c.SDL_GL_SetAttribute(c.SDL_GL_CONTEXT_MINOR_VERSION, 2);
        _ = c.SDL_GL_SetAttribute(c.SDL_GL_CONTEXT_PROFILE_MASK, c.SDL_GL_CONTEXT_PROFILE_CORE);
        if (builtin.os.tag == .macos) _ = c.SDL_GL_SetAttribute(c.SDL_GL_CONTEXT_FLAGS, c.SDL_GL_CONTEXT_FORWARD_COMPATIBLE_FLAG);
        _ = c.SDL_GL_SetAttribute(c.SDL_GL_DOUBLEBUFFER, 1);
        _ = c.SDL_GL_SetAttribute(c.SDL_GL_DEPTH_SIZE, 24);
        _ = c.SDL_GL_SetAttribute(c.SDL_GL_STENCIL_SIZE, 8);
        _ = c.SDL_GL_SetAttribute(c.SDL_GL_ALPHA_SIZE, 8); // transparent corners

        // Borderless: we draw our own title bar + window controls so the browser
        // looks identical on macOS, Linux and Windows.
        const flags = c.SDL_WINDOW_OPENGL | c.SDL_WINDOW_RESIZABLE | c.SDL_WINDOW_HIGH_PIXEL_DENSITY | c.SDL_WINDOW_BORDERLESS | c.SDL_WINDOW_TRANSPARENT;
        const window = c.SDL_CreateWindow("Red Browser", 1280, 800, flags) orelse {
            std.log.err("SDL_CreateWindow: {s}", .{c.SDL_GetError()});
            return error.WindowCreationFailed;
        };
        errdefer c.SDL_DestroyWindow(window);
        _ = c.SDL_SetWindowMinimumSize(window, 560, 320);
        setIcon(window);

        const gl = c.SDL_GL_CreateContext(window) orelse {
            std.log.err("SDL_GL_CreateContext: {s}", .{c.SDL_GetError()});
            return error.GLContextCreationFailed;
        };
        _ = c.SDL_GL_MakeCurrent(window, gl);
        _ = c.SDL_GL_SetSwapInterval(1);

        const self = try a.create(App);
        errdefer a.destroy(self);
        self.* = .{ .a = a, .window = window, .gl = gl, .g = undefined, .opts = opts, .settings = Settings.load() };
        self.applyTheme(false);
        const size = self.querySize();
        var dir_bufs: [3][1024]u8 = undefined;
        var dirs: [3][]const u8 = undefined;
        const n_dirs = assetDirs(&dir_bufs, &dirs);
        self.g = try gfx.Gfx.init(getProcAddress, size.pw, size.ph, size.scale, dirs[0..n_dirs]);
        _ = c.SDL_SetWindowHitTest(window, windowHitTest, self);

        self.cursor_default = c.SDL_CreateSystemCursor(c.SDL_SYSTEM_CURSOR_DEFAULT);
        self.cursor_pointer = c.SDL_CreateSystemCursor(c.SDL_SYSTEM_CURSOR_POINTER);
        self.cursor_text = c.SDL_CreateSystemCursor(c.SDL_SYSTEM_CURSOR_TEXT);

        _ = try self.openTab(opts.initial_url orelse home_url, true);
        self.loadWallpaper();
        if (opts.initial_url == null) self.focusHome();
        return self;
    }

    pub fn deinit(self: *App) void {
        for (self.tabs.items) |t| {
            t.deinit();
            self.a.destroy(t);
        }
        self.tabs.deinit(self.a);
        self.bar.deinit(self.a);
        self.home_bar.deinit(self.a);
        if (self.hover_link) |l| self.a.free(l);
        self.g.deinit();
        for ([_]?*c.SDL_Cursor{ self.cursor_default, self.cursor_pointer, self.cursor_text }) |cur| {
            if (cur) |p| c.SDL_DestroyCursor(p);
        }
        _ = c.SDL_GL_DestroyContext(self.gl);
        c.SDL_DestroyWindow(self.window);
        c.SDL_Quit();
        self.a.destroy(self);
    }

    /// Where bundled assets (fonts, icon) live: ./assets, the .app Resources dir,
    /// or the repo's assets dir relative to zig-out/bin.
    fn assetDirs(bufs: *[3][1024]u8, out: *[3][]const u8) usize {
        const base: []const u8 = if (c.SDL_GetBasePath()) |p| std.mem.span(p) else "";
        const rels = [_][]const u8{ "", "../Resources/", "../../assets/" };
        var n: usize = 0;
        out[n] = "assets/";
        n += 1;
        for (rels[1..]) |rel| {
            out[n] = std.fmt.bufPrint(&bufs[n], "{s}{s}", .{ base, rel }) catch continue;
            n += 1;
        }
        return n;
    }

    /// Window dragging / resizing for the borderless window (SDL calls this on hit).
    fn windowHitTest(win: ?*c.SDL_Window, area: [*c]const c.SDL_Point, data: ?*anyopaque) callconv(.C) c.SDL_HitTestResult {
        _ = win;
        const self: *App = @ptrCast(@alignCast(data orelse return c.SDL_HITTEST_NORMAL));
        const x: f32 = @floatFromInt(area.*.x);
        const y: f32 = @floatFromInt(area.*.y);
        const e: f32 = 5;
        const maximized = (c.SDL_GetWindowFlags(self.window) & c.SDL_WINDOW_MAXIMIZED) != 0;
        if (!maximized) {
            const left = x < e;
            const right = x > self.win_w - e;
            const top = y < e;
            const bottom = y > self.win_h - e;
            if (top and left) return c.SDL_HITTEST_RESIZE_TOPLEFT;
            if (top and right) return c.SDL_HITTEST_RESIZE_TOPRIGHT;
            if (bottom and left) return c.SDL_HITTEST_RESIZE_BOTTOMLEFT;
            if (bottom and right) return c.SDL_HITTEST_RESIZE_BOTTOMRIGHT;
            if (top) return c.SDL_HITTEST_RESIZE_TOP;
            if (bottom) return c.SDL_HITTEST_RESIZE_BOTTOM;
            if (left) return c.SDL_HITTEST_RESIZE_LEFT;
            if (right) return c.SDL_HITTEST_RESIZE_RIGHT;
        }
        return if (ui.hitTest(self.geo(), x, y) == .titlebar) c.SDL_HITTEST_DRAGGABLE else c.SDL_HITTEST_NORMAL;
    }

    fn toggleMaximize(self: *App) void {
        if ((c.SDL_GetWindowFlags(self.window) & c.SDL_WINDOW_MAXIMIZED) != 0) {
            _ = c.SDL_RestoreWindow(self.window);
        } else {
            _ = c.SDL_MaximizeWindow(self.window);
        }
    }

    fn setIcon(window: *c.SDL_Window) void {
        var buf: [1024]u8 = undefined;
        const base: []const u8 = if (c.SDL_GetBasePath()) |p| std.mem.span(p) else "";
        const rels = [_][]const u8{
            "assets/AppIcon.png", "../../assets/AppIcon.png", "../Resources/AppIcon.png",
            "assets/icon.png",    "../../assets/icon.png",
        };
        // try cwd first, then relative to the executable (zig-out/bin)
        for ([_][]const u8{ "", base }) |prefix| {
            for (rels) |rel| {
                const path = std.fmt.bufPrintZ(&buf, "{s}{s}", .{ prefix, rel }) catch continue;
                if (c.SDL_LoadPNG(path.ptr)) |surface| {
                    _ = c.SDL_SetWindowIcon(window, surface);
                    c.SDL_DestroySurface(surface);
                    return;
                }
            }
        }
    }

    const Size = struct { pw: i32, ph: i32, w: f32, h: f32, scale: f32 };

    fn querySize(self: *App) Size {
        var w: c_int = 0;
        var h: c_int = 0;
        var pw: c_int = 0;
        var ph: c_int = 0;
        _ = c.SDL_GetWindowSize(self.window, &w, &h);
        _ = c.SDL_GetWindowSizeInPixels(self.window, &pw, &ph);
        self.win_w = @floatFromInt(@max(w, 1));
        self.win_h = @floatFromInt(@max(h, 1));
        const scale = @as(f32, @floatFromInt(@max(pw, 1))) / self.win_w;
        return .{ .pw = pw, .ph = ph, .w = self.win_w, .h = self.win_h, .scale = scale };
    }

    fn tab(self: *App) *Tab {
        return self.tabs.items[self.active];
    }

    fn chromeH(self: *const App) f32 {
        return ui.chromeH(self.tabs.items.len);
    }

    fn viewH(self: *const App) f32 {
        return self.win_h - self.chromeH();
    }

    fn geo(self: *const App) ui.Geo {
        return .{ .w = self.win_w, .ntabs = self.tabs.items.len };
    }

    // ------------------------------------------------------------------
    // Tabs & navigation
    // ------------------------------------------------------------------

    fn openTab(self: *App, url: []const u8, focus: bool) !*Tab {
        const t = try self.a.create(Tab);
        errdefer self.a.destroy(t);
        t.* = try Tab.init(self.a, self.next_tab_id);
        self.next_tab_id += 1;
        try self.tabs.append(self.a, t);
        if (focus) self.activate(self.tabs.items.len - 1);
        try t.navigate(url, true, onLoadComplete);
        self.dirty = true;
        return t;
    }

    pub fn openBackgroundTab(self: *App, url: []const u8) !void {
        _ = try self.openTab(url, false);
    }

    /// Debug aid for screenshots: scroll the active tab once its page is laid out.
    pub fn debugScroll(self: *App, px: f32) void {
        self.pending_debug_scroll = px;
    }

    // ------------------------------------------------------------------
    // Theme & settings
    // ------------------------------------------------------------------

    fn isDark(self: *const App) bool {
        return switch (self.settings.theme) {
            .light => false,
            .dark => true,
            .system => c.SDL_GetSystemTheme() == c.SDL_SYSTEM_THEME_DARK,
        };
    }

    /// Recompute the palette from settings + system appearance. With `reload_pages`,
    /// built-in about: pages are re-rendered so they pick up the new colours.
    fn applyTheme(self: *App, reload_pages: bool) void {
        const dark = self.isDark();
        const sc = self.settings.scheme(dark);
        const accent = self.settings.accentColor(dark);
        const p = ui.Palette.from(sc, accent);
        const changed = !std.meta.eql(p, ui.pal);
        ui.pal = p;
        pages.setTheme(.{
            .dark = dark,
            .prefs = self.settings,
            .colors = .{ .bg = sc.surface, .card = sc.bg, .text = sc.fg, .muted = sc.muted, .brand = accent, .link = sc.link },
        });
        self.dirty = true;
        if (reload_pages and changed) {
            for (self.tabs.items) |t| {
                if (std.mem.startsWith(u8, t.url, "about:")) t.reload(onLoadComplete) catch {};
            }
        }
    }

    fn cycleTheme(self: *App) void {
        self.settings.theme = self.settings.theme.next();
        self.settings.save();
        self.applyTheme(true);
        // about:settings shows the selected mode; refresh it even if colours didn't change
        for (self.tabs.items) |t| {
            if (std.mem.startsWith(u8, t.url, "about:settings")) t.reload(onLoadComplete) catch {};
        }
    }

    /// `about:settings?key=value` links change preferences (pages have no JS).
    fn handleSettingsUrl(self: *App, url: []const u8) bool {
        const prefix = "about:settings?";
        if (!std.mem.startsWith(u8, url, prefix)) return false;
        if (std.mem.eql(u8, url[prefix.len..], "wallpaper=choose")) {
            self.chooseWallpaper();
            return true;
        }
        const old_wallpaper = self.settings.wallpaper;
        if (self.settings.applyQuery(url[prefix.len..])) {
            if (self.settings.wallpaper != old_wallpaper) self.loadWallpaper();
            self.settings.save();
            self.applyTheme(true);
        }
        const t = self.tab();
        const on_settings = std.mem.startsWith(u8, t.url, "about:settings");
        t.navigate("about:settings", !on_settings, onLoadComplete) catch {};
        self.blurAddressBar();
        return true;
    }

    fn closeTab(self: *App, i: usize) void {
        if (self.tabs.items.len == 1) {
            // Closing the last tab resets it to a fresh home page rather than quitting.
            const t = self.tabs.items[0];
            t.navigate(home_url, true, onLoadComplete) catch {};
            self.focusHome();
            return;
        }
        const t = self.tabs.orderedRemove(i);
        t.deinit();
        self.a.destroy(t);
        if (self.active >= self.tabs.items.len) self.active = self.tabs.items.len - 1 else if (i < self.active) self.active -= 1;
        self.activate(self.active);
    }

    fn activate(self: *App, i: usize) void {
        self.active = i;
        self.blurAddressBar();
        self.updateTitle();
        self.dirty = true;
    }

    fn navigate(self: *App, url: []const u8) void {
        if (self.handleSettingsUrl(url)) return;
        self.tab().navigate(url, true, onLoadComplete) catch |err| std.log.err("navigate: {}", .{err});
        self.blurAddressBar();
        self.dirty = true;
    }

    fn followLink(self: *App, href: []const u8, new_tab: bool) void {
        const t = self.tab();
        if (std.ascii.startsWithIgnoreCase(std.mem.trim(u8, href, " "), "javascript:")) return;
        const resolved = urlz.resolve(self.a, if (t.base_url.len > 0) t.base_url else t.url, href) catch return;
        defer self.a.free(resolved);
        if (new_tab and !std.mem.startsWith(u8, resolved, "about:settings?")) {
            _ = self.openTab(resolved, false) catch {};
        } else {
            self.navigate(resolved);
        }
    }

    fn openSettings(self: *App) void {
        for (self.tabs.items, 0..) |t, i| {
            if (std.mem.startsWith(u8, t.url, "about:settings")) return self.activate(i);
        }
        _ = self.openTab("about:settings", true) catch {};
    }

    fn updateTitle(self: *App) void {
        var buf: [512]u8 = undefined;
        const t = self.tab();
        const title = std.fmt.bufPrintZ(&buf, "{s} — Red Browser", .{t.title[0..@min(t.title.len, 400)]}) catch "Red Browser";
        _ = c.SDL_SetWindowTitle(self.window, title.ptr);
    }

    fn anyLoading(self: *const App) bool {
        for (self.tabs.items) |t| {
            if (t.loading) return true;
        }
        return false;
    }

    // ------------------------------------------------------------------
    // Address bar
    // ------------------------------------------------------------------

    fn isHome(t: *const Tab) bool {
        return t.url.len == 0 or std.mem.startsWith(u8, t.url, "about:home") or std.mem.startsWith(u8, t.url, "about:newtab");
    }

    fn startTextInput(self: *App) void {
        if (!self.bar.focused and !self.home_bar.focused) _ = c.SDL_StartTextInput(self.window);
    }

    fn focusHome(self: *App) void {
        if (self.bar.focused) self.blurAddressBar();
        self.home_bar.set(self.a, "") catch {};
        self.startTextInput();
        self.home_bar.focused = true;
        self.dirty = true;
    }

    fn blurHome(self: *App) void {
        if (self.home_bar.focused and !self.bar.focused) _ = c.SDL_StopTextInput(self.window);
        self.home_bar.focused = false;
        self.selecting_home = false;
        self.dirty = true;
    }

    /// The text field that currently has keyboard focus, if any.
    fn focusedField(self: *App) ?*ui.AddressBar {
        if (self.bar.focused) return &self.bar;
        if (self.home_bar.focused) return &self.home_bar;
        return null;
    }

    fn focusAddressBar(self: *App) void {
        if (self.home_bar.focused) self.blurHome();
        const t = self.tab();
        const shown = if (std.mem.startsWith(u8, t.url, "about:home")) "" else t.url;
        self.bar.set(self.a, shown) catch {};
        self.bar.selectAll();
        self.startTextInput();
        self.bar.focused = true;
        self.dirty = true;
    }

    fn blurAddressBar(self: *App) void {
        if (self.bar.focused and !self.home_bar.focused) _ = c.SDL_StopTextInput(self.window);
        self.bar.focused = false;
        self.selecting_url = false;
        self.dirty = true;
    }

    fn submitField(self: *App, field: *ui.AddressBar) void {
        if (std.mem.trim(u8, field.text(), " ").len == 0) return;
        const url = urlz.fromInput(self.a, field.text()) catch return;
        defer self.a.free(url);
        self.blurHome();
        self.navigate(url);
    }

    // ------------------------------------------------------------------
    // Wallpaper
    // ------------------------------------------------------------------

    fn loadWallpaper(self: *App) void {
        if (self.wallpaper) |img| self.g.freeImage(img);
        self.wallpaper = null;
        if (self.settings.wallpaper != .custom) return;
        var buf: [1024]u8 = undefined;
        const path = Settings.wallpaperPath(&buf) orelse return;
        self.wallpaper = self.g.loadImage(path);
        if (self.wallpaper == null) std.log.warn("could not load wallpaper {s}", .{path});
        self.dirty = true;
    }

    /// Copy the image into the profile and use it as the new-tab wallpaper.
    fn setWallpaperFrom(self: *App, src: []const u8) void {
        var buf: [1024]u8 = undefined;
        const dst = Settings.wallpaperPath(&buf) orelse return;
        std.fs.cwd().copyFile(src, std.fs.cwd(), dst, .{}) catch |err| {
            std.log.err("wallpaper copy failed: {}", .{err});
            return;
        };
        self.settings.wallpaper = .custom;
        self.settings.save();
        self.loadWallpaper();
        if (self.wallpaper == null) {
            // not a decodable image: fall back
            self.settings.wallpaper = .gradient;
            self.settings.save();
        }
        self.applyTheme(false);
        for (self.tabs.items) |t| {
            if (std.mem.startsWith(u8, t.url, "about:settings")) t.reload(onLoadComplete) catch {};
        }
    }

    fn chooseWallpaper(self: *App) void {
        const filters = [_]c.SDL_DialogFileFilter{.{ .name = "Images", .pattern = "png;jpg;jpeg;webp;gif;bmp" }};
        c.SDL_ShowOpenFileDialog(onWallpaperChosen, null, self.window, &filters, filters.len, null, false);
    }

    // ------------------------------------------------------------------
    // Event loop
    // ------------------------------------------------------------------

    pub fn run(self: *App) !void {
        while (self.running) {
            const loading = self.anyLoading();
            const timeout: i32 = if (self.anim.animating) 1 else if (loading or self.bar.focused or self.home_bar.focused) 33 else 1000;
            var ev: c.SDL_Event = undefined;
            if (c.SDL_WaitEventTimeout(&ev, timeout)) {
                self.handle(&ev);
                while (c.SDL_PollEvent(&ev)) self.handle(&ev);
            }
            if (loading or self.bar.focused or self.home_bar.focused or self.anim.animating) self.dirty = true;
            if (self.dirty) {
                self.draw();
                self.dirty = false;
                if (self.opts.screenshot_path) |p| {
                    if (!self.anyLoading() and !self.anim.animating) {
                        self.frames_since_idle += 1;
                        if (self.frames_since_idle >= 2) {
                            self.saveScreenshot(p);
                            self.running = false;
                        } else self.dirty = true;
                    }
                }
            }
        }
    }

    fn primaryMod(mod: u16) bool {
        return if (builtin.os.tag == .macos) (mod & c.SDL_KMOD_GUI) != 0 else (mod & c.SDL_KMOD_CTRL) != 0;
    }

    fn handle(self: *App, ev: *const c.SDL_Event) void {
        switch (ev.type) {
            c.SDL_EVENT_QUIT => self.running = false,
            c.SDL_EVENT_WINDOW_RESIZED, c.SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED, c.SDL_EVENT_WINDOW_DISPLAY_SCALE_CHANGED => {
                const s = self.querySize();
                self.g.resize(s.pw, s.ph, s.scale);
                self.dirty = true;
            },
            c.SDL_EVENT_WINDOW_EXPOSED, c.SDL_EVENT_WINDOW_FOCUS_GAINED, c.SDL_EVENT_WINDOW_FOCUS_LOST, c.SDL_EVENT_WINDOW_MAXIMIZED, c.SDL_EVENT_WINDOW_RESTORED => self.dirty = true,
            c.SDL_EVENT_SYSTEM_THEME_CHANGED => if (self.settings.theme == .system) self.applyTheme(true),
            c.SDL_EVENT_MOUSE_MOTION => self.onMouseMove(ev.motion.x, ev.motion.y),
            c.SDL_EVENT_MOUSE_BUTTON_DOWN => self.onMouseDown(ev.button.x, ev.button.y, ev.button.button, ev.button.clicks),
            c.SDL_EVENT_MOUSE_BUTTON_UP => self.onMouseUp(ev.button.x, ev.button.y, ev.button.button),
            c.SDL_EVENT_MOUSE_WHEEL => {
                self.tab().scrollBy(-ev.wheel.y * 48, self.viewH());
                self.dirty = true;
            },
            c.SDL_EVENT_WINDOW_MOUSE_LEAVE => {
                self.hover = .none;
                self.setHoverLink(null);
                self.dirty = true;
            },
            c.SDL_EVENT_TEXT_INPUT => {
                if (self.focusedField()) |f| {
                    f.insert(self.a, std.mem.span(ev.text.text)) catch {};
                    self.dirty = true;
                }
            },
            c.SDL_EVENT_KEY_DOWN => self.onKey(ev.key.key, ev.key.mod),
            c.SDL_EVENT_DROP_FILE => if (ev.drop.data) |p| self.setWallpaperFrom(std.mem.span(p)),
            else => {
                if (ev.type == wallpaper_event_type) {
                    const p: [*:0]u8 = @ptrCast(ev.user.data1 orelse return);
                    defer c.SDL_free(p);
                    self.setWallpaperFrom(std.mem.span(p));
                    return;
                }
                if (ev.type == load_event_type) {
                    const res: *net.Result = @ptrCast(@alignCast(ev.user.data1));
                    defer res.deinit();
                    for (self.tabs.items) |t| {
                        if (t.id != res.tab_id) continue;
                        const applied = t.finishLoad(res) catch |err| blk: {
                            std.log.err("load failed: {}", .{err});
                            t.loading = false;
                            break :blk false;
                        };
                        if (applied and t == self.tab()) self.updateTitle();
                    }
                    self.dirty = true;
                }
            },
        }
    }

    fn setHoverLink(self: *App, href: ?[]const u8) void {
        if (self.hover_link) |old| {
            if (href) |h| {
                if (std.mem.eql(u8, old, h)) return;
            }
            self.a.free(old);
            self.hover_link = null;
        }
        if (href) |h| {
            const t = self.tab();
            self.hover_link = urlz.resolve(self.a, if (t.base_url.len > 0) t.base_url else t.url, h) catch null;
        }
        self.dirty = true;
    }

    fn linkUnder(self: *App, x: f32, y: f32) ?[]const u8 {
        const top = self.chromeH();
        if (y < top) return null;
        const t = self.tab();
        const page = t.page orelse return null;
        return page.linkAt(x, y - top + t.view_scroll);
    }

    fn onMouseMove(self: *App, x: f32, y: f32) void {
        self.mouse_x = x;
        self.mouse_y = y;
        const hit = ui.hitTest(self.geo(), x, y);
        if (!std.meta.eql(hit, self.hover)) {
            self.hover = hit;
            self.dirty = true;
        }
        if (self.selecting_url) {
            self.bar.clickAt(&self.g, ui.font_size, self.geo().textX(), x, true);
            self.dirty = true;
        }
        if (self.selecting_home) {
            self.home_bar.clickAt(&self.g, ui.home_font, ui.homeTextX(self.win_w, self.win_h), x, true);
            self.dirty = true;
        }
        const over_home = self.overHomeSearch(x, y);
        if (over_home != self.hover_home) {
            self.hover_home = over_home;
            self.dirty = true;
        }
        const link = self.linkUnder(x, y);
        self.setHoverLink(link);
        const cursor = if (link != null) self.cursor_pointer else if (hit == .url_bar or over_home) self.cursor_text else self.cursor_default;
        if (cursor != self.current_cursor) {
            if (cursor) |cur| _ = c.SDL_SetCursor(cur);
            self.current_cursor = cursor;
        }
    }

    fn overHomeSearch(self: *App, x: f32, y: f32) bool {
        return isHome(self.tab()) and ui.homeSearchRect(self.win_w, self.win_h).contains(x, y);
    }

    fn onMouseDown(self: *App, x: f32, y: f32, button: u8, clicks: u8) void {
        const hit = ui.hitTest(self.geo(), x, y);
        self.pressed = hit;
        self.dirty = true;
        if (button == c.SDL_BUTTON_MIDDLE) {
            switch (hit) {
                .tab, .tab_close => |i| self.closeTab(i),
                .content => if (self.linkUnder(x, y)) |h| self.followLink(h, true),
                else => {},
            }
            return;
        }
        if (button != c.SDL_BUTTON_LEFT) return;
        switch (hit) {
            .url_bar => {
                if (!self.bar.focused) {
                    self.focusAddressBar();
                } else if (clicks >= 2) {
                    self.bar.selectAll();
                } else {
                    const mod = c.SDL_GetModState();
                    self.bar.clickAt(&self.g, ui.font_size, self.geo().textX(), x, (mod & c.SDL_KMOD_SHIFT) != 0);
                    self.selecting_url = true;
                }
            },
            .tab => |i| self.activate(i),
            .titlebar => if (clicks >= 2) self.toggleMaximize(),
            .content => {
                self.blurAddressBar();
                if (self.overHomeSearch(x, y)) {
                    if (!self.home_bar.focused) self.focusHome();
                    if (clicks >= 2) {
                        self.home_bar.selectAll();
                    } else {
                        self.home_bar.clickAt(&self.g, ui.home_font, ui.homeTextX(self.win_w, self.win_h), x, (c.SDL_GetModState() & c.SDL_KMOD_SHIFT) != 0);
                        self.selecting_home = true;
                    }
                } else self.blurHome();
            },
            .none => {
                self.blurAddressBar();
                self.blurHome();
            },
            else => {},
        }
    }

    fn onMouseUp(self: *App, x: f32, y: f32, button: u8) void {
        self.selecting_url = false;
        self.selecting_home = false;
        const hit = ui.hitTest(self.geo(), x, y);
        const pressed = self.pressed;
        self.pressed = .none;
        self.dirty = true;
        if (button != c.SDL_BUTTON_LEFT or !std.meta.eql(hit, pressed)) return;
        const t = self.tab();
        switch (hit) {
            .tab_close => |i| self.closeTab(i),
            .new_tab => {
                _ = self.openTab(home_url, true) catch {};
                self.focusHome();
            },
            .back => t.back(onLoadComplete) catch {},
            .forward => t.forward(onLoadComplete) catch {},
            .reload => if (t.loading) t.stop() else t.reload(onLoadComplete) catch {},
            .menu => self.openSettings(),
            .win_min => _ = c.SDL_MinimizeWindow(self.window),
            .win_max => self.toggleMaximize(),
            .win_close => self.running = false,
            .theme => self.cycleTheme(),
            .content => if (self.linkUnder(x, y)) |h| {
                const mod = c.SDL_GetModState();
                self.followLink(h, primaryMod(mod));
            },
            else => {},
        }
    }

    fn onKey(self: *App, key: u32, mod: u16) void {
        const primary = primaryMod(mod);
        const shift = (mod & c.SDL_KMOD_SHIFT) != 0;
        const alt = (mod & c.SDL_KMOD_ALT) != 0;
        const ctrl = (mod & c.SDL_KMOD_CTRL) != 0;
        const t = self.tab();
        self.dirty = true;

        // Global shortcuts
        if (primary) {
            switch (key) {
                c.SDLK_T => {
                    _ = self.openTab(home_url, true) catch {};
                    self.focusHome();
                    return;
                },
                c.SDLK_W => return self.closeTab(self.active),
                c.SDLK_L => return self.focusAddressBar(),
                c.SDLK_R => return t.reload(onLoadComplete) catch {},
                c.SDLK_H => if (shift) return self.navigate(home_url),
                c.SDLK_COMMA => return self.openSettings(),
                c.SDLK_Q => {
                    self.running = false;
                    return;
                },
                c.SDLK_LEFTBRACKET => return t.back(onLoadComplete) catch {},
                c.SDLK_RIGHTBRACKET => return t.forward(onLoadComplete) catch {},
                c.SDLK_1...c.SDLK_9 => {
                    const n = key - c.SDLK_1;
                    const idx = if (key == c.SDLK_9) self.tabs.items.len - 1 else @min(n, self.tabs.items.len - 1);
                    return self.activate(idx);
                },
                else => {},
            }
        }
        if (ctrl and key == c.SDLK_TAB) {
            const n = self.tabs.items.len;
            return self.activate(if (shift) (self.active + n - 1) % n else (self.active + 1) % n);
        }

        if (self.focusedField()) |f| return self.onFieldKey(f, key, primary, shift, alt);

        // Page navigation keys
        const vh = self.viewH();
        switch (key) {
            c.SDLK_DOWN => t.scrollBy(48, vh),
            c.SDLK_UP => t.scrollBy(-48, vh),
            c.SDLK_PAGEDOWN => t.scrollBy(vh - 48, vh),
            c.SDLK_PAGEUP => t.scrollBy(-(vh - 48), vh),
            c.SDLK_SPACE => t.scrollBy(if (shift) -(vh - 48) else vh - 48, vh),
            c.SDLK_HOME => t.scrollBy(-std.math.floatMax(f32) / 2, vh),
            c.SDLK_END => t.scrollBy(std.math.floatMax(f32) / 2, vh),
            c.SDLK_BACKSPACE => t.back(onLoadComplete) catch {},
            c.SDLK_LEFT => if (alt or primary) t.back(onLoadComplete) catch {},
            c.SDLK_RIGHT => if (alt or primary) t.forward(onLoadComplete) catch {},
            c.SDLK_F5 => t.reload(onLoadComplete) catch {},
            c.SDLK_ESCAPE => if (t.loading) t.stop(),
            else => {},
        }
    }

    fn onFieldKey(self: *App, bar: *ui.AddressBar, key: u32, primary: bool, shift: bool, alt: bool) void {
        const word = if (builtin.os.tag == .macos) alt else primary;
        switch (key) {
            c.SDLK_RETURN, c.SDLK_KP_ENTER => self.submitField(bar),
            c.SDLK_ESCAPE => if (bar == &self.bar) self.blurAddressBar() else self.blurHome(),
            c.SDLK_BACKSPACE => bar.backspace(word),
            c.SDLK_DELETE => bar.deleteForward(),
            c.SDLK_LEFT => bar.move(if (primary and builtin.os.tag == .macos) .home else if (word) .word_left else .left, shift),
            c.SDLK_RIGHT => bar.move(if (primary and builtin.os.tag == .macos) .end else if (word) .word_right else .right, shift),
            c.SDLK_HOME, c.SDLK_UP => bar.move(.home, shift),
            c.SDLK_END, c.SDLK_DOWN => bar.move(.end, shift),
            c.SDLK_A => if (primary) bar.selectAll(),
            c.SDLK_C, c.SDLK_X => if (primary) {
                const sel = bar.selection();
                if (sel.len > 0) {
                    const z = self.a.dupeZ(u8, sel) catch return;
                    defer self.a.free(z);
                    _ = c.SDL_SetClipboardText(z.ptr);
                    if (key == c.SDLK_X) _ = bar.deleteSelection();
                }
            },
            c.SDLK_V => if (primary) {
                if (c.SDL_GetClipboardText()) |txt| {
                    defer c.SDL_free(txt);
                    bar.insert(self.a, std.mem.span(txt)) catch {};
                }
            },
            else => {},
        }
    }

    // ------------------------------------------------------------------
    // Drawing
    // ------------------------------------------------------------------

    fn draw(self: *App) void {
        self.render();
        _ = c.SDL_GL_SwapWindow(self.window);
    }

    /// Build and render a frame into the back buffer (no present).
    fn render(self: *App) void {
        const g = &self.g;
        const t = self.tab();
        const now = std.time.milliTimestamp();
        const dt: f32 = if (self.last_frame_ms == 0) 1.0 / 60.0 else @as(f32, @floatFromInt(now - self.last_frame_ms)) / 1000.0;
        self.last_frame_ms = now;
        const an = &self.anim;
        an.begin(dt);
        defer an.end();

        t.ensureLayout(g, self.win_w) catch |err| std.log.err("layout failed: {}", .{err});
        const top = self.chromeH();
        if (self.pending_debug_scroll) |px| {
            if (t.page != null and !t.loading) {
                t.scroll = px;
                t.view_scroll = @min(px, t.maxScroll(self.viewH()));
                self.pending_debug_scroll = null;
            }
        }
        t.scroll = std.math.clamp(t.scroll, 0, t.maxScroll(self.viewH()));
        // smooth scrolling: ease the visible offset towards the target
        t.view_scroll = an.get(ui.key(10, t.id), t.scroll, 22, t.scroll);

        const layout_geo = self.geo();

        const maximized = (c.SDL_GetWindowFlags(self.window) & c.SDL_WINDOW_MAXIMIZED) != 0;
        const home = isHome(t);

        g.begin();
        // Rounded window: everything is clipped to a rounded rect on a transparent surface.
        if (!maximized) g.pushClip(0, 0, self.win_w, self.win_h, ui.window_radius);
        if (home) {
            const wp: ui.Wallpaper = switch (self.settings.wallpaper) {
                .none => .none,
                .gradient => .gradient,
                .custom => if (self.wallpaper) |img| .{ .image = img } else .gradient,
            };
            ui.drawHomeBackground(g, wp, self.win_w, self.win_h);
            ui.drawHome(g, an, wp, &self.home_bar, self.hover_home, self.win_w, self.win_h, now);
        } else if (t.page) |*p| {
            // Page fills the whole window and scrolls *under* the chrome.
            g.rect(0, 0, self.win_w, self.win_h, p.background);
            p.paint(g, 0, top - t.view_scroll, self.win_h, t.view_scroll - top);
        } else {
            g.rect(0, 0, self.win_w, self.win_h, ui.pal.page_bg);
        }
        if (!home) if (t.page) |p| ui.drawScrollbar(g, an, self.win_w, self.win_h, top, t.view_scroll, p.height, self.mouse_x > self.win_w - 16 and self.mouse_y > top);

        ui.drawChrome(g, an, .{
            .geo = layout_geo,
            .win_h = self.win_h,
            .tabs = self.tabs.items,
            .active = self.active,
            .bar = &self.bar,
            .hover = self.hover,
            .pressed = self.pressed,
            .now_ms = now,
            .theme_mode = self.settings.theme,
            .maximized = maximized,
            .focused_window = (c.SDL_GetWindowFlags(self.window) & c.SDL_WINDOW_INPUT_FOCUS) != 0,
        });
        ui.drawStatus(g, an, self.win_w, self.win_h, self.hover_link orelse "");
        if (!maximized) {
            g.popClip();
            ui.drawWindowFrame(g, self.win_w, self.win_h);
        }
        g.end();
    }

    fn saveScreenshot(self: *App, path: [:0]const u8) void {
        // Re-render into the back buffer and read it before swapping.
        self.render();
        var pw: c_int = 0;
        var ph: c_int = 0;
        _ = c.SDL_GetWindowSizeInPixels(self.window, &pw, &ph);
        const ReadPixels = *const fn (x: c_int, y: c_int, w: c_int, h: c_int, format: u32, ty: u32, data: ?*anyopaque) callconv(.C) void;
        const read: ReadPixels = @ptrCast(c.SDL_GL_GetProcAddress("glReadPixels") orelse return);
        const surface = c.SDL_CreateSurface(pw, ph, c.SDL_PIXELFORMAT_ABGR8888) orelse return;
        defer c.SDL_DestroySurface(surface);
        const stride: usize = @intCast(surface.*.pitch);
        const rows: usize = @intCast(ph);
        const tmp = self.a.alloc(u8, stride * rows) catch return;
        defer self.a.free(tmp);
        read(0, 0, pw, ph, 0x1908, 0x1401, tmp.ptr); // GL_RGBA, GL_UNSIGNED_BYTE
        const dst: [*]u8 = @ptrCast(surface.*.pixels.?);
        for (0..rows) |r| {
            @memcpy(dst[r * stride ..][0..stride], tmp[(rows - 1 - r) * stride ..][0..stride]);
        }
        if (c.SDL_SavePNG(surface, path.ptr)) {
            std.log.info("saved screenshot to {s}", .{path});
        } else {
            std.log.err("SDL_SavePNG: {s}", .{c.SDL_GetError()});
        }
    }
};

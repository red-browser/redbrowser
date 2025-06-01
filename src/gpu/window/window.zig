const std = @import("std");
const glfw = @import("glfw");
const Allocator = std.mem.Allocator;

pub const Window = struct {
    handle: *glfw.Window,
    allocator: Allocator,

    pub const Options = struct {
        title: [:0]const u8 = "Red Browser",
        width: u32 = 1280,
        height: u32 = 720,
    };

    pub fn init(allocator: Allocator, options: Options) !Window {
        try glfw.init();
        errdefer glfw.terminate();

        glfw.windowHint(glfw.ClientAPI, glfw.OpenGLAPI);
        glfw.windowHint(glfw.ContextVersionMajor, 4);
        glfw.windowHint(glfw.ContextVersionMinor, 6);
        glfw.windowHint(glfw.OpenGLProfile, glfw.OpenGLCoreProfile);
        glfw.windowHint(glfw.OpenGLForwardCompat, 1);

        const handle = try glfw.createWindow(@intCast(options.width), @intCast(options.height), options.title, null, null);

        return Window{
            .handle = handle,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Window) void {
        glfw.destroyWindow(self.handle);
        glfw.terminate();
    }

    pub fn shouldClose(self: *Window) bool {
        return glfw.windowShouldClose(self.handle);
    }

    pub fn pollEvents(_: *Window) void {
        glfw.pollEvents();
    }

    pub fn getFramebufferSize(self: *Window) [2]u32 {
        var width: i32 = 0;
        var height: i32 = 0;
        glfw.getFramebufferSize(self.handle, &width, &height);
        return [2]u32{ @intCast(width), @intCast(height) };
    }

    pub fn swapBuffers(self: *Window) void {
        glfw.swapBuffers(self.handle);
    }
};

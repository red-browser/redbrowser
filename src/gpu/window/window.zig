const std = @import("std");
const glfw = @import("glfw");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.Window);

fn glfwErrorCallback(error_code: i32, description: [*:0]const u8) callconv(.C) void {
    const description_slice = std.mem.span(description);
    std.debug.print("GLFW Error {d}: {s}\n", .{ error_code, description_slice });
}

pub const Window = struct {
    handle: *glfw.Window,
    allocator: Allocator,

    pub const Options = struct {
        title: [:0]const u8 = "Red Browser",
        width: u32 = 1280,
        height: u32 = 720,
    };

    pub fn init(allocator: Allocator, options: Options) !Window {
        log.debug("Initializing GLFW (starting glfw.init call)...", .{});
        _ = glfw.setErrorCallback(glfwErrorCallback);

        try glfw.init();
        log.debug("Initializing GLFW (glfw.init call returned successfully).", .{});

        errdefer glfw.terminate();
        log.debug("GLFW initialized successfully. Setting window hints...", .{});

        glfw.windowHint(glfw.ClientAPI, glfw.OpenGLAPI);
        log.debug("Set ClientAPI hint.", .{});

        glfw.windowHint(glfw.ContextVersionMajor, 4);
        log.debug("Set ContextVersionMajor hint.", .{});

        glfw.windowHint(glfw.ContextVersionMinor, 6);
        log.debug("Set ContextVersionMinor hint.", .{});

        glfw.windowHint(glfw.OpenGLProfile, glfw.OpenGLCoreProfile);
        log.debug("Set OpenGLProfile hint.", .{});

        glfw.windowHint(glfw.OpenGLForwardCompat, 1);
        log.debug("Set OpenGLForwardCompat hint.", .{});

        log.debug("All window hints set. Creating window: '{s}' ({d}x{d})...", .{ options.title, options.width, options.height });
        const handle = try glfw.createWindow(@intCast(options.width), @intCast(options.height), options.title, null, null);
        glfw.makeContextCurrent(handle);
        log.debug("OpenGL context made current.", .{});

        log.debug("Window initialized successfully.", .{});
        return Window{
            .handle = handle,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Window) void {
        log.debug("Destroying window...", .{});
        glfw.destroyWindow(self.handle);
        log.debug("Terminating GLFW...", .{});
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

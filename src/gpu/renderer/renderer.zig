const std = @import("std");
const glfw = @import("glfw");
const gl = @import("zgl");
const Window = @import("window").Window;

const log = std.log.scoped(.Renderer);

pub const Renderer = struct {
    allocator: std.mem.Allocator,
    window: *Window,

    pub fn init(allocator: std.mem.Allocator, window: *Window) !Renderer {
        log.debug("Initializing renderer...", .{});

        gl.loadCoreProfile(getGlfwProcAddressCastingWrapper);

        log.debug("Renderer initialized successfully.", .{});

        gl.ClearColor(0.2, 0.3, 0.3, 1.0);
        gl.Clear(gl.binding.COLOR_BUFFER_BIT);

        // Other rendering setup, like VAOs, VBOs, shaders, etc.

        return Renderer{
            .allocator = allocator,
            .window = window,
        };
    }

    pub fn deinit(self: *Renderer) void {
        log.debug("Deinitializing renderer...", .{});
        _ = self;
    }

    pub fn beginFrame(self: *Renderer) !void {
        gl.ClearColor(0.2, 0.3, 0.3, 1.0);
        gl.Clear(gl.binding.COLOR_BUFFER_BIT);
        _ = self;
    }

    pub fn endFrame(self: *Renderer) !void {
        self.window.swapBuffers();
    }
};

fn getGlfwProcAddressCastingWrapper(procname: [*:0]const u8) ?gl.binding.FunctionPointer {
    const proc_addr_specific = glfw.getProcAddress(procname);
    return @as(?gl.binding.FunctionPointer, @ptrCast(proc_addr_specific));
}

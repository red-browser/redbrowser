const std = @import("std");
const c = @cImport({
    @cInclude("SDL3/SDL.h");
});

pub const Window = struct {
    window: *c.SDL_Window,
    gl_context: c.SDL_GLContext,
    width: i32,
    height: i32,
    title: []const u8,
    should_close: bool,
    allocator: std.mem.Allocator,

    pub const Options = struct {
        title: [:0]const u8 = "Red Browser",
        width: u32 = 1280,
        height: u32 = 720,
    };

    pub fn init(allocator: std.mem.Allocator, options: Options) !Window {
        if (!c.SDL_Init(c.SDL_INIT_VIDEO)) {
            return error.SDLInitFailed;
        }

        // Set OpenGL attributes for Piston compatibility
        _ = c.SDL_GL_SetAttribute(c.SDL_GL_CONTEXT_MAJOR_VERSION, 3);
        _ = c.SDL_GL_SetAttribute(c.SDL_GL_CONTEXT_MINOR_VERSION, 3);
        _ = c.SDL_GL_SetAttribute(c.SDL_GL_CONTEXT_PROFILE_MASK, c.SDL_GL_CONTEXT_PROFILE_CORE);
        _ = c.SDL_GL_SetAttribute(c.SDL_GL_DOUBLEBUFFER, 1);
        _ = c.SDL_GL_SetAttribute(c.SDL_GL_DEPTH_SIZE, 24);
        _ = c.SDL_GL_SetAttribute(c.SDL_GL_STENCIL_SIZE, 8);

        const window = c.SDL_CreateWindow(options.title.ptr, @intCast(options.width), @intCast(options.height), c.SDL_WINDOW_OPENGL | c.SDL_WINDOW_RESIZABLE) orelse return error.WindowCreationFailed;

        const gl_context = c.SDL_GL_CreateContext(window) orelse {
            c.SDL_DestroyWindow(window);
            return error.GLContextCreationFailed;
        };

        // Enable VSync
        _ = c.SDL_GL_SetSwapInterval(1);

        return Window{
            .window = window,
            .gl_context = gl_context,
            .width = @intCast(options.width),
            .height = @intCast(options.height),
            .title = options.title,
            .should_close = false,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Window) void {
        _ = c.SDL_GL_DestroyContext(self.gl_context);
        c.SDL_DestroyWindow(self.window);
        c.SDL_Quit();
    }

    pub fn pollEvents(self: *Window) void {
        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event)) {
            switch (event.type) {
                c.SDL_EVENT_QUIT => {
                    self.should_close = true;
                },
                c.SDL_EVENT_WINDOW_RESIZED => {
                    self.width = event.window.data1;
                    self.height = event.window.data2;
                },
                else => {},
            }
        }
    }

    pub fn swapBuffers(self: *Window) void {
        _ = c.SDL_GL_SwapWindow(self.window);
    }

    pub fn shouldClose(self: *Window) bool {
        return self.should_close;
    }

    pub fn getSize(self: *Window) struct { width: i32, height: i32 } {
        return .{
            .width = self.width,
            .height = self.height,
        };
    }

    pub fn getHandle(self: *Window) *anyopaque {
        return @ptrCast(self.window);
    }
};

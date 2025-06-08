const std = @import("std");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.Window);

pub const Window = struct {
    handle: *anyopaque,
    allocator: Allocator,

    pub const Options = struct {
        title: [:0]const u8 = "Red Browser",
        width: u32 = 1280,
        height: u32 = 720,
    };

    pub fn init(allocator: Allocator, options: Options) !Window {
        log.debug("Creating window: '{s}' ({d}x{d})...", .{ options.title, options.width, options.height });
        const handle = create_window(options.title.ptr, options.width, options.height);
        if (handle == null) {
            return error.WindowCreationFailed;
        }

        log.debug("Window created successfully.", .{});
        return Window{
            .handle = handle.?,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Window) void {
        log.debug("Destroying window...", .{});
        destroy_window(self.handle);
    }

    pub fn run(self: *Window) void {
        log.debug("Running event loop...", .{});
        run_event_loop(self.handle);
    }

    pub fn pollEvents(self: *Window) void {
        poll_window_events(self.handle);
    }

    pub fn getSize(self: *Window) [2]u32 {
        var width: u32 = 0;
        var height: u32 = 0;
        get_window_size(self.handle, &width, &height);
        return [2]u32{ width, height };
    }

    pub fn getHandle(self: *Window) *anyopaque {
        return get_raw_window_handle(self.handle);
    }

    pub fn shouldClose(self: *Window) bool {
        return should_close(self.handle);
    }

    pub fn swapBuffers(self: *Window) void {
        swap_buffers(self.handle);
    }
};

extern "winit-bindings" fn create_window(title: [*:0]const u8, width: u32, height: u32) ?*anyopaque;
extern "winit-bindings" fn destroy_window(window: *anyopaque) void;
extern "winit-bindings" fn run_event_loop(window: *anyopaque) void;
extern "winit-bindings" fn poll_window_events(window: *anyopaque) void;
extern "winit-bindings" fn get_window_size(window: *anyopaque, width: *u32, height: *u32) void;
extern "winit-bindings" fn get_raw_window_handle(window: *anyopaque) ?*anyopaque;
extern "winit-bindings" fn should_close(window: *anyopaque) bool;
extern "winit-bindings" fn swap_buffers(window: *anyopaque) void;

const std = @import("std");
const glfw = @import("glfw");
const Window = @import("window").Window;

const log = std.log.scoped(.Renderer);

pub const Renderer = struct {
    allocator: std.mem.Allocator,
    window: *Window,
    time: f32,
    piston_window: *anyopaque,
    command_buffer: *anyopaque,

    pub fn init(allocator: std.mem.Allocator, window: *Window) !Renderer {
        log.debug("Initializing renderer...", .{});

        const piston_window = create_window(800, 600); // TODO: Get actual window size
        if (piston_window == null) {
            return error.FailedToCreatePistonWindow;
        }

        const command_buffer = create_command_buffer();
        if (command_buffer == null) {
            destroy_window(piston_window.?);
            return error.FailedToCreateCommandBuffer;
        }

        log.debug("Renderer initialized successfully.", .{});

        return Renderer{
            .allocator = allocator,
            .window = window,
            .time = 0.0,
            .piston_window = piston_window.?,
            .command_buffer = command_buffer.?,
        };
    }

    pub fn deinit(self: *Renderer) void {
        log.debug("Deinitializing renderer...", .{});
        destroy_command_buffer(self.command_buffer);
        destroy_window(self.piston_window);
    }

    pub fn beginFrame(self: *Renderer) !void {
        clear_color(self.command_buffer, 0.0, 0.0, 0.0, 1.0);
        self.time += 0.016;
    }

    pub fn endFrame(self: *Renderer) !void {
        submit_commands(self.piston_window, self.command_buffer);
        present_frame(self.piston_window);
        self.window.swapBuffers();
    }

    pub fn drawRect(self: *Renderer, x: f64, y: f64, width: f64, height: f64, r: f32, g: f32, b: f32, a: f32) void {
        draw_rectangle(self.command_buffer, x, y, width, height, r, g, b, a);
    }

    pub fn drawCircle(self: *Renderer, x: f64, y: f64, radius: f64, r: f32, g: f32, b: f32, a: f32) void {
        // TODO: Replace with proper circle drawing when available in the Rust library
        draw_rectangle(self.command_buffer, x - radius, y - radius, radius * 2, radius * 2, r, g, b, a);
    }
};

extern "rust_piston_bindings" fn create_window(width: u32, height: u32) ?*anyopaque;
extern "rust_piston_bindings" fn destroy_window(window: *anyopaque) void;
extern "rust_piston_bindings" fn create_command_buffer() ?*anyopaque;
extern "rust_piston_bindings" fn destroy_command_buffer(buffer: *anyopaque) void;
extern "rust_piston_bindings" fn clear_color(buffer: *anyopaque, r: f32, g: f32, b: f32, a: f32) void;
extern "rust_piston_bindings" fn draw_rectangle(buffer: *anyopaque, x: f64, y: f64, width: f64, height: f64, r: f32, g: f32, b: f32, a: f32) void;
extern "rust_piston_bindings" fn submit_commands(graphics: *anyopaque, buffer: *anyopaque) void;
extern "rust_piston_bindings" fn present_frame(graphics: *anyopaque) void;

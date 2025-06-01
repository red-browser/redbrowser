const std = @import("std");
const Renderer = @import("renderer").Renderer;
const Window = @import("window").Window;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var window = try Window.init(allocator, .{
        .title = "Red Browser",
        .width = 1280,
        .height = 720,
    });
    defer window.deinit();

    var renderer = try Renderer.init(allocator, &window);
    defer renderer.deinit();

    while (!window.shouldClose()) {
        try renderer.beginFrame();
        // TODO: Add rendering commands here
        try renderer.endFrame();
        window.pollEvents();
    }
}

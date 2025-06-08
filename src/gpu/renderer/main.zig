const std = @import("std");
const Window = @import("window").Window;
const Renderer = @import("renderer").Renderer;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var window = try Window.init(allocator, .{
        .title = "Red Browser",
        .width = 800,
        .height = 600,
    });
    defer window.deinit();

    var renderer = try Renderer.init(allocator, &window);
    defer renderer.deinit();

    while (!window.shouldClose()) {
        window.pollEvents();

        renderer.beginFrame();
        renderer.drawTriangle();
        renderer.endFrame();
    }
}

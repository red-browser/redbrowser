const std = @import("std");
const App = @import("browser/app.zig").App;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var initial_url: ?[]u8 = null;
    defer if (initial_url) |u| allocator.free(u);
    if (args.len > 1) initial_url = try @import("browser/url.zig").fromInput(allocator, args[1]);

    const shot = std.process.getEnvVarOwned(allocator, "REDBROWSER_SCREENSHOT") catch null;
    defer if (shot) |s| allocator.free(s);
    const shot_z = if (shot) |s| try allocator.dupeZ(u8, s) else null;
    defer if (shot_z) |s| allocator.free(s);

    const app = try App.init(allocator, .{ .initial_url = initial_url, .screenshot_path = shot_z });
    defer app.deinit();
    // Extra arguments open in additional tabs.
    if (args.len > 2) {
        for (args[2..]) |arg| {
            const u = try @import("browser/url.zig").fromInput(allocator, arg);
            defer allocator.free(u);
            try app.openBackgroundTab(u);
        }
    }
    if (std.posix.getenv("REDBROWSER_SCROLL")) |v| app.debugScroll(std.fmt.parseFloat(f32, v) catch 0);
    try app.run();
}

test {
    _ = @import("browser/url.zig");
}

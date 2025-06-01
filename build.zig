const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "red-gpu",
        .root_source_file = .{ .src_path = .{ .owner = b, .sub_path = "src/gpu/renderer/main.zig" } },
        .target = target,
        .optimize = optimize,
    });

    const zgl_module = b.createModule(.{
        .root_source_file = .{ .src_path = .{ .owner = b, .sub_path = "libs/zgl/zgl.zig" } },
    });

    const glfw_module = b.createModule(.{
        .root_source_file = .{ .src_path = .{ .owner = b, .sub_path = "libs/zglfw/glfw.zig" } },
    });

    const window_module = b.createModule(.{
        .root_source_file = .{ .src_path = .{ .owner = b, .sub_path = "src/gpu/window/window.zig" } },
    });

    const renderer_module = b.createModule(.{
        .root_source_file = .{ .src_path = .{ .owner = b, .sub_path = "src/gpu/renderer/renderer.zig" } },
    });

    window_module.addImport("glfw", glfw_module);
    renderer_module.addImport("zgl", zgl_module);
    renderer_module.addImport("window", window_module);

    exe.root_module.addImport("renderer", renderer_module);
    exe.root_module.addImport("window", window_module);
    exe.root_module.addImport("glfw", glfw_module);
    exe.root_module.addImport("zgl", zgl_module);

    exe.linkSystemLibrary("glfw");
    exe.linkSystemLibrary("opengl");
    exe.linkSystemLibrary("freetype");
    exe.linkSystemLibrary("harfbuzz");
    exe.linkSystemLibrary("z");

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the GPU renderer");
    run_step.dependOn(&run_cmd.step);

    // Tests
    const test_step = b.step("test", "Run all tests");
    const test_filter = b.option([]const u8, "test-filter", "Filter for test");

    const test_exe = b.addTest(.{
        .name = "red-gpu-test",
        .root_source_file = .{ .src_path = .{ .owner = b, .sub_path = "src/gpu/renderer/main.zig" } },
        .target = target,
        .optimize = optimize,
        .filter = test_filter,
    });

    test_exe.root_module.addImport("renderer", renderer_module);
    test_exe.root_module.addImport("window", window_module);
    test_exe.root_module.addImport("glfw", glfw_module);
    test_exe.root_module.addImport("zgl", zgl_module);

    const test_run = b.addRunArtifact(test_exe);
    test_step.dependOn(&test_run.step);
}

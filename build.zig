const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "redbrowser",
        .root_source_file = b.path("src/gpu/renderer/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Add SDL dependency
    exe.linkSystemLibrary("SDL3");
    exe.linkSystemLibrary("GL");
    exe.linkLibC();

    // Add include paths
    exe.addIncludePath(.{ .cwd_relative = "/usr/include" });
    exe.addIncludePath(.{ .cwd_relative = "/usr/include/SDL3" });

    // Create modules
    const window_module = b.createModule(.{
        .root_source_file = b.path("src/gpu/window/sdl.zig"),
    });

    const renderer_module = b.createModule(.{
        .root_source_file = b.path("src/gpu/renderer/piston.zig"),
    });

    // Add module dependencies
    renderer_module.addImport("window", window_module);

    // Add modules to executable
    exe.root_module.addImport("window", window_module);
    exe.root_module.addImport("renderer", renderer_module);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}

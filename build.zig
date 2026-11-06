const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const is_macos = target.result.os.tag == .macos;

    // ------------------------------------------------------------------
    // Rust engine bridge (WebRender + html5ever), built with cargo.
    // ------------------------------------------------------------------
    const cargo_release = optimize != .Debug;
    const cargo = b.addSystemCommand(&.{ "cargo", "build", "--manifest-path" });
    cargo.addFileArg(b.path("engine/Cargo.toml"));
    if (cargo_release) cargo.addArg("--release");
    cargo.has_side_effects = true; // let cargo decide what is up to date
    const engine_lib = b.path(if (cargo_release) "engine/target/release/libredengine.a" else "engine/target/debug/libredengine.a");

    // ------------------------------------------------------------------
    // Red Browser (Zig shell)
    // ------------------------------------------------------------------
    const exe = b.addExecutable(.{
        .name = "redbrowser",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.step.dependOn(&cargo.step);
    exe.addObjectFile(engine_lib);
    linkPlatform(b, exe, is_macos);
    // SpiderMonkey (inside the engine lib) is C++ and uses zlib.
    exe.linkLibCpp();
    exe.linkSystemLibrary("z");
    exe.link_gc_sections = true;
    if (is_macos) {
        for ([_][]const u8{ "CoreFoundation", "CoreGraphics", "CoreText", "Foundation", "AppKit", "Security", "SystemConfiguration" }) |f| exe.linkFramework(f);
        exe.linkSystemLibrary("iconv");
    } else {
        for ([_][]const u8{ "dl", "pthread", "m", "freetype", "fontconfig" }) |l| exe.linkSystemLibrary(l);
    }
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run Red Browser");
    run_step.dependOn(&run_cmd.step);

    const tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    tests.step.dependOn(&cargo.step);
    tests.addObjectFile(engine_lib);
    linkPlatform(b, tests, is_macos);
    if (is_macos) {
        for ([_][]const u8{ "CoreFoundation", "CoreGraphics", "CoreText", "Foundation", "AppKit", "Security", "SystemConfiguration" }) |f| tests.linkFramework(f);
        tests.linkSystemLibrary("iconv");
    }
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);

    // ------------------------------------------------------------------
    // Legacy Piston/OpenGL triangle renderer (kept for reference): `zig build piston`
    // ------------------------------------------------------------------
    const legacy = b.addExecutable(.{
        .name = "redbrowser-piston",
        .root_source_file = b.path("src/gpu/renderer/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkPlatform(b, legacy, is_macos);
    if (is_macos) legacy.linkFramework("OpenGL") else legacy.linkSystemLibrary("GL");
    const window_module = b.createModule(.{ .root_source_file = b.path("src/gpu/window/sdl.zig") });
    const renderer_module = b.createModule(.{ .root_source_file = b.path("src/gpu/renderer/piston.zig") });
    const inc = if (is_macos) "/opt/homebrew/include" else "/usr/include";
    window_module.addIncludePath(.{ .cwd_relative = inc });
    renderer_module.addIncludePath(.{ .cwd_relative = inc });
    renderer_module.addImport("window", window_module);
    legacy.root_module.addImport("window", window_module);
    legacy.root_module.addImport("renderer", renderer_module);
    const legacy_step = b.step("piston", "Build the legacy Piston/OpenGL renderer");
    legacy_step.dependOn(&b.addInstallArtifact(legacy, .{}).step);
}

fn linkPlatform(b: *std.Build, step: *std.Build.Step.Compile, is_macos: bool) void {
    _ = b;
    step.linkLibC();
    step.linkSystemLibrary("SDL3");
    if (is_macos) {
        step.addIncludePath(.{ .cwd_relative = "/opt/homebrew/include" });
        step.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });
    } else {
        step.addIncludePath(.{ .cwd_relative = "/usr/include" });
    }
}

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const core = b.addModule("chronotail", .{
        .root_source_file = b.path("src/chronotail.zig"),
        .target = target,
        .optimize = optimize,
    });

    const cli = b.addExecutable(.{
        .name = "chronotail",
        .root_module = module(b, "src/cli.zig", target, optimize, core),
    });
    b.installArtifact(cli);

    const shared = b.addLibrary(.{
        .name = "chronotail",
        .linkage = .dynamic,
        .root_module = module(b, "src/c_api.zig", target, optimize, core),
    });
    shared.linkLibC();
    b.installArtifact(shared);

    const static = b.addLibrary(.{
        .name = "chronotail",
        .linkage = .static,
        .root_module = module(b, "src/c_api.zig", target, optimize, core),
    });
    static.linkLibC();
    b.installArtifact(static);
    b.installFile("include/chronotail.h", "include/chronotail.h");

    const simulator = b.addExecutable(.{
        .name = "chronotail-sim",
        .root_module = module(b, "sim/main.zig", target, optimize, core),
    });
    const sim_step = b.step("simulator", "Build the deterministic simulator");
    sim_step.dependOn(&b.addInstallArtifact(simulator, .{}).step);

    const tests = b.addTest(.{
        .root_module = module(b, "tests/main.zig", target, optimize, core),
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run Chronotail tests");
    test_step.dependOn(&run_tests.step);

    addBenchmark(b, "bench-append", "bench/engine.zig", target, optimize, core);
    addBenchmark(b, "bench-checkpoint", "bench/checkpoint.zig", target, optimize, core);
    addBenchmark(b, "bench-concurrency", "bench/concurrency.zig", target, optimize, core);
    addBenchmark(b, "bench-native-batch", "bench/native_batch.zig", target, optimize, core);

    const run_cli = b.addRunArtifact(cli);
    if (b.args) |args| run_cli.addArgs(args);
    const run_step = b.step("run", "Run chronotail");
    run_step.dependOn(&run_cli.step);
}

fn module(
    b: *std.Build,
    path: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    core: *std.Build.Module,
) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path(path),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "chronotail", .module = core }},
    });
}

fn addBenchmark(
    b: *std.Build,
    name: []const u8,
    path: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    core: *std.Build.Module,
) void {
    const executable = b.addExecutable(.{
        .name = name,
        .root_module = module(b, path, target, optimize, core),
    });
    const run = b.addRunArtifact(executable);
    const step = b.step(name, "Run benchmark");
    step.dependOn(&run.step);
}

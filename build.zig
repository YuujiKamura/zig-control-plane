const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const mod = b.addModule("zig-control-plane", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const lib = b.addLibrary(.{
        .name = "zig-control-plane",
        .root_module = mod,
    });
    b.installArtifact(lib);
    const tests = b.addTest(.{
        .root_module = mod,
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    // Issue #222 repro: writeAll wedge on slow client.
    // Kept as a separate step (`zig build repro`) so CI can run it
    // explicitly without slowing down the default unit-test run.
    const repro_mod = b.createModule(.{
        .root_source_file = b.path("tests/repro_writeall_slow_client_leak.zig"),
        .target = target,
        .optimize = optimize,
    });
    repro_mod.addImport("zig-control-plane", mod);
    const repro_tests = b.addTest(.{
        .root_module = repro_mod,
    });
    const run_repro = b.addRunArtifact(repro_tests);
    const repro_step = b.step("repro", "Run issue-#222 writeAll slow-client repro");
    repro_step.dependOn(&run_repro.step);
}

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const module = b.addModule("regent", .{
        .root_source_file = b.path("regent.zig"),
        .target = target,
        .optimize = optimize,
    });

    const test_filters = b.option([]const []const u8, "test-filter", "Filter tests by string match") orelse &.{};

    const unit_tests = b.addTest(.{
        .root_module = module,
        .filters = test_filters,
        .use_llvm = true,
    });
    b.installArtifact(unit_tests);
    const run_unit_tests = b.addRunArtifact(unit_tests);

    b.getInstallStep().dependOn(&run_unit_tests.step);
}

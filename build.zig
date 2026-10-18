const std = @import("std");

pub fn build(builder: *std.Build) void {
    const target = builder.standardTargetOptions(.{});
    const optimize = builder.standardOptimizeOption(.{});

    const gale_module = builder.addModule("gale", .{
        .root_source_file = builder.path("src/root.zig"),
        .target = target,
    });

    const executable = builder.addExecutable(.{
        .name = "gale",
        .root_module = builder.createModule(.{
            .root_source_file = builder.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "gale", .module = gale_module },
            },
        }),
    });
    builder.installArtifact(executable);

    const run_step = builder.step("run", "Run all six scenarios and write the outputs");
    const run_command = builder.addRunArtifact(executable);
    run_step.dependOn(&run_command.step);
    run_command.step.dependOn(builder.getInstallStep());

    const tests = builder.addTest(.{
        .root_module = gale_module,
    });
    const test_step = builder.step("test", "Run the scenario regression tests");
    test_step.dependOn(&builder.addRunArtifact(tests).step);
}

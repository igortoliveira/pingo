const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("pingo", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const xev = b.dependency("libxev", .{ .target = target, .optimize = optimize });

    const exe = b.addExecutable(.{
        .name = "pingo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "pingo", .module = mod },
                .{ .name = "xev", .module = xev.module("xev") },
            },
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const conformance = b.addExecutable(.{
        .name = "conformance",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/conformance.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "pingo", .module = mod },
            },
        }),
    });
    const conformance_step = b.step("conformance", "Run the r5rs conformance suite");
    conformance_step.dependOn(&b.addRunArtifact(conformance).step);

    // C API: static and shared libpingo over src/capi.zig, plus the header.
    const capi_mod = b.createModule(.{
        .root_source_file = b.path("src/host/capi.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "pingo", .module = mod },
        },
    });
    const lib_static = b.addLibrary(.{ .name = "pingo", .linkage = .static, .root_module = capi_mod });
    const lib_shared = b.addLibrary(.{ .name = "pingo", .linkage = .dynamic, .root_module = capi_mod });
    b.installArtifact(lib_static);
    b.installArtifact(lib_shared);
    b.installFile("include/pingo.h", "include/pingo.h");

    const capi_tests = b.addTest(.{ .root_module = capi_mod });

    // C smoke test: compile tests/capi_smoke.c against the static libpingo.
    const capi_smoke_mod = b.createModule(.{ .target = target, .optimize = optimize });
    capi_smoke_mod.addCSourceFile(.{ .file = b.path("tests/capi_smoke.c") });
    capi_smoke_mod.addIncludePath(b.path("include"));
    capi_smoke_mod.linkLibrary(lib_static);
    capi_smoke_mod.link_libc = true;
    const capi_smoke = b.addExecutable(.{ .name = "capi-smoke", .root_module = capi_smoke_mod });
    const capi_smoke_step = b.step("capi-smoke", "Build and run the C API smoke test");
    capi_smoke_step.dependOn(&b.addRunArtifact(capi_smoke).step);

    const mod_tests = b.addTest(.{ .root_module = mod });
    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const example_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/examples_test.zig"),
            .target = target,
            .imports = &.{
                .{ .name = "pingo", .module = mod },
            },
        }),
    });
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(mod_tests).step);
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);
    test_step.dependOn(&b.addRunArtifact(example_tests).step);
    test_step.dependOn(&b.addRunArtifact(capi_tests).step);
}

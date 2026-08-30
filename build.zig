// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie
// SPDX-License-Identifier: MIT

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const openapi2zig_dep = b.dependency("openapi2zig", .{
        .target = target,
        .optimize = optimize,
    });

    const netbox_mod = netbox_mod: {
        const generate_exe = b.addExecutable(.{
            .name = "generate",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/generate.zig"),
                .target = target,
                .optimize = .ReleaseFast,
                .imports = &.{
                    .{
                        .name = "openapi2zig",
                        .module = openapi2zig_dep.module("openapi2zig"),
                    },
                },
            }),
            .use_lld = false,
            .use_llvm = false,
        });

        const generate_cmd = b.addRunArtifact(generate_exe);
        generate_cmd.setStdIn(.{ .lazy_path = b.path("api/api.json") });
        const api_zig = generate_cmd.captureStdOut(.{ .basename = "api.zig" });

        const install_api_zig = b.addInstallFile(api_zig, "api.zig");
        b.getInstallStep().dependOn(&install_api_zig.step);

        const netbox_mod = b.addModule("netbox", .{
            .root_source_file = api_zig,
            .target = target,
            .optimize = optimize,
        });

        break :netbox_mod netbox_mod;
    };

    const netbox_lib = b.addLibrary(.{
        .name = "netbox",
        .root_module = netbox_mod,
    });

    const install_docs = b.addInstallDirectory(.{
        .source_dir = netbox_lib.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });

    const docs_step = b.step("docs", "Build the API docs");
    docs_step.dependOn(&install_docs.step);

    const netbox_tests = b.addTest(.{
        .root_module = netbox_mod,
    });

    const run_netbox_tests = b.addRunArtifact(netbox_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_netbox_tests.step);
}

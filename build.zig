const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});

    const benchmark_step = b.step("benchmark", "Build all benchmark binaries (3 modes × [1 general + 2 specific])");

    const modes: [3]std.builtin.OptimizeMode = .{ .ReleaseFast, .ReleaseSafe, .ReleaseSmall };

    inline for (modes) |mode| {
        // ---- generic: one binary per mode (trace_to_file is runtime) ----
        {
            const options = b.addOptions();
            options.addOption([]const u8, "build", "general");
            options.addOption(bool, "trace_to_file", false); // required by config.zig but unused in generic path

            const mode_str = @tagName(mode);
            const name = b.fmt("bskysim-bench-general-{s}", .{mode_str});

            const exe = b.addExecutable(.{
                .name = name,
                .root_module = b.createModule(.{
                    .root_source_file = b.path("src/main-generic.zig"),
                    .target = target,
                    .optimize = mode,
                }),
            });

            exe.root_module.addOptions("build", options);
            wireDependencies(b, exe, target, mode);

            b.installArtifact(exe);
            benchmark_step.dependOn(&exe.step);
        }

        // ---- specific: two binaries per mode (trace_to_file baked at compile time) ----
        inline for (.{ true, false }) |trace| {
            const options = b.addOptions();
            options.addOption([]const u8, "build", "specific");
            options.addOption(bool, "trace_to_file", trace);

            const mode_str = @tagName(mode);
            const trace_str = if (trace) "trace" else "notrace";
            const name = b.fmt("bskysim-bench-specific-{s}-{s}", .{ mode_str, trace_str });

            const exe = b.addExecutable(.{
                .name = name,
                .root_module = b.createModule(.{
                    .root_source_file = b.path("src/main-specific.zig"),
                    .target = target,
                    .optimize = mode,
                }),
            });

            exe.root_module.addOptions("build", options);
            wireDependencies(b, exe, target, mode);

            b.installArtifact(exe);
            benchmark_step.dependOn(&exe.step);
        }
    }

    benchmark_step.dependOn(b.getInstallStep());
}

fn wireDependencies(
    b: *std.Build,
    exe: *std.Build.Step.Compile,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const eazy_args_dep = b.dependency("eazy_args", .{ .target = target, .optimize = optimize });
    const eazy_args_mod = eazy_args_dep.module("eazy_args");

    const ds_dep = b.dependency("ds_bskysim", .{ .target = target, .optimize = optimize });
    const ds_mod = ds_dep.module("ds");

    const distributions_dep = b.dependency("distributions", .{ .target = target, .optimize = optimize });
    const distributions_mod = distributions_dep.module("distributions");

    exe.root_module.addImport("eazy_args", eazy_args_mod);
    exe.root_module.addImport("ds", ds_mod);
    exe.root_module.addImport("distributions", distributions_mod);
}

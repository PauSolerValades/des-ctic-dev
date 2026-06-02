const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const versions: [2][]const u8 = .{ "general", "specific" };

    inline for (versions) |version| {
        const options = b.addOptions();
        options.addOption([]const u8, "build", version);

        const exe = b.addExecutable(.{
            .name = b.fmt("bskysim-{s}", .{version}),
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });

        exe.root_module.addOptions("build", options);

        const eazy_args_dep = b.dependency("eazy_args", .{
            .target = target,
            .optimize = optimize,
        });
        const eazy_args_mod = eazy_args_dep.module("eazy_args");

        const ds_dep = b.dependency("ds_bskysim", .{ // this is the repo name
            .target = target,
            .optimize = optimize,
        });
        const ds_mod = ds_dep.module("ds"); // this is the name on the build.zig on that repo

        const distributions_dep = b.dependency("distributions", .{
            .target = target,
            .optimize = optimize,
        });
        const distributions_mod = distributions_dep.module("distributions");

        // link the dependencies in here
        exe.root_module.addImport("eazy_args", eazy_args_mod);
        exe.root_module.addImport("ds", ds_mod);
        exe.root_module.addImport("distributions", distributions_mod);

        b.installArtifact(exe); // creates the exe in the folder

        const run_cmd = b.addRunArtifact(exe);

        // Install it as the module
        run_cmd.step.dependOn(b.getInstallStep());

        if (b.args) |args| {
            run_cmd.addArgs(args);
        }

        const run_step = b.step("run" ++ version, "Run the app");
        run_step.dependOn(&run_cmd.step);
    }
}

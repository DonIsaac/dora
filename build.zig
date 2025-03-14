const std = @import("std");

/// Name of library and executable. Set this to the name of your project.
const NAME = "dora";

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});
    const single_threaded = b.option(bool, "single-threaded", "Only ever use one thread") orelse false;
    const build_tests = b.option(bool, "build-tests", "Also spit out binaries for tests") orelse false;

    const lib = b.addStaticLibrary(.{
        .name = NAME,
        // In this case the main source file is merely a path, however, in more
        // complicated build scripts, this could be a generated file.
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = single_threaded,
    });

    // This declares intent for the library to be installed into the standard
    // location when the user invokes the "install" step (the default step when
    // running `zig build`).
    b.installArtifact(lib);

    const exe = b.addExecutable(.{
        .name = NAME,
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = single_threaded,
    });

    // This declares intent for the executable to be installed into the
    // standard location when the user invokes the "install" step (the default
    // step when running `zig build`).
    b.installArtifact(exe);

    // This *creates* a Run step in the build graph, to be executed when another
    // step is evaluated that depends on it. The next line below will establish
    // such a dependency.
    const run_cmd = b.addRunArtifact(exe);

    // By making the run step depend on the install step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    // This is not necessary, however, if the application depends on other installed
    // files, this ensures they will be present and in the expected location.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // This creates a build step. It will be visible in the `zig build --help` menu,
    // and can be selected like this: `zig build run`
    // This will evaluate the `run` step rather than the default, which is "install".
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Creates a step for unit testing. This only builds the test executable
    // but does not run it.
    // TODO: TSAN linking is broken in 0.13 but fixed on main. Enable it when 0.14 releases.
    // see: https://github.com/ziglang/zig/issues/15241
    const lib_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        // .sanitize_thread = true,
        .single_threaded = single_threaded,
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);
    if (build_tests) b.installArtifact(lib_unit_tests);

    const exe_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        // .sanitize_thread = true,
        .single_threaded = single_threaded,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&run_exe_unit_tests.step);

    {
        const check_step = b.step("check", "Check for semantic errors");

        inline for (.{ "src/root.zig", "src/main.zig" }) |source_file| {
            const check_test = b.addTest(.{
                .root_source_file = b.path(source_file),
                .target = target,
                .optimize = optimize,
            });
            check_step.dependOn(&check_test.step);

            const addArtifact = comptime if (std.mem.endsWith(u8, source_file, "root.zig"))
                std.Build.addStaticLibrary
            else
                std.Build.addExecutable;

            const check_artifact = addArtifact(b, .{
                .name = NAME,
                .root_source_file = b.path(source_file),
                .target = target,
                .optimize = optimize,
            });
            check_step.dependOn(&check_artifact.step);
        }
    }
}

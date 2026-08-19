const std = @import("std");
const napi_build = @import("zig-napi").napi_build;
const ohos_binding_build = @import("ohos_zig_binding").binding_build;

const default_ohos_target: std.Target.Query = .{
    .cpu_arch = .aarch64,
    .os_tag = .linux,
    .abi = .ohos,
};

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{ .default_target = default_ohos_target });
    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Prioritize performance, safety, or binary size (defaults to ReleaseFast)",
    ) orelse .ReleaseFast;
    const api = ohos_binding_build.apiOption(b) orelse ohos_binding_build.default_api;

    const zig_napi = b.dependency("zig-napi", .{});
    const napi = zig_napi.module("napi");
    const native = b.option(bool, "native", "Build the OpenHarmony addon from git dependencies") orelse true;
    const host_ghostty = b.dependency("ghostty", .{
        .target = b.graph.host,
        .optimize = optimize,
        .simd = false,
    });
    const host_ghostty_c = ghosttyApiModule(b, b.graph.host, optimize, host_ghostty);

    if (native) {
        const result = try napi_build.nativeAddonBuild(b, .{
            .name = "terminal",
            .root_module_options = .{
                .root_source_file = b.path("src/lib.zig"),
                .target = target,
                .optimize = optimize,
            },
        });

        if (result.arm64) |arm64| try configureAddon(b, arm64, napi, optimize, api);
        if (result.arm) |arm| try configureAddon(b, arm, napi, optimize, api);
        if (result.x64) |x64| try configureAddon(b, x64, napi, optimize, api);

        const dist = b.addUpdateSourceFiles();
        if (result.arm64) |arm64| {
            dist.addCopyFileToSource(arm64.getEmittedBin(), "package/libs/arm64-v8a/libterminal.so");
            dist.addCopyFileToSource(arm64.getEmittedBin(), "example/libs/arm64-v8a/libterminal.so");
        }
        if (result.arm) |arm| {
            dist.addCopyFileToSource(arm.getEmittedBin(), "package/libs/armeabi-v7a/libterminal.so");
            dist.addCopyFileToSource(arm.getEmittedBin(), "example/libs/armeabi-v7a/libterminal.so");
        }
        if (result.x64) |x64| {
            dist.addCopyFileToSource(x64.getEmittedBin(), "package/libs/x86_64/libterminal.so");
            dist.addCopyFileToSource(x64.getEmittedBin(), "example/libs/x86_64/libterminal.so");
        }
        const dist_step = b.step("dist", "Install the Zig-built addon into the HAR and example modules");
        dist_step.dependOn(&dist.step);
    }

    const font_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/font.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        }),
    });
    const layout_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/layout.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        }),
    });
    const byte_queue_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/byte_queue.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        }),
    });
    const ghostty_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ghostty_test.zig"),
            .target = b.graph.host,
            .optimize = optimize,
            .imports = &.{.{ .name = "ghostty_c", .module = host_ghostty_c }},
        }),
    });
    ghostty_tests.root_module.link_libc = true;
    ghostty_tests.root_module.linkLibrary(host_ghostty.artifact("ghostty-vt-static"));

    const test_step = b.step("test", "Run host unit tests");
    test_step.dependOn(&b.addRunArtifact(font_tests).step);
    test_step.dependOn(&b.addRunArtifact(layout_tests).step);
    test_step.dependOn(&b.addRunArtifact(byte_queue_tests).step);
    test_step.dependOn(&b.addRunArtifact(ghostty_tests).step);
}

fn configureAddon(
    b: *std.Build,
    compile: *std.Build.Step.Compile,
    napi: *std.Build.Module,
    optimize: std.builtin.OptimizeMode,
    api: u32,
) !void {
    const resolved = compile.root_module.resolved_target.?;
    const ohos_binding = b.dependency("ohos_zig_binding", .{
        .target = resolved,
        .optimize = optimize,
        .api = api,
        .xcomponent_napi = true,
    });
    const raw_window_handle = b.dependency("raw_window_handle", .{
        .target = resolved,
        .optimize = optimize,
    });
    // wgpu's 32-bit OHOS path has an additional lazy source dependency. On a
    // clean machine the dependency build intentionally exposes no module on
    // the first configure pass while Zig fetches it; return and let Zig rerun
    // configuration instead of turning that normal fetch cycle into a panic.
    const wgpu = wgpuModule(b, resolved, optimize) orelse return;

    compile.root_module.addImport("napi", napi);
    compile.root_module.addImport("xcomponent", ohos_binding.module("xcomponent"));
    compile.root_module.addImport("hilog", ohos_binding.module("hilog"));
    compile.root_module.addImport("native_window", ohos_binding.module("native_window"));
    compile.root_module.addImport("native_drawing", ohos_binding.module("native_drawing"));
    compile.root_module.addImport("input_method", ohos_binding.module("input_method"));
    compile.root_module.addImport("wgpu", wgpu);
    compile.root_module.addImport("raw-window-handle", raw_window_handle.module("raw-window-handle"));
    compile.root_module.link_libc = true;
    compile.root_module.link_libcpp = true;
    try linkGhostty(b, compile, optimize);
}

fn wgpuModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) ?*std.Build.Module {
    const dep = b.dependency("wgpu_native_zig", .{
        .target = target,
        .optimize = optimize,
    });
    return dep.builder.modules.get("wgpu");
}

fn linkGhostty(
    b: *std.Build,
    compile: *std.Build.Step.Compile,
    optimize: std.builtin.OptimizeMode,
) !void {
    const target = compile.root_module.resolved_target.?;
    const dependency = b.dependency("ghostty", .{
        .target = target,
        .optimize = optimize,
        .simd = false,
    });
    compile.root_module.addImport(
        "ghostty_c",
        ghosttyApiModule(b, target, optimize, dependency),
    );
    compile.root_module.linkLibrary(dependency.artifact("ghostty-vt-static"));
}

fn ghosttyApiModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    dependency: *std.Build.Dependency,
) *std.Build.Module {
    const translate = b.addTranslateC(.{
        .root_source_file = b.path("src/ghostty_ffi.h"),
        .target = target,
        .optimize = optimize,
    });
    translate.addIncludePath(dependency.path("include"));
    return translate.addModule("ghostty_c");
}

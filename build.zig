const std = @import("std");
const enums_backend = @import("src/enums_backend.zig");
const Pkg = std.Build.Pkg;
const Compile = std.Build.Step.Compile;

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    var back_to_build = b.option(enums_backend.Backend, "backend", "Backend to build");

    const test_step = b.step("test", "Test the dvui codebase");
    const check_step = b.step("check", "Check that the entire dvui codebase has no syntax errors");

    // Setting this to false may fix linking errors: https://github.com/david-vanderson/dvui/issues/269
    const use_lld = b.option(bool, "use-lld", "The value of the use_lld executable option");
    const test_filters = b.option([]const []const u8, "test-filter", "Skip tests that do not match any filter") orelse &[0][]const u8{};

    const generate_doc_images = b.option(bool, "generate-images", "Add this to 'docs' to generate images") orelse false;
    if (generate_doc_images) {
        back_to_build = .sdl3;
    }

    const build_options = b.addOptions();
    build_options.addOption(
        ?bool,
        "zig_arena",
        b.option(bool, "zig_arena", "Use zig std lib arena for memory management"),
    );
    build_options.addOption(
        ?[]const u8,
        "snapshot_image_suffix",
        b.option([]const u8, "snapshot-images", "When this name is defined, dvui.testing.snapshot will save an image ending with the string provided"),
    );
    build_options.addOption(
        ?[]const u8,
        "image_dir",
        if (generate_doc_images)
            b.getInstallPath(.prefix, "docs")
        else
            b.option([]const u8, "image-dir", "Default directory for dvui.testing.saveImage"),
    );
    build_options.addOption(
        ?u8,
        "log_stack_trace",
        b.option(u8, "log-stack-trace", "The max number of stack frames to display in error log stack traces (32 shows almost everything, 0 to disable)"),
    );
    build_options.addOption(
        ?bool,
        "log_error_trace",
        b.option(bool, "log-error-trace", "If error logs should include the error return trace (automatically enabled with log stack traces)"),
    );

    const dvui_opts = DvuiModuleOptions{
        .b = b,
        .target = target,
        .optimize = optimize,
        .test_step = test_step,
        .test_filters = test_filters,
        .check_step = check_step,
        .use_lld = use_lld,
        .build_options = build_options,
    };

    if (back_to_build) |backend| {
        buildBackend(backend, true, dvui_opts);
    } else {
        for (std.meta.tags(enums_backend.Backend)) |backend| {
            switch (backend) {
                .custom => continue,
                else => {},
            }
            // if we are building all the backends, here's where we do dvui tests
            const test_dvui_and_app = backend == .sdl3;
            buildBackend(backend, test_dvui_and_app, dvui_opts);
        }
    }

    // Docs
    {
        const docs_step = b.step("docs", "Build documentation");
        const docs = b.addLibrary(.{ .name = "dvui", .root_module = b.createModule(.{
            .root_source_file = b.path("src/dvui.zig"),
            .target = target,
        }) });

        const install_docs = b.addInstallDirectory(.{
            .source_dir = docs.getEmittedDocs(),
            .install_dir = .prefix,
            .install_subdir = "docs",
            // Seems a bit drastic but by default only index.html is installed
            // and I override it below. Maybe there is a cleaner way ?
            .exclude_extensions = &.{".html"},
        });
        docs_step.dependOn(&install_docs.step);

        if (generate_doc_images) {
            if (b.modules.get("dvui_sdl2")) |dvui| {
                const image_tests = b.addTest(.{
                    .name = "generate-images",
                    .root_module = dvui,
                    .filters = &.{"DOCIMG"},
                    .test_runner = .{ .mode = .simple, .path = b.path("docs/image_gen_test_runner.zig") },
                    .use_lld = use_lld,
                });
                docs_step.dependOn(&b.addRunArtifact(image_tests).step);
            } else {
                docs_step.dependOn(&b.addFail("'generate-images' requires the sdl2 backend").step);
            }
        }

        // Don't add to normal install step as it fails in ci
        // b.getInstallStep().dependOn(docs_step);

        // Use customized index.html
        const add_doc_logo = b.addExecutable(.{
            .name = "addDocLogo",
            .root_module = b.createModule(.{
                .root_source_file = b.path("docs/add_doc_logo.zig"),
                .target = b.graph.host,
            }),
        });
        const run_add_logo = b.addRunArtifact(add_doc_logo);
        run_add_logo.addFileArg(b.path("docs/index.html"));
        run_add_logo.addFileArg(b.path("docs/favicon.svg"));
        run_add_logo.addFileArg(b.path("docs/logo.svg"));
        const indexhtml_file = run_add_logo.captureStdOut();
        docs_step.dependOn(&b.addInstallFileWithDir(indexhtml_file, .prefix, "docs/index.html").step);
    }
}

pub fn buildBackend(backend: enums_backend.Backend, test_dvui_and_app: bool, dvui_opts: DvuiModuleOptions) void {
    const b = dvui_opts.b;
    const target = dvui_opts.target;
    const optimize = dvui_opts.optimize;
    switch (backend) {
        .custom => {
            // For export to users who are bringing their own backend.  Use in your build.zig:
            // const dvui_mod = dvui_dep.module("dvui");
            // @import("dvui").linkBackend(dvui_mod, your_backend_module);
            _ = addDvuiModule("dvui", dvui_opts);
            // does not need to be tested as only dependent would hit this path and test themselves
        },
        .testing => {
            const testing_mod = b.addModule("testing", .{
                .root_source_file = b.path("src/backends/testing.zig"),
                .target = target,
                .optimize = optimize,
            });
            dvui_opts.addChecks(testing_mod, "testing-backend");
            dvui_opts.addTests(testing_mod, "testing-backend");

            const dvui_testing = addDvuiModule("dvui_testing", dvui_opts);
            dvui_opts.addChecks(dvui_testing, "dvui_testing");
            if (test_dvui_and_app) {
                dvui_opts.addTests(dvui_testing, "dvui_testing");
            }

            linkBackend(dvui_testing, testing_mod);
            const example_opts: ExampleOptions = .{
                .dvui_mod = dvui_testing,
                .backend_name = "testing-backend",
                .backend_mod = testing_mod,
            };
            addExample("testing-app", b.path("examples/app.zig"), test_dvui_and_app, example_opts, dvui_opts);
        },
        .sdl3 => {
            const sdl_mod = b.addModule("sdl3", .{
                .root_source_file = b.path("src/backends/sdl.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            });
            dvui_opts.addChecks(sdl_mod, "sdl3-backend");
            dvui_opts.addTests(sdl_mod, "sdl3-backend");

            const sdl3_options = b.addOptions();
            sdl3_options.addOption(
                ?bool,
                "callbacks",
                b.option(bool, "sdl3-callbacks", "Use callbacks for live resizing on windows/mac"),
            );

            if (b.systemIntegrationOption("sdl3", .{})) {
                // SDL3 from system
                sdl3_options.addOption(std.SemanticVersion, "version", .{ .major = 3, .minor = 0, .patch = 0 });
                sdl_mod.linkSystemLibrary("SDL3", .{});
            } else {
                // SDL3 compiled from source
                sdl3_options.addOption(std.SemanticVersion, "version", .{ .major = 3, .minor = 0, .patch = 0 });
                if (b.lazyDependency("sdl3", .{
                    .target = target,
                    .optimize = optimize,
                })) |sdl3| {
                    sdl_mod.linkLibrary(sdl3.artifact("SDL3"));
                }
            }
            sdl_mod.addOptions("sdl_options", sdl3_options);

            const dvui_sdl = addDvuiModule("dvui_sdl3", dvui_opts);
            dvui_opts.addChecks(dvui_sdl, "dvui_sdl3");
            if (test_dvui_and_app) {
                dvui_opts.addTests(dvui_sdl, "dvui_sdl3");
            }

            linkBackend(dvui_sdl, sdl_mod);
            const example_opts: ExampleOptions = .{
                .dvui_mod = dvui_sdl,
                .backend_name = "sdl-backend",
                .backend_mod = sdl_mod,
            };
            addExample("sdl3-standalone", b.path("examples/sdl-standalone.zig"), true, example_opts, dvui_opts);
            addExample("sdl3-ontop", b.path("examples/sdl-ontop.zig"), true, example_opts, dvui_opts);
            addExample("sdl3-app", b.path("examples/app.zig"), test_dvui_and_app, example_opts, dvui_opts);
        },
        .sdl3_vk => {
            const sdl3_vk_mod = b.addModule("sdl3_vk", .{
                .root_source_file = b.path("src/backends/sdl3_vk.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            });
            dvui_opts.addChecks(sdl3_vk_mod, "sdl3_vk-backend");
            dvui_opts.addTests(sdl3_vk_mod, "sdl3_vk-backend");

            const sdl3_vk_options = b.addOptions();
            sdl3_vk_options.addOption(
                ?bool,
                "callbacks",
                b.option(bool, "sdl3_vk-callbacks", "Use callbacks for live resizing on windows/mac"),
            );

            if (b.systemIntegrationOption("sdl3", .{})) {
                // SDL3 from system
                sdl3_vk_options.addOption(std.SemanticVersion, "version", .{ .major = 3, .minor = 0, .patch = 0 });
                sdl3_vk_mod.linkSystemLibrary("SDL3", .{});
            } else {
                // SDL3 compiled from source
                sdl3_vk_options.addOption(std.SemanticVersion, "version", .{ .major = 3, .minor = 0, .patch = 0 });
                if (b.lazyDependency("sdl3", .{
                    .target = target,
                    .optimize = optimize,
                })) |sdl3| {
                    sdl3_vk_mod.linkLibrary(sdl3.artifact("SDL3"));
                }
            }
            sdl3_vk_mod.addOptions("sdl_options", sdl3_vk_options);

            const dvui_sdl3_vk = addDvuiModule("dvui_sdl3_vk", dvui_opts);
            dvui_opts.addChecks(dvui_sdl3_vk, "dvui_sdl3_vk");
            if (test_dvui_and_app) {
                dvui_opts.addTests(dvui_sdl3_vk, "dvui_sdl3_vk");
            }

            linkBackend(dvui_sdl3_vk, sdl3_vk_mod);
        },
        .web => {
            const export_symbol_names = &[_][]const u8{
                "dvui_init",
                "dvui_deinit",
                "dvui_update",
                "add_event",
                "arena_u8",
                "gpa_u8",
                "gpa_free",
                "new_font",
            };

            const web_mod = b.addModule("web", .{
                .root_source_file = b.path("src/backends/web.zig"),
                .target = target,
                .optimize = optimize,
            });
            web_mod.export_symbol_names = export_symbol_names;
            dvui_opts.addChecks(web_mod, "web-backend");
            dvui_opts.addTests(web_mod, "web-backend");

            // NOTE: exported module uses the standard target so it can be overridden by users
            const dvui_web = addDvuiModule("dvui_web", dvui_opts);
            dvui_opts.addChecks(web_mod, "dvui_web");
            if (test_dvui_and_app) {
                dvui_opts.addTests(web_mod, "dvui_web");
            }

            linkBackend(dvui_web, web_mod);

            // Examples, must be compiled for wasm32
            {
                const wasm_dvui_opts = DvuiModuleOptions{
                    .b = b,
                    .target = b.resolveTargetQuery(.{
                        .cpu_arch = .wasm32,
                        .os_tag = .freestanding,
                    }),
                    .optimize = optimize,
                    .build_options = dvui_opts.build_options,
                    .test_filters = dvui_opts.test_filters,
                    // no tests or checks needed, they are check above in native build
                };

                const web_mod_wasm = b.createModule(.{
                    .root_source_file = b.path("src/backends/web.zig"),
                });
                web_mod_wasm.export_symbol_names = export_symbol_names;

                const dvui_web_wasm = addDvuiModule("dvui_web_wasm", wasm_dvui_opts);
                linkBackend(dvui_web_wasm, web_mod_wasm);
                const example_opts: ExampleOptions = .{
                    .dvui_mod = dvui_web_wasm,
                    .backend_name = "web-backend",
                    .backend_mod = web_mod_wasm,
                };
                addWebExample("web-test", b.path("examples/web-test.zig"), example_opts, wasm_dvui_opts);
                addWebExample("web-app", b.path("examples/app.zig"), example_opts, wasm_dvui_opts);
            }
        },
    }
}

pub fn linkBackend(dvui_mod: *std.Build.Module, backend_mod: *std.Build.Module) void {
    backend_mod.addImport("dvui", dvui_mod);
    dvui_mod.addImport("backend", backend_mod);
}

const DvuiModuleOptions = struct {
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    check_step: ?*std.Build.Step = null,
    test_step: ?*std.Build.Step = null,
    test_filters: []const []const u8,
    add_stb_image: bool = true,
    use_lld: ?bool = null,
    build_options: *std.Build.Step.Options,

    fn addChecks(self: *const @This(), mod: *std.Build.Module, name: []const u8) void {
        const tests = self.b.addTest(.{
            .root_module = mod,
            .name = name,
            .filters = self.test_filters,
            .use_lld = self.use_lld,
            .use_llvm = true,
        });
        self.b.installArtifact(tests); // Compile check on default install step
        if (self.check_step) |step| {
            step.dependOn(&tests.step);
        }
    }
    fn addTests(self: *const @This(), mod: *std.Build.Module, name: []const u8) void {
        if (self.test_step) |step| {
            const tests = self.b.addTest(.{
                .root_module = mod,
                .name = name,
                .filters = self.test_filters,
                .use_lld = self.use_lld,
                .use_llvm = true,
            });
            step.dependOn(&self.b.addRunArtifact(tests).step);
        }
    }
};

fn addDvuiModule(
    comptime name: []const u8,
    opts: DvuiModuleOptions,
) *std.Build.Module {
    const b = opts.b;
    const target = opts.target;
    const optimize = opts.optimize;

    const dvui_mod = b.addModule(name, .{
        .root_source_file = b.path("src/dvui.zig"),
        .target = target,
        .optimize = optimize,
    });
    dvui_mod.addOptions("build_options", opts.build_options);
    dvui_mod.addImport("svg2tvg", b.dependency("svg2tvg", .{
        .target = target,
        .optimize = optimize,
    }).module("svg2tvg"));

    if (target.result.os.tag == .windows) {
        // tinyfiledialogs needs this
        dvui_mod.linkSystemLibrary("comdlg32", .{});
        dvui_mod.linkSystemLibrary("ole32", .{});
    }

    dvui_mod.addIncludePath(b.path("src/stb"));

    if (target.result.cpu.arch == .wasm32 or target.result.cpu.arch == .wasm64) {
        dvui_mod.addCSourceFiles(.{
            .files = &.{
                "src/stb/stb_image_impl.c",
                "src/stb/stb_image_write_impl.c",
                "src/stb/stb_truetype_impl.c",
            },
            .flags = &.{ "-DINCLUDE_CUSTOM_LIBC_FUNCS=1", "-DSTBI_NO_STDLIB=1", "-DSTBIW_NO_STDLIB=1" },
        });
    } else {
        if (opts.add_stb_image) {
            dvui_mod.addCSourceFiles(.{ .files = &.{
                "src/stb/stb_image_impl.c",
                "src/stb/stb_image_write_impl.c",
            } });
        }
        dvui_mod.addCSourceFiles(.{ .files = &.{"src/stb/stb_truetype_impl.c"} });

        dvui_mod.addIncludePath(b.path("src/tfd"));
        dvui_mod.addCSourceFiles(.{ .files = &.{"src/tfd/tinyfiledialogs.c"} });

        if (b.systemIntegrationOption("freetype", .{})) {
            dvui_mod.linkSystemLibrary("freetype2", .{});
        } else {
            const freetype_dep = b.lazyDependency("freetype", .{
                .target = target,
                .optimize = optimize,
            });
            if (freetype_dep) |fd| {
                dvui_mod.linkLibrary(fd.artifact("freetype"));
            }
        }
    }

    return dvui_mod;
}

const ExampleOptions = struct {
    dvui_mod: *std.Build.Module,
    backend_name: []const u8,
    backend_mod: *std.Build.Module,
};

fn addExample(
    comptime name: []const u8,
    file: std.Build.LazyPath,
    add_tests: bool,
    example_opts: ExampleOptions,
    opts: DvuiModuleOptions,
) void {
    const b = opts.b;

    const mod = b.createModule(.{
        .root_source_file = file,
        .target = opts.target,
        .optimize = opts.optimize,
    });
    mod.addImport("dvui", example_opts.dvui_mod);
    mod.addImport(example_opts.backend_name, example_opts.backend_mod);

    const exe = b.addExecutable(.{ .name = name, .root_module = mod, .use_lld = opts.use_lld, .use_llvm = true });
    if (opts.check_step) |step| {
        step.dependOn(&exe.step);
    }

    if (opts.target.result.os.tag == .windows) {
        exe.win32_manifest = b.path("./src/main.manifest");
        exe.subsystem = .Windows;
        // TODO: This may just be only used for directx
        if (b.lazyDependency("win32", .{})) |zigwin32| {
            mod.addImport("win32", zigwin32.module("win32"));
        }
    }

    if (add_tests) {
        opts.addChecks(mod, name);
        opts.addTests(mod, name);
        var test_step_opts = opts;
        test_step_opts.test_step = b.step("test-" ++ name, "Test " ++ name);
        test_step_opts.addTests(mod, name);
    }

    const compile_step = b.step("compile-" ++ name, "Compile " ++ name);
    const compile_cmd = b.addInstallArtifact(exe, .{});
    compile_step.dependOn(&compile_cmd.step);
    b.getInstallStep().dependOn(compile_step);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(compile_step);

    const run_step = b.step(name, "Run " ++ name);
    run_step.dependOn(&run_cmd.step);
}

fn addWebExample(
    comptime name: []const u8,
    file: std.Build.LazyPath,
    example_opts: ExampleOptions,
    opts: DvuiModuleOptions,
) void {
    const b = opts.b;

    const exeOptions: std.Build.ExecutableOptions = .{
        .name = "web",
        .use_llvm = true,
        .root_module = b.createModule(.{
            .root_source_file = file,
            .target = opts.target,
            .optimize = opts.optimize,
            .link_libc = false,
            .strip = if (opts.optimize == .ReleaseFast or opts.optimize == .ReleaseSmall) true else false,
        }),
    };
    const web_test = b.addExecutable(exeOptions);
    web_test.entry = .disabled;
    web_test.root_module.addImport("dvui", example_opts.dvui_mod);
    web_test.root_module.addImport(example_opts.backend_name, example_opts.backend_mod);

    const web_test_check = b.addExecutable(exeOptions);
    web_test_check.entry = .disabled;
    web_test_check.root_module.addImport("dvui", example_opts.dvui_mod);
    web_test_check.root_module.addImport(example_opts.backend_name, example_opts.backend_mod);
    if (opts.check_step) |step| step.dependOn(&web_test_check.step);

    const install_dir: std.Build.InstallDir = .{ .custom = "bin/" ++ name };

    const install_wasm = b.addInstallArtifact(web_test, .{
        .dest_dir = .{ .override = install_dir },
    });

    const cb = b.addExecutable(.{
        .name = "cacheBuster",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cacheBuster.zig"),
            .target = b.graph.host,
        }),
    });
    const cb_run = b.addRunArtifact(cb);
    cb_run.addFileArg(b.path("src/backends/index.html"));
    cb_run.addFileArg(b.path("src/backends/web.js"));
    cb_run.addFileArg(web_test.getEmittedBin());
    const output = cb_run.captureStdOut();

    const install_noto = b.addInstallFileWithDir(b.path("src/fonts/NotoSansKR-Regular.ttf"), install_dir, "NotoSansKR-Regular.ttf");

    const compile_step = b.step(name, "Compile " ++ name);
    compile_step.dependOn(&b.addInstallFileWithDir(output, install_dir, "index.html").step);
    const web_js = b.path("src/backends/web.js");
    compile_step.dependOn(&b.addInstallFileWithDir(web_js, install_dir, "web.js").step);
    b.addNamedLazyPath("web.js", web_js);
    compile_step.dependOn(&install_wasm.step);
    compile_step.dependOn(&install_noto.step);

    b.getInstallStep().dependOn(compile_step);
}

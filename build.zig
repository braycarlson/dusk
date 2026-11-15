const std = @import("std");

const assert = std.debug.assert;

const format_paths = [_][]const u8{ "build.zig", "src" };

const Steps = struct {
    check: *std.Build.Step,
    continuous_integration: *std.Build.Step,
    run: *std.Build.Step,
    test_all: *std.Build.Step,
    test_fake: *std.Build.Step,
    test_format: *std.Build.Step,
    test_unit: *std.Build.Step,
};

const Context = struct {
    builder: *std.Build,
    filters: []const []const u8,
    optimize: std.lang.Optimize,
    steps: Steps,
    target: std.Build.ResolvedTarget,
};

const assets = [_][]const u8{ "active.rgba", "inactive.rgba", "toolbar.rgba" };
const resource_path = "dusk.rc";

pub fn build(builder: *std.Build) void {
    const filters = builder.option(
        []const []const u8,
        "test-filter",
        "Skip tests that do not match any filter",
    ) orelse &.{};

    const context = Context{
        .builder = builder,
        .filters = filters,
        .optimize = builder.standardOptimizeOption(.{ .preferred_optimize_mode = null }),
        .steps = steps_declare(builder),
        .target = builder.standardTargetOptions(.{ .whitelist = null, .default_target = .{} }),
    };

    add_executable(&context);
    add_unit_tests(&context);
    add_fake_tests(&context);
    add_cross_check(&context);
    add_format(&context);

    builder.getInstallStep().dependOn(context.steps.check);
}

fn steps_declare(builder: *std.Build) Steps {
    const result = Steps{
        .check = builder.step("check", "Compile every artifact without running it"),
        .continuous_integration = builder.step("ci", "Run every check and test"),
        .run = builder.step("run", "Build and run the application"),
        .test_all = builder.step("test", "Run every test suite and the format check"),
        .test_fake = builder.step("test:fake", "Run the end to end tests against the fakes"),
        .test_format = builder.step("test:fmt", "Check that every source file is formatted"),
        .test_unit = builder.step("test:unit", "Run the unit tests and the tidy check"),
    };

    assert(result.check != result.test_all);
    assert(result.continuous_integration != result.check);
    assert(result.test_fake != result.test_unit);

    return result;
}

fn add_executable(context: *const Context) void {
    assert(context.steps.run != context.steps.check);

    const builder = context.builder;
    const module = create_module(context, "src/main.zig");
    const exe = builder.addExecutable(.{ .name = "dusk", .root_module = module });

    assert(exe.kind == .exe);

    add_windows_resource(context, module, exe);

    builder.installArtifact(exe);

    const run = builder.addRunArtifact(exe);

    run.step.dependOn(builder.getInstallStep());

    context.steps.run.dependOn(&run.step);
    context.steps.check.dependOn(&exe.step);
}

fn add_unit_tests(context: *const Context) void {
    assert(context.steps.test_unit != context.steps.test_all);

    const builder = context.builder;
    const module = create_module(context, "src/unit_tests.zig");
    const unit = builder.addTest(.{ .root_module = module, .filters = context.filters });
    const run = builder.addRunArtifact(unit);

    assert(unit.kind == .@"test");

    run.has_side_effects = true;
    run.setCwd(builder.path("."));

    context.steps.test_unit.dependOn(&run.step);
    context.steps.test_all.dependOn(&run.step);
    context.steps.check.dependOn(&unit.step);
    context.steps.continuous_integration.dependOn(context.steps.test_unit);
}

fn add_fake_tests(context: *const Context) void {
    assert(context.steps.test_fake != context.steps.test_all);

    const builder = context.builder;
    const module = create_module(context, "src/scenario.zig");
    const fake = builder.addTest(.{ .root_module = module, .filters = context.filters });
    const run = builder.addRunArtifact(fake);

    assert(fake.kind == .@"test");

    context.steps.test_fake.dependOn(&run.step);
    context.steps.test_all.dependOn(&run.step);
    context.steps.check.dependOn(&fake.step);
    context.steps.continuous_integration.dependOn(context.steps.test_fake);
}

fn add_cross_check(context: *const Context) void {
    assert(context.steps.continuous_integration != context.steps.check);

    const builder = context.builder;

    const queries = [_]std.Target.Query{
        .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu },
        .{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu },
    };

    for (queries) |query| {
        const resolved = builder.resolveTargetQuery(query);

        assert(resolved.result.cpu.arch == query.cpu_arch.?);
        assert(resolved.result.os.tag == query.os_tag.?);

        var scoped = context.*;

        scoped.target = resolved;

        const module = create_module(&scoped, "src/main.zig");

        const exe = builder.addExecutable(.{
            .name = builder.fmt("dusk-{s}", .{@tagName(query.os_tag.?)}),
            .root_module = module,
        });

        add_windows_resource(&scoped, module, exe);

        context.steps.check.dependOn(&exe.step);
    }
}

fn add_format(context: *const Context) void {
    assert(context.steps.test_format != context.steps.test_all);
    assert(context.steps.continuous_integration != context.steps.test_format);

    const builder = context.builder;
    const format = builder.addFmt(.{ .paths = builder.pathList(&format_paths), .check = true });

    context.steps.test_format.dependOn(&format.step);
    context.steps.test_all.dependOn(&format.step);
    context.steps.continuous_integration.dependOn(context.steps.test_format);
    context.steps.continuous_integration.dependOn(context.steps.check);
}

fn add_windows_resource(
    context: *const Context,
    module: *std.Build.Module,
    exe: *std.Build.Step.Compile,
) void {
    assert(exe.kind == .exe);
    assert(exe.root_module == module);

    if (context.target.result.os.tag != .windows) {
        return;
    }

    exe.subsystem = .windows;

    module.addWin32ResourceFile(.{
        .file = context.builder.path(resource_path),
        .flags = &.{},
        .include_paths = &.{},
    });
}

fn create_module(context: *const Context, root: []const u8) *std.Build.Module {
    assert(std.mem.startsWith(u8, root, "src/"));
    assert(std.mem.endsWith(u8, root, ".zig"));

    const builder = context.builder;

    const arc = builder.dependency("arc", .{
        .target = context.target,
        .optimize = context.optimize,
    });

    const kalymma = builder.dependency("kalymma", .{
        .target = context.target,
        .optimize = context.optimize,
    });

    const nimble = builder.dependency("nimble", .{
        .target = context.target,
        .optimize = context.optimize,
    });

    const toml = builder.dependency("toml", .{
        .target = context.target,
        .optimize = context.optimize,
    });

    const umbra = builder.dependency("umbra", .{
        .target = context.target,
        .optimize = context.optimize,
    });

    const module = builder.createModule(.{
        .root_source_file = builder.path(root),
        .target = context.target,
        .optimize = context.optimize,
    });

    module.addImport("arc", arc.module("arc"));
    module.addImport("kalymma", kalymma.module("kalymma"));
    module.addImport("nimble", nimble.module("nimble"));
    module.addImport("toml", toml.module("toml"));
    module.addImport("umbra", umbra.module("umbra"));

    for (assets) |asset| {
        module.addAnonymousImport(asset, .{
            .root_source_file = builder.path(builder.fmt("assets/{s}", .{asset})),
        });
    }

    return module;
}

const std = @import("std");

const kalymma = @import("kalymma");
const umbra = @import("umbra");

const Level = @import("level.zig").Level;
const target_module = @import("target.zig");

const assert = std.debug.assert;

const CapacityError = umbra.CapacityError;
const Monitor = kalymma.Monitor;
const Target = target_module.Target;

pub fn MenuType(comptime App: type) type {
    return struct {
        active: bool,
        level: Level,
        monitors: []const Monitor,
        target: *const Target,

        const Menu = @This();
        const MenuBuilder = App.MenuBuilder;
        const Radio = App.Menu.Item.Radio;

        pub fn fill(menu: *const Menu, tray: *App.Menu) CapacityError!void {
            assert(menu.monitors.len <= target_module.pieces_max);
            assert(menu.level.is_valid());

            tray.clear();

            const builder = MenuBuilder.init(tray)
                .toggle(Choice.encode(.toggle), label_toggle, .{ .checked = menu.active });

            const levels = menu.fill_levels(builder);
            const targets = menu.fill_targets(levels.separator());

            _ = try targets.separator().action(Choice.encode(.exit), label_exit).done();

            assert(!tray.is_empty());
            assert(tray.depth == 0);
        }

        fn fill_levels(menu: *const Menu, builder: MenuBuilder) MenuBuilder {
            assert(menu.level.is_valid());
            assert(builder.menu.depth == 0);

            var result = builder.submenu_begin(id_level, menu.level.to_percent_label());
            var index: u8 = 0;

            while (index < Level.count) : (index += 1) {
                const level = Level.from_index(index);
                const choice = Choice{ .level = level };

                const options = Radio{
                    .checked = level.percent == menu.level.percent,
                    .group = group_level,
                };

                result = result.radio(choice.encode(), level.to_percent_label(), options);
            }

            return result.submenu_end();
        }

        fn fill_targets(menu: *const Menu, builder: MenuBuilder) MenuBuilder {
            assert(menu.monitors.len <= target_module.pieces_max);
            assert(builder.menu.depth == 0);

            const all = Radio{ .checked = menu.target.* == .all, .group = group_target };

            return menu.fill_region(builder.radio(Choice.encode(.all), label_all, all));
        }

        fn fill_region(menu: *const Menu, builder: MenuBuilder) MenuBuilder {
            assert(builder.menu.depth == 0);
            if (menu.target.* == .region) assert(!menu.target.region.is_empty());

            const submenu = builder.submenu_begin(id_region_menu, label_region_menu);
            const listed = menu.fill_monitors(submenu);
            const result = if (menu.monitors.len > 0) listed.separator() else listed;

            if (menu.target.* != .region) {
                return result.action(Choice.encode(.draw), label_draw).submenu_end();
            }

            const options = Radio{ .checked = true, .group = group_target };

            return result
                .radio(Choice.encode(.region), label_region, options)
                .action(Choice.encode(.edit), label_edit)
                .action(Choice.encode(.delete), label_delete)
                .action(Choice.encode(.draw), label_draw)
                .submenu_end();
        }

        fn fill_monitors(menu: *const Menu, builder: MenuBuilder) MenuBuilder {
            assert(menu.monitors.len <= target_module.pieces_max);
            assert(builder.menu.depth == 1);

            var result = builder;

            for (menu.monitors, 0..) |*monitor, index| {
                const choice = Choice{ .monitor = @intCast(index) };
                var label: [label_monitor_bytes_max]u8 = undefined;

                const options = Radio{
                    .checked = menu.target.is_monitor(monitor),
                    .group = group_target,
                };

                result = result.radio(choice.encode(), label_of(monitor, &label), options);
            }

            return result;
        }
    };
}

pub const Choice = union(enum) {
    all: void,
    delete: void,
    draw: void,
    edit: void,
    exit: void,
    level: Level,
    monitor: u8,
    region: void,
    toggle: void,

    pub fn decode(id: u32) ?Choice {
        assert(id <= umbra.limits.menu_item_id_max);

        if (id >= level_base) {
            if (id < level_base + Level.count) {
                return .{ .level = Level.from_index(@intCast(id - level_base)) };
            }
        }

        if (id >= monitor_base) {
            if (id < monitor_base + target_module.pieces_max) {
                return .{ .monitor = @intCast(id - monitor_base) };
            }
        }

        return switch (id) {
            id_all => .all,
            id_delete => .delete,
            id_draw => .draw,
            id_edit => .edit,
            id_exit => .exit,
            id_region => .region,
            id_toggle => .toggle,
            else => null,
        };
    }

    pub fn encode(choice: Choice) u32 {
        assert(choice.is_valid());

        const result = switch (choice) {
            .all => id_all,
            .delete => id_delete,
            .draw => id_draw,
            .edit => id_edit,
            .exit => id_exit,
            .level => |level| level_base + level.to_index(),
            .monitor => |index| monitor_base + index,
            .region => id_region,
            .toggle => id_toggle,
        };

        assert(result > 0);
        assert(result <= umbra.limits.menu_item_id_max);

        return result;
    }

    pub fn is_valid(choice: Choice) bool {
        return switch (choice) {
            .all, .delete, .draw, .edit, .exit, .region, .toggle => true,
            .level => |level| level.is_valid(),
            .monitor => |index| index < target_module.pieces_max,
        };
    }
};

const group_level = "level";
const group_target = "target";
const id_all: u32 = 2;
const id_delete: u32 = 7;
const id_draw: u32 = 4;
const id_edit: u32 = 6;
const id_exit: u32 = 5;
const id_level: u32 = 8;
const id_region: u32 = 3;
const id_region_menu: u32 = 9;
const id_toggle: u32 = 1;

const ids_fixed = [_]u32{
    id_all,
    id_delete,
    id_draw,
    id_edit,
    id_exit,
    id_level,
    id_region,
    id_region_menu,
    id_toggle,
};

const label_all = "All monitors";
const label_delete = "Delete the region";
const label_draw = "Draw a region";
const label_edit = "Move or resize the region";
const label_exit = "Exit";

const label_monitor_bytes_max: u32 =
    kalymma.limits.monitor_name_bytes_max + label_primary_suffix.len;

const label_monitor_fallback = "Monitor";
const label_primary_suffix = " (primary)";
const label_region = "Drawn region";
const label_region_menu = "Region";
const label_toggle = "Dim";
const level_base: u32 = 100;
const monitor_base: u32 = 200;
const separator_count: u32 = 3;

comptime {
    const item_count_max = ids_fixed.len + separator_count + Level.count + target_module.pieces_max;

    assert(item_count_max <= umbra.limits.menu_item_count_max);
    assert(label_monitor_bytes_max <= umbra.limits.menu_label_bytes_max);
    assert(label_monitor_fallback.len <= kalymma.limits.monitor_name_bytes_max);
    assert(level_base + Level.count <= monitor_base);
    assert(monitor_base + target_module.pieces_max <= umbra.limits.menu_item_id_max);

    for (ids_fixed, 0..) |id, index| {
        assert(id > 0);
        assert(id < level_base);

        for (ids_fixed[index + 1 ..]) |other| {
            assert(id != other);
        }
    }
}

fn label_of(monitor: *const Monitor, buffer: *[label_monitor_bytes_max]u8) []const u8 {
    const name = if (monitor.get_name().len == 0) label_monitor_fallback else monitor.get_name();

    assert(name.len > 0);

    if (!monitor.primary) {
        return name;
    }

    const length = name.len + label_primary_suffix.len;

    assert(length <= label_monitor_bytes_max);

    @memcpy(buffer[0..name.len], name);
    @memcpy(buffer[name.len..length], label_primary_suffix);

    return buffer[0..length];
}

const testing = std.testing;

const FakeApp = umbra.AppType(umbra.Fake);
const FakeMenu = MenuType(FakeApp);

const Placed = struct {
    depth: u8,
    id: u32,
};

const monitors = [_]Monitor{
    Monitor.init("DP-1", .{ .height = 1080, .width = 1920 }),
    Monitor.init("HDMI-A-1", .{ .height = 1024, .width = 1280, .x = 1920 }),
};

fn open() !*FakeApp {
    const app = try testing.allocator.create(FakeApp);
    errdefer testing.allocator.destroy(app);

    try app.init(.{ .name = "dusk" });

    assert(app.menu.is_empty());

    return app;
}

fn close(app: *FakeApp) void {
    app.deinit();
    testing.allocator.destroy(app);
}

fn is_checked(tray: *const FakeApp.Menu, choice: Choice) bool {
    assert(choice.is_valid());

    return tray.is_checked(choice.encode());
}

fn label_at(tray: *const FakeApp.Menu, choice: Choice) []const u8 {
    assert(choice.is_valid());

    const item = tray.get_item(choice.encode()) orelse return "";
    return item.get_label();
}

test MenuType {
    const app = try open();
    defer close(app);

    const tray = &app.menu;
    const target: Target = .all;

    const menu = FakeMenu{
        .active = true,
        .level = .default,
        .monitors = &monitors,
        .target = &target,
    };

    try menu.fill(tray);

    try testing.expect(is_checked(tray, .toggle));
    try testing.expect(is_checked(tray, .all));
    try testing.expect(is_checked(tray, .{ .level = .default }));
    try testing.expectEqualStrings("All monitors", label_at(tray, .all));
    try testing.expectEqual(Choice.draw, Choice.decode(Choice.encode(.draw)).?);
}

test "each choice round trips through its menu identifier" {
    const fixed = [_]Choice{ .all, .delete, .draw, .edit, .exit, .region, .toggle };

    for (fixed) |choice| {
        try testing.expectEqual(choice, Choice.decode(choice.encode()).?);
    }

    var index: u8 = 0;

    while (index < Level.count) : (index += 1) {
        const choice = Choice{ .level = Level.from_index(index) };

        try testing.expectEqual(choice, Choice.decode(choice.encode()).?);
    }

    index = 0;

    while (index < target_module.pieces_max) : (index += 1) {
        const choice = Choice{ .monitor = index };

        try testing.expectEqual(choice, Choice.decode(choice.encode()).?);
    }
}

test "an identifier outside every range decodes to nothing" {
    const unknown = [_]u32{
        0,
        id_level,
        id_region_menu,
        id_region_menu + 1,
        level_base - 1,
        level_base + Level.count,
        monitor_base - 1,
        monitor_base + target_module.pieces_max,
        1 << 20,
        umbra.limits.menu_item_id_max,
    };

    for (unknown) |id| {
        try testing.expectEqual(@as(?Choice, null), Choice.decode(id));
    }
}

test "a choice outside the levels or the monitors is invalid" {
    try testing.expect(!(Choice{ .level = .{ .percent = 45 } }).is_valid());
    try testing.expect(!(Choice{ .monitor = target_module.pieces_max }).is_valid());
    try testing.expect((Choice{ .monitor = target_module.pieces_max - 1 }).is_valid());
    try testing.expect((Choice{ .level = .default }).is_valid());
}

test "the menu checks the active state, the chosen monitor, and the level" {
    const app = try open();
    defer close(app);

    const tray = &app.menu;
    const target = Target{ .monitor = monitors[1] };

    const menu = FakeMenu{
        .active = true,
        .level = .{ .percent = 60 },
        .monitors = &monitors,
        .target = &target,
    };

    try menu.fill(tray);

    try testing.expect(is_checked(tray, .toggle));
    try testing.expect(!is_checked(tray, .all));
    try testing.expect(!is_checked(tray, .{ .monitor = 0 }));
    try testing.expect(is_checked(tray, .{ .monitor = 1 }));
    try testing.expect(is_checked(tray, .{ .level = .{ .percent = 60 } }));
    try testing.expect(!is_checked(tray, .{ .level = .{ .percent = 50 } }));
    try testing.expectEqualStrings("HDMI-A-1", label_at(tray, .{ .monitor = 1 }));
    try testing.expectEqualStrings("60%", label_at(tray, .{ .level = .{ .percent = 60 } }));
    try testing.expectEqualStrings("60%", tray.get_item(id_level).?.get_label());

    const absent = [_]Choice{ .delete, .edit, .region };

    for (absent) |choice| {
        const item = tray.get_item(choice.encode());

        try testing.expectEqual(@as(?*const FakeApp.Menu.Item, null), item);
    }
}

test "a drawn region adds a checked item and all monitors lose their mark" {
    const app = try open();
    defer close(app);

    const tray = &app.menu;
    const target = Target{ .region = .{ .height = 10, .width = 10 } };

    const menu = FakeMenu{
        .active = false,
        .level = .default,
        .monitors = &monitors,
        .target = &target,
    };

    try menu.fill(tray);

    try testing.expect(!is_checked(tray, .toggle));
    try testing.expect(!is_checked(tray, .all));
    try testing.expect(is_checked(tray, .region));
    try testing.expectEqualStrings(label_draw, label_at(tray, .draw));
    try testing.expectEqualStrings(label_exit, label_at(tray, .exit));
    try testing.expectEqualStrings(label_edit, label_at(tray, .edit));
    try testing.expectEqualStrings(label_delete, label_at(tray, .delete));
}

test "the monitors and the drawn region sit in the region submenu below all monitors" {
    const app = try open();
    defer close(app);

    const tray = &app.menu;
    const target = Target{ .region = .{ .height = 10, .width = 10 } };

    const menu = FakeMenu{
        .active = true,
        .level = .{ .percent = 70 },
        .monitors = &monitors,
        .target = &target,
    };

    try menu.fill(tray);

    const head = [_]u32{ id_toggle, id_level };

    const tail = [_]Placed{
        .{ .depth = 0, .id = 0 },
        .{ .depth = 0, .id = id_all },
        .{ .depth = 0, .id = id_region_menu },
        .{ .depth = 1, .id = monitor_base },
        .{ .depth = 1, .id = monitor_base + 1 },
        .{ .depth = 1, .id = 0 },
        .{ .depth = 1, .id = id_region },
        .{ .depth = 1, .id = id_edit },
        .{ .depth = 1, .id = id_delete },
        .{ .depth = 1, .id = id_draw },
        .{ .depth = 0, .id = 0 },
        .{ .depth = 0, .id = id_exit },
    };

    const levels = tray.items[head.len..][0..Level.count];
    const rest = tray.items[head.len + Level.count ..][0..tail.len];

    try testing.expectEqual(head.len + Level.count + tail.len, tray.count);

    for (head, tray.items[0..head.len]) |id, *item| {
        try testing.expectEqual(id, item.id);
        try testing.expectEqual(@as(u8, 0), item.depth);
    }

    for (levels, 0..) |*item, index| {
        try testing.expectEqual(level_base + index, item.id);
        try testing.expectEqual(@as(u8, 1), item.depth);
    }

    for (tail, rest) |placed, *item| {
        try testing.expectEqual(placed.id, item.id);
        try testing.expectEqual(placed.depth, item.depth);
    }

    var separators: u32 = 0;

    for (tray.items[0..tray.count]) |*item| {
        if (item.kind == .separator) separators += 1;
    }

    try testing.expectEqual(separator_count, separators);
    try testing.expectEqual(FakeApp.Menu.Item.Kind.submenu, tray.get_item(id_level).?.kind);
    try testing.expectEqual(FakeApp.Menu.Item.Kind.submenu, tray.get_item(id_region_menu).?.kind);
    try testing.expectEqualStrings("70%", tray.get_item(id_level).?.get_label());
    try testing.expectEqualStrings("Region", tray.get_item(id_region_menu).?.get_label());
    try testing.expect(is_checked(tray, .{ .level = .{ .percent = 70 } }));
}

test "without a drawn region the region submenu holds the monitors and the draw action" {
    const app = try open();
    defer close(app);

    const tray = &app.menu;
    const target = Target{ .monitor = monitors[0] };

    const menu = FakeMenu{
        .active = true,
        .level = .default,
        .monitors = &monitors,
        .target = &target,
    };

    try menu.fill(tray);

    const tail = [_]Placed{
        .{ .depth = 0, .id = id_region_menu },
        .{ .depth = 1, .id = monitor_base },
        .{ .depth = 1, .id = monitor_base + 1 },
        .{ .depth = 1, .id = 0 },
        .{ .depth = 1, .id = id_draw },
        .{ .depth = 0, .id = 0 },
        .{ .depth = 0, .id = id_exit },
    };

    const rest = tray.items[tray.count - tail.len .. tray.count];

    for (tail, rest) |placed, *item| {
        try testing.expectEqual(placed.id, item.id);
        try testing.expectEqual(placed.depth, item.depth);
    }

    try testing.expectEqualStrings(label_draw, label_at(tray, .draw));
    try testing.expect(is_checked(tray, .{ .monitor = 0 }));
}

test "without a monitor the region submenu opens straight onto the draw action" {
    const app = try open();
    defer close(app);

    const tray = &app.menu;
    const target: Target = .all;

    const menu = FakeMenu{
        .active = false,
        .level = .default,
        .monitors = &.{},
        .target = &target,
    };

    try menu.fill(tray);

    const tail = [_]Placed{
        .{ .depth = 0, .id = id_all },
        .{ .depth = 0, .id = id_region_menu },
        .{ .depth = 1, .id = id_draw },
        .{ .depth = 0, .id = 0 },
        .{ .depth = 0, .id = id_exit },
    };

    const rest = tray.items[tray.count - tail.len .. tray.count];

    for (tail, rest) |placed, *item| {
        try testing.expectEqual(placed.id, item.id);
        try testing.expectEqual(placed.depth, item.depth);
    }

    try testing.expect(is_checked(tray, .all));
}

test "a monitor without a name gets a fallback label" {
    const unnamed = Monitor.init("", .{ .height = 10, .width = 10 });
    var buffer: [label_monitor_bytes_max]u8 = undefined;

    try testing.expectEqualStrings(label_monitor_fallback, label_of(&unnamed, &buffer));
    try testing.expectEqualStrings("DP-1", label_of(&monitors[0], &buffer));
}

test "the primary monitor carries a marker after its name" {
    var buffer: [label_monitor_bytes_max]u8 = undefined;
    var named = monitors[1];
    named.primary = true;
    var unnamed = Monitor.init("", .{ .height = 10, .width = 10 });
    unnamed.primary = true;
    const longest: [kalymma.limits.monitor_name_bytes_max]u8 = @splat('w');
    var widest = Monitor.init(&longest, .{ .height = 10, .width = 10 });
    widest.primary = true;

    try testing.expectEqualStrings("HDMI-A-1 (primary)", label_of(&named, &buffer));
    try testing.expectEqualStrings("Monitor (primary)", label_of(&unnamed, &buffer));
    try testing.expectEqualStrings("DP-1", label_of(&monitors[0], &buffer));

    const label = label_of(&widest, &buffer);

    try testing.expectEqual(@as(usize, label_monitor_bytes_max), label.len);
    try testing.expect(std.mem.startsWith(u8, label, &longest));
    try testing.expect(std.mem.endsWith(u8, label, label_primary_suffix));
}

test "the menu marks the primary monitor and still checks the chosen one by name" {
    const app = try open();
    defer close(app);

    const tray = &app.menu;
    var screens = monitors;
    screens[1].primary = true;
    const target = Target{ .monitor = Monitor.init("HDMI-A-1", .{}) };

    const menu = FakeMenu{
        .active = true,
        .level = .default,
        .monitors = &screens,
        .target = &target,
    };

    try menu.fill(tray);

    try testing.expectEqualStrings("DP-1", label_at(tray, .{ .monitor = 0 }));
    try testing.expectEqualStrings("HDMI-A-1 (primary)", label_at(tray, .{ .monitor = 1 }));
    try testing.expect(!is_checked(tray, .{ .monitor = 0 }));
    try testing.expect(is_checked(tray, .{ .monitor = 1 }));
}

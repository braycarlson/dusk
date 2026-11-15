const std = @import("std");

const kalymma = @import("kalymma");
const nimble = @import("nimble");
const umbra = @import("umbra");

const application_module = @import("application.zig");
const Level = @import("level.zig").Level;
const Choice = @import("menu.zig").Choice;
const Store = @import("store.zig").Store;
const pieces_max = @import("target.zig").pieces_max;
const Button = @import("toolbar.zig").Button;

const assert = std.debug.assert;

const Application = ApplicationType(FakeLibraries);
const ApplicationType = application_module.ApplicationType;
const Custom = umbra.Event.Custom;
const Input = kalymma.Event.Input;
const Key = kalymma.Key;
const Message = application_module.Message;
const Monitor = kalymma.Monitor;
const Point = kalymma.Point;
const Rect = kalymma.Rect;
const TimerID = application_module.TimerID;

const testing = std.testing;

const FakeLibraries = struct {
    pub const App = umbra.AppType(umbra.Fake);
    pub const Client = nimble.RuntimeType(nimble.Fake).Client;
    pub const Runtime = kalymma.RuntimeType(kalymma.Fake);
};

const temporary_options: std.Io.Dir.OpenOptions = .{
    .access_sub_paths = true,
    .follow_symlinks = true,
    .iterate = false,
};

const drawn = Stroke{ .from = .{ .x = 100, .y = 100 }, .to = .{ .x = 500, .y = 400 } };
const left = Monitor.init("left", .{ .height = 1080, .width = 1920, .x = 0, .y = 0 });
const probe_code: umbra.Event.Code = @fromBackingInt(0x70726f62);
const right = Monitor.init("right", .{ .height = 1024, .width = 1280, .x = 1920, .y = 0 });
const shifted = Monitor.init("right", .{ .height = 1024, .width = 1280, .x = -1280, .y = 0 });

comptime {
    assert(std.enums.fromInt(Message, @backingInt(probe_code)) == null);
}

const Shown = struct {
    area: i64 = 0,
    count: u32 = 0,
    interactive: u32 = 0,
};

const Stroke = struct {
    from: Point,
    to: Point,
};

fn open() !*Application {
    return open_with(.{ .logger = null, .store = null });
}

fn open_with(options: Application.Options) !*Application {
    comptime assert(@sizeOf(@TypeOf(options)) <= 16);
    if (options.store) |store| assert(store.get_path().len > 0);

    const application = try testing.allocator.create(Application);
    errdefer testing.allocator.destroy(application);

    try application.init(options);

    arrange(application, &.{ left, right });
    post(application, .shades);

    assert(application.monitors.count == 2);

    return application;
}

fn close(application: *Application) void {
    application.deinit();
    testing.allocator.destroy(application);
}

fn display(application: *Application) *kalymma.Fake {
    return &application.overlay.platform;
}

fn arrange(application: *Application, monitors: []const Monitor) void {
    assert(monitors.len > 0);
    assert(monitors.len <= kalymma.limits.monitor_count_max);

    var list = Monitor.List.init();

    for (monitors) |monitor| {
        list.append(monitor);
    }

    display(application).set_monitors(&list);
}

fn post(application: *Application, message: Message) void {
    application.on_custom(.{ .code = @fromBackingInt(@backingInt(message)) });
}

fn select(application: *Application, choice: Choice) void {
    assert(choice.is_valid());

    application.on_menu_select(.{ .checked = false, .id = choice.encode() });
}

fn tick(application: *Application, timer: TimerID) void {
    application.on_timer_tick(.{ .id = @backingInt(timer), .count = 0 });
}

fn touch(application: *Application, index: u8, input: Input) void {
    assert(index < application.picker.catchers.count);
    assert(input != .monitors_changed);

    display(application).inject_shade(application.picker.catchers.slice()[index], input);
    post(application, .shades);
}

fn click(application: *Application, button: Button) void {
    const rect = button.rect();

    const center = Point{
        .x = rect.x + @divFloor(rect.width, 2),
        .y = rect.y + @divFloor(rect.height, 2),
    };

    reach(application, .{ .pointer_down = center });
    reach(application, .{ .pointer_up = center });
}

fn press(application: *Application, key: Key) void {
    assert(key.is_valid());

    reach(application, .{ .key_down = key });
}

fn reach(application: *Application, input: Input) void {
    assert(application.picker.mode == .edit);
    assert(input != .monitors_changed);

    display(application).inject(application.picker.toolbar.surface, input);
    post(application, .shades);
}

fn drag(application: *Application, stroke: Stroke) void {
    assert(application.picker.is_open());
    assert(application.picker.catchers.count > 0);
    assert(!stroke.from.eql(stroke.to));

    touch(application, 0, .{ .pointer_down = stroke.from });
    touch(application, 0, .{ .pointer_move = stroke.to });
    touch(application, 0, .{ .pointer_up = stroke.to });
}

fn submenu_label(application: *const Application) []const u8 {
    const menu = &application.runtime.menu;

    assert(menu.count <= umbra.limits.menu_item_count_max);

    for (menu.items[0..menu.count]) |*item| {
        if (item.kind == .submenu) return item.get_label();
    }

    return "";
}

fn is_checked(application: *const Application, choice: Choice) bool {
    assert(choice.is_valid());

    return application.runtime.menu.is_checked(choice.encode());
}

fn label_of(application: *const Application, choice: Choice) []const u8 {
    assert(choice.is_valid());

    const item = application.runtime.menu.get_item(choice.encode()) orelse return "";
    return item.get_label();
}

fn is_timing_out(application: *const Application) bool {
    return application.runtime.timers.is_running(@backingInt(TimerID.pick));
}

fn is_toolbar_shown(application: *const Application) bool {
    return application.overlay.surface_is_visible(application.picker.toolbar.surface);
}

fn shown(application: *Application) Shown {
    var result = Shown{};

    for (display(application).shade_table.slots) |slot| {
        if (!slot.used) continue;

        result.area += slot.rect.area();
        result.count += 1;

        if (slot.interactive) {
            result.interactive += 1;
        }
    }

    assert(result.interactive <= result.count);

    return result;
}

fn expect_dimmed(application: *Application, rects: []const Rect, color: u32) !void {
    assert(rects.len <= pieces_max);

    var matched: u32 = 0;

    for (display(application).shade_table.slots) |slot| {
        if (!slot.used) continue;

        try testing.expect(!slot.interactive);
        try testing.expectEqual(color, slot.color);
        try testing.expect(contains(rects, slot.rect));

        matched += 1;
    }

    try testing.expectEqual(@as(u32, @intCast(rects.len)), matched);
}

fn contains(rects: []const Rect, wanted: Rect) bool {
    assert(rects.len <= pieces_max);
    assert(!wanted.is_empty());

    for (rects) |rect| {
        if (std.meta.eql(rect, wanted)) return true;
    }

    return false;
}

test "a fresh application dims nothing and marks all monitors at the default level" {
    const application = try open();
    defer close(application);

    try testing.expectEqual(@as(u32, 0), shown(application).count);
    try testing.expectEqualStrings("inactive", application.runtime.icons.get_current_name().?);
    try testing.expect(!is_checked(application, .toggle));
    try testing.expect(is_checked(application, .all));
    try testing.expect(is_checked(application, .{ .level = Level.default }));
    try testing.expectEqualStrings("All monitors", label_of(application, .all));
    try testing.expectEqualStrings("Draw a region", label_of(application, .draw));
    try testing.expectEqualStrings("left", label_of(application, .{ .monitor = 0 }));
    try testing.expectEqualStrings("right", label_of(application, .{ .monitor = 1 }));
    try testing.expectEqualStrings("", label_of(application, .region));
}

test "the toggle dims every monitor at half strength and turns it off again" {
    const application = try open();
    defer close(application);

    post(application, .toggle);

    try expect_dimmed(application, &.{ left.rect, right.rect }, 0x80000000);
    try testing.expectEqualStrings("active", application.runtime.icons.get_current_name().?);
    try testing.expect(is_checked(application, .toggle));

    post(application, .toggle);

    try testing.expectEqual(@as(u32, 0), shown(application).count);
    try testing.expectEqualStrings("inactive", application.runtime.icons.get_current_name().?);
    try testing.expect(!is_checked(application, .toggle));
}

test "darker and lighter refill the live shades and stop at the ends of the range" {
    const application = try open();
    defer close(application);

    post(application, .toggle);
    post(application, .darker);

    try expect_dimmed(application, &.{ left.rect, right.rect }, 0x99000000);

    post(application, .lighter);
    post(application, .lighter);

    try expect_dimmed(application, &.{ left.rect, right.rect }, 0x66000000);
    try testing.expect(is_checked(application, .{ .level = .{ .percent = 40 } }));

    var round: u32 = 0;

    while (round < 2 * Level.count) : (round += 1) {
        post(application, .darker);
    }

    try expect_dimmed(application, &.{ left.rect, right.rect }, 0xE6000000);
    try testing.expectEqual(@as(u32, 2), display(application).count_of(.shade_create));
}

test "a level change while the screen is light waits for the next toggle" {
    const application = try open();
    defer close(application);

    post(application, .lighter);

    try testing.expectEqual(@as(u32, 0), shown(application).count);
    try testing.expect(!application.active);

    post(application, .toggle);

    try expect_dimmed(application, &.{ left.rect, right.rect }, 0x66000000);
}

test "choosing where to dim never turns the dimming on or off" {
    const application = try open();
    defer close(application);

    select(application, .{ .monitor = 1 });

    try testing.expect(!application.active);
    try testing.expectEqual(@as(u32, 0), shown(application).count);
    try testing.expect(is_checked(application, .{ .monitor = 1 }));
    try testing.expectEqualStrings("inactive", application.runtime.icons.get_current_name().?);

    select(application, .draw);
    drag(application, drawn);
    drag(application, .{ .from = .{ .x = 150, .y = 120 }, .to = .{ .x = 350, .y = 220 } });
    click(application, .done);

    try testing.expect(!application.active);
    try testing.expectEqual(@as(u32, 0), shown(application).count);
    try testing.expect(is_checked(application, .region));

    post(application, .toggle);

    const moved = Rect{ .height = 300, .width = 400, .x = 300, .y = 200 };

    try expect_dimmed(application, &.{moved}, 0x80000000);

    select(application, .{ .monitor = 1 });

    try testing.expect(application.active);
    try expect_dimmed(application, &.{right.rect}, 0x80000000);

    select(application, .all);

    try testing.expect(application.active);
    try expect_dimmed(application, &.{ left.rect, right.rect }, 0x80000000);
}

test "a monitor choice dims only that monitor and follows it through a layout change" {
    const application = try open();
    defer close(application);

    post(application, .toggle);
    select(application, .{ .monitor = 1 });

    try testing.expect(application.active);
    try testing.expect(is_checked(application, .{ .monitor = 1 }));
    try testing.expect(!is_checked(application, .all));
    try expect_dimmed(application, &.{right.rect}, 0x80000000);

    arrange(application, &.{ left, shifted });
    post(application, .shades);

    try expect_dimmed(application, &.{shifted.rect}, 0x80000000);
}

test "a monitor that leaves takes its shade and its menu entry with it" {
    const application = try open();
    defer close(application);

    post(application, .toggle);
    select(application, .{ .monitor = 1 });
    arrange(application, &.{left});
    post(application, .shades);

    try testing.expectEqual(@as(u32, 0), shown(application).count);
    try testing.expectEqualStrings("", label_of(application, .{ .monitor = 1 }));
    try testing.expect(!is_checked(application, .all));

    select(application, .{ .monitor = 1 });

    try testing.expectEqual(@as(u32, 0), shown(application).count);
}

test "a finished drawing opens the editor at once and the region dims only once dim is on" {
    const application = try open();
    defer close(application);

    select(application, .draw);

    const catchers = Shown{
        .area = left.rect.area() + right.rect.area(),
        .count = 2,
        .interactive = 2,
    };

    try testing.expectEqual(catchers, shown(application));
    try testing.expect(!is_toolbar_shown(application));

    touch(application, 0, .{ .pointer_down = .{ .x = 100, .y = 100 } });
    touch(application, 0, .{ .pointer_move = .{ .x = 2000, .y = 500 } });

    try testing.expectEqual(@as(u32, 4), shown(application).count);

    touch(application, 0, .{ .pointer_up = .{ .x = 2000, .y = 500 } });

    const region = Rect{ .height = 400, .width = 1900, .x = 100, .y = 100 };

    const editing = Shown{
        .area = catchers.area + region.area(),
        .count = 4,
        .interactive = 2,
    };

    try testing.expect(application.picker.is_open());
    try testing.expect(is_toolbar_shown(application));
    try testing.expectEqual(editing, shown(application));
    try testing.expectEqual(region, application.picker.mode.edit);
    try testing.expectEqual(region, application.target.region);
    try testing.expect(!application.active);
    try testing.expectEqualStrings("inactive", application.runtime.icons.get_current_name().?);
    try testing.expect(is_checked(application, .region));
    try testing.expectEqualStrings("Delete the region", label_of(application, .delete));

    click(application, .done);

    try testing.expectEqual(@as(u32, 0), shown(application).count);
    try testing.expect(!application.active);
    try testing.expect(!application.picker.is_open());
    try testing.expect(!is_toolbar_shown(application));

    post(application, .toggle);

    const on_left = Rect{ .height = 400, .width = 1820, .x = 100, .y = 100 };
    const on_right = Rect{ .height = 400, .width = 80, .x = 1920, .y = 100 };

    try expect_dimmed(application, &.{ on_left, on_right }, 0x80000000);
    try testing.expect(application.active);
    try testing.expect(is_checked(application, .region));
    try testing.expect(!is_checked(application, .all));
}

test "an editor the display refuses after a drawing still keeps the drawn region" {
    const application = try open();
    defer close(application);

    post(application, .toggle);
    select(application, .draw);
    touch(application, 0, .{ .pointer_down = drawn.from });
    touch(application, 0, .{ .pointer_move = drawn.to });

    display(application).fault.arm(.surface_show);

    touch(application, 0, .{ .pointer_up = drawn.to });

    const region = Rect{ .height = 300, .width = 400, .x = 100, .y = 100 };

    try testing.expect(!application.picker.is_open());
    try testing.expect(!is_toolbar_shown(application));
    try testing.expectEqual(region, application.target.region);
    try testing.expect(is_checked(application, .region));
    try expect_dimmed(application, &.{region}, 0x80000000);
}

test "escape cancels the drawing and brings back the dimming it replaced" {
    const application = try open();
    defer close(application);

    post(application, .toggle);
    select(application, .draw);

    try testing.expectEqual(@as(u32, 2), shown(application).count);
    try testing.expectEqual(@as(u32, 2), shown(application).interactive);

    touch(application, 1, .{ .key_down = .escape });

    try expect_dimmed(application, &.{ left.rect, right.rect }, 0x80000000);
    try testing.expect(is_checked(application, .all));
}

test "a click without a drag cancels the drawing and leaves the screen light" {
    const application = try open();
    defer close(application);

    select(application, .draw);
    touch(application, 0, .{ .pointer_down = .{ .x = 300, .y = 300 } });
    touch(application, 0, .{ .pointer_up = .{ .x = 302, .y = 301 } });

    try testing.expectEqual(@as(u32, 0), shown(application).count);
    try testing.expect(!application.active);
    try testing.expect(!application.picker.is_open());
}

test "a hotkey during the drawing only cancels the drawing" {
    const application = try open();
    defer close(application);

    const messages = [_]Message{ .toggle, .darker, .lighter };

    for (messages) |message| {
        select(application, .draw);
        post(application, message);

        try testing.expect(!application.picker.is_open());
        try testing.expect(!application.active);
        try testing.expectEqual(Level.default, application.level);
        try testing.expectEqual(@as(u32, 0), shown(application).count);
    }
}

test "the drawing gives up when its timeout fires" {
    const application = try open();
    defer close(application);

    select(application, .draw);
    tick(application, .pick);

    try testing.expect(!application.picker.is_open());
    try testing.expectEqual(@as(u32, 0), shown(application).count);

    tick(application, .pick);

    try testing.expect(!application.picker.is_open());
}

test "a layout change during the drawing cancels it" {
    const application = try open();
    defer close(application);

    select(application, .draw);
    arrange(application, &.{left});
    post(application, .shades);

    try testing.expect(!application.picker.is_open());
    try testing.expectEqual(@as(u32, 0), shown(application).count);
    try testing.expectEqualStrings("", label_of(application, .{ .monitor = 1 }));
}

test "a menu choice during the drawing cancels it and then takes effect" {
    const application = try open();
    defer close(application);

    post(application, .toggle);
    select(application, .draw);
    select(application, .all);

    try testing.expect(!application.picker.is_open());
    try testing.expect(application.active);
    try expect_dimmed(application, &.{ left.rect, right.rect }, 0x80000000);
}

test "unknown codes, menu identifiers, and timers change nothing" {
    const application = try open();
    defer close(application);

    application.on_custom(.{ .code = @fromBackingInt(99) });
    application.on_menu_select(.{ .checked = false, .id = 99_999 });
    application.on_timer_tick(.{ .id = @backingInt(TimerID.pick) + 1, .count = 0 });

    try testing.expect(!application.active);
    try testing.expectEqual(@as(u32, 0), shown(application).count);
}

test "the level and the target survive a restart" {
    var temporary = testing.tmpDir(temporary_options);
    defer temporary.cleanup();

    var buffer: [umbra.limits.path_bytes_max]u8 = undefined;
    const length = try temporary.dir.realPath(testing.io, &buffer);
    var store: Store = undefined;

    try store.init(testing.io, buffer[0..length]);

    const first = try open_with(.{ .logger = null, .store = &store });

    select(first, .{ .monitor = 1 });
    post(first, .darker);

    close(first);

    const second = try open_with(.{ .logger = null, .store = &store });
    defer close(second);

    try testing.expectEqual(@as(u8, 60), second.level.percent);
    try testing.expect(is_checked(second, .{ .monitor = 1 }));
    try testing.expect(!second.active);

    post(second, .toggle);

    try expect_dimmed(second, &.{right.rect}, 0x99000000);
}

test "a level chosen from the level submenu dims at that level and names it on the submenu" {
    const application = try open();
    defer close(application);

    try testing.expectEqualStrings("50%", submenu_label(application));

    post(application, .toggle);
    select(application, .{ .level = .{ .percent = 70 } });

    try expect_dimmed(application, &.{ left.rect, right.rect }, 0xB3000000);
    try testing.expectEqualStrings("70%", submenu_label(application));
    try testing.expectEqualStrings("70%", label_of(application, .{ .level = .{ .percent = 70 } }));
    try testing.expect(is_checked(application, .{ .level = .{ .percent = 70 } }));
}

test "deleting the drawn region lifts its shade and leaves the whole screen for the next toggle" {
    const application = try open();
    defer close(application);

    post(application, .toggle);
    select(application, .draw);
    drag(application, drawn);
    click(application, .done);

    const region = Rect{ .height = 300, .width = 400, .x = 100, .y = 100 };

    try expect_dimmed(application, &.{region}, 0x80000000);
    try testing.expectEqualStrings("Delete the region", label_of(application, .delete));

    select(application, .delete);

    try testing.expectEqual(@as(u32, 0), shown(application).count);
    try testing.expect(!application.active);
    try testing.expect(is_checked(application, .all));
    try testing.expectEqualStrings("", label_of(application, .region));
    try testing.expectEqualStrings("", label_of(application, .edit));
    try testing.expectEqualStrings("", label_of(application, .delete));

    post(application, .toggle);

    try expect_dimmed(application, &.{ left.rect, right.rect }, 0x80000000);
}

test "the editor stays open through a move until done and the tray's move opens it again" {
    const application = try open();
    defer close(application);

    post(application, .toggle);
    select(application, .draw);
    drag(application, drawn);

    const moving = Shown{
        .area = left.rect.area() + right.rect.area() + 400 * 300,
        .count = 3,
        .interactive = 2,
    };

    try testing.expect(application.picker.is_open());
    try testing.expectEqual(moving, shown(application));
    try testing.expect(is_toolbar_shown(application));

    drag(application, .{ .from = .{ .x = 150, .y = 120 }, .to = .{ .x = 1850, .y = 220 } });

    const moved = Rect{ .height = 300, .width = 400, .x = 1800, .y = 200 };
    const on_left = Rect{ .height = 300, .width = 120, .x = 1800, .y = 200 };
    const on_right = Rect{ .height = 300, .width = 280, .x = 1920, .y = 200 };

    try testing.expect(application.picker.is_open());
    try testing.expectEqual(moved, application.target.region);

    click(application, .done);

    try expect_dimmed(application, &.{ on_left, on_right }, 0x80000000);
    try testing.expect(application.active);
    try testing.expect(is_checked(application, .region));
    try testing.expect(!application.picker.is_open());
    try testing.expect(!is_timing_out(application));
    try testing.expect(!is_toolbar_shown(application));

    select(application, .edit);

    const reopened = Shown{
        .area = left.rect.area() + right.rect.area() + moved.area(),
        .count = 4,
        .interactive = 2,
    };

    try testing.expect(application.picker.is_open());
    try testing.expect(is_toolbar_shown(application));
    try testing.expectEqual(reopened, shown(application));
    try testing.expectEqual(moved, application.picker.mode.edit);

    press(application, .escape);

    try expect_dimmed(application, &.{ on_left, on_right }, 0x80000000);
    try testing.expect(!application.picker.is_open());
}

test "the region moves as often as wanted and each drop is saved before the editor closes" {
    var temporary = testing.tmpDir(temporary_options);
    defer temporary.cleanup();

    var buffer: [umbra.limits.path_bytes_max]u8 = undefined;
    const length = try temporary.dir.realPath(testing.io, &buffer);
    var store: Store = undefined;

    try store.init(testing.io, buffer[0..length]);

    const application = try open_with(.{ .logger = null, .store = &store });
    defer close(application);

    post(application, .toggle);
    select(application, .draw);
    drag(application, drawn);

    const placed = try store.load();
    const region = Rect{ .height = 300, .width = 400, .x = 100, .y = 100 };

    try testing.expect(application.picker.is_open());
    try testing.expectEqual(region, placed.target.region);

    const strokes = [_]Stroke{
        .{ .from = .{ .x = 150, .y = 120 }, .to = .{ .x = 350, .y = 220 } },
        .{ .from = .{ .x = 350, .y = 250 }, .to = .{ .x = 1850, .y = 650 } },
    };

    const landings = [_]Rect{
        .{ .height = 300, .width = 400, .x = 300, .y = 200 },
        .{ .height = 300, .width = 400, .x = 1800, .y = 600 },
    };

    for (strokes, landings) |stroke, landing| {
        drag(application, stroke);

        const settings = try store.load();

        try testing.expect(application.picker.is_open());
        try testing.expectEqual(landing, application.target.region);
        try testing.expectEqual(landing, settings.target.region);
    }

    click(application, .done);

    const on_left = Rect{ .height = 300, .width = 120, .x = 1800, .y = 600 };
    const on_right = Rect{ .height = 300, .width = 280, .x = 1920, .y = 600 };

    try expect_dimmed(application, &.{ on_left, on_right }, 0x80000000);
    try testing.expect(!application.picker.is_open());
}

test "an edge or a corner of the drawn region resizes it and saves each new size" {
    var temporary = testing.tmpDir(temporary_options);
    defer temporary.cleanup();

    var buffer: [umbra.limits.path_bytes_max]u8 = undefined;
    const length = try temporary.dir.realPath(testing.io, &buffer);
    var store: Store = undefined;

    try store.init(testing.io, buffer[0..length]);

    const application = try open_with(.{ .logger = null, .store = &store });
    defer close(application);

    post(application, .toggle);
    select(application, .draw);
    drag(application, drawn);

    const strokes = [_]Stroke{
        .{ .from = .{ .x = 500, .y = 250 }, .to = .{ .x = 700, .y = 250 } },
        .{ .from = .{ .x = 95, .y = 95 }, .to = .{ .x = 195, .y = 145 } },
        .{ .from = .{ .x = 700, .y = 300 }, .to = .{ .x = 205, .y = 300 } },
    };

    const sizes = [_]Rect{
        .{ .height = 300, .width = 600, .x = 100, .y = 100 },
        .{ .height = 250, .width = 500, .x = 200, .y = 150 },
        .{ .height = 250, .width = 8, .x = 200, .y = 150 },
    };

    for (strokes, sizes) |stroke, size| {
        drag(application, stroke);

        const settings = try store.load();

        try testing.expect(application.picker.is_open());
        try testing.expectEqual(size, application.target.region);
        try testing.expectEqual(size, settings.target.region);
    }

    click(application, .done);

    try expect_dimmed(application, &.{sizes[2]}, 0x80000000);
    try testing.expect(!application.picker.is_open());
    try testing.expectEqualStrings("Move or resize the region", label_of(application, .edit));
}

test "every way out of the editor keeps the region where it last landed" {
    const Exit = enum { done, enter, escape, layout, timeout };
    const moved = Rect{ .height = 300, .width = 400, .x = 300, .y = 200 };

    for (std.enums.values(Exit)) |way| {
        const application = try open();
        defer close(application);

        post(application, .toggle);
        select(application, .draw);
        drag(application, drawn);
        drag(application, .{ .from = .{ .x = 150, .y = 120 }, .to = .{ .x = 350, .y = 220 } });

        switch (way) {
            .done => click(application, .done),
            .enter => press(application, .enter),
            .escape => press(application, .escape),
            .layout => {
                arrange(application, &.{left});
                post(application, .shades);
            },
            .timeout => tick(application, .pick),
        }

        try testing.expect(!application.picker.is_open());
        try testing.expect(!is_timing_out(application));
        try testing.expect(!is_toolbar_shown(application));
        try testing.expectEqual(moved, application.target.region);
        try expect_dimmed(application, &.{moved}, 0x80000000);
    }
}

test "delete on the toolbar right after drawing or after a move lifts the region" {
    const moves = [_]?Stroke{
        null,
        .{ .from = .{ .x = 150, .y = 120 }, .to = .{ .x = 350, .y = 220 } },
    };

    for (moves) |move| {
        const application = try open();
        defer close(application);

        select(application, .draw);
        drag(application, drawn);

        if (move) |stroke| drag(application, stroke);

        click(application, .delete);

        try testing.expect(!application.picker.is_open());
        try testing.expect(!application.active);
        try testing.expect(application.target == .all);
        try testing.expect(!is_timing_out(application));
        try testing.expectEqual(@as(u32, 0), shown(application).count);
        try testing.expect(!is_toolbar_shown(application));
        try testing.expect(is_checked(application, .all));
        try testing.expectEqualStrings("", label_of(application, .region));
        try testing.expectEqualStrings("", label_of(application, .edit));
        try testing.expectEqualStrings("", label_of(application, .delete));
        try testing.expectEqualStrings("Draw a region", label_of(application, .draw));
    }
}

test "the tray's delete during the editor closes it and removes the region" {
    const application = try open();
    defer close(application);

    select(application, .draw);
    drag(application, drawn);
    select(application, .delete);

    try testing.expect(!application.picker.is_open());
    try testing.expect(application.target == .all);
    try testing.expectEqual(@as(u32, 0), shown(application).count);
    try testing.expect(!is_toolbar_shown(application));
}

test "escape during a drag puts the region back and a hotkey closes the editor where it was" {
    const application = try open();
    defer close(application);

    post(application, .toggle);
    select(application, .draw);
    drag(application, drawn);
    touch(application, 0, .{ .pointer_down = .{ .x = 150, .y = 120 } });
    touch(application, 0, .{ .pointer_move = .{ .x = 900, .y = 600 } });
    touch(application, 1, .{ .key_down = .escape });

    const region = Rect{ .height = 300, .width = 400, .x = 100, .y = 100 };

    try testing.expect(application.picker.is_open());
    try testing.expectEqual(region, application.picker.mode.edit);
    try testing.expectEqual(region, application.target.region);

    touch(application, 1, .{ .key_down = .escape });

    try expect_dimmed(application, &.{region}, 0x80000000);
    try testing.expect(!application.picker.is_open());

    select(application, .edit);
    touch(application, 0, .{ .pointer_down = .{ .x = 150, .y = 120 } });
    touch(application, 0, .{ .pointer_move = .{ .x = 900, .y = 600 } });
    post(application, .darker);

    try expect_dimmed(application, &.{region}, 0x80000000);
    try testing.expect(!application.picker.is_open());
    try testing.expectEqual(Level.default, application.level);
}

test "a move or a delete without a drawn region changes nothing" {
    const application = try open();
    defer close(application);

    post(application, .toggle);
    select(application, .{ .monitor = 1 });
    select(application, .edit);

    try testing.expect(!application.picker.is_open());
    try expect_dimmed(application, &.{right.rect}, 0x80000000);

    select(application, .delete);

    try testing.expect(application.active);
    try testing.expect(is_checked(application, .{ .monitor = 1 }));
    try expect_dimmed(application, &.{right.rect}, 0x80000000);
}

test "a moved region and then its deletion survive a restart" {
    var temporary = testing.tmpDir(temporary_options);
    defer temporary.cleanup();

    var buffer: [umbra.limits.path_bytes_max]u8 = undefined;
    const length = try temporary.dir.realPath(testing.io, &buffer);
    var store: Store = undefined;

    try store.init(testing.io, buffer[0..length]);

    const first = try open_with(.{ .logger = null, .store = &store });

    select(first, .draw);
    drag(first, drawn);
    drag(first, .{ .from = .{ .x = 300, .y = 300 }, .to = .{ .x = 400, .y = 350 } });

    close(first);

    const second = try open_with(.{ .logger = null, .store = &store });
    const moved = Rect{ .height = 300, .width = 400, .x = 200, .y = 150 };

    try testing.expectEqual(moved, second.target.region);
    try testing.expect(is_checked(second, .region));

    select(second, .delete);
    close(second);

    const third = try open_with(.{ .logger = null, .store = &store });
    defer close(third);

    try testing.expect(third.target == .all);
    try testing.expect(is_checked(third, .all));
    try testing.expectEqualStrings("", label_of(third, .region));
}

test "the whole screen dims through the tint where the platform has one and lays no shade" {
    const application = try open();
    defer close(application);

    display(application).set_tint_supported(true);

    post(application, .toggle);

    try testing.expectEqual(@as(?u32, 0x80000000), display(application).tint_of());
    try testing.expectEqual(@as(u32, 0), shown(application).count);

    post(application, .darker);

    try testing.expectEqual(@as(?u32, 0x99000000), display(application).tint_of());

    post(application, .lighter);
    post(application, .lighter);

    try testing.expectEqual(@as(?u32, 0x66000000), display(application).tint_of());
    try testing.expectEqual(@as(u32, 0), display(application).count_of(.shade_create));

    post(application, .toggle);

    try testing.expect(display(application).tint_of() == null);
    try testing.expectEqual(@as(u32, 0), shown(application).count);
}

test "a monitor target trades the tint for a shade and the whole screen trades it back" {
    const application = try open();
    defer close(application);

    display(application).set_tint_supported(true);

    post(application, .toggle);
    select(application, .{ .monitor = 1 });

    try expect_dimmed(application, &.{right.rect}, 0x80000000);
    try testing.expect(display(application).tint_of() == null);

    select(application, .all);

    try testing.expectEqual(@as(?u32, 0x80000000), display(application).tint_of());
    try testing.expectEqual(@as(u32, 0), shown(application).count);
}

test "the only monitor chosen by name tints like the whole screen until a second one arrives" {
    const application = try open();
    defer close(application);

    display(application).set_tint_supported(true);
    post(application, .toggle);

    arrange(application, &.{left});
    post(application, .shades);
    select(application, .{ .monitor = 0 });

    try testing.expect(is_checked(application, .{ .monitor = 0 }));
    try testing.expectEqual(@as(?u32, 0x80000000), display(application).tint_of());
    try testing.expectEqual(@as(u32, 0), shown(application).count);

    arrange(application, &.{ left, right });
    post(application, .shades);

    try expect_dimmed(application, &.{left.rect}, 0x80000000);
    try testing.expect(display(application).tint_of() == null);
}

test "drawing lifts the tint, escape brings it back, and a drawn region dims with shades" {
    const application = try open();
    defer close(application);

    display(application).set_tint_supported(true);

    post(application, .toggle);
    select(application, .draw);

    try testing.expect(display(application).tint_of() == null);
    try testing.expectEqual(@as(u32, 2), shown(application).interactive);

    touch(application, 0, .{ .key_down = .escape });

    try testing.expectEqual(@as(?u32, 0x80000000), display(application).tint_of());
    try testing.expectEqual(@as(u32, 0), shown(application).count);

    select(application, .draw);
    touch(application, 0, .{ .pointer_down = .{ .x = 100, .y = 100 } });
    touch(application, 0, .{ .pointer_up = .{ .x = 500, .y = 400 } });

    try testing.expect(display(application).tint_of() == null);

    press(application, .enter);

    const region = Rect{ .height = 300, .width = 400, .x = 100, .y = 100 };

    try expect_dimmed(application, &.{region}, 0x80000000);
    try testing.expect(display(application).tint_of() == null);
}

test "a tint the platform refuses falls back to shades until it works again" {
    const application = try open();
    defer close(application);

    display(application).set_tint_supported(true);
    display(application).fault.arm(.tint_apply);

    post(application, .toggle);

    try expect_dimmed(application, &.{ left.rect, right.rect }, 0x80000000);
    try testing.expect(display(application).tint_of() == null);

    display(application).fault.disarm();
    post(application, .darker);

    try testing.expectEqual(@as(?u32, 0x99000000), display(application).tint_of());
    try testing.expectEqual(@as(u32, 0), shown(application).count);
}

test "shutting down lifts the tint" {
    const application = try open();
    defer testing.allocator.destroy(application);

    display(application).set_tint_supported(true);

    post(application, .toggle);

    const before = display(application).tint_of();

    application.deinit();

    try testing.expectEqual(@as(?u32, 0x80000000), before);
}

const Probe = struct {
    application: *Application,
    catchers_shown: bool = false,
    dimmed: bool = false,
    done_disarmed_timeout: bool = false,
    draw_kept_timeout: bool = false,
    drop_kept_timeout: bool = false,
    shutdown_closed_drawing: bool = false,
    timeout_armed: bool = false,
    timeout_disarmed_by_escape: bool = false,
    timeout_disarmed_by_tick: bool = false,
    tray_created: bool = false,

    pub fn on_custom(probe: *Probe, custom: Custom) void {
        assert(@backingInt(custom.code) > 0);

        if (custom.code != probe_code) return;

        const application = probe.application;

        probe.tray_created = application.runtime.tray.is_created();

        post(application, .toggle);

        probe.dimmed = shown(application).count == 2;

        select(application, .draw);

        probe.catchers_shown = shown(application).interactive == 2;
        probe.timeout_armed = is_timing_out(application);

        touch(application, 0, .{ .key_down = .escape });

        probe.timeout_disarmed_by_escape = !is_timing_out(application);

        select(application, .draw);
        tick(application, .pick);

        probe.timeout_disarmed_by_tick = !is_timing_out(application) and
            !application.picker.is_open();

        select(application, .draw);
        drag(application, drawn);

        probe.draw_kept_timeout = is_timing_out(application) and is_toolbar_shown(application);

        drag(application, .{ .from = .{ .x = 150, .y = 120 }, .to = .{ .x = 350, .y = 220 } });

        probe.drop_kept_timeout = is_timing_out(application) and application.picker.is_open();

        click(application, .done);

        probe.done_disarmed_timeout = !is_timing_out(application) and
            !application.picker.is_open();

        select(application, .draw);
        application.on_app_shutdown();

        probe.shutdown_closed_drawing = !is_timing_out(application) and
            !application.picker.is_open();
    }
};

test "a full run creates the tray, binds the hotkeys, and times the drawing out" {
    const application = try open();
    defer close(application);

    var probe = Probe{ .application = application };

    try application.runtime.bus.attach(Probe, &probe);

    const posted = application.runtime.post(probe_code);

    try testing.expect(posted);
    try application.run();

    try testing.expectEqual(@as(u8, 5), application.runtime.bus.listener_count());
    try testing.expect(probe.tray_created);
    try testing.expect(probe.dimmed);
    try testing.expect(probe.catchers_shown);
    try testing.expect(probe.timeout_armed);
    try testing.expect(probe.timeout_disarmed_by_escape);
    try testing.expect(probe.timeout_disarmed_by_tick);
    try testing.expect(probe.draw_kept_timeout);
    try testing.expect(probe.drop_kept_timeout);
    try testing.expect(probe.done_disarmed_timeout);
    try testing.expect(probe.shutdown_closed_drawing);
}

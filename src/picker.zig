const std = @import("std");

const kalymma = @import("kalymma");

const ShadeSetType = @import("shade_set.zig").ShadeSetType;
const target_module = @import("target.zig");
const toolbar_module = @import("toolbar.zig");

const assert = std.debug.assert;

const Cursor = kalymma.Cursor;
const Event = kalymma.Event;
const Input = kalymma.Event.Input;
const Key = kalymma.Key;
const Monitor = kalymma.Monitor;
const Point = kalymma.Point;
const Rect = kalymma.Rect;
const Surface = kalymma.Surface;
const Target = target_module.Target;
const ToolbarType = toolbar_module.ToolbarType;

pub fn PickerType(comptime Runtime: type) type {
    return struct {
        anchor: ?Point,
        catchers: ShadeSet,
        color: u32,
        grip: Grip,
        mode: Mode,
        monitors: Monitor.List,
        pointer: ?Point,
        preview: ShadeSet,
        toolbar: Toolbar,

        const Picker = @This();
        const ShadeSet = ShadeSetType(Runtime);
        const Toolbar = ToolbarType(Runtime);

        pub const BeginError = ShadeSet.Error || Toolbar.PresentError;
        pub const InitError = Toolbar.Error;

        pub fn init(picker: *Picker, runtime: *Runtime) InitError!void {
            const toolbar = try Toolbar.init(runtime);

            picker.* = .{
                .anchor = null,
                .catchers = .init(runtime, .{ .interactive = true }),
                .color = 0,
                .grip = .interior,
                .mode = .draw,
                .monitors = .init(),
                .pointer = null,
                .preview = .init(runtime, .{ .interactive = false }),
                .toolbar = toolbar,
            };

            assert(!picker.is_open());
            assert(picker.preview.is_empty());
        }

        pub fn deinit(picker: *Picker) void {
            assert(!picker.is_open());
            assert(picker.preview.is_empty());

            picker.toolbar.deinit();
        }

        pub fn begin(
            picker: *Picker,
            monitors: *const Monitor.List,
            color: u32,
            mode: Mode,
        ) BeginError!void {
            assert(!picker.is_open());
            assert(color >> 24 > 0);
            if (mode == .edit) assert(!mode.edit.is_empty());

            var pieces = Target.Pieces{};
            const everything: Target = .all;

            everything.pieces(monitors.slice(), &pieces);

            picker.anchor = null;
            picker.color = color;
            picker.grip = .interior;
            picker.mode = .draw;
            picker.monitors = monitors.*;
            picker.pointer = null;

            try picker.catchers.set_cursor(.crosshair);
            try picker.catchers.show(pieces.slice(), catcher_color);

            switch (mode) {
                .draw => {},
                .edit => |region| try picker.edit(region),
            }

            assert(picker.catchers.count == pieces.count);
            assert(std.meta.eql(picker.mode, mode));
            if (mode == .draw) assert(picker.preview.is_empty());
        }

        pub fn edit(picker: *Picker, region: Rect) BeginError!void {
            assert(picker.is_open());
            assert(picker.anchor == null);
            assert(picker.mode == .draw);
            assert(!region.is_empty());

            picker.mode = .{ .edit = region };

            try picker.show_preview(region);
            try picker.toolbar.show();
            try picker.aim();

            assert(std.meta.eql(picker.mode.edit, region));
        }

        pub fn end(picker: *Picker) void {
            picker.toolbar.hide();
            picker.preview.clear();
            picker.catchers.clear();

            picker.anchor = null;
            picker.pointer = null;

            assert(!picker.is_open());
            assert(picker.preview.is_empty());
        }

        pub fn handle(picker: *Picker, event: Event) Outcome {
            assert(picker.is_open());
            if (event.input == .monitors_changed) assert(event.source == .display);

            const shade = switch (event.source) {
                .display => return .pending,
                .shade => |shade| shade,
                .surface => |surface| return picker.handle_surface(surface, event.input),
            };

            const index = picker.catchers.index_of(shade) orelse return .pending;

            return picker.handle_catcher(index, event.input);
        }

        pub fn is_open(picker: *const Picker) bool {
            return !picker.catchers.is_empty();
        }

        fn aim(picker: *Picker) ShadeSet.Error!void {
            assert(picker.is_open());
            assert(picker.anchor == null);

            const cursor = switch (picker.mode) {
                .draw => Cursor.crosshair,
                .edit => |region| cursor_at(region, picker.pointer),
            };

            try picker.catchers.set_cursor(cursor);

            assert(picker.catchers.cursor == cursor);
        }

        fn cancel(picker: *Picker) Outcome {
            assert(picker.mode == .edit);
            assert(picker.anchor != null);

            picker.anchor = null;

            picker.show_preview(picker.mode.edit) catch {
                return .closed;
            };

            picker.aim() catch {
                return .closed;
            };

            assert(picker.anchor == null);

            return .pending;
        }

        fn drag(picker: *Picker, point: Point) Outcome {
            assert(is_coordinate(point));

            picker.pointer = point;

            const anchor = picker.anchor orelse return picker.hover();
            const stroke = Stroke{ .from = anchor, .to = point };
            const region = picker.region_of(stroke) orelse return .pending;

            picker.show_preview(region) catch {
                return .closed;
            };

            return .pending;
        }

        fn drop(picker: *Picker, rect: Rect) Outcome {
            assert(picker.mode == .edit);
            assert(rect.width >= 0);
            assert(rect.height >= 0);
            if (picker.grip.is_interior()) assert(rect.area() == picker.mode.edit.area());

            const region = picker.mode.edit;

            picker.show_preview(rect) catch {
                return .closed;
            };

            picker.catchers.set_cursor(cursor_at(rect, picker.pointer)) catch {
                return .closed;
            };

            if (std.meta.eql(rect, region)) return .pending;

            picker.mode = .{ .edit = rect };

            assert(std.meta.eql(picker.mode.edit, rect));

            if (picker.grip.is_interior()) return .{ .moved = rect };
            return .{ .resized = rect };
        }

        fn escape(picker: *Picker) Outcome {
            assert(picker.is_open());

            if (picker.mode == .draw) return .closed;
            if (picker.anchor == null) return .closed;
            return picker.cancel();
        }

        fn handle_catcher(picker: *Picker, index: u8, input: Input) Outcome {
            assert(index < picker.catchers.count);
            assert(input != .monitors_changed);

            const origin = picker.catchers.rect_at(index);

            return switch (input) {
                .key_down => |key| picker.press_key(key),
                .pointer_down => |point| picker.press(locate(origin, point)),
                .pointer_move => |point| picker.drag(locate(origin, point)),
                .pointer_up => |point| picker.release(locate(origin, point)),
                .focus_lost, .monitors_changed, .pointer_leave => .pending,
            };
        }

        fn handle_surface(picker: *Picker, surface: Surface, input: Input) Outcome {
            assert(picker.is_open());
            assert(input != .monitors_changed);

            if (picker.mode != .edit) return .pending;
            if (picker.toolbar.surface != surface) return .pending;
            if (input == .key_down) return picker.press_key(input.key_down);

            const action = picker.toolbar.handle(input) catch {
                return .closed;
            };

            return switch (action) {
                .delete => .deleted,
                .done => .closed,
                .none => .pending,
            };
        }

        fn hover(picker: *Picker) Outcome {
            assert(picker.is_open());
            assert(picker.anchor == null);

            picker.aim() catch {
                return .closed;
            };

            return .pending;
        }

        fn press(picker: *Picker, point: Point) Outcome {
            assert(picker.is_open());
            assert(is_coordinate(point));

            picker.pointer = point;

            switch (picker.mode) {
                .draw => {},
                .edit => |region| picker.grip = grip_at(region, point) orelse return .pending,
            }

            picker.anchor = point;

            if (picker.mode == .edit) {
                picker.catchers.set_cursor(cursor_of(picker.grip)) catch {
                    return .closed;
                };
            }

            assert(picker.anchor != null);

            return .pending;
        }

        fn press_key(picker: *Picker, key: Key) Outcome {
            assert(picker.is_open());
            assert(key.is_valid());

            return switch (key) {
                .escape => picker.escape(),
                .enter => if (picker.mode == .edit) .closed else .pending,
                .down, .left, .other, .right, .space, .up => .pending,
            };
        }

        fn region_of(picker: *const Picker, stroke: Stroke) ?Rect {
            assert(is_coordinate(stroke.from));
            assert(is_coordinate(stroke.to));

            return switch (picker.mode) {
                .draw => span(.{ stroke.from, stroke.to }),
                .edit => |region| reshape(region, picker.grip, stroke),
            };
        }

        fn release(picker: *Picker, point: Point) Outcome {
            assert(is_coordinate(point));

            picker.pointer = point;

            const anchor = picker.anchor orelse return .pending;

            picker.anchor = null;

            const rect = picker.region_of(.{ .from = anchor, .to = point }) orelse return .closed;

            switch (picker.mode) {
                .draw => if (!is_spanned(rect)) return .closed,
                .edit => return picker.drop(rect),
            }

            assert(!rect.is_empty());

            return .{ .picked = rect };
        }

        fn show_preview(picker: *Picker, region: Rect) ShadeSet.Error!void {
            assert(picker.is_open());

            const target = Target{ .region = region };
            var pieces = Target.Pieces{};

            target.pieces(picker.monitors.slice(), &pieces);

            try picker.preview.show(pieces.slice(), picker.color);

            assert(picker.preview.count == pieces.count);
        }
    };
}

pub const Mode = union(enum) {
    draw: void,
    edit: Rect,
};

pub const Outcome = union(enum) {
    closed: void,
    deleted: void,
    moved: Rect,
    pending: void,
    picked: Rect,
    resized: Rect,
};

const Extent = struct {
    length: i32,
    start: i32,
};

const Grip = struct {
    horizontal: Reach,
    vertical: Reach,

    const interior = Grip{ .horizontal = .both, .vertical = .both };

    fn is_interior(grip: Grip) bool {
        return grip.horizontal == .both and grip.vertical == .both;
    }

    fn is_valid(grip: Grip) bool {
        return (grip.horizontal == .both) == (grip.vertical == .both);
    }
};

const Reach = enum {
    both,
    high,
    low,
    none,
};

const Stroke = struct {
    from: Point,
    to: Point,
};

const catcher_color: u32 = 0x26000000;
const coordinate_max: i32 = 1 << 29;
const grip_pixels: i32 = 12;
const offset_max: i32 = 1 << 24;
const span_pixels_min: i32 = 8;

comptime {
    assert(catcher_color >> 24 > 0);
    assert(grip_pixels > 0);
    assert(grip_pixels < offset_max);
    assert(2 * offset_max <= coordinate_max);
    assert(2 * coordinate_max <= std.math.maxInt(i32));
    assert(offset_max > std.math.maxInt(i16));
    assert(span_pixels_min > 0);
    assert(2 * target_module.pieces_max <= kalymma.limits.shade_count_max);
    assert(kalymma.limits.surface_count_max > 0);
}

fn cursor_at(region: Rect, pointer: ?Point) Cursor {
    assert(!region.is_empty());
    if (pointer) |point| assert(is_coordinate(point));

    const point = pointer orelse return .arrow;
    const grip = grip_at(region, point) orelse return .arrow;

    return cursor_of(grip);
}

fn cursor_of(grip: Grip) Cursor {
    assert(grip.is_valid());
    if (grip.horizontal == .none) assert(grip.vertical != .none);

    if (grip.is_interior()) return .move;
    if (grip.horizontal == .none) return .resize_north_south;
    if (grip.vertical == .none) return .resize_east_west;
    if (grip.horizontal == grip.vertical) return .resize_northwest_southeast;
    return .resize_northeast_southwest;
}

fn grip_at(region: Rect, point: Point) ?Grip {
    assert(!region.is_empty());
    assert(is_coordinate(point));

    const horizontal = Extent{ .length = region.width, .start = region.x };
    const vertical = Extent{ .length = region.height, .start = region.y };

    const result = Grip{
        .horizontal = reach_of(horizontal, point.x) orelse return null,
        .vertical = reach_of(vertical, point.y) orelse return null,
    };

    if (result.horizontal != .none) return result;
    if (result.vertical != .none) return result;
    return .interior;
}

fn is_coordinate(point: Point) bool {
    if (point.x < -coordinate_max) return false;
    if (point.x > coordinate_max) return false;
    if (point.y < -coordinate_max) return false;
    return point.y <= coordinate_max;
}

fn is_offset(point: Point) bool {
    if (point.x < -offset_max) return false;
    if (point.x > offset_max) return false;
    if (point.y < -offset_max) return false;
    return point.y <= offset_max;
}

fn is_spanned(rect: Rect) bool {
    assert(rect.width >= 0);
    assert(rect.height >= 0);

    if (rect.width < span_pixels_min) return false;
    return rect.height >= span_pixels_min;
}

fn locate(origin: Rect, point: Point) Point {
    assert(!origin.is_empty());
    assert(is_offset(.{ .x = origin.x, .y = origin.y }));
    assert(is_offset(point));

    const result = Point{ .x = origin.x + point.x, .y = origin.y + point.y };

    assert(is_coordinate(result));

    return result;
}

fn reach_of(extent: Extent, coordinate: i32) ?Reach {
    assert(extent.length > 0);
    assert(@abs(coordinate) <= coordinate_max);

    const inset = @min(grip_pixels, @divFloor(extent.length, 3));
    const offset = @as(i64, coordinate) - extent.start;

    if (offset < -grip_pixels) return null;
    if (offset >= @as(i64, extent.length) + grip_pixels) return null;
    if (offset < inset) return .low;
    if (offset >= extent.length - inset) return .high;
    return .none;
}

fn reshape(region: Rect, grip: Grip, stroke: Stroke) ?Rect {
    assert(!region.is_empty());
    assert(grip.is_valid());
    assert(is_coordinate(stroke.from));
    assert(is_coordinate(stroke.to));

    const offset = Point{ .x = stroke.to.x - stroke.from.x, .y = stroke.to.y - stroke.from.y };
    const horizontal = Extent{ .length = region.width, .start = region.x };
    const vertical = Extent{ .length = region.height, .start = region.y };
    const columns = stretch(horizontal, grip.horizontal, offset.x) orelse return null;
    const rows = stretch(vertical, grip.vertical, offset.y) orelse return null;

    const result = Rect{
        .height = rows.length,
        .width = columns.length,
        .x = columns.start,
        .y = rows.start,
    };

    if (grip.is_interior()) assert(result.area() == region.area());

    return result;
}

fn span(corners: [2]Point) Rect {
    assert(is_coordinate(corners[0]));
    assert(is_coordinate(corners[1]));

    const x = @min(corners[0].x, corners[1].x);
    const y = @min(corners[0].y, corners[1].y);

    const result = Rect{
        .height = @max(corners[0].y, corners[1].y) - y,
        .width = @max(corners[0].x, corners[1].x) - x,
        .x = x,
        .y = y,
    };

    assert(result.height >= 0);
    assert(result.width >= 0);

    return result;
}

fn stretch(extent: Extent, reach: Reach, delta: i32) ?Extent {
    assert(extent.length > 0);
    assert(@abs(delta) <= 2 * coordinate_max);

    var high = @as(i64, extent.start) + extent.length;
    var low: i64 = extent.start;

    switch (reach) {
        .both => {
            high += delta;
            low += delta;
        },
        .high => high = @max(high + delta, low + span_pixels_min),
        .low => low = @min(low + delta, high - span_pixels_min),
        .none => {},
    }

    assert(low < high);

    const result = Extent{
        .length = std.math.cast(i32, high - low) orelse return null,
        .start = std.math.cast(i32, low) orelse return null,
    };

    return result;
}

const testing = std.testing;

const FakeRuntime = kalymma.RuntimeType(kalymma.Fake);
const FakePicker = PickerType(FakeRuntime);

const left = Monitor.init("left", .{ .height = 1080, .width = 1920, .x = 0, .y = 0 });
const right = Monitor.init("right", .{ .height = 1024, .width = 1280, .x = 1920, .y = 0 });
const dim: u32 = 0x80000000;

const Change = struct {
    after: Extent,
    before: Extent,
};

const Fixture = struct {
    picker: FakePicker,
    runtime: FakeRuntime,
};

const GripCase = struct {
    expected: Rect,
    grab: Point,
};

const HoverCase = struct {
    cursor: Cursor,
    point: Point,
};

const hover_cases = [_]HoverCase{
    .{ .cursor = .move, .point = .{ .x = 210, .y = 170 } },
    .{ .cursor = .resize_east_west, .point = .{ .x = 12, .y = 170 } },
    .{ .cursor = .resize_east_west, .point = .{ .x = 415, .y = 170 } },
    .{ .cursor = .resize_north_south, .point = .{ .x = 210, .y = 15 } },
    .{ .cursor = .resize_north_south, .point = .{ .x = 210, .y = 325 } },
    .{ .cursor = .resize_northwest_southeast, .point = .{ .x = 5, .y = 15 } },
    .{ .cursor = .resize_northeast_southwest, .point = .{ .x = 415, .y = 15 } },
    .{ .cursor = .resize_northeast_southwest, .point = .{ .x = 5, .y = 325 } },
    .{ .cursor = .arrow, .point = .{ .x = 600, .y = 600 } },
};

const grip_cases = [_]GripCase{
    .{
        .expected = .{ .height = 280, .width = 370, .x = 130, .y = 120 },
        .grab = .{ .x = 95, .y = 95 },
    },
    .{
        .expected = .{ .height = 280, .width = 400, .x = 100, .y = 120 },
        .grab = .{ .x = 300, .y = 104 },
    },
    .{
        .expected = .{ .height = 280, .width = 430, .x = 100, .y = 120 },
        .grab = .{ .x = 505, .y = 98 },
    },
    .{
        .expected = .{ .height = 300, .width = 430, .x = 100, .y = 100 },
        .grab = .{ .x = 495, .y = 250 },
    },
    .{
        .expected = .{ .height = 320, .width = 430, .x = 100, .y = 100 },
        .grab = .{ .x = 499, .y = 399 },
    },
    .{
        .expected = .{ .height = 320, .width = 400, .x = 100, .y = 100 },
        .grab = .{ .x = 300, .y = 405 },
    },
    .{
        .expected = .{ .height = 320, .width = 370, .x = 130, .y = 100 },
        .grab = .{ .x = 100, .y = 400 },
    },
    .{
        .expected = .{ .height = 300, .width = 370, .x = 130, .y = 100 },
        .grab = .{ .x = 88, .y = 250 },
    },
};

fn open(mode: Mode) !*Fixture {
    if (mode == .edit) assert(!mode.edit.is_empty());

    const fixture = try testing.allocator.create(Fixture);
    errdefer testing.allocator.destroy(fixture);

    try fixture.runtime.init(.{ .fault = null });
    errdefer fixture.runtime.deinit();

    var monitors = Monitor.List.init();

    monitors.append(left);
    monitors.append(right);

    try fixture.picker.init(&fixture.runtime);
    errdefer fixture.picker.deinit();

    fixture.picker.begin(&monitors, dim, mode) catch |err| {
        fixture.picker.end();

        return err;
    };

    assert(fixture.picker.is_open());

    return fixture;
}

fn close(fixture: *Fixture) void {
    fixture.picker.end();
    fixture.picker.deinit();

    assert(!fixture.picker.is_open());
    assert(fixture.runtime.platform.shade_table.count() == 0);
    assert(fixture.runtime.platform.table.count() == 0);

    fixture.runtime.deinit();
    testing.allocator.destroy(fixture);
}

fn feed(picker: *FakePicker, index: u8, input: Event.Input) Outcome {
    assert(index < picker.catchers.count);

    const shade = picker.catchers.slice()[index];
    return picker.handle(.{ .input = input, .source = .{ .shade = shade } });
}

fn feed_toolbar(picker: *FakePicker, input: Event.Input) Outcome {
    assert(picker.mode == .edit);

    const surface = picker.toolbar.surface;
    return picker.handle(.{ .input = input, .source = .{ .surface = surface } });
}

fn click(picker: *FakePicker, button: toolbar_module.Button) Outcome {
    const rect = button.rect();

    const center = Point{
        .x = rect.x + @divFloor(rect.width, 2),
        .y = rect.y + @divFloor(rect.height, 2),
    };

    _ = feed_toolbar(picker, .{ .pointer_down = center });

    return feed_toolbar(picker, .{ .pointer_up = center });
}

fn is_toolbar_shown(picker: *const FakePicker) bool {
    return picker.toolbar.runtime.surface_is_visible(picker.toolbar.surface);
}

fn expect_sides(change: Change, reach: Reach, delta: i32) !void {
    assert(change.before.length > 0);
    assert(change.after.length >= 0);
    assert(@abs(delta) <= 2 * coordinate_max);

    const before = [2]i32{ change.before.start, change.before.start + change.before.length };
    const after = [2]i32{ change.after.start, change.after.start + change.after.length };
    const length = change.after.length;

    switch (reach) {
        .both => {
            try testing.expectEqual(before[0] + delta, after[0]);
            try testing.expectEqual(before[1] + delta, after[1]);
        },
        .high => {
            try testing.expectEqual(before[0], after[0]);
            try testing.expect(length >= span_pixels_min);

            if (after[1] != before[1] + delta) try testing.expectEqual(span_pixels_min, length);
        },
        .low => {
            try testing.expectEqual(before[1], after[1]);
            try testing.expect(length >= span_pixels_min);

            if (after[0] != before[0] + delta) try testing.expectEqual(span_pixels_min, length);
        },
        .none => {
            try testing.expectEqual(before[0], after[0]);
            try testing.expectEqual(before[1], after[1]);
        },
    }
}

fn catcher_cursor(picker: *const FakePicker) !Cursor {
    assert(picker.is_open());
    assert(picker.catchers.count > 0);

    const fake = &picker.catchers.runtime.platform;
    const first = fake.shade_of(picker.catchers.slice()[0]) orelse return error.ShadeMissing;

    for (picker.catchers.slice()) |shade| {
        const slot = fake.shade_of(shade) orelse return error.ShadeMissing;

        try testing.expectEqual(first.cursor, slot.cursor);
    }

    return first.cursor;
}

fn preview_area(picker: *const FakePicker) i64 {
    assert(picker.preview.count <= target_module.pieces_max);

    var result: i64 = 0;

    for (picker.preview.slice()) |shade| {
        const slot = picker.preview.runtime.platform.shade_of(shade) orelse return -1;

        result += slot.rect.area();
    }

    return result;
}

test PickerType {
    const fixture = try open(.draw);
    defer close(fixture);

    const picker = &fixture.picker;
    const down = Event.Input{ .pointer_down = .{ .x = 10, .y = 20 } };
    const up = Event.Input{ .pointer_up = .{ .x = 110, .y = 70 } };
    const expected = Rect{ .height = 50, .width = 100, .x = 10, .y = 20 };

    try testing.expect(picker.is_open());
    try testing.expectEqual(Outcome.pending, feed(picker, 0, down));
    try testing.expectEqual(Outcome{ .picked = expected }, feed(picker, 0, up));
}

test "a drag across two monitors previews and picks the rectangle in screen coordinates" {
    const fixture = try open(.draw);
    defer close(fixture);

    const picker = &fixture.picker;
    const start = Point{ .x = 100, .y = 100 };
    const end = Point{ .x = 2000, .y = 500 };
    const expected = Rect{ .height = 400, .width = 1900, .x = 100, .y = 100 };

    try testing.expectEqual(@as(u8, 2), picker.catchers.count);
    try testing.expectEqual(Outcome.pending, feed(picker, 0, .{ .pointer_down = start }));
    try testing.expectEqual(Outcome.pending, feed(picker, 0, .{ .pointer_move = end }));

    try testing.expectEqual(@as(u8, 2), picker.preview.count);
    try testing.expectEqual(expected.area(), preview_area(picker));

    const outcome = feed(picker, 0, .{ .pointer_up = end });

    try testing.expectEqual(Outcome{ .picked = expected }, outcome);
}

test "a press on the second monitor lands in that monitor's coordinates" {
    const fixture = try open(.draw);
    defer close(fixture);

    const picker = &fixture.picker;

    _ = feed(picker, 1, .{ .pointer_down = .{ .x = 10, .y = 10 } });

    const outcome = feed(picker, 1, .{ .pointer_up = .{ .x = 110, .y = 60 } });
    const expected = Rect{ .height = 50, .width = 100, .x = 1930, .y = 10 };

    try testing.expectEqual(Outcome{ .picked = expected }, outcome);
}

test "a finished drawing turns into an editor that moves the drawn rectangle" {
    const fixture = try open(.draw);
    defer close(fixture);

    const fake = &fixture.runtime.platform;
    const picker = &fixture.picker;
    const drawn = Rect{ .height = 50, .width = 100, .x = 10, .y = 20 };

    _ = feed(picker, 0, .{ .pointer_down = .{ .x = 10, .y = 20 } });
    _ = feed(picker, 0, .{ .pointer_move = .{ .x = 300, .y = 300 } });

    const outcome = feed(picker, 0, .{ .pointer_up = .{ .x = 110, .y = 70 } });

    try testing.expectEqual(Outcome{ .picked = drawn }, outcome);
    try testing.expect(!is_toolbar_shown(picker));

    try picker.edit(drawn);

    const slot = fake.shade_of(picker.preview.slice()[0]) orelse return error.ShadeMissing;

    try testing.expect(is_toolbar_shown(picker));
    try testing.expectEqual(drawn, picker.mode.edit);
    try testing.expectEqual(@as(u8, 2), picker.catchers.count);
    try testing.expectEqual(@as(u8, 1), picker.preview.count);
    try testing.expectEqual(drawn, slot.rect);

    _ = feed(picker, 0, .{ .pointer_down = .{ .x = 60, .y = 45 } });

    const moved = feed(picker, 0, .{ .pointer_up = .{ .x = 160, .y = 245 } });
    const landed = Rect{ .height = 50, .width = 100, .x = 110, .y = 220 };

    try testing.expectEqual(Outcome{ .moved = landed }, moved);
    try testing.expectEqual(Outcome.deleted, click(picker, .delete));
}

test "escape and a click without a drag close the drawing and enter does not" {
    const fixture = try open(.draw);
    defer close(fixture);

    const picker = &fixture.picker;
    const spot = Point{ .x = 50, .y = 50 };

    try testing.expectEqual(Outcome.pending, feed(picker, 0, .{ .key_down = .enter }));
    try testing.expectEqual(Outcome.closed, feed(picker, 1, .{ .key_down = .escape }));

    _ = feed(picker, 0, .{ .pointer_down = spot });

    try testing.expectEqual(Outcome.closed, feed(picker, 0, .{ .pointer_up = spot }));

    _ = feed(picker, 0, .{ .pointer_down = spot });

    const nudge = Point{ .x = 53, .y = 90 };

    try testing.expectEqual(Outcome.closed, feed(picker, 0, .{ .pointer_up = nudge }));
    try testing.expect(!is_toolbar_shown(picker));
}

test "a release without a press and events from foreign sources change nothing" {
    const fixture = try open(.draw);
    defer close(fixture);

    const picker = &fixture.picker;
    const point = Point{ .x = 400, .y = 300 };
    const display = Event{ .input = .{ .monitors_changed = {} }, .source = .{ .display = {} } };
    const stranger: kalymma.Surface = @fromBackingInt(1 << 16);
    const foreign = Event{ .input = .{ .key_down = .escape }, .source = .{ .surface = stranger } };

    try testing.expectEqual(Outcome.pending, feed(picker, 0, .{ .pointer_up = point }));
    try testing.expectEqual(Outcome.pending, feed(picker, 0, .{ .pointer_move = point }));
    try testing.expectEqual(Outcome.pending, picker.handle(display));
    try testing.expectEqual(Outcome.pending, picker.handle(foreign));
    try testing.expect(picker.preview.is_empty());
}

test "ending the pick removes every catcher, preview shade, and toolbar from the display" {
    const fixture = try open(.{ .edit = .{ .height = 300, .width = 400, .x = 100, .y = 100 } });
    defer close(fixture);

    const picker = &fixture.picker;

    _ = feed(picker, 0, .{ .pointer_down = .{ .x = 110, .y = 110 } });
    _ = feed(picker, 0, .{ .pointer_move = .{ .x = 300, .y = 300 } });

    try testing.expect(!picker.preview.is_empty());
    try testing.expect(is_toolbar_shown(picker));

    picker.end();

    try testing.expectEqual(@as(u32, 0), fixture.runtime.platform.shade_table.count());
    try testing.expect(!is_toolbar_shown(picker));
}

test "a move shows the region and its toolbar and carries the region by the point that grabbed it" {
    const region = Rect{ .height = 300, .width = 400, .x = 100, .y = 100 };
    const fixture = try open(.{ .edit = region });
    defer close(fixture);

    const picker = &fixture.picker;
    const grab = Point{ .x = 150, .y = 120 };
    const drop = Point{ .x = 1850, .y = 220 };

    try testing.expectEqual(@as(u8, 1), picker.preview.count);
    try testing.expectEqual(region.area(), preview_area(picker));
    try testing.expect(is_toolbar_shown(picker));
    try testing.expectEqual(Outcome.pending, feed(picker, 0, .{ .pointer_down = grab }));
    try testing.expectEqual(Outcome.pending, feed(picker, 0, .{ .pointer_move = drop }));

    const moved = Rect{ .height = 300, .width = 400, .x = 1800, .y = 200 };

    try testing.expectEqual(@as(u8, 2), picker.preview.count);
    try testing.expectEqual(moved.area(), preview_area(picker));

    const outcome = feed(picker, 0, .{ .pointer_up = drop });

    try testing.expectEqual(Outcome{ .moved = moved }, outcome);
    try testing.expect(picker.is_open());
    try testing.expectEqual(moved, picker.mode.edit);
}

test "a move stays open and grabs the region where it last landed" {
    const region = Rect{ .height = 100, .width = 200, .x = 0, .y = 0 };
    const fixture = try open(.{ .edit = region });
    defer close(fixture);

    const picker = &fixture.picker;

    _ = feed(picker, 0, .{ .pointer_down = .{ .x = 50, .y = 40 } });

    const first = feed(picker, 0, .{ .pointer_up = .{ .x = 550, .y = 340 } });
    const landed = Rect{ .height = 100, .width = 200, .x = 500, .y = 300 };

    try testing.expectEqual(Outcome{ .moved = landed }, first);

    _ = feed(picker, 0, .{ .pointer_down = .{ .x = 10, .y = 10 } });

    try testing.expect(picker.anchor == null);

    _ = feed(picker, 1, .{ .pointer_down = .{ .x = -1400, .y = 320 } });

    const second = feed(picker, 1, .{ .pointer_up = .{ .x = -1300, .y = 420 } });
    const again = Rect{ .height = 100, .width = 200, .x = 600, .y = 400 };

    try testing.expectEqual(Outcome{ .moved = again }, second);
    try testing.expectEqual(again.area(), preview_area(picker));
    try testing.expect(picker.is_open());
}

test "a release away from the last move point still lands the preview where it was dropped" {
    const region = Rect{ .height = 100, .width = 200, .x = 0, .y = 0 };
    const fixture = try open(.{ .edit = region });
    defer close(fixture);

    const fake = &fixture.runtime.platform;
    const picker = &fixture.picker;

    _ = feed(picker, 0, .{ .pointer_down = .{ .x = 50, .y = 40 } });
    _ = feed(picker, 0, .{ .pointer_move = .{ .x = 900, .y = 900 } });

    const outcome = feed(picker, 0, .{ .pointer_up = .{ .x = 80, .y = 80 } });
    const landed = Rect{ .height = 100, .width = 200, .x = 30, .y = 40 };
    const slot = fake.shade_of(picker.preview.slice()[0]) orelse return error.ShadeMissing;

    try testing.expectEqual(Outcome{ .moved = landed }, outcome);
    try testing.expectEqual(@as(u8, 1), picker.preview.count);
    try testing.expectEqual(landed, slot.rect);
}

test "an edit ignores a press beyond its grip band and escape ends a drag before the editor" {
    const region = Rect{ .height = 300, .width = 400, .x = 100, .y = 100 };
    const fixture = try open(.{ .edit = region });
    defer close(fixture);

    const picker = &fixture.picker;
    const outside = Point{ .x = 100 + 400 + grip_pixels, .y = 100 };
    const away = Point{ .x = 900, .y = 700 };

    try testing.expectEqual(Outcome.pending, feed(picker, 0, .{ .pointer_down = outside }));
    try testing.expectEqual(Outcome.pending, feed(picker, 0, .{ .pointer_move = away }));
    try testing.expectEqual(region.area(), preview_area(picker));
    try testing.expectEqual(Outcome.pending, feed(picker, 0, .{ .pointer_up = away }));
    try testing.expect(picker.anchor == null);

    const corner = Point{ .x = 499, .y = 399 };

    _ = feed(picker, 0, .{ .pointer_down = corner });

    try testing.expectEqual(corner, picker.anchor.?);
    try testing.expectEqual(Outcome.pending, feed(picker, 1, .{ .key_down = .escape }));
    try testing.expect(picker.anchor == null);
    try testing.expectEqual(Outcome.closed, feed(picker, 1, .{ .key_down = .escape }));
    try testing.expectEqual(Outcome.closed, feed(picker, 0, .{ .key_down = .enter }));
    try testing.expectEqual(Outcome.pending, feed(picker, 0, .{ .key_down = .space }));
}

test "a click on the region without a drag keeps it where it was and the move open" {
    const region = Rect{ .height = 4, .width = 5, .x = 10, .y = 10 };
    const fixture = try open(.{ .edit = region });
    defer close(fixture);

    const picker = &fixture.picker;
    const inside = Point{ .x = 12, .y = 12 };

    _ = feed(picker, 0, .{ .pointer_down = inside });

    const outcome = feed(picker, 0, .{ .pointer_up = inside });

    try testing.expectEqual(Outcome.pending, outcome);
    try testing.expect(picker.is_open());
    try testing.expectEqual(region, picker.mode.edit);
}

test "the toolbar deletes, finishes, and takes the keys while its hover changes nothing" {
    const region = Rect{ .height = 300, .width = 400, .x = 100, .y = 100 };
    const fixture = try open(.{ .edit = region });
    defer close(fixture);

    const picker = &fixture.picker;
    const hover = Event.Input{ .pointer_move = .{ .x = 4, .y = 4 } };

    try testing.expectEqual(Outcome.pending, feed_toolbar(picker, hover));
    try testing.expectEqual(Outcome.pending, feed_toolbar(picker, .{ .key_down = .left }));
    try testing.expectEqual(Outcome.closed, feed_toolbar(picker, .{ .key_down = .escape }));
    try testing.expectEqual(Outcome.closed, feed_toolbar(picker, .{ .key_down = .enter }));
    try testing.expectEqual(Outcome.deleted, click(picker, .delete));
    try testing.expectEqual(Outcome.closed, click(picker, .done));

    fixture.runtime.platform.fault.arm(.surface_present);

    const lit = Event.Input{ .pointer_move = .{ .x = 250, .y = 20 } };

    try testing.expectEqual(Outcome.closed, feed_toolbar(picker, lit));
}

test "a toolbar the display refuses fails the move and the end leaves nothing behind" {
    const runtime = try testing.allocator.create(FakeRuntime);
    defer testing.allocator.destroy(runtime);

    try runtime.init(.{ .fault = null });
    defer runtime.deinit();

    var monitors = Monitor.List.init();
    var picker: FakePicker = undefined;

    monitors.append(left);

    try picker.init(runtime);
    defer picker.deinit();

    runtime.platform.fault.arm(.surface_show);

    const region = Rect{ .height = 300, .width = 400, .x = 100, .y = 100 };
    const refused = picker.begin(&monitors, dim, .{ .edit = region });

    try testing.expectError(error.SurfaceShowFailed, refused);

    runtime.platform.fault.disarm();
    picker.end();

    try testing.expectEqual(@as(u32, 0), runtime.platform.shade_table.count());
    try testing.expect(!is_toolbar_shown(&picker));
}

test "a picker the display refuses a toolbar for fails to start" {
    const runtime = try testing.allocator.create(FakeRuntime);
    defer testing.allocator.destroy(runtime);

    try runtime.init(.{ .fault = null });
    defer runtime.deinit();

    runtime.platform.fault.arm(.surface_create);

    var picker: FakePicker = undefined;

    try testing.expectError(error.SurfaceCreateFailed, picker.init(runtime));
}

test "each edge and corner resizes the region from the sides it grabbed" {
    const region = Rect{ .height = 300, .width = 400, .x = 100, .y = 100 };

    for (grip_cases) |case| {
        const fixture = try open(.{ .edit = region });
        defer close(fixture);

        const picker = &fixture.picker;
        const to = Point{ .x = case.grab.x + 30, .y = case.grab.y + 20 };

        _ = feed(picker, 0, .{ .pointer_down = case.grab });

        const outcome = feed(picker, 0, .{ .pointer_up = to });

        try testing.expectEqual(Outcome{ .resized = case.expected }, outcome);
        try testing.expectEqual(case.expected, picker.mode.edit);
        try testing.expectEqual(case.expected.area(), preview_area(picker));
    }
}

test "a resize stops at the minimum size instead of turning the region over" {
    const region = Rect{ .height = 300, .width = 400, .x = 100, .y = 100 };
    const fixture = try open(.{ .edit = region });
    defer close(fixture);

    const fake = &fixture.runtime.platform;
    const picker = &fixture.picker;

    _ = feed(picker, 0, .{ .pointer_down = .{ .x = 100, .y = 250 } });
    _ = feed(picker, 0, .{ .pointer_move = .{ .x = 900, .y = 250 } });

    const slot = fake.shade_of(picker.preview.slice()[0]) orelse return error.ShadeMissing;
    const narrow = Rect{ .height = 300, .width = 8, .x = 492, .y = 100 };

    try testing.expectEqual(narrow, slot.rect);

    const outcome = feed(picker, 0, .{ .pointer_up = .{ .x = 900, .y = 250 } });

    try testing.expectEqual(Outcome{ .resized = narrow }, outcome);

    _ = feed(picker, 0, .{ .pointer_down = .{ .x = 500, .y = 250 } });

    const held = feed(picker, 0, .{ .pointer_up = .{ .x = 200, .y = 250 } });

    try testing.expectEqual(Outcome.pending, held);
    try testing.expectEqual(narrow, picker.mode.edit);
}

test "drawing shows a crosshair and editing shows the cursor of the grip under the pointer" {
    const fixture = try open(.draw);
    defer close(fixture);

    const picker = &fixture.picker;

    try testing.expectEqual(Cursor.crosshair, try catcher_cursor(picker));

    _ = feed(picker, 0, .{ .pointer_down = .{ .x = 10, .y = 20 } });
    _ = feed(picker, 0, .{ .pointer_move = .{ .x = 300, .y = 200 } });

    try testing.expectEqual(Cursor.crosshair, try catcher_cursor(picker));

    const outcome = feed(picker, 0, .{ .pointer_up = .{ .x = 410, .y = 320 } });
    const drawn = Rect{ .height = 300, .width = 400, .x = 10, .y = 20 };

    try testing.expectEqual(Outcome{ .picked = drawn }, outcome);

    try picker.edit(drawn);

    try testing.expectEqual(Cursor.resize_northwest_southeast, try catcher_cursor(picker));

    for (hover_cases) |case| {
        _ = feed(picker, 0, .{ .pointer_move = case.point });

        try testing.expectEqual(case.cursor, try catcher_cursor(picker));
    }
}

test "a drag keeps its cursor until release and escape puts the region back without closing" {
    const region = Rect{ .height = 300, .width = 400, .x = 100, .y = 100 };
    const fixture = try open(.{ .edit = region });
    defer close(fixture);

    const picker = &fixture.picker;

    try testing.expectEqual(Cursor.arrow, try catcher_cursor(picker));

    _ = feed(picker, 0, .{ .pointer_move = .{ .x = 500, .y = 250 } });

    try testing.expectEqual(Cursor.resize_east_west, try catcher_cursor(picker));

    _ = feed(picker, 0, .{ .pointer_down = .{ .x = 500, .y = 250 } });
    _ = feed(picker, 0, .{ .pointer_move = .{ .x = 800, .y = 600 } });

    try testing.expectEqual(Cursor.resize_east_west, try catcher_cursor(picker));
    try testing.expectEqual(@as(i64, 700 * 300), preview_area(picker));
    try testing.expectEqual(Outcome.pending, feed(picker, 1, .{ .key_down = .escape }));
    try testing.expectEqual(region.area(), preview_area(picker));
    try testing.expectEqual(region, picker.mode.edit);
    try testing.expectEqual(Cursor.arrow, try catcher_cursor(picker));

    const late = Event.Input{ .pointer_up = .{ .x = 800, .y = 600 } };

    try testing.expectEqual(Outcome.pending, feed(picker, 0, late));

    _ = feed(picker, 0, .{ .pointer_down = .{ .x = 300, .y = 250 } });

    try testing.expectEqual(Cursor.move, try catcher_cursor(picker));

    const outcome = feed(picker, 0, .{ .pointer_up = .{ .x = 350, .y = 250 } });
    const shifted = Rect{ .height = 300, .width = 400, .x = 150, .y = 100 };

    try testing.expectEqual(Outcome{ .moved = shifted }, outcome);
    try testing.expectEqual(Cursor.move, try catcher_cursor(picker));
}

test "a cursor the display refuses ends the editor like any other display failure" {
    const region = Rect{ .height = 300, .width = 400, .x = 100, .y = 100 };
    const fixture = try open(.{ .edit = region });
    defer close(fixture);

    const picker = &fixture.picker;

    fixture.runtime.platform.fault.arm(.shade_set_cursor);

    const inside = Event.Input{ .pointer_move = .{ .x = 300, .y = 250 } };

    try testing.expectEqual(Outcome.closed, feed(picker, 0, inside));
}

test "a press grips the region exactly within its band and moves it only from the inner part" {
    var prng = std.Random.DefaultPrng.init(0x67726970);
    const random = prng.random();
    var interior_count: u32 = 0;
    var none_count: u32 = 0;
    var round: u32 = 0;

    while (round < 4096) : (round += 1) {
        const region = Rect{
            .height = random.intRangeAtMost(i32, 1, 90),
            .width = random.intRangeAtMost(i32, 1, 90),
            .x = random.intRangeAtMost(i32, -100, 100),
            .y = random.intRangeAtMost(i32, -100, 100),
        };

        const point = Point{
            .x = random.intRangeAtMost(i32, -130, 210),
            .y = random.intRangeAtMost(i32, -130, 210),
        };

        const band = Rect{
            .height = region.height + 2 * grip_pixels,
            .width = region.width + 2 * grip_pixels,
            .x = region.x - grip_pixels,
            .y = region.y - grip_pixels,
        };

        const inset_x = @min(grip_pixels, @divFloor(region.width, 3));
        const inset_y = @min(grip_pixels, @divFloor(region.height, 3));

        const core = Rect{
            .height = region.height - 2 * inset_y,
            .width = region.width - 2 * inset_x,
            .x = region.x + inset_x,
            .y = region.y + inset_y,
        };

        const pixel = Rect{ .height = 1, .width = 1, .x = point.x, .y = point.y };
        const grip = grip_at(region, point);
        const interior = if (grip) |held| held.is_interior() else false;

        try testing.expectEqual(!band.intersect(pixel).is_empty(), grip != null);
        try testing.expectEqual(!core.intersect(pixel).is_empty(), interior);

        if (grip == null) none_count += 1;
        if (interior) interior_count += 1;
    }

    try testing.expect(none_count > 0);
    try testing.expect(interior_count > 0);
}

test "a resize moves only the grabbed sides and leaves every other side where it was" {
    var prng = std.Random.DefaultPrng.init(0x726573697a65);
    const random = prng.random();
    const reaches = [_]Reach{ .high, .low, .none };
    var round: u32 = 0;

    while (round < 2048) : (round += 1) {
        const region = Rect{
            .height = random.intRangeAtMost(i32, 1, 4000),
            .width = random.intRangeAtMost(i32, 1, 4000),
            .x = random.intRangeAtMost(i32, -4000, 4000),
            .y = random.intRangeAtMost(i32, -4000, 4000),
        };

        const grip = Grip{
            .horizontal = reaches[random.uintLessThan(u32, reaches.len)],
            .vertical = reaches[random.uintLessThan(u32, reaches.len)],
        };

        const stroke = Stroke{
            .from = .{ .x = random.intRangeAtMost(i32, -8000, 8000), .y = 0 },
            .to = .{ .x = random.intRangeAtMost(i32, -8000, 8000), .y = random.int(i16) },
        };

        const result = reshape(region, grip, stroke) orelse return error.ReshapeOverflow;

        const columns = Change{
            .after = .{ .length = result.width, .start = result.x },
            .before = .{ .length = region.width, .start = region.x },
        };

        const rows = Change{
            .after = .{ .length = result.height, .start = result.y },
            .before = .{ .length = region.height, .start = region.y },
        };

        try expect_sides(columns, grip.horizontal, stroke.to.x - stroke.from.x);
        try expect_sides(rows, grip.vertical, stroke.to.y - stroke.from.y);
    }
}

test "an interior grip carries the grabbed point along and the reverse stroke undoes it" {
    var prng = std.Random.DefaultPrng.init(0x7368696674);
    const random = prng.random();
    var round: u32 = 0;

    while (round < 1024) : (round += 1) {
        const region = Rect{
            .height = random.intRangeAtMost(i32, 1, 4000),
            .width = random.intRangeAtMost(i32, 1, 4000),
            .x = random.intRangeAtMost(i32, -4000, 4000),
            .y = random.intRangeAtMost(i32, -4000, 4000),
        };

        const anchor = Point{
            .x = random.intRangeAtMost(i32, -8000, 8000),
            .y = random.intRangeAtMost(i32, -8000, 8000),
        };

        const point = Point{
            .x = random.intRangeAtMost(i32, -8000, 8000),
            .y = random.intRangeAtMost(i32, -8000, 8000),
        };

        const moved = reshape(region, .interior, .{ .from = anchor, .to = point }) orelse {
            return error.ReshapeOverflow;
        };

        const back = reshape(moved, .interior, .{ .from = point, .to = anchor }) orelse {
            return error.ReshapeOverflow;
        };

        try testing.expectEqual(region, back);
        try testing.expectEqual(anchor.x - region.x, point.x - moved.x);
        try testing.expectEqual(anchor.y - region.y, point.y - moved.y);
    }
}

test "a reshape that would leave the coordinate range is refused" {
    const edge = Rect{ .height = 10, .width = 10, .x = std.math.maxInt(i32) - 20, .y = 0 };
    const floor = Rect{ .height = 10, .width = 10, .x = std.math.minInt(i32) + 20, .y = 0 };
    const grab = Point{ .x = 0, .y = 0 };
    const drop = Point{ .x = 100, .y = 0 };
    const pull = Grip{ .horizontal = .low, .vertical = .none };
    const push = Stroke{ .from = grab, .to = drop };
    const still = Stroke{ .from = drop, .to = drop };
    const back = Stroke{ .from = drop, .to = grab };

    try testing.expectEqual(@as(?Rect, null), reshape(edge, .interior, push));
    try testing.expectEqual(@as(?Rect, edge), reshape(edge, .interior, still));
    try testing.expectEqual(@as(?Rect, null), reshape(floor, pull, back));
}

test "a span is the same from either corner and measures the distance between them" {
    var prng = std.Random.DefaultPrng.init(0x7370616e);
    const random = prng.random();
    var round: u32 = 0;

    while (round < 256) : (round += 1) {
        const start = Point{
            .x = random.intRangeAtMost(i32, -4000, 4000),
            .y = random.intRangeAtMost(i32, -4000, 4000),
        };

        const end = Point{
            .x = random.intRangeAtMost(i32, -4000, 4000),
            .y = random.intRangeAtMost(i32, -4000, 4000),
        };

        const forward = span(.{ start, end });

        try testing.expectEqual(forward, span(.{ end, start }));
        try testing.expectEqual(@as(i32, @intCast(@abs(start.x - end.x))), forward.width);
        try testing.expectEqual(@as(i32, @intCast(@abs(start.y - end.y))), forward.height);
    }
}

test "a coordinate outside its bound is refused and one on the bound is kept" {
    try testing.expect(is_offset(.{ .x = offset_max, .y = -offset_max }));
    try testing.expect(!is_offset(.{ .x = offset_max + 1, .y = 0 }));
    try testing.expect(!is_offset(.{ .x = 0, .y = -offset_max - 1 }));
    try testing.expect(is_coordinate(.{ .x = -coordinate_max, .y = coordinate_max }));
    try testing.expect(!is_coordinate(.{ .x = 0, .y = coordinate_max + 1 }));
    try testing.expect(!is_coordinate(.{ .x = -coordinate_max - 1, .y = 0 }));
}

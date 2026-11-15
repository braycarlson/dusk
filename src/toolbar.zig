const std = @import("std");

const kalymma = @import("kalymma");

const assert = std.debug.assert;

const Input = kalymma.Event.Input;
const Point = kalymma.Point;
const Rect = kalymma.Rect;
const Surface = kalymma.Surface;

pub fn ToolbarType(comptime Runtime: type) type {
    return struct {
        hovered: ?Button,
        pressed: ?Button,
        runtime: *Runtime,
        surface: Surface,

        const Toolbar = @This();

        pub const Error = kalymma.Error;
        pub const PresentError = kalymma.PlatformError || kalymma.RequestError;

        pub fn init(runtime: *Runtime) Error!Toolbar {
            const surface = try runtime.surface_create(.{
                .anchor = .top_right,
                .height = height,
                .margin = margin,
                .name = name,
                .width = width,
            });

            const result = Toolbar{
                .hovered = null,
                .pressed = null,
                .runtime = runtime,
                .surface = surface,
            };

            assert(!runtime.surface_is_visible(result.surface));
            assert(runtime.surface_frame(result.surface).len == pixel_count);

            return result;
        }

        pub fn deinit(toolbar: *const Toolbar) void {
            assert(toolbar.runtime.surface_frame(toolbar.surface).len == pixel_count);

            toolbar.runtime.surface_destroy(toolbar.surface);

            assert(!toolbar.runtime.surface_is_visible(toolbar.surface));
        }

        pub fn handle(toolbar: *Toolbar, input: Input) PresentError!Action {
            assert(input != .key_down);
            assert(input != .monitors_changed);

            switch (input) {
                .pointer_down => |point| toolbar.pressed = button_at(point),
                .pointer_leave => try toolbar.hover(null),
                .pointer_move => |point| try toolbar.hover(button_at(point)),
                .pointer_up => |point| return toolbar.release(point),
                .focus_lost, .key_down, .monitors_changed => {},
            }

            return .none;
        }

        pub fn hide(toolbar: *Toolbar) void {
            toolbar.runtime.surface_hide(toolbar.surface);

            toolbar.hovered = null;
            toolbar.pressed = null;

            assert(!toolbar.runtime.surface_is_visible(toolbar.surface));
        }

        pub fn show(toolbar: *Toolbar) PresentError!void {
            toolbar.hovered = null;
            toolbar.pressed = null;

            paint(toolbar.runtime.surface_frame(toolbar.surface), null);

            try toolbar.runtime.surface_show(toolbar.surface);
            errdefer toolbar.runtime.surface_hide(toolbar.surface);

            try toolbar.runtime.surface_present(toolbar.surface);

            assert(toolbar.runtime.surface_is_visible(toolbar.surface));
        }

        fn hover(toolbar: *Toolbar, button: ?Button) PresentError!void {
            if (toolbar.hovered == button) return;

            toolbar.hovered = button;

            paint(toolbar.runtime.surface_frame(toolbar.surface), button);

            try toolbar.runtime.surface_present(toolbar.surface);

            assert(toolbar.hovered == button);
        }

        fn release(toolbar: *Toolbar, point: Point) Action {
            assert(is_coordinate(point));

            const pressed = toolbar.pressed orelse return .none;

            toolbar.pressed = null;

            if (button_at(point) != pressed) return .none;

            return switch (pressed) {
                .delete => .delete,
                .done => .done,
            };
        }
    };
}

pub const Action = enum {
    delete,
    done,
    none,
};

pub const Button = enum {
    delete,
    done,

    pub fn rect(button: Button) Rect {
        const result = switch (button) {
            .delete => rect_delete,
            .done => rect_done,
        };

        assert(!result.is_empty());

        return result;
    }
};

const coordinate_max: i32 = 1 << 24;
const height: u32 = 52;
const hover_weight: u32 = 31;
const margin: u32 = 12;
const name = "Dusk";
const panel: u32 = 0xFF1A1A1A;
const pixel_count: u32 = width * height;
const pixels = @embedFile("toolbar.rgba");
const rect_delete = Rect{ .height = 32, .width = 82, .x = 238, .y = 10 };
const rect_done = Rect{ .height = 32, .width = 82, .x = 328, .y = 10 };
const width: u32 = 420;

comptime {
    assert(pixels.len == pixel_count * 4);
    assert(width <= kalymma.limits.width_pixels_max);
    assert(height <= kalymma.limits.height_pixels_max);
    assert(margin <= kalymma.limits.margin_pixels_max);
    assert(name.len <= kalymma.limits.name_bytes_max);
    assert(coordinate_max > std.math.maxInt(i16));
    assert(hover_weight > 0);
    assert(hover_weight < 0xFF);
    assert(panel >> 24 == 0xFF);
    assert(rect_delete.x + rect_delete.width < rect_done.x);
    assert(rect_done.x + rect_done.width < width);
    assert(rect_delete.y + rect_delete.height < height);
    assert(rect_done.y + rect_done.height < height);
}

fn button_at(point: Point) ?Button {
    assert(is_coordinate(point));

    for (std.enums.values(Button)) |button| {
        const rect = button.rect();
        if (point.x < rect.x) continue;
        if (point.y < rect.y) continue;
        if (point.x >= rect.x + rect.width) continue;
        if (point.y >= rect.y + rect.height) continue;

        return button;
    }

    return null;
}

fn color_at(index: u32) u32 {
    assert(index < pixel_count);

    const rgba = pixels[index * 4 ..][0..4];
    const alpha: u32 = rgba[3];
    const red = scale(rgba[0], alpha);
    const green = scale(rgba[1], alpha);
    const blue = scale(rgba[2], alpha);
    const result = (alpha << 24) | (red << 16) | (green << 8) | blue;

    assert(is_premultiplied(result));

    return result;
}

fn is_coordinate(point: Point) bool {
    if (point.x < -coordinate_max) return false;
    if (point.x > coordinate_max) return false;
    if (point.y < -coordinate_max) return false;
    return point.y <= coordinate_max;
}

fn is_premultiplied(color: u32) bool {
    if (((color >> 16) & 0xFF) > (color >> 24)) return false;
    if (((color >> 8) & 0xFF) > (color >> 24)) return false;
    return (color & 0xFF) <= (color >> 24);
}

fn lift(frame: []u32, button: Button) void {
    assert(frame.len == pixel_count);
    assert(!button.rect().is_empty());

    for (frame, 0..) |*pixel, position| {
        if (pixel.* == panel) continue;

        const index: u32 = @intCast(position);
        if (button_at(point_of(index)) != button) continue;

        pixel.* = lighten(pixel.*);
    }
}

fn lighten(color: u32) u32 {
    assert(is_premultiplied(color));

    const alpha = color >> 24;
    const shifts = [_]u5{ 16, 8, 0 };
    var result = alpha << 24;

    for (shifts) |shift| {
        const channel = (color >> shift) & 0xFF;
        const lifted = channel + @divFloor((alpha - channel) * hover_weight, 0xFF);

        result |= lifted << shift;
    }

    assert(is_premultiplied(result));
    assert(result >> 24 == alpha);

    return result;
}

fn paint(frame: []u32, hovered: ?Button) void {
    assert(frame.len == pixel_count);

    for (frame, 0..) |*pixel, position| {
        pixel.* = color_at(@intCast(position));
    }

    const button = hovered orelse return;

    lift(frame, button);
}

fn point_of(index: u32) Point {
    assert(index < pixel_count);

    const result = Point{
        .x = @intCast(@mod(index, width)),
        .y = @intCast(@divFloor(index, width)),
    };

    assert(result.x < width);
    assert(result.y < height);

    return result;
}

fn scale(channel: u8, alpha: u32) u32 {
    assert(alpha <= 0xFF);

    const result = @divFloor(@as(u32, channel) * alpha + 127, 0xFF);

    assert(result <= alpha);

    return result;
}

const testing = std.testing;

const FakeRuntime = kalymma.RuntimeType(kalymma.Fake);
const FakeToolbar = ToolbarType(FakeRuntime);

const fill_delete: u32 = 0xFF2A2A2A;
const fill_done: u32 = 0xFF3B82F6;

fn open() !*FakeRuntime {
    const runtime = try testing.allocator.create(FakeRuntime);
    errdefer testing.allocator.destroy(runtime);

    try runtime.init(.{ .fault = null });

    assert(runtime.platform.table.count() == 0);

    return runtime;
}

fn close(runtime: *FakeRuntime) void {
    runtime.deinit();
    testing.allocator.destroy(runtime);
}

fn open_shown(runtime: *FakeRuntime) !FakeToolbar {
    var result = try FakeToolbar.init(runtime);

    try result.show();

    assert(runtime.surface_is_visible(result.surface));

    return result;
}

fn center_of(button: Button) Point {
    const rect = button.rect();

    return .{ .x = rect.x + @divFloor(rect.width, 2), .y = rect.y + @divFloor(rect.height, 2) };
}

fn index_of(point: Point) u32 {
    assert(point.x >= 0);
    assert(point.y >= 0);

    const result = @as(u32, @intCast(point.y)) * width + @as(u32, @intCast(point.x));

    assert(result < pixel_count);

    return result;
}

test ToolbarType {
    const runtime = try open();
    defer close(runtime);

    var toolbar = try open_shown(runtime);
    const done = center_of(.done);

    try testing.expect(runtime.surface_is_visible(toolbar.surface));
    try testing.expectEqual(Action.none, try toolbar.handle(.{ .pointer_down = done }));
    try testing.expectEqual(Action.done, try toolbar.handle(.{ .pointer_up = done }));

    toolbar.hide();

    try testing.expect(!runtime.surface_is_visible(toolbar.surface));

    toolbar.deinit();

    try testing.expect(runtime.platform.table.resolve(toolbar.surface) == null);
}

test "a button fires only when the press and the release both land on it" {
    const runtime = try open();
    defer close(runtime);

    var toolbar = try open_shown(runtime);
    defer toolbar.deinit();

    const delete = center_of(.delete);
    const done = center_of(.done);
    const gap = Point{ .x = rect_delete.x + rect_delete.width + 2, .y = done.y };

    try testing.expectEqual(Action.none, try toolbar.handle(.{ .pointer_up = delete }));

    _ = try toolbar.handle(.{ .pointer_down = delete });

    try testing.expectEqual(Action.none, try toolbar.handle(.{ .pointer_up = done }));

    _ = try toolbar.handle(.{ .pointer_down = done });

    try testing.expectEqual(Action.none, try toolbar.handle(.{ .pointer_up = gap }));

    _ = try toolbar.handle(.{ .pointer_down = gap });

    try testing.expectEqual(Action.none, try toolbar.handle(.{ .pointer_up = gap }));

    _ = try toolbar.handle(.{ .pointer_down = delete });

    try testing.expectEqual(Action.delete, try toolbar.handle(.{ .pointer_up = delete }));
    try testing.expectEqual(Action.none, try toolbar.handle(.{ .pointer_up = delete }));
}

test "the image paints each button exactly over its hit area" {
    for (std.enums.values(Button)) |button| {
        const rect = button.rect();
        const fill = if (button == .delete) fill_delete else fill_done;
        const middle = rect.y + @divFloor(rect.height, 2);
        const center = rect.x + @divFloor(rect.width, 2);

        const inside = [_]Point{
            .{ .x = rect.x, .y = middle },
            .{ .x = rect.x + rect.width - 1, .y = middle },
            .{ .x = center, .y = rect.y },
            .{ .x = center, .y = rect.y + rect.height - 1 },
        };

        const outside = [_]Point{
            .{ .x = rect.x - 1, .y = middle },
            .{ .x = rect.x + rect.width, .y = middle },
            .{ .x = center, .y = rect.y - 1 },
            .{ .x = center, .y = rect.y + rect.height },
            .{ .x = rect.x, .y = rect.y },
        };

        for (inside) |point| {
            try testing.expectEqual(fill, color_at(index_of(point)));
            try testing.expectEqual(@as(?Button, button), button_at(point));
        }

        for (outside) |point| {
            try testing.expectEqual(panel, color_at(index_of(point)));
        }
    }
}

test "hovering lifts only the hovered button and leaving restores the image" {
    const runtime = try open();
    defer close(runtime);

    var toolbar = try open_shown(runtime);
    defer toolbar.deinit();

    const frame = runtime.surface_frame(toolbar.surface);
    var lifted_count: u32 = 0;

    _ = try toolbar.handle(.{ .pointer_move = center_of(.done) });

    for (frame, 0..) |pixel, position| {
        const index: u32 = @intCast(position);
        const color = color_at(index);
        const owner = button_at(point_of(index));

        if (owner == .done) {
            if (color != panel) {
                try testing.expectEqual(lighten(color), pixel);

                lifted_count += 1;

                continue;
            }
        }

        try testing.expectEqual(color, pixel);
    }

    const edge = Point{ .x = rect_done.x, .y = rect_done.y + @divFloor(rect_done.height, 2) };

    try testing.expect(lifted_count > 2000);
    try testing.expectEqual(@as(u32, 0xFF5291F7), frame[index_of(edge)]);

    _ = try toolbar.handle(.{ .pointer_leave = {} });

    for (frame, 0..) |pixel, position| {
        try testing.expectEqual(color_at(@intCast(position)), pixel);
    }
}

test "a hover only repaints when the button under the pointer changes" {
    const runtime = try open();
    defer close(runtime);

    var toolbar = try open_shown(runtime);
    defer toolbar.deinit();

    const delete = center_of(.delete);

    try testing.expectEqual(@as(u32, 1), runtime.platform.count_of(.surface_present));

    _ = try toolbar.handle(.{ .pointer_move = .{ .x = 4, .y = 4 } });
    _ = try toolbar.handle(.{ .pointer_move = delete });
    _ = try toolbar.handle(.{ .pointer_move = .{ .x = delete.x + 1, .y = delete.y } });
    _ = try toolbar.handle(.{ .pointer_leave = {} });
    _ = try toolbar.handle(.{ .pointer_leave = {} });

    try testing.expectEqual(@as(u32, 3), runtime.platform.count_of(.surface_present));

    runtime.platform.fault.arm(.surface_present);

    const refused = toolbar.handle(.{ .pointer_move = delete });

    try testing.expectError(error.SurfacePresentFailed, refused);
}

test "showing again starts from the plain image and a refused show stays hidden" {
    const runtime = try open();
    defer close(runtime);

    var toolbar = try open_shown(runtime);
    defer toolbar.deinit();

    _ = try toolbar.handle(.{ .pointer_move = center_of(.delete) });
    _ = try toolbar.handle(.{ .pointer_down = center_of(.delete) });

    toolbar.hide();

    try toolbar.show();

    const frame = runtime.surface_frame(toolbar.surface);

    try testing.expect(toolbar.hovered == null);
    try testing.expect(toolbar.pressed == null);
    try testing.expectEqual(fill_delete, frame[index_of(.{ .x = rect_delete.x, .y = 26 })]);

    toolbar.hide();
    runtime.platform.fault.arm(.surface_present);

    try testing.expectError(error.SurfacePresentFailed, toolbar.show());
    try testing.expect(!runtime.surface_is_visible(toolbar.surface));

    runtime.platform.fault.arm(.surface_show);

    try testing.expectError(error.SurfaceShowFailed, toolbar.show());
    try testing.expect(!runtime.surface_is_visible(toolbar.surface));
}

test "a toolbar the display refuses to create reserves nothing" {
    const runtime = try open();
    defer close(runtime);

    runtime.platform.fault.arm(.surface_create);

    try testing.expectError(error.SurfaceCreateFailed, FakeToolbar.init(runtime));
    try testing.expectEqual(@as(u32, 0), runtime.platform.table.count());
}

test "every pixel of the image premultiplies to channels at or below its alpha" {
    var opaque_count: u32 = 0;
    var index: u32 = 0;

    while (index < pixel_count) : (index += 1) {
        const color = color_at(index);
        const rgba = pixels[index * 4 ..][0..4];

        try testing.expect(is_premultiplied(color));
        try testing.expectEqual(@as(u32, rgba[3]), color >> 24);

        if (rgba[3] == 0xFF) {
            const straight = (@as(u32, 0xFF) << 24) | (@as(u32, rgba[0]) << 16) |
                (@as(u32, rgba[1]) << 8) | rgba[2];

            try testing.expectEqual(straight, color);

            opaque_count += 1;
        }
    }

    try testing.expect(opaque_count > pixel_count - 200);
    try testing.expectEqual(@as(u32, 0), color_at(0));
    try testing.expectEqual(panel, color_at(index_of(.{ .x = 200, .y = 6 })));
}

test "scaling a channel rounds to the nearest of its exact product with the alpha" {
    var alpha: u32 = 0;

    while (alpha <= 0xFF) : (alpha += 1) {
        var channel: u32 = 0;

        while (channel <= 0xFF) : (channel += 1) {
            const scaled = scale(@intCast(channel), alpha);
            const exact = @as(f64, @floatFromInt(channel * alpha)) / 255.0;
            const distance = @abs(@as(f64, @floatFromInt(scaled)) - exact);

            try testing.expect(distance <= 0.5);
        }

        try testing.expectEqual(alpha, scale(0xFF, alpha));
        try testing.expectEqual(@as(u32, 0), scale(0, alpha));
    }
}

test "lifting moves each channel toward its alpha and never past it" {
    var alpha: u32 = 0;

    while (alpha <= 0xFF) : (alpha += 1) {
        var channel: u32 = 0;

        while (channel <= alpha) : (channel += 1) {
            const color = (alpha << 24) | (channel << 8);
            const lifted = (lighten(color) >> 8) & 0xFF;

            try testing.expect(lifted >= channel);
            try testing.expect(lifted <= alpha);

            if (alpha - channel >= 9) try testing.expect(lifted > channel);
        }
    }

    try testing.expectEqual(@as(u32, 0xFFFFFFFF), lighten(0xFFFFFFFF));
    try testing.expectEqual(@as(u32, 0xFF5291F7), lighten(fill_done));
}

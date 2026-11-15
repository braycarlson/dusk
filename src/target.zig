const std = @import("std");

const kalymma = @import("kalymma");

const assert = std.debug.assert;

const Monitor = kalymma.Monitor;
const Rect = kalymma.Rect;

pub const Target = union(enum) {
    all: void,
    monitor: Monitor,
    region: Rect,

    pub const Pieces = struct {
        count: u8 = 0,
        rects: [pieces_max]Rect = undefined,

        fn append(list: *Pieces, rect: Rect) void {
            assert(list.count < pieces_max);
            assert(!rect.is_empty());

            list.rects[list.count] = rect;
            list.count += 1;
        }

        pub fn covers(list: *const Pieces, monitors: []const Monitor) bool {
            assert(list.count <= pieces_max);
            assert(monitors.len <= pieces_max);

            if (list.count != monitors.len) {
                return false;
            }

            for (list.slice(), monitors) |rect, *monitor| {
                if (!std.meta.eql(rect, monitor.rect)) {
                    return false;
                }
            }

            return true;
        }

        pub fn slice(list: *const Pieces) []const Rect {
            assert(list.count <= pieces_max);

            return list.rects[0..list.count];
        }
    };

    pub fn is_monitor(target: *const Target, monitor: *const Monitor) bool {
        const chosen = switch (target.*) {
            .monitor => |*value| value,
            .all, .region => return false,
        };

        assert(chosen.get_name().len > 0);

        return std.mem.eql(u8, chosen.get_name(), monitor.get_name());
    }

    pub fn pieces(target: *const Target, monitors: []const Monitor, result: *Pieces) void {
        assert(monitors.len <= pieces_max);

        result.* = .{};

        for (monitors) |*monitor| {
            const rect = target.piece_of(monitor);

            if (!rect.is_empty()) {
                result.append(rect);
            }
        }

        assert(result.count <= monitors.len);
    }

    fn piece_of(target: *const Target, monitor: *const Monitor) Rect {
        const result = switch (target.*) {
            .all => monitor.rect,
            .monitor => if (target.is_monitor(monitor)) monitor.rect else Rect{},
            .region => |region| region.intersect(monitor.rect),
        };

        if (!result.is_empty()) assert(result.area() <= monitor.rect.area());

        return result;
    }
};

pub const pieces_max: u8 = kalymma.limits.monitor_count_max;

comptime {
    assert(pieces_max > 0);
}

const testing = std.testing;

const layout = [_]Monitor{
    Monitor.init("left", .{ .height = 20, .width = 30, .x = 0, .y = 0 }),
    Monitor.init("right", .{ .height = 25, .width = 20, .x = 30, .y = 0 }),
    Monitor.init("below", .{ .height = 10, .width = 15, .x = -15, .y = 5 }),
};

fn covered_pixel_count(region: Rect) i64 {
    assert(region.height > 0);
    assert(region.width > 0);

    var result: i64 = 0;
    var y = region.y;

    while (y < region.y + region.height) : (y += 1) {
        var x = region.x;

        while (x < region.x + region.width) : (x += 1) {
            if (is_on_screen(.{ .height = 1, .width = 1, .x = x, .y = y })) result += 1;
        }
    }

    assert(result <= region.area());

    return result;
}

fn is_on_screen(pixel: Rect) bool {
    assert(pixel.height == 1);
    assert(pixel.width == 1);

    for (&layout) |*monitor| {
        const rect = monitor.rect;
        if (pixel.x < rect.x) continue;
        if (pixel.x >= rect.x + rect.width) continue;
        if (pixel.y < rect.y) continue;
        if (pixel.y >= rect.y + rect.height) continue;

        return true;
    }

    return false;
}

fn total_area(list: *const Target.Pieces) i64 {
    assert(list.count <= pieces_max);

    var result: i64 = 0;

    for (list.slice()) |rect| {
        result += rect.area();
    }

    assert(result >= 0);

    return result;
}

test Target {
    const target = Target{ .region = .{ .height = 10, .width = 20, .x = 20, .y = 0 } };
    var found = Target.Pieces{};

    target.pieces(&layout, &found);

    try testing.expectEqual(@as(u8, 2), found.count);
    try testing.expectEqual(Rect{ .height = 10, .width = 10, .x = 20, .y = 0 }, found.slice()[0]);
    try testing.expectEqual(Rect{ .height = 10, .width = 10, .x = 30, .y = 0 }, found.slice()[1]);
    try testing.expect(!found.covers(&layout));
}

test "the whole screen covers every monitor" {
    var found = Target.Pieces{};
    const target: Target = .all;

    target.pieces(&layout, &found);

    try testing.expectEqual(@as(u8, layout.len), found.count);

    for (found.slice(), &layout) |rect, *monitor| {
        try testing.expectEqual(monitor.rect, rect);
    }
}

test "a named monitor covers only itself and nothing once it is gone" {
    var found = Target.Pieces{};
    const target = Target{ .monitor = Monitor.init("right", .{}) };

    target.pieces(&layout, &found);

    try testing.expectEqual(@as(u8, 1), found.count);
    try testing.expectEqual(layout[1].rect, found.slice()[0]);
    try testing.expect(target.is_monitor(&layout[1]));
    try testing.expect(!target.is_monitor(&layout[0]));

    target.pieces(layout[0..1], &found);

    try testing.expectEqual(@as(u8, 0), found.count);
}

test "a region split across monitors covers exactly the pixels a brute force count finds" {
    var prng = std.Random.DefaultPrng.init(0x6475736b);
    const random = prng.random();
    var round: u32 = 0;

    while (round < 256) : (round += 1) {
        const region = Rect{
            .height = random.intRangeAtMost(i32, 1, 40),
            .width = random.intRangeAtMost(i32, 1, 70),
            .x = random.intRangeAtMost(i32, -25, 55),
            .y = random.intRangeAtMost(i32, -10, 30),
        };

        var found = Target.Pieces{};
        const target = Target{ .region = region };

        target.pieces(&layout, &found);

        try testing.expectEqual(covered_pixel_count(region), total_area(&found));

        for (found.slice()) |rect| {
            try testing.expectEqual(rect, rect.intersect(region));
        }
    }
}

test "the whole screen and the only monitor cover the screen, and one of several does not" {
    var found = Target.Pieces{};
    const whole: Target = .all;
    const named = Target{ .monitor = Monitor.init("left", .{}) };

    whole.pieces(&layout, &found);

    try testing.expect(found.covers(&layout));

    named.pieces(&layout, &found);

    try testing.expect(!found.covers(&layout));

    named.pieces(layout[0..1], &found);

    try testing.expect(found.covers(layout[0..1]));

    whole.pieces(&.{}, &found);

    try testing.expect(found.covers(&.{}));
}

test "pieces cover the screen exactly when a brute force count finds every monitor pixel" {
    var prng = std.Random.DefaultPrng.init(0x636f76657273);
    const random = prng.random();
    const everything = Rect{ .height = 60, .width = 120, .x = -40, .y = -20 };
    const screen_pixel_count = covered_pixel_count(everything);
    var covering_count: u32 = 0;
    var round: u32 = 0;

    while (round < 512) : (round += 1) {
        const region = Rect{
            .height = random.intRangeAtMost(i32, 1, 40),
            .width = random.intRangeAtMost(i32, 1, 80),
            .x = random.intRangeAtMost(i32, -25, 5),
            .y = random.intRangeAtMost(i32, -10, 5),
        };

        var found = Target.Pieces{};
        const target = Target{ .region = region };
        const expected = covered_pixel_count(region) == screen_pixel_count;

        target.pieces(&layout, &found);

        try testing.expectEqual(expected, found.covers(&layout));

        if (expected) covering_count += 1;
    }

    try testing.expect(covering_count > 0);
}

test "a region away from every monitor covers nothing" {
    var found = Target.Pieces{};
    const target = Target{ .region = .{ .height = 5, .width = 5, .x = 100, .y = 100 } };

    target.pieces(&layout, &found);

    try testing.expectEqual(@as(u8, 0), found.count);
}

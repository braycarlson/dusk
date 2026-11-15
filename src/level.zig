const std = @import("std");

const assert = std.debug.assert;

pub const Level = struct {
    percent: u8,

    pub const count: u8 = @divExact(percent_max - percent_min, percent_step) + 1;
    pub const default: Level = .{ .percent = 50 };
    pub const percent_max: u8 = 90;
    pub const percent_min: u8 = 10;
    const percent_step: u8 = 10;

    const percent_labels = label_table("{d}%");

    comptime {
        assert(percent_min > 0);
        assert(percent_max < 100);
        assert(percent_min < percent_max);
        assert(@mod(percent_max - percent_min, percent_step) == 0);
        assert(@mod(default.percent - percent_min, percent_step) == 0);
        assert(default.percent >= percent_min);
        assert(default.percent <= percent_max);
    }

    pub fn darker(level: Level) Level {
        assert(level.is_valid());

        const result = from_index(@min(level.to_index() + 1, count - 1));

        assert(result.percent >= level.percent);
        assert(result.percent <= level.percent + percent_step);

        return result;
    }

    pub fn from_index(index: u8) Level {
        assert(index < count);

        const result = Level{ .percent = percent_min + index * percent_step };

        assert(result.is_valid());

        return result;
    }

    pub fn from_percent(percent: u8) Level {
        assert(percent >= percent_min);
        assert(percent <= percent_max);

        const steps = @divFloor(percent - percent_min + @divExact(percent_step, 2), percent_step);
        const result = from_index(steps);

        assert(result.is_valid());
        assert(@abs(@as(i16, result.percent) - percent) <= @divExact(percent_step, 2));

        return result;
    }

    pub fn is_valid(level: Level) bool {
        if (level.percent < percent_min) return false;
        if (level.percent > percent_max) return false;
        return @mod(level.percent - percent_min, percent_step) == 0;
    }

    pub fn lighter(level: Level) Level {
        assert(level.is_valid());

        const index = level.to_index();
        const result = from_index(if (index == 0) 0 else index - 1);

        assert(result.percent <= level.percent);
        assert(result.percent + percent_step >= level.percent);

        return result;
    }

    pub fn to_color(level: Level) u32 {
        assert(level.is_valid());

        const alpha: u32 = @divFloor(@as(u32, level.percent) * 255 + 50, 100);

        assert(alpha > 0);
        assert(alpha < 255);

        return alpha << 24;
    }

    pub fn to_index(level: Level) u8 {
        assert(level.is_valid());

        const result = @divExact(level.percent - percent_min, percent_step);

        assert(result < count);

        return result;
    }

    pub fn to_percent_label(level: Level) []const u8 {
        assert(level.is_valid());

        const result = percent_labels[level.to_index()];

        assert(result.len > 0);
        assert(result[result.len - 1] == '%');

        return result;
    }

    fn label_table(comptime format: []const u8) [count][]const u8 {
        comptime assert(format.len > 0);
        comptime assert(std.mem.endsWith(u8, format, "{d}%"));

        var result: [count][]const u8 = undefined;

        for (&result, 0..) |*label, index| {
            label.* = std.fmt.comptimePrint(format, .{percent_min + index * percent_step});
        }

        return result;
    }
};

const testing = std.testing;

test Level {
    const level = Level.default;

    try testing.expectEqual(@as(u8, 60), level.darker().percent);
    try testing.expectEqual(@as(u8, 40), level.lighter().percent);
    try testing.expectEqual(@as(u32, 0x80000000), level.to_color());
    try testing.expectEqualStrings("50%", level.to_percent_label());
}

test "each level maps to the alpha a floating point reference rounds to" {
    var index: u8 = 0;

    while (index < Level.count) : (index += 1) {
        const level = Level.from_index(index);
        const fraction = @as(f64, @floatFromInt(level.percent)) / 100.0;
        const expected: u32 = @intFromFloat(@round(fraction * 255.0));

        try testing.expectEqual(expected << 24, level.to_color());
    }

    try testing.expectEqual(@as(u32, 0x80000000), Level.default.to_color());
}

test "darker and lighter walk the whole range and stop at its ends" {
    var level = Level.from_index(0);
    var steps: u8 = 0;

    while (steps < Level.count + 2) : (steps += 1) {
        level = level.darker();
    }

    try testing.expectEqual(Level.percent_max, level.percent);
    try testing.expectEqual(Level.percent_max, level.darker().percent);

    steps = 0;

    while (steps < Level.count + 2) : (steps += 1) {
        level = level.lighter();
    }

    try testing.expectEqual(Level.percent_min, level.percent);
    try testing.expectEqual(Level.percent_min, level.lighter().percent);
}

test "an index round trips through its level and its labels" {
    var index: u8 = 0;

    while (index < Level.count) : (index += 1) {
        const level = Level.from_index(index);
        var buffer: [32]u8 = undefined;
        const percent = try std.mem.print(&buffer, "{d}%", .{level.percent});

        try testing.expectEqual(index, level.to_index());
        try testing.expectEqualStrings(percent, level.to_percent_label());
    }
}

test "a stored percent snaps to the nearest step inside the range" {
    try testing.expectEqual(@as(u8, 10), Level.from_percent(10).percent);
    try testing.expectEqual(@as(u8, 10), Level.from_percent(14).percent);
    try testing.expectEqual(@as(u8, 20), Level.from_percent(15).percent);
    try testing.expectEqual(@as(u8, 40), Level.from_percent(44).percent);
    try testing.expectEqual(@as(u8, 50), Level.from_percent(45).percent);
    try testing.expectEqual(@as(u8, 90), Level.from_percent(86).percent);
    try testing.expectEqual(@as(u8, 90), Level.from_percent(90).percent);
}

test "each percent in the range snaps to a level no other level is closer to" {
    var percent: u8 = Level.percent_min;

    while (percent <= Level.percent_max) : (percent += 1) {
        const snapped = Level.from_percent(percent);
        const distance = @abs(@as(i16, snapped.percent) - percent);
        var index: u8 = 0;

        while (index < Level.count) : (index += 1) {
            const other = Level.from_index(index);
            const other_distance = @abs(@as(i16, other.percent) - percent);

            try testing.expect(distance <= other_distance);

            if (distance == other_distance) try testing.expect(snapped.percent >= other.percent);
        }
    }
}

test "a level off the step or outside the range is invalid" {
    try testing.expect(!(Level{ .percent = 0 }).is_valid());
    try testing.expect(!(Level{ .percent = 45 }).is_valid());
    try testing.expect(!(Level{ .percent = 100 }).is_valid());
    try testing.expect((Level{ .percent = 90 }).is_valid());
}

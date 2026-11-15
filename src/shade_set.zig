const std = @import("std");

const kalymma = @import("kalymma");

const pieces_max = @import("target.zig").pieces_max;

const assert = std.debug.assert;

const Cursor = kalymma.Cursor;
const Rect = kalymma.Rect;
const Shade = kalymma.Shade;

pub fn ShadeSetType(comptime Runtime: type) type {
    return struct {
        color: u32,
        count: u8,
        cursor: Cursor,
        interactive: bool,
        rects: [pieces_max]Rect,
        runtime: *Runtime,
        shades: [pieces_max]Shade,

        const ShadeSet = @This();

        pub const Error = error{
            DisplayUnavailable,
            ShadeCreateFailed,
            ShadeEmpty,
            ShadeOutOfRange,
            ShadeUnknown,
            ShadeUpdateFailed,
            ShadesExhausted,
            SurfaceCreateFailed,
            SurfacePresentFailed,
            SurfaceShowFailed,
            ThreadSpawnFailed,
            TintFailed,
        };

        pub const Options = struct {
            interactive: bool,
        };

        pub fn init(runtime: *Runtime, options: Options) ShadeSet {
            comptime assert(@sizeOf(@TypeOf(options)) <= 16);

            const result = ShadeSet{
                .color = 0,
                .count = 0,
                .cursor = .crosshair,
                .interactive = options.interactive,
                .rects = undefined,
                .runtime = runtime,
                .shades = undefined,
            };

            assert(result.is_empty());
            assert(result.interactive == options.interactive);

            return result;
        }

        pub fn clear(set: *ShadeSet) void {
            assert(set.count <= pieces_max);

            for (set.slice()) |shade| {
                set.runtime.shade_destroy(shade);
            }

            set.count = 0;

            assert(set.is_empty());
        }

        pub fn index_of(set: *const ShadeSet, shade: Shade) ?u8 {
            assert(set.count <= pieces_max);

            for (set.slice(), 0..) |owned, index| {
                if (owned == shade) {
                    assert(index < set.count);

                    return @intCast(index);
                }
            }

            return null;
        }

        pub fn is_empty(set: *const ShadeSet) bool {
            return set.count == 0;
        }

        pub fn rect_at(set: *const ShadeSet, index: u8) Rect {
            assert(index < set.count);
            assert(!set.rects[index].is_empty());

            return set.rects[index];
        }

        pub fn set_cursor(set: *ShadeSet, cursor: Cursor) Error!void {
            assert(set.count <= pieces_max);
            assert(set.interactive);
            if (cursor != .crosshair) assert(set.count > 0);

            if (set.cursor == cursor) return;

            for (set.slice()) |shade| {
                try set.runtime.shade_set_cursor(shade, cursor);
            }

            set.cursor = cursor;

            assert(set.cursor == cursor);
        }

        pub fn show(set: *ShadeSet, rects: []const Rect, color: u32) Error!void {
            assert(rects.len <= pieces_max);
            assert(color >> 24 > 0);

            set.reconcile(rects, color) catch |err| {
                set.clear();

                return err;
            };

            assert(set.count == rects.len);
            if (set.count > 0) assert(set.color == color);
        }

        pub fn slice(set: *const ShadeSet) []const Shade {
            assert(set.count <= pieces_max);

            return set.shades[0..set.count];
        }

        fn reconcile(set: *ShadeSet, rects: []const Rect, color: u32) Error!void {
            assert(rects.len <= pieces_max);
            assert(color >> 24 > 0);

            while (set.count > rects.len) {
                set.count -= 1;

                set.runtime.shade_destroy(set.shades[set.count]);
            }

            for (set.slice(), 0..) |shade, index| {
                if (!std.meta.eql(set.rects[index], rects[index])) {
                    try set.runtime.shade_place(shade, rects[index]);

                    set.rects[index] = rects[index];
                }

                if (set.color != color) {
                    try set.runtime.shade_fill(shade, color);
                }
            }

            set.color = color;

            while (set.count < rects.len) {
                const options = Shade.Options{
                    .color = color,
                    .cursor = set.cursor,
                    .interactive = set.interactive,
                    .rect = rects[set.count],
                };

                set.shades[set.count] = try set.runtime.shade_create(options);
                set.rects[set.count] = rects[set.count];
                set.count += 1;
            }

            assert(set.count == rects.len);
        }
    };
}

const testing = std.testing;

const FakeRuntime = kalymma.RuntimeType(kalymma.Fake);
const FakeShadeSet = ShadeSetType(FakeRuntime);

const left = Rect{ .height = 1080, .width = 1920, .x = 0, .y = 0 };
const right = Rect{ .height = 1024, .width = 1280, .x = 1920, .y = 0 };
const corner = Rect{ .height = 200, .width = 300, .x = 10, .y = 20 };

fn open() !*FakeRuntime {
    const runtime = try testing.allocator.create(FakeRuntime);
    errdefer testing.allocator.destroy(runtime);

    try runtime.init(.{ .fault = null });

    assert(runtime.platform.shade_table.count() == 0);

    return runtime;
}

fn close(runtime: *FakeRuntime) void {
    runtime.deinit();
    testing.allocator.destroy(runtime);
}

fn live_count(runtime: *const FakeRuntime) u32 {
    const result = runtime.platform.shade_table.count();

    assert(result <= kalymma.limits.shade_count_max);

    return result;
}

fn expect_displayed(set: *const FakeShadeSet, rects: []const Rect, color: u32) !void {
    try testing.expectEqual(rects.len, set.slice().len);
    try testing.expectEqual(@as(u32, @intCast(rects.len)), live_count(set.runtime));

    for (set.slice(), rects) |shade, rect| {
        const slot = set.runtime.platform.shade_of(shade) orelse return error.ShadeMissing;

        try testing.expectEqual(rect, slot.rect);
        try testing.expectEqual(color, slot.color);
        try testing.expectEqual(set.interactive, slot.interactive);
    }
}

test ShadeSetType {
    const runtime = try open();
    defer close(runtime);

    var set = FakeShadeSet.init(runtime, .{ .interactive = false });
    defer set.clear();

    try set.show(&.{ left, right }, 0x80000000);

    try testing.expectEqual(@as(u8, 2), set.count);
    try testing.expectEqual(right, set.rect_at(1));

    try set.show(&.{}, 0x80000000);

    try testing.expect(set.is_empty());
}

test "a shown list puts one shade on each rectangle in the display" {
    const runtime = try open();
    defer close(runtime);

    var set = FakeShadeSet.init(runtime, .{ .interactive = false });
    defer set.clear();

    try set.show(&.{ left, right }, 0x80000000);
    try expect_displayed(&set, &.{ left, right }, 0x80000000);
}

test "a second show moves and refills the shades it already holds" {
    const runtime = try open();
    defer close(runtime);

    var set = FakeShadeSet.init(runtime, .{ .interactive = false });
    defer set.clear();

    try set.show(&.{ left, right }, 0x80000000);
    try set.show(&.{ right, corner }, 0x99000000);
    try expect_displayed(&set, &.{ right, corner }, 0x99000000);

    try testing.expectEqual(@as(u32, 2), runtime.platform.count_of(.shade_create));
    try testing.expectEqual(@as(u32, 2), runtime.platform.count_of(.shade_place));
    try testing.expectEqual(@as(u32, 2), runtime.platform.count_of(.shade_fill));
}

test "an unchanged rectangle and color reach the display only once" {
    const runtime = try open();
    defer close(runtime);

    var set = FakeShadeSet.init(runtime, .{ .interactive = false });
    defer set.clear();

    try set.show(&.{left}, 0x80000000);
    try set.show(&.{left}, 0x80000000);

    try testing.expectEqual(@as(u32, 1), runtime.platform.count_of(.shade_create));
    try testing.expectEqual(@as(u32, 0), runtime.platform.count_of(.shade_place));
    try testing.expectEqual(@as(u32, 0), runtime.platform.count_of(.shade_fill));
}

test "a shorter list destroys the surplus shades and an empty one clears the set" {
    const runtime = try open();
    defer close(runtime);

    var set = FakeShadeSet.init(runtime, .{ .interactive = true });
    defer set.clear();

    try set.show(&.{ left, right, corner }, 0x26000000);
    try set.show(&.{corner}, 0x26000000);
    try expect_displayed(&set, &.{corner}, 0x26000000);

    try set.show(&.{}, 0x26000000);

    try testing.expect(set.is_empty());
    try testing.expectEqual(@as(u32, 0), live_count(runtime));
}

test "a failed creation leaves no shade behind" {
    const runtime = try open();
    defer close(runtime);

    var set = FakeShadeSet.init(runtime, .{ .interactive = false });
    defer set.clear();

    try set.show(&.{left}, 0x80000000);

    runtime.platform.fault.arm(.shade_create);

    try testing.expectError(error.ShadeCreateFailed, set.show(&.{ left, right }, 0x80000000));
    try testing.expect(set.is_empty());
    try testing.expectEqual(@as(u32, 0), live_count(runtime));
}

test "a shade is found by its handle and reports its rectangle" {
    const runtime = try open();
    defer close(runtime);

    var set = FakeShadeSet.init(runtime, .{ .interactive = true });
    defer set.clear();

    try set.show(&.{ left, right }, 0x26000000);

    const second = set.slice()[1];

    try testing.expectEqual(@as(?u8, 1), set.index_of(second));
    try testing.expectEqual(right, set.rect_at(1));

    set.clear();

    try testing.expectEqual(@as(?u8, null), set.index_of(second));
}

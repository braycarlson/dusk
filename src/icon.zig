const std = @import("std");

const umbra = @import("umbra");

const assert = std.debug.assert;

const CapacityError = umbra.CapacityError;
const Pixmap = umbra.Icon.Pixmap;
const PlatformError = umbra.PlatformError;
const RequestError = umbra.RequestError;

pub fn IconType(comptime App: type) type {
    return enum {
        active,
        inactive,

        const Icon = @This();

        pub const RegisterError = CapacityError || RequestError;
        pub const ShowError = PlatformError || RequestError;

        pub fn register(icons: *App.IconSet) RegisterError!void {
            assert(icons.is_empty());

            _ = try App.IconBuilder.init(icons)
                .pixels(@tagName(Icon.active), pixmap_active)
                .pixels(@tagName(Icon.inactive), pixmap_inactive)
                .done();

            assert(icons.get_source(@tagName(Icon.active)) != null);
            assert(icons.get_source(@tagName(Icon.inactive)) != null);
        }

        pub fn show(icon: Icon, icons: *App.IconSet) ShowError!void {
            assert(icons.get_source(@tagName(icon)) != null);

            try icons.set_current(@tagName(icon));

            assert(icons.get_current_name() != null);
        }
    };
}

const dimension: u32 = 32;
const pixmap_active = Pixmap.from_rgba(@embedFile("active.rgba"), dimension);
const pixmap_inactive = Pixmap.from_rgba(@embedFile("inactive.rgba"), dimension);

comptime {
    assert(pixmap_active.height == dimension);
    assert(pixmap_inactive.height == dimension);
}

const testing = std.testing;

const FakeApp = umbra.AppType(umbra.Fake);
const FakeIcon = IconType(FakeApp);

const Pixel = struct {
    column: u32,
    row: u32,
};

fn partial_alpha_count(argb: []const u8) u32 {
    assert(argb.len % 4 == 0);

    var result: u32 = 0;
    var index: usize = 0;

    while (index < argb.len) : (index += 4) {
        const alpha = argb[index];
        if (alpha == 0) continue;
        if (alpha == 255) continue;

        result += 1;
    }

    assert(result <= @divExact(argb.len, 4));

    return result;
}

fn pixel_at(pixmap: *const Pixmap, pixel: Pixel) []const u8 {
    assert(pixel.column < dimension);
    assert(pixel.row < dimension);
    assert(pixmap.argb.len == dimension * dimension * 4);

    const offset = ((pixel.row * dimension) + pixel.column) * 4;

    return pixmap.argb[offset..][0..4];
}

test IconType {
    const app = try testing.allocator.create(FakeApp);
    defer testing.allocator.destroy(app);

    try app.init(.{ .name = "dusk" });
    defer app.deinit();

    const icons = &app.icons;

    try FakeIcon.register(icons);
    try FakeIcon.inactive.show(icons);

    try testing.expectEqualStrings("inactive", icons.get_current_name().?);

    try FakeIcon.active.show(icons);

    try testing.expectEqualStrings("active", icons.get_current_name().?);

    try FakeIcon.inactive.show(icons);

    try testing.expectEqualStrings("inactive", icons.get_current_name().?);
}

test "the embedded pixmaps are complete 32 bit images" {
    try testing.expectEqual(dimension * dimension * 4, pixmap_active.argb.len);
    try testing.expectEqual(dimension * dimension * 4, pixmap_inactive.argb.len);
    try testing.expect(pixmap_active.is_valid());
    try testing.expect(pixmap_inactive.is_valid());
}

test "each pixmap keeps the antialiasing of the frame it was taken from" {
    try testing.expect(partial_alpha_count(pixmap_active.argb) > 0);
    try testing.expect(partial_alpha_count(pixmap_inactive.argb) > 0);
}

test "the body of each crescent carries the colour its source declares" {
    const amber = [_]u8{ 0xff, 0xf5, 0x9e, 0x0b };
    const body = Pixel{ .column = 6, .row = 17 };
    const white = [_]u8{ 0xff, 0xff, 0xff, 0xff };

    try testing.expectEqualSlices(u8, &amber, pixel_at(&pixmap_active, body));
    try testing.expectEqualSlices(u8, &white, pixel_at(&pixmap_inactive, body));
}

test "the bite out of each crescent is transparent" {
    const bite = Pixel{ .column = 28, .row = 2 };

    try testing.expectEqual(@as(u8, 0), pixel_at(&pixmap_active, bite)[0]);
    try testing.expectEqual(@as(u8, 0), pixel_at(&pixmap_inactive, bite)[0]);
}

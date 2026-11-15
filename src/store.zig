const std = @import("std");

const kalymma = @import("kalymma");
const toml = @import("toml");
const umbra = @import("umbra");

const Level = @import("level.zig").Level;
const Target = @import("target.zig").Target;

const assert = std.debug.assert;

const Monitor = kalymma.Monitor;
const Rect = kalymma.Rect;

pub const Store = struct {
    content: [content_bytes_max + 1]u8,
    document: Document,
    io: std.Io,
    path: [umbra.limits.path_bytes_max]u8,
    path_length: u32,
    scratch: [scratch_bytes_max]u8,

    pub const CapacityError = error{
        ContentTooLong,
        PathTooLong,
    };

    pub const PlatformError = error{
        ReadFailed,
        WriteFailed,
    };

    pub const RequestError = error{
        PathRelative,
    };

    pub const SettingsError = error{
        ContentInvalid,
    };

    pub const InitError = CapacityError || RequestError;
    pub const LoadError = error{FileMissing} || CapacityError || PlatformError || SettingsError;
    pub const SaveError = PlatformError || SettingsError;

    pub const Settings = struct {
        level: Level = .default,
        target: Target = .all,
    };

    pub fn init(store: *Store, io: std.Io, directory: []const u8) InitError!void {
        assert(directory.len > 0);
        if (!std.Io.Dir.path.isAbsolute(directory)) return error.PathRelative;

        store.io = io;
        store.path_length = 0;

        const separator = std.Io.Dir.path.sep;

        const path = std.mem.print(
            &store.path,
            "{s}{c}{s}",
            .{ directory, separator, file_name },
        ) catch {
            return error.PathTooLong;
        };

        store.path_length = @intCast(path.len);

        assert(store.path_length > directory.len);
        assert(std.mem.endsWith(u8, store.get_path(), file_name));
    }

    pub fn get_path(store: *const Store) []const u8 {
        assert(store.path_length > 0);
        assert(store.path_length <= umbra.limits.path_bytes_max);

        return store.path[0..store.path_length];
    }

    pub fn load(store: *Store) LoadError!Settings {
        const content = try store.read();

        assert(content.len > 0);
        assert(content.len <= content_bytes_max);

        const source = try store.parse(content);
        const result = decode(&source);

        assert(result.level.is_valid());

        return result;
    }

    pub fn save(store: *const Store, settings: *const Settings) SaveError!void {
        assert(settings.level.is_valid());
        if (settings.target == .region) assert(!settings.target.region.is_empty());

        const path = store.get_path();
        const source = encode(settings);
        const options: std.Io.Dir.CreateFileAtomicOptions = .{ .make_path = true, .replace = true };

        var atomic = std.Io.Dir.cwd().createFileAtomic(store.io, path, options) catch {
            return error.WriteFailed;
        };

        defer atomic.deinit(store.io);

        var buffer: [write_bytes_max]u8 = undefined;
        var sink = atomic.file.writer(store.io, &buffer);
        var writer: toml.Writer = undefined;

        writer.init(&sink.interface, writer_options);

        toml.encode(TOMLSettings, &writer, &source) catch |err| switch (err) {
            error.DatetimeInvalid, error.Utf8Invalid => return error.ContentInvalid,
            error.WriteFailed => return error.WriteFailed,
        };

        writer.finish();

        sink.interface.flush() catch {
            return error.WriteFailed;
        };

        atomic.file.sync(store.io) catch {
            return error.WriteFailed;
        };

        atomic.replace(store.io) catch {
            return error.WriteFailed;
        };
    }

    fn parse(store: *Store, content: []const u8) SettingsError!TOMLSettings {
        assert(content.len > 0);
        assert(content.len <= content_bytes_max);

        store.document.parse(content, .{ .version = .v1_1 }) catch {
            return error.ContentInvalid;
        };

        var region: toml.Region = .init(&store.scratch);
        var result: TOMLSettings = undefined;
        const document = &store.document.base;

        toml.decode(TOMLSettings, &region, document, document.root(), &result, .{
            .unknown_members = .refused,
        }) catch {
            return error.ContentInvalid;
        };

        return result;
    }

    fn read(store: *Store) LoadError![]const u8 {
        const path = store.get_path();

        assert(std.Io.Dir.path.isAbsolute(path));

        const file = std.Io.Dir.openFileAbsolute(
            store.io,
            path,
            read_options,
        ) catch |err| switch (err) {
            error.FileNotFound => return error.FileMissing,
            else => return error.ReadFailed,
        };

        defer file.close(store.io);

        const count = file.readPositionalAll(store.io, &store.content, 0) catch {
            return error.ReadFailed;
        };

        if (count == 0) return error.ContentInvalid;
        if (count > content_bytes_max) return error.ContentTooLong;

        return store.content[0..count];
    }
};

const TOMLRegion = struct {
    height: i64,
    left: i64,
    top: i64,
    width: i64,

    pub const toml = .{ .left = "x", .top = "y" };
};

const TOMLSettings = struct {
    level: ?i64 = null,
    monitor: ?[]const u8 = null,
    region: ?TOMLRegion = null,
};

const content_bytes_max: u32 = 4096;
const document_node_count_max: u32 = 16;
const document_text_bytes_max: u32 = 1024;
const file_name = "config.toml";
const scratch_bytes_max: u32 = 4096;
const write_bytes_max: u32 = 1024;

const read_options: std.Io.Dir.OpenFileOptions = .{
    .allow_ctty = false,
    .allow_directory = false,
    .follow_symlinks = true,
    .lock = .none,
    .lock_nonblocking = false,
    .mode = .read_only,
    .path_only = false,
    .resolve_beneath = false,
};

const rect_unknown: Rect = .{ .height = 0, .width = 0, .x = 0, .y = 0 };

const writer_options: toml.Writer.Options = .{
    .layout = .compact,
    .strings = .auto,
    .version = .v1_1,
};

const Document = toml.DocumentType(.{
    .line_count_max = null,
    .node_count_max = document_node_count_max,
    .text_bytes_max = document_text_bytes_max,
});

comptime {
    assert(content_bytes_max <= toml.limits.source_bytes_max);
    assert(document_text_bytes_max <= content_bytes_max);
    assert(document_node_count_max >= 2 + 2 * @typeInfo(TOMLSettings).@"struct".field_names.len);
    assert(file_name.len > 0);
    assert(rect_unknown.is_empty());
    assert(write_bytes_max > 0);
}

fn decode(source: *const TOMLSettings) Store.Settings {
    const stored = source.level orelse Level.default.percent;
    const percent = std.math.clamp(stored, Level.percent_min, Level.percent_max);

    const result = Store.Settings{
        .level = Level.from_percent(@intCast(percent)),
        .target = target_of(source),
    };

    assert(result.level.is_valid());
    if (result.target == .region) assert(!result.target.region.is_empty());

    return result;
}

fn encode(settings: *const Store.Settings) TOMLSettings {
    assert(settings.level.is_valid());

    var result = TOMLSettings{ .level = settings.level.percent };

    switch (settings.target) {
        .all => {},
        .monitor => |*monitor| result.monitor = monitor.get_name(),
        .region => |rect| result.region = .{
            .height = rect.height,
            .left = rect.x,
            .top = rect.y,
            .width = rect.width,
        },
    }

    assert(result.level != null);

    return result;
}

fn rect_of(source: *const TOMLRegion) ?Rect {
    const result = Rect{
        .height = std.math.cast(i32, source.height) orelse return null,
        .width = std.math.cast(i32, source.width) orelse return null,
        .x = std.math.cast(i32, source.left) orelse return null,
        .y = std.math.cast(i32, source.top) orelse return null,
    };

    if (result.is_empty()) return null;

    assert(result.height > 0);
    assert(result.width > 0);

    return result;
}

fn target_of(source: *const TOMLSettings) Target {
    if (source.monitor) |name| {
        if (name.len > 0) return .{ .monitor = Monitor.init(name, rect_unknown) };
    }

    const region = source.region orelse return .all;
    const rect = rect_of(&region) orelse return .all;

    return .{ .region = rect };
}

const testing = std.testing;

const temporary_options: std.Io.Dir.OpenOptions = .{
    .access_sub_paths = true,
    .follow_symlinks = true,
    .iterate = false,
};

fn absolute_path_of(temporary: *const testing.TmpDir, buffer: []u8) ![]const u8 {
    assert(buffer.len >= umbra.limits.path_bytes_max);

    const length = try temporary.dir.realPath(testing.io, buffer);
    return buffer[0..length];
}

fn open_store(temporary: *const testing.TmpDir, store: *Store) !void {
    var buffer: [umbra.limits.path_bytes_max]u8 = undefined;
    const path = try absolute_path_of(temporary, &buffer);

    try store.init(testing.io, path);

    assert(store.get_path().len > path.len);
}

test Store {
    var temporary = testing.tmpDir(temporary_options);
    defer temporary.cleanup();

    var store: Store = undefined;

    try open_store(&temporary, &store);
    try testing.expectError(error.FileMissing, store.load());

    const settings = Store.Settings{ .level = .{ .percent = 30 }, .target = .all };

    try store.save(&settings);

    try testing.expectEqual(settings, try store.load());
}

test "settings round trip through the file for each kind of target" {
    var temporary = testing.tmpDir(temporary_options);
    defer temporary.cleanup();

    var store: Store = undefined;

    try open_store(&temporary, &store);

    const cases = [_]Store.Settings{
        .{},
        .{ .level = .{ .percent = 30 }, .target = .{ .monitor = Monitor.init("DP-1", .{}) } },
        .{ .level = .{ .percent = 90 }, .target = .{ .region = .{ .height = 400, .width = 800 } } },
        .{
            .level = .{ .percent = 10 },
            .target = .{ .region = .{ .height = 9, .width = 9, .x = -1920, .y = -8 } },
        },
    };

    for (&cases) |*expected| {
        try store.save(expected);

        const actual = try store.load();

        try testing.expectEqual(expected.*, actual);
    }
}

test "the file holds the keys a person would write by hand" {
    var temporary = testing.tmpDir(temporary_options);
    defer temporary.cleanup();

    var store: Store = undefined;

    try open_store(&temporary, &store);

    const settings = Store.Settings{
        .level = .{ .percent = 70 },
        .target = .{ .monitor = Monitor.init("HDMI-A-1", .{}) },
    };

    try store.save(&settings);

    const limit: std.Io.Limit = .limited(4096);
    const text = try temporary.dir.readFileAlloc(testing.io, file_name, testing.allocator, limit);
    defer testing.allocator.free(text);

    try testing.expect(std.mem.find(u8, text, "level = 70") != null);
    try testing.expect(std.mem.find(u8, text, "monitor = \"HDMI-A-1\"") != null);
    try testing.expect(std.mem.find(u8, text, "region") == null);
}

test "a drawn region is written with the x and y a person would write by hand" {
    var temporary = testing.tmpDir(temporary_options);
    defer temporary.cleanup();

    var store: Store = undefined;

    try open_store(&temporary, &store);

    const settings = Store.Settings{
        .level = .default,
        .target = .{ .region = .{ .height = 30, .width = 40, .x = -10, .y = 20 } },
    };

    try store.save(&settings);

    const limit: std.Io.Limit = .limited(4096);
    const text = try temporary.dir.readFileAlloc(testing.io, file_name, testing.allocator, limit);
    defer testing.allocator.free(text);

    try testing.expect(std.mem.find(u8, text, "x = -10") != null);
    try testing.expect(std.mem.find(u8, text, "y = 20") != null);
    try testing.expect(std.mem.find(u8, text, "left") == null);
    try testing.expect(std.mem.find(u8, text, "top") == null);
}

test "a missing file and a broken file are told apart" {
    var temporary = testing.tmpDir(temporary_options);
    defer temporary.cleanup();

    var store: Store = undefined;

    try open_store(&temporary, &store);
    try testing.expectError(error.FileMissing, store.load());

    const broken = [_][]const u8{
        "level = \n",
        "colour = 1\n",
        "level = \"high\"\n",
        "region = { height = 10, left = 0, top = 0, width = 10 }\n",
        "",
    };

    for (broken) |data| {
        try temporary.dir.writeFile(testing.io, .{ .data = data, .sub_path = file_name });
        try testing.expectError(error.ContentInvalid, store.load());
    }
}

test "a stored level snaps to its step and a broken region falls back to the whole screen" {
    const empty = TOMLSettings{
        .level = 47,
        .region = .{ .height = 10, .left = 0, .top = 0, .width = 0 },
    };

    const huge = TOMLSettings{
        .level = std.math.maxInt(i64),
        .region = .{ .height = 10, .left = std.math.maxInt(i64), .top = 0, .width = 10 },
    };

    try testing.expectEqual(@as(u8, 50), decode(&empty).level.percent);
    try testing.expectEqual(Target.all, decode(&empty).target);
    try testing.expectEqual(@as(u8, 90), decode(&huge).level.percent);
    try testing.expectEqual(Target.all, decode(&huge).target);
}

test "a stored level outside the range clamps to the nearest end" {
    const stored = [_]i64{ std.math.minInt(i64), -5, 0, 9, 91, 100, std.math.maxInt(i64) };
    const expected = [_]u8{ 10, 10, 10, 10, 90, 90, 90 };

    for (stored, expected) |level, percent| {
        const source = TOMLSettings{ .level = level };

        try testing.expectEqual(percent, decode(&source).level.percent);
        try testing.expectEqual(Target.all, decode(&source).target);
    }
}

test "a monitor name wins over a region and an empty name is no monitor" {
    const both = TOMLSettings{
        .monitor = "DP-2",
        .region = .{ .height = 10, .left = 0, .top = 0, .width = 10 },
    };

    const unnamed = TOMLSettings{ .monitor = "" };

    try testing.expectEqualStrings("DP-2", decode(&both).target.monitor.get_name());
    try testing.expectEqual(Target.all, decode(&unnamed).target);
    try testing.expectEqual(Level.default, decode(&unnamed).level);
}

test "a path that does not fit is refused" {
    var store: Store = undefined;
    var long: [umbra.limits.path_bytes_max]u8 = @splat('a');

    long[0] = std.Io.Dir.path.sep;

    try testing.expectError(error.PathTooLong, store.init(testing.io, &long));
}

test "a directory whose path exactly fits is accepted" {
    var store: Store = undefined;
    var directory: [umbra.limits.path_bytes_max - file_name.len - 1]u8 = @splat('a');

    directory[0] = std.Io.Dir.path.sep;

    try store.init(testing.io, &directory);

    try testing.expectEqual(umbra.limits.path_bytes_max, store.path_length);
    try testing.expect(std.mem.startsWith(u8, store.get_path(), &directory));
}

test "a relative directory is refused" {
    var store: Store = undefined;

    try testing.expectError(error.PathRelative, store.init(testing.io, "dusk"));
    try testing.expectError(error.PathRelative, store.init(testing.io, "config/dusk"));
}

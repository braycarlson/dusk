const std = @import("std");

const arc = @import("arc");
const kalymma = @import("kalymma");
const nimble = @import("nimble");
const umbra = @import("umbra");

const IconType = @import("icon.zig").IconType;
const Level = @import("level.zig").Level;
const menu_module = @import("menu.zig");
const picker_module = @import("picker.zig");
const ShadeSetType = @import("shade_set.zig").ShadeSetType;
const Store = @import("store.zig").Store;
const target_module = @import("target.zig");

const assert = std.debug.assert;

const Choice = menu_module.Choice;
const Custom = umbra.Event.Custom;
const Key = nimble.Key;
const Logger = arc.Logger;
const MenuType = menu_module.MenuType;
const Mode = picker_module.Mode;
const Monitor = kalymma.Monitor;
const Outcome = picker_module.Outcome;
const PickerType = picker_module.PickerType;
const Pieces = Target.Pieces;
const Rect = kalymma.Rect;
const Selection = umbra.Event.Selection;
const Settings = Store.Settings;
const Target = target_module.Target;
const Tick = umbra.Event.Tick;

pub fn ApplicationType(comptime Libraries: type) type {
    return struct {
        active: bool,
        client: Client,
        dimmer: ShadeSet,
        level: Level,
        logger: ?*const Logger,
        monitors: Monitor.List,
        overlay: Runtime,
        picker: Picker,
        runtime: App,
        store: ?*Store,
        target: Target,

        const Application = @This();
        const App = Libraries.App;
        const Client = Libraries.Client;
        const Icon = IconType(App);
        const Menu = MenuType(App);
        const Picker = PickerType(Runtime);
        const Runtime = Libraries.Runtime;
        const ShadeSet = ShadeSetType(Runtime);

        pub const InitError = umbra.Error || kalymma.PlatformError || Picker.InitError;

        pub const Options = struct {
            logger: ?*const Logger = null,
            store: ?*Store = null,
        };

        pub const RunError = umbra.Error ||
            nimble.remote.CapacityError ||
            nimble.remote.PlatformError ||
            nimble.remote.RequestError;

        pub fn init(application: *Application, options: Options) InitError!void {
            comptime assert(@sizeOf(@TypeOf(options)) <= 16);
            if (options.store) |store| assert(store.get_path().len > 0);

            application.* = .{
                .active = false,
                .client = .{},
                .dimmer = .init(&application.overlay, .{ .interactive = false }),
                .level = .default,
                .logger = options.logger,
                .monitors = .init(),
                .overlay = undefined,
                .picker = undefined,
                .runtime = undefined,
                .store = options.store,
                .target = .all,
            };

            application.restore();

            try application.runtime.init(.{ .name = name, .tooltip = name });
            errdefer application.runtime.deinit();

            try application.overlay.init(Runtime.Options{});
            errdefer application.overlay.deinit();

            try application.picker.init(&application.overlay);
            errdefer application.picker.deinit();

            try Icon.register(&application.runtime.icons);
            try Icon.inactive.show(&application.runtime.icons);

            _ = application.overlay.monitors_list(&application.monitors);

            application.fill_menu();

            assert(!application.active);
            assert(!application.picker.is_open());
            assert(application.level.is_valid());

            application.log("Application is ready");
        }

        pub fn deinit(application: *Application) void {
            application.log("Shutting down");

            application.picker.end();
            application.picker.deinit();
            application.dimmer.clear();

            application.overlay.events_unsubscribe();
            application.overlay.deinit();

            application.client.disconnect();
            application.runtime.deinit();

            assert(application.dimmer.is_empty());
            assert(!application.picker.is_open());
            assert(!application.runtime.is_running());
            assert(!application.client.is_connected());
        }

        pub fn run(application: *Application) RunError!void {
            assert(!application.client.is_connected());
            assert(!application.picker.is_open());

            try application.runtime.bus.attach(Application, application);

            application.overlay.events_subscribe(Application, application, on_shades_wake);

            application.client.connect() catch |err| {
                application.log_error("Unable to connect to the input service", err);

                return err;
            };

            try application.bind(binding_toggle, on_toggle);
            try application.bind(binding_darker, on_darker);
            try application.bind(binding_lighter, on_lighter);

            try application.runtime.run();

            assert(!application.runtime.is_running());
        }

        pub fn on_app_shutdown(application: *Application) void {
            application.log("Shutdown event received");

            if (application.picker.is_open()) {
                application.finish_pick(.closed);
            }

            assert(!application.picker.is_open());
            assert(!application.runtime.timers.is_running(@backingInt(TimerID.pick)));
        }

        pub fn on_custom(application: *Application, custom: Custom) void {
            assert(@backingInt(custom.code) > 0);

            const message = std.enums.fromInt(Message, @backingInt(custom.code)) orelse return;

            switch (message) {
                .darker, .lighter, .toggle => application.on_hotkey(message),
                .shades => application.drain(),
            }
        }

        pub fn on_menu_select(application: *Application, selection: Selection) void {
            assert(selection.id <= umbra.limits.menu_item_id_max);

            const choice = Choice.decode(selection.id) orelse return;

            if (application.picker.is_open()) {
                application.finish_pick(.closed);
            }

            assert(!application.picker.is_open());

            switch (choice) {
                .all => application.set_target(.all),
                .delete => application.delete_region(),
                .draw => application.begin_pick(.draw),
                .edit => application.edit_region(),
                .exit => application.on_exit(),
                .level => |level| application.set_level(level),
                .monitor => |index| application.choose_monitor(index),
                .region => application.set_target(application.target),
                .toggle => application.set_active(!application.active),
            }
        }

        pub fn on_timer_tick(application: *Application, tick: Tick) void {
            assert(tick.id <= umbra.limits.timer_id_max);

            const timer = std.enums.fromInt(TimerID, tick.id) orelse return;

            switch (timer) {
                .pick => application.on_pick_timeout(),
            }
        }

        fn apply(application: *Application) void {
            assert(!application.picker.is_open());
            assert(application.level.is_valid());

            if (!application.active) {
                application.dimmer.clear();
                application.overlay.tint_clear();

                return;
            }

            const color = application.level.to_color();
            var pieces = Pieces{};

            application.target.pieces(application.monitors.slice(), &pieces);

            if (application.tint(&pieces, color)) {
                application.dimmer.clear();

                return;
            }

            application.dimmer.show(pieces.slice(), color) catch |err| {
                application.log_error("Unable to dim the screen", err);
            };

            application.overlay.tint_clear();

            assert(application.dimmer.count <= pieces.count);
        }

        fn begin_pick(application: *Application, mode: Mode) void {
            assert(!application.picker.is_open());
            if (mode == .edit) assert(application.target == .region);

            if (application.monitors.count == 0) {
                application.log_pick("No monitor to pick a region on", mode);

                return;
            }

            application.dimmer.clear();
            application.overlay.tint_clear();

            const color = application.level.to_color();

            application.picker.begin(&application.monitors, color, mode) catch |err| {
                application.log_error("Unable to start picking a region", err);
                application.picker.end();
                application.apply();

                return;
            };

            application.start_pick_timer();

            assert(application.picker.is_open());

            application.log_pick("Picking a region", mode);
        }

        fn bind(
            application: *Application,
            comptime pattern: []const u8,
            comptime callback: fn (*Application, ?*const Key) void,
        ) RunError!void {
            comptime assert(pattern.len > 0);
            assert(application.client.is_connected());

            _ = application.client.bind(
                pattern,
                .{ .consume = true },
                Application,
                application,
                callback,
            ) catch |err| {
                application.log_error("Unable to bind a hotkey", err);

                return err;
            };
        }

        fn choose_monitor(application: *Application, index: u8) void {
            assert(index < target_module.pieces_max);

            const monitors = application.monitors.slice();

            if (index >= monitors.len) {
                application.log("The chosen monitor is gone");

                return;
            }

            application.set_target(.{ .monitor = monitors[index] });

            assert(application.target.is_monitor(&monitors[index]));
        }

        fn delete_region(application: *Application) void {
            assert(!application.picker.is_open());

            if (application.target != .region) {
                application.log("No drawn region to delete");

                return;
            }

            application.target = .all;
            application.active = false;

            application.save();
            application.update();
            application.log("Deleted the drawn region");

            assert(application.target == .all);
            assert(!application.active);
        }

        fn dispatch(application: *Application, event: kalymma.Event) void {
            if (event.input == .monitors_changed) assert(event.source == .display);
            if (event.source == .display) assert(event.input == .monitors_changed);

            if (event.input == .monitors_changed) {
                application.on_monitors_changed();

                return;
            }

            if (!application.picker.is_open()) {
                return;
            }

            const outcome = application.picker.handle(event);

            switch (outcome) {
                .closed, .deleted => application.finish_pick(outcome),
                .moved => |rect| application.on_region_edited(rect, "Moved the drawn region"),
                .pending => {},
                .picked => |rect| application.on_region_drawn(rect),
                .resized => |rect| application.on_region_edited(rect, "Resized the drawn region"),
            }
        }

        fn drain(application: *Application) void {
            var list = kalymma.Event.List.init();
            const count = application.overlay.events_poll(&list);

            assert(count == list.count);
            assert(count <= kalymma.limits.event_count_max);

            for (list.slice()) |event| {
                application.dispatch(event);
            }
        }

        fn edit_region(application: *Application) void {
            assert(!application.picker.is_open());

            const region = switch (application.target) {
                .region => |rect| rect,
                .all, .monitor => {
                    application.log("No drawn region to edit");

                    return;
                },
            };

            assert(!region.is_empty());

            application.begin_pick(.{ .edit = region });
        }

        fn fill_menu(application: *Application) void {
            assert(application.level.is_valid());
            assert(application.monitors.count <= target_module.pieces_max);

            const menu = Menu{
                .active = application.active,
                .level = application.level,
                .monitors = application.monitors.slice(),
                .target = &application.target,
            };

            menu.fill(&application.runtime.menu) catch |err| {
                application.log_error("Unable to fill the menu", err);
            };
        }

        fn finish_pick(application: *Application, outcome: Outcome) void {
            assert(application.picker.is_open());
            assert(outcome != .moved);
            assert(outcome != .pending);
            assert(outcome != .picked);
            assert(outcome != .resized);

            application.picker.end();
            application.stop_pick_timer();

            switch (outcome) {
                .closed => {
                    application.log_pick("Picking a region ended", application.picker.mode);
                    application.update();
                },
                .deleted => application.delete_region(),
                .moved, .pending, .picked, .resized => unreachable,
            }

            assert(!application.picker.is_open());
        }

        fn on_exit(application: *Application) void {
            assert(!application.picker.is_open());

            application.log("Exiting");
            application.runtime.quit();

            assert(!application.runtime.is_running());
        }

        fn on_hotkey(application: *Application, message: Message) void {
            assert(message != .shades);

            if (application.picker.is_open()) {
                application.finish_pick(.closed);

                return;
            }

            switch (message) {
                .darker => application.set_level(application.level.darker()),
                .lighter => application.set_level(application.level.lighter()),
                .toggle => application.set_active(!application.active),
                .shades => unreachable,
            }
        }

        fn on_monitors_changed(application: *Application) void {
            defer assert(!application.picker.is_open());

            const count = application.overlay.monitors_list(&application.monitors);

            assert(count <= target_module.pieces_max);

            application.log("The monitor layout changed");

            if (application.picker.is_open()) {
                application.finish_pick(.closed);

                return;
            }

            application.update();
        }

        fn on_pick_timeout(application: *Application) void {
            defer assert(!application.picker.is_open());
            defer assert(!application.runtime.timers.is_running(@backingInt(TimerID.pick)));

            if (!application.picker.is_open()) {
                application.stop_pick_timer();

                return;
            }

            application.log_pick("Picking a region timed out", application.picker.mode);
            application.finish_pick(.closed);
        }

        fn on_region_drawn(application: *Application, rect: Rect) void {
            assert(application.picker.is_open());
            assert(application.picker.mode == .draw);
            assert(!rect.is_empty());

            application.place_region(rect);
            application.log("Drew a region");

            application.picker.edit(rect) catch |err| {
                application.log_error("Unable to open the region editor", err);
                application.finish_pick(.closed);
            };
        }

        fn on_region_edited(application: *Application, rect: Rect, message: []const u8) void {
            assert(application.picker.is_open());
            assert(application.picker.mode == .edit);
            assert(!rect.is_empty());
            assert(message.len > 0);

            application.place_region(rect);
            application.log(message);
        }

        fn place_region(application: *Application, rect: Rect) void {
            assert(application.picker.is_open());
            assert(!rect.is_empty());

            const active = application.active;
            defer assert(application.active == active);

            application.target = .{ .region = rect };

            application.save();
            application.stop_pick_timer();
            application.start_pick_timer();
            application.refresh_tray();

            assert(std.meta.eql(application.target.region, rect));
        }

        fn refresh_tray(application: *Application) void {
            const icon: Icon = if (application.active) .active else .inactive;

            icon.show(&application.runtime.icons) catch |err| {
                application.log_error("Unable to show the tray icon", err);
            };

            application.fill_menu();

            application.runtime.menu.build() catch |err| {
                application.log_error("Unable to build the menu", err);
            };
        }

        fn restore(application: *Application) void {
            assert(application.target == .all);
            assert(application.level.percent == Level.default.percent);

            const store = application.store orelse return;

            const settings = store.load() catch |err| switch (err) {
                error.FileMissing => return,
                else => {
                    application.log_error("Unable to load the settings", err);

                    return;
                },
            };

            application.level = settings.level;
            application.target = settings.target;

            assert(application.level.is_valid());
        }

        fn save(application: *Application) void {
            assert(application.level.is_valid());

            const store = application.store orelse return;
            const settings = Settings{ .level = application.level, .target = application.target };

            store.save(&settings) catch |err| {
                application.log_error("Unable to save the settings", err);
            };
        }

        fn set_active(application: *Application, value: bool) void {
            assert(!application.picker.is_open());

            application.active = value;

            application.update();
            application.log(if (value) "Dimming turned on" else "Dimming turned off");

            assert(application.active == value);
        }

        fn set_level(application: *Application, level: Level) void {
            assert(!application.picker.is_open());
            assert(level.is_valid());

            application.level = level;

            application.save();
            application.update();

            assert(application.level.percent == level.percent);
        }

        fn set_target(application: *Application, target: Target) void {
            assert(!application.picker.is_open());

            const active = application.active;

            application.target = target;

            application.save();
            application.update();

            assert(application.active == active);
        }

        fn start_pick_timer(application: *Application) void {
            assert(application.picker.is_open());

            const timeout = App.TimerSet.Timer{
                .id = @backingInt(TimerID.pick),
                .interval_ms = pick_timeout_ms,
            };

            application.runtime.timers.start(timeout) catch |err| {
                application.log_error("Unable to start the picking timeout", err);
            };
        }

        fn stop_pick_timer(application: *Application) void {
            const id = @backingInt(TimerID.pick);

            if (!application.runtime.timers.is_running(id)) {
                return;
            }

            application.runtime.timers.stop(id) catch |err| {
                application.log_error("Unable to stop the drawing timeout", err);
            };

            assert(!application.runtime.timers.is_running(id));
        }

        fn tint(application: *Application, pieces: *const Pieces, color: u32) bool {
            assert(application.active);
            assert(!application.picker.is_open());
            assert(color >> 24 > 0);
            assert((color & 0x00FFFFFF) == 0);

            if (!pieces.covers(application.monitors.slice())) {
                return false;
            }

            if (!application.overlay.tint_is_supported()) {
                return false;
            }

            application.overlay.tint_apply(color) catch |err| {
                application.log_error("Unable to tint the screen", err);

                return false;
            };

            return true;
        }

        fn update(application: *Application) void {
            assert(!application.picker.is_open());

            application.apply();
            application.refresh_tray();
        }

        fn log(application: *Application, message: []const u8) void {
            assert(message.len > 0);

            if (application.logger) |logger| {
                logger.information(message, &.{}, &@src());
            }
        }

        fn log_error(application: *Application, message: []const u8, err: anyerror) void {
            assert(message.len > 0);

            if (application.logger) |logger| {
                logger.err(
                    message,
                    &.{.{ .key = "error", .value = .{ .string = @errorName(err) } }},
                    &@src(),
                );
            }
        }

        fn log_pick(application: *Application, message: []const u8, mode: Mode) void {
            assert(message.len > 0);
            if (mode == .edit) assert(!mode.edit.is_empty());

            if (application.logger) |logger| {
                logger.information(
                    message,
                    &.{.{ .key = "mode", .value = .{ .string = @tagName(mode) } }},
                    &@src(),
                );
            }
        }

        fn on_darker(application: *Application, _: ?*const Key) void {
            _ = application.runtime.post(@fromBackingInt(@backingInt(Message.darker)));
        }

        fn on_lighter(application: *Application, _: ?*const Key) void {
            _ = application.runtime.post(@fromBackingInt(@backingInt(Message.lighter)));
        }

        fn on_shades_wake(application: *Application) void {
            _ = application.runtime.post(@fromBackingInt(@backingInt(Message.shades)));
        }

        fn on_toggle(application: *Application, _: ?*const Key) void {
            _ = application.runtime.post(@fromBackingInt(@backingInt(Message.toggle)));
        }
    };
}

pub const Message = enum(u32) {
    darker = 1,
    lighter = 2,
    shades = 3,
    toggle = 4,
};

pub const TimerID = enum(u32) {
    pick = 1,
};

const binding_darker = "Ctrl+Alt+-";
const binding_lighter = "Ctrl+Alt+=";
const binding_toggle = "Ctrl+Alt+0";
const name = "Dusk";
const pick_timeout_ms: u32 = 60 * 1000;

comptime {
    assert(!std.mem.eql(u8, binding_darker, binding_lighter));
    assert(!std.mem.eql(u8, binding_darker, binding_toggle));
    assert(!std.mem.eql(u8, binding_lighter, binding_toggle));
    assert(name.len > 0);
    assert(pick_timeout_ms > 0);
    assert(pick_timeout_ms <= umbra.limits.timer_interval_ms_max);
    assert(@backingInt(TimerID.pick) <= umbra.limits.timer_id_max);
}

const testing = std.testing;

const FakeLibraries = struct {
    pub const App = umbra.AppType(umbra.Fake);
    pub const Client = nimble.RuntimeType(nimble.Fake).Client;
    pub const Runtime = kalymma.RuntimeType(kalymma.Fake);
};

const FakeApplication = ApplicationType(FakeLibraries);

test ApplicationType {
    const application = try testing.allocator.create(FakeApplication);
    defer testing.allocator.destroy(application);

    try application.init(.{ .logger = null, .store = null });
    defer application.deinit();

    try testing.expect(!application.active);

    application.on_custom(.{ .code = @fromBackingInt(@backingInt(Message.toggle)) });

    try testing.expect(application.active);
    try testing.expectEqualStrings("active", application.runtime.icons.get_current_name().?);
    try testing.expectEqual(@as(u8, 1), application.dimmer.count);

    application.on_menu_select(.{ .checked = false, .id = Choice.encode(.toggle) });

    try testing.expect(!application.active);
    try testing.expectEqualStrings("inactive", application.runtime.icons.get_current_name().?);
    try testing.expect(application.dimmer.is_empty());
}

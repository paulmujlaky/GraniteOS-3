//! The loader's boot options: the end of the last failed boot's log, and a menu that leaves parts out to narrow a failure down.

const std = @import("std");

const boot = @import("../info.zig");
const variable = @import("variable.zig");
const Log = @import("../../debug/log.zig").Log;

const uefi = std.os.uefi;

const Choice = struct {

    key: u8,
    label: []const u8,
    field: []const u8,

};

const choices = [_]Choice{

    .{ .key = '1', .label = "Start only the first processor", .field = "processors" },
    .{ .key = '2', .label = "Keep the local APIC in xAPIC mode", .field = "x2apic" },
    .{ .key = '3', .label = "Leave USB out", .field = "usb" },
    .{ .key = '4', .label = "Leave NVMe out", .field = "nvme" },
    .{ .key = '5', .label = "Leave audio out", .field = "audio" },
    .{ .key = '6', .label = "Leave the network out", .field = "network" },

};

/// Shows what the last failed boot kept, then the menu if a key comes in time; returns what to leave out.
pub fn choose(services: *uefi.tables.BootServices, runtime: u64, log: Log) boot.Skip {

    var kept: [2048]u8 = undefined;
    const count = variable.readFailure(runtime, &kept);

    if (count != 0) {

        variable.keepFailure(runtime, &.{}) catch {

        };

        log.line("the last boot failed; its log ended:");
        log.write(kept[0..count]);
        text("\nThe last boot failed. Its log ended:\n");
        text(kept[0..count]);

    }

    text("\nPress any key for boot options.\n");

    // A failure leaves longer to read the log and pick options.
    if (!waited(services, if (count != 0) 30_000 else 1_500)) return .{};

    return menu(services, log);

}

fn menu(services: *uefi.tables.BootServices, log: Log) boot.Skip {

    var skip = boot.Skip{};

    while (true) {

        if (uefi.system_table.con_out) |output| output.clearScreen() catch {

        };

        text("Boot options, by number to switch; 0 picks safe mode, Enter boots:\n");

        inline for (choices) |choice| {

            text(if (@field(skip, choice.field)) "  [x] " else "  [ ] ");
            text(&.{choice.key});
            text("  ");
            text(choice.label);
            text("\n");

        }

        const key = next(services) orelse return skip;

        switch (key) {

            '\r', '\n' => break,
            '0' => skip = .{ .processors = true, .x2apic = true, .audio = true, .network = true },
            else => inline for (choices) |choice| {

                if (key == choice.key) @field(skip, choice.field) = !@field(skip, choice.field);

            },

        }

    }

    inline for (choices) |choice| if (@field(skip, choice.field)) log.line("boot option: " ++ choice.label);

    return skip;

}

/// Waits up to `milliseconds` for a key, taking it if one came.
fn waited(services: *uefi.tables.BootServices, milliseconds: usize) bool {

    const input = uefi.system_table.con_in orelse return false;

    for (0..milliseconds / 10) |_| {

        if (input.readKeyStroke()) |_| return true else |_| {

        }

        services.stall(10_000) catch return false;

    }

    return false;

}

/// The next key typed, as ASCII; null without a keyboard.
fn next(services: *uefi.tables.BootServices) ?u8 {

    const input = uefi.system_table.con_in orelse return null;

    while (true) {

        if (input.readKeyStroke()) |key| {

            if (key.unicode_char != 0 and key.unicode_char < 128) return @intCast(key.unicode_char);

        } else |_| {

            services.stall(10_000) catch return null;

        }

    }

}

/// Writes `bytes` to the firmware console, line feeds as CR LF.
fn text(bytes: []const u8) void {

    const output = uefi.system_table.con_out orelse return;

    for (bytes) |byte| {

        if (byte == '\n') _ = output.outputString(std.unicode.utf8ToUtf16LeStringLiteral("\r")) catch return;

        const character = [_:0]u16{if (byte >= 32 and byte < 127 or byte == '\n') byte else '?'};

        _ = output.outputString(&character) catch return;

    }

}

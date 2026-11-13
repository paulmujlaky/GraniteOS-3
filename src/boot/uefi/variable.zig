const std = @import("std");

const uefi = std.os.uefi;

pub const VariableError = error{ NoDevice, Invalid };

/// GraniteOS's own variables, kept apart from the ones the UEFI specification defines.
const vendor = uefi.Guid{

    .time_low = 0x6d2f8a4b,
    .time_mid = 0x91c3,
    .time_high_and_version = 0x4e7a,
    .clock_seq_high_and_reserved = 0xb0,
    .clock_seq_low = 0xd5,
    .node = .{ 0x3f, 0x8e, 0x2c, 0x1a, 0x9b, 0x47 },

};

const failure_name = std.unicode.utf8ToUtf16LeStringLiteral("GraniteFailure");

/// Keeps the end of a failed boot's log for the next boot; empty `data` forgets it.
pub fn keepFailure(table: u64, data: []const u8) VariableError!void {

    _ = try accessAs(table, failure_name, &vendor, @constCast(data), true);

}

/// Reads what the last failed boot kept into `data`; zero bytes when none did.
pub fn readFailure(table: u64, data: []u8) usize {

    return accessAs(table, failure_name, &vendor, data, false) catch 0;

}

/// Reads or writes a global firmware variable; runtime services stay in physical mode, so `table` is identity-mapped.
pub fn access(table: u64, name: [*:0]const u16, data: []u8, write: bool) VariableError!usize {

    return accessAs(table, name, &uefi.tables.global_variable, data, write);

}

fn accessAs(table: u64, name: [*:0]const u16, guid: *const uefi.Guid, data: []u8, write: bool) VariableError!usize {

    if (table == 0) return error.NoDevice;

    const services: *const uefi.tables.RuntimeServices = @ptrFromInt(table);

    const attributes = uefi.tables.RuntimeServices.VariableAttributes{

        .non_volatile = true,
        .bootservice_access = true,
        .runtime_access = true,

    };

    var size = data.len;

    const status = if (write) services._setVariable(name, guid, attributes, data.len, data.ptr) else services._getVariable(name, guid, null, &size, data.ptr);

    return switch (status) {

        .success => size,
        .not_found => error.NoDevice,
        else => error.Invalid,

    };

}

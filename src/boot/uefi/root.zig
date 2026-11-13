const std = @import("std");

const boot = @import("../info.zig");
const memory = @import("map.zig");
const graphics = @import("graphics.zig");
const clock = @import("clock.zig");
const menu = @import("menu.zig");
const Log = @import("../../debug/log.zig").Log;

const uefi = std.os.uefi;
const LoaderError = error{ MissingBootServices, MissingLoadedImage, MemoryMapUnstable };
var exit_attempted = false;

pub fn prepare(log: Log) !*const boot.Info {

    const table = uefi.system_table;
    const services = table.boot_services orelse return LoaderError.MissingBootServices;

    try services.setWatchdogTimer(0, 0, null);
    console("\r\nGraniteOS 3\r\nPreparing firmware handoff.\r\nA green band at the top confirms boot completed.\r\nSerial diagnostics: COM1, 115200 8N1.\r\n");

    const skip = menu.choose(services, @intFromPtr(table.runtime_services), log);
    const loaded = try services.handleProtocol(uefi.protocol.LoadedImage, uefi.handle) orelse return LoaderError.MissingLoadedImage;
    const info_bytes = try services.allocatePool(.loader_data, @sizeOf(boot.Info));
    const info: *boot.Info = @ptrCast(@alignCast(info_bytes.ptr));
    const stack = try services.allocatePages(.any, .loader_data, 16);

    const trampoline = try services.allocatePages(.{

        .max_address = @ptrFromInt(0xff000),

    }, .loader_data, 1);

    info.* = .{

        .memory = &.{

        },

        .image = .{

            .base = @intFromPtr(loaded.image_base),
            .size = loaded.image_size,
            .kind = .loader,

        },
        .stack = .{

            .base = @intFromPtr(stack.ptr),
            .size = stack.len * 4096,
            .kind = .loader,

        },

        .framebuffer = try graphics.capture(services, log),
        .acpi_rsdp = findAcpi(table),
        .trampoline = @intFromPtr(trampoline.ptr),
        .runtime = @intFromPtr(table.runtime_services),
        .efi = copy(services, loaded),
        .clock = clock.capture(table.runtime_services),
        .skip = skip,

    };

    var map = try memory.Map.allocate(services);

    for (0..8) |_| {

        if (try map.read(services) == .success) break;

        try services.freePool(map.buffer.ptr);
        try services.freePool(@ptrCast(map.regions.ptr));

        map = try memory.Map.allocate(services);

    } else return LoaderError.MemoryMapUnstable;

    log.line("exit firmware");
    info.memory = try map.finish(services, uefi.handle, &exit_attempted);
    log.line("firmware released");

    return info;

}

// Reads the loader's own file for the installer; null when the boot volume cannot provide it.
fn copy(services: *uefi.tables.BootServices, loaded: *const uefi.protocol.LoadedImage) ?boot.Region {

    const device = loaded.device_handle orelse return null;
    const filesystem = (services.handleProtocol(uefi.protocol.SimpleFileSystem, device) catch return null) orelse return null;
    const volume = filesystem.openVolume() catch return null;

    var path = std.mem.zeroes([256:0]u16);
    var node: [*]const u8 = @ptrCast(loaded.file_path);

    // ponytail: takes the first file-path node; firmware that splits the path across nodes needs concatenation.
    while (node[0] != 0x7f) {

        const length = std.mem.readInt(u16, node[2..4], .little);

        if (length < 4) return null;

        if (node[0] == 4 and node[1] == 4) {

            if (length < 6 or (length - 4) / 2 > path.len) return null;
            @memcpy(std.mem.sliceAsBytes(path[0 .. (length - 4) / 2]), node[4..length]);
            break;

        }

        node += length;

    } else return null;

    const file = volume.open(&path, .read, .{}) catch return null;
    var info: [512]u8 align(8) = undefined;
    const size = (file.getInfo(.file, &info) catch return null).file_size;
    const pages = services.allocatePages(.any, .loader_data, (size + 4095) / 4096) catch return null;
    const bytes = std.mem.sliceAsBytes(pages)[0..size];

    if ((file.read(bytes) catch return null) != size) return null;

    return .{

        .base = @intFromPtr(pages.ptr),
        .size = size,
        .kind = .loader,

    };

}

fn findAcpi(table: *uefi.tables.SystemTable) ?u64 {

    const Configuration = uefi.tables.ConfigurationTable;
    var legacy: ?u64 = null;

    for (table.configuration_table[0..table.number_of_table_entries]) |entry| {

        if (entry.vendor_guid.eql(Configuration.acpi_20_table_guid)) return @intFromPtr(entry.vendor_table);
        if (entry.vendor_guid.eql(Configuration.acpi_10_table_guid)) legacy = @intFromPtr(entry.vendor_table);

    }

    return legacy;

}

fn console(comptime message: []const u8) void {

    if (uefi.system_table.con_out) |output| {

        _ = output.outputString(std.unicode.utf8ToUtf16LeStringLiteral(message)) catch return;

    }

}

pub fn reportFailure(name: []const u8) void {

    if (exit_attempted) return;

    console("\r\nBOOT FAILED: ");

    if (uefi.system_table.con_out) |output| {

        for (name) |byte| {

            const character = [_:0]u16{

                byte,

            };

            _ = output.outputString(&character) catch return;

        }

    }

    console("\r\nSee serial diagnostics. Reset to return to firmware.\r\n");

}

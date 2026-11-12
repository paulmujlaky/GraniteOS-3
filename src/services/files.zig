const std = @import("std");

const volume = @import("volume.zig");
const disk = @import("disk.zig");

const api = @import("api");

const protocol = api.protocol;
pub const panic = api.panic;

const path_limit = 1024;

var mounted: volume.Volume(disk.Disk) = undefined;
var ready = false;

var path: [path_limit + 1]u8 = undefined;
// As much as one fetch or store moves, so large files cross in few steps.
var chunk: [0x10000]u8 = undefined;
var sector: [512]u8 = undefined;

pub export fn app_main(_: usize, _: usize, environment: *const api.abi.Environment) callconv(.c) noreturn {

    api.start(environment, .service);
    if (!api.permits(.ipc) or api.permits(.ports) or api.permits(.management) or api.permits(.dma)) api.exit(2);

    while (true) {

        const message = api.receive(true) catch continue;

        api.answer(message, handle(message));

    }

}

fn handle(message: api.Request) u64 {

    const operation = protocol.operation(message.second);
    const value = protocol.value(message.second);

    switch (operation) {

        .hello => return protocol.version,
        .crash => return api.crash(message),
        .list, .read, .write, .create, .directory, .remove, .volume, .change, .rename => {

        },
        else => return protocol.invalid,

    }

    // Mounting waits for the first request, so the supervisor's handshake never waits on storage.
    if (!ready) mount() catch |err| return code(err);
    mounted.user = api.sender(message).user;

    if (operation == .volume) {

        const usage = mounted.usage();
        const bytes = std.mem.toBytes([2]u64{ usage.total, usage.free });

        api.store(message, 0, &bytes) catch return protocol.invalid;

        return 0;

    }

    const window = message.fourth;
    const size = @min(window, path.len);

    api.fetch(message, 0, path[0..size]) catch return protocol.invalid;

    const length = std.mem.indexOfScalar(u8, path[0..size], 0) orelse return protocol.invalid;
    const name = path[0..length];

    return serve(message, operation, value, name, window - length - 1) catch |err| code(err);

}

fn serve(message: api.Request, operation: protocol.Operation, value: u56, name: []const u8, payload: u64) (volume.Error || api.ApiError)!u64 {

    switch (operation) {

        .create => try mounted.create(name, .file),
        .directory => try mounted.create(name, .directory),
        .remove => try mounted.remove(name),
        .rename => {

            // The new path follows the old one, NUL-terminated too.
            const rest = path[name.len + 1 .. @min(name.len + 1 + payload, path.len)];
            const end = std.mem.indexOfScalar(u8, rest, 0) orelse return error.Invalid;

            try mounted.rename(name, rest[0..end]);

        },
        .change => {

            const owner: u32 = @truncate(value >> 16);

            try mounted.change(name, @truncate(value), if (owner == api.abi.nobody.user) null else owner);

        },
        .read => {

            const node = try mounted.file(name, 4);
            var done: u64 = 0;

            while (done < message.fourth) {

                const count = try mounted.get(node, value + done, chunk[0..@min(chunk.len, message.fourth - done)]);
                if (count == 0) break;

                try api.store(message, done, chunk[0..count]);
                done += count;

            }

            return done;

        },
        .write => {

            if (payload == 0) return 0;

            const start = name.len + 1;
            const node = try mounted.file(name, 2);
            var done: u64 = 0;

            while (done < payload) {

                const count = @min(chunk.len, payload - done);

                try api.fetch(message, start + done, chunk[0..count]);
                try mounted.put(node, value + done, chunk[0..count]);
                done += count;

            }

            try mounted.flush();

            return done;

        },
        .list => {

            // Records are kind, size, mode, owner, name length, then the name.
            var done: u64 = 0;
            var index: u64 = value;

            while (try mounted.entry(name, index)) |entry| : (index += 1) {

                const record = 16 + entry.name.len;
                if (done + record > message.fourth) break;

                chunk[0] = @intFromEnum(entry.kind);
                std.mem.writeInt(u64, chunk[1..9], entry.size, .little);
                std.mem.writeInt(u16, chunk[9..11], entry.mode, .little);
                std.mem.writeInt(u32, chunk[11..15], entry.owner, .little);
                chunk[15] = @intCast(entry.name.len);
                @memcpy(chunk[16..record], entry.name);

                try api.store(message, done, chunk[0..record]);
                done += record;

            }

            return index - value;

        },
        else => return protocol.invalid,

    }

    return 0;

}

fn mount() volume.Error!void {

    var index: u8 = 0;

    while (index < 32) : (index += 1) {

        const sectors = try disk.sectors(index);
        if (sectors == 0) break;

        const target = disk.Disk{

            .index = index,

        };

        const range = try volume.find(target, &sector, sectors) orelse continue;
        const formatted = try mounted.mount(target, range);

        ready = true;
        api.log(if (formatted) "files: volume formatted\n" else "files: volume mounted\n");

        return;

    }

    return error.Missing;

}

fn code(err: anyerror) u64 {

    return switch (err) {

        error.Missing => protocol.missing,
        error.Exists => protocol.exists,
        error.Full => protocol.full,
        error.Busy => protocol.busy,
        error.Denied => protocol.denied,
        else => protocol.invalid,

    };

}

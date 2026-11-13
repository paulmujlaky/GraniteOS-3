const std = @import("std");

const cpu = @import("arch/root.zig").cpu;
const serial = @import("board/pc/serial.zig");
const screen = @import("debug/screen.zig");
const loader = @import("boot/uefi/root.zig");
const boot = @import("boot/info.zig");
const kernel = @import("kernel/root.zig");

const Log = @import("debug/log.zig").Log;

var log = Log{

    .output = output,
    .scope = "boot",

};

pub const panic = std.debug.FullPanic(fatal);

pub fn main() noreturn {

    serial.init();
    log.line("GraniteOS 3 (x86_64 UEFI)");

    const info = loader.prepare(log) catch |err| {

        loader.reportFailure(@errorName(err));
        fatal(@errorName(err), null);

    };

    cpu.enter(info, @intCast(info.stack.base + info.stack.size), entry);

}

fn entry(pointer: *const anyopaque) callconv(.c) noreturn {

    const info: *const boot.Info = @ptrCast(@alignCast(pointer));
    const stack = cpu.stackPointer();

    if (cpu.interruptsEnabled() or stack < info.stack.base or stack >= info.stack.base + info.stack.size) {

        fatal("Invalid CPU handoff", null);

    }

    log.line("handoff ready");
    log.scope = "kernel";

    kernel.start(info, log) catch |err| kernel.failure(@errorName(err));

}

fn output(bytes: []const u8) void {

    serial.write(bytes);
    screen.write(bytes);

}

fn fatal(message: []const u8, address: ?usize) noreturn {

    if (std.mem.eql(u8, log.scope, "kernel")) kernel.failureAt(message, address);
    log.err(message);
    cpu.halt();

}

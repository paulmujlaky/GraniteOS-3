const api = @import("api");

const protocol = api.protocol;
pub const panic = api.panic;
const base = 0x2f8;

pub export fn app_main(_: usize, _: usize, environment: *const api.abi.Environment) callconv(.c) noreturn {

    api.start(environment, .service);
    if (!api.permits(.ports) or api.permits(.management) or api.permits(.mmio)) api.exit(2);

    if (api.raw(.port, 0x3f8, 0, 0).number != 1 or api.raw(.map, 0xfee00000, 0, 0).number != 1 or api.raw(.spawn, 0, 0, 0).number != 1) api.exit(2);

    output(1, 0);
    output(3, 0x80);
    output(0, 1);
    output(1, 0);
    output(3, 3);
    output(2, 0xc7);
    output(4, 3);
    output(7, 0x5a);
    if (input(7) != 0x5a or input(5) == 0xff) api.exit(3);

    while (true) {

        const request = api.receive(true) catch continue;
        const value = protocol.value(request.second);

        const result: u64 = switch (protocol.operation(request.second)) {

            .hello => protocol.version,
            .write => if (write(value)) 0 else protocol.invalid,
            .read => if (input(5) & 1 != 0) input(0) else protocol.empty,
            .crash => api.crash(request),
            else => protocol.invalid,

        };

        api.answer(request, result);

    }

}

fn input(offset: u16) u8 {

    const result = api.raw(.port, base + offset, 0, 0);
    if (result.number != 0) api.exit(1);

    return @intCast(result.first);

}

fn output(offset: u16, byte: u8) void {

    if (api.raw(.port, base + offset, 1, byte).number != 0) api.exit(1);

}

fn write(chunk: u56) bool {

    const deadline = api.ticks() + 10;

    while (input(5) & 0x20 == 0) {

        if (api.ticks() >= deadline) return false;
        _ = api.raw(.yield, 0, 0, 0);

    }

    // An empty transmit FIFO holds 16 bytes, so a whole chunk fits without polling again.
    var rest = chunk;

    while (rest != 0) : (rest >>= 8) output(0, @truncate(rest));

    return true;

}

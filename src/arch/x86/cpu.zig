pub inline fn out(port: u16, value: u8) void {

    asm volatile ("outb %[value], %[port]" // Write one byte to an I/O port.
        :
        : [value] "{al}" (value),
          [port] "{dx}" (port),
        : .{

            .memory = true,

        });

}

pub inline fn in(port: u16) u8 {

    return asm volatile ("inb %[port], %[value]" // Read one byte from an I/O port.
        : [value] "={al}" (-> u8),
        : [port] "{dx}" (port),
        : .{

            .memory = true,

        });

}

pub inline fn out16(port: u16, value: u16) void {

    asm volatile ("outw %[value], %[port]" // Write two bytes to an I/O port.
        :
        : [value] "{ax}" (value),
          [port] "{dx}" (port),
        : .{

            .memory = true,

        });

}

pub inline fn in16(port: u16) u16 {

    return asm volatile ("inw %[port], %[value]" // Read two bytes from an I/O port.
        : [value] "={ax}" (-> u16),
        : [port] "{dx}" (port),
        : .{

            .memory = true,

        });

}

pub inline fn out32(port: u16, value: u32) void {

    asm volatile ("outl %[value], %[port]" // Write four bytes to an I/O port.
        :
        : [value] "{eax}" (value),
          [port] "{dx}" (port),
        : .{

            .memory = true,

        });

}

pub inline fn in32(port: u16) u32 {

    return asm volatile ("inl %[port], %[value]" // Read four bytes from an I/O port.
        : [value] "={eax}" (-> u32),
        : [port] "{dx}" (port),
        : .{

            .memory = true,

        });

}

pub fn halt() noreturn {

    disable();

    while (true) asm volatile ("hlt"); // Halt this CPU.

}

pub fn interruptsEnabled() bool {

    const flags = asm volatile ("pushfq; popq %[flags]" // Read the CPU flags.
        : [flags] "=r" (-> usize),
    );

    return flags & (1 << 9) != 0;

}

pub fn stackPointer() usize {

    return asm volatile ("movq %%rsp, %[stack]" // Read the stack pointer.
        : [stack] "=r" (-> usize),
    );

}

pub extern fn enter(info: *const anyopaque, stack_top: usize, entry: *const fn (*const anyopaque) callconv(.c) noreturn) callconv(.c) noreturn;

pub fn readMsr(index: u32) u64 {

    var low: u32 = undefined;
    var high: u32 = undefined;

    asm volatile ("rdmsr" // Read a model-specific CPU register.
        : [low] "={eax}" (low),
          [high] "={edx}" (high),
        : [index] "{ecx}" (index),
    );

    return (@as(u64, high) << 32) | low;

}

pub fn writeMsr(index: u32, value: u64) void {

    asm volatile ("wrmsr" // Write a model-specific CPU register.
        :
        : [index] "{ecx}" (index),
          [low] "{eax}" (@as(u32, @truncate(value))),
          [high] "{edx}" (@as(u32, @truncate(value >> 32))),
        : .{

            .memory = true,

        });

}

/// Returns EAX, EBX, ECX, and EDX for CPUID leaf `leaf` and subleaf `sub`.
pub fn cpuid(leaf: u32, sub: u32) [4]u32 {

    var a: u32 = undefined;
    var b: u32 = undefined;
    var c: u32 = undefined;
    var d: u32 = undefined;

    asm volatile ("cpuid" // Ask the processor what it supports.
        : [a] "={eax}" (a),
          [b] "={ebx}" (b),
          [c] "={ecx}" (c),
          [d] "={edx}" (d),
        : [leaf] "{eax}" (leaf),
          [sub] "{ecx}" (sub),
    );

    return .{ a, b, c, d };

}

pub fn relax() void {

    asm volatile ("pause"); // Pause briefly in the busy loop.

}

pub fn disable() void {

    asm volatile ("cli" ::: .{ // Disable maskable interrupts.

            .memory = true,

        });

}

pub fn ticks() u64 {

    var low: u32 = undefined;
    var high: u32 = undefined;

    asm volatile ("rdtsc" // Read the timestamp counter.
        : [low] "={eax}" (low),
          [high] "={edx}" (high),
    );

    return (@as(u64, high) << 32) | low;

}

// The power-on layout with entry 1 turned from write-through to write-combining, which framebuffers need to be fast.
const pat = 0x0007040600070106;

pub fn features() void {

    const cr0 = asm volatile ("mov %%cr0, %[value]" // Read the primary CPU controls.
        : [value] "=r" (-> usize),
    );

    asm volatile ("mov %[value], %%cr0" // Enable the FPU and kernel write protection.
        :
        : [value] "r" ((cr0 & ~@as(usize, 12)) | 0x10002),
        : .{

            .memory = true,

        });

    const cr4 = asm volatile ("mov %%cr4, %[value]" // Read the extended CPU controls.
        : [value] "=r" (-> usize),
    );

    // FXSAVE owns the complete enabled user floating-point state.
    asm volatile ("mov %[value], %%cr4" // Enable SSE state; disable unmanaged features.
        :
        : [value] "r" ((cr4 | 0x600) & ~@as(usize, 0x70000)),
        : .{

            .memory = true,

        });

    writeMsr(0xc0000080, readMsr(0xc0000080) | (1 << 11));
    // Page tables pick memory types by this layout, whatever the firmware left.
    if (readMsr(0x277) != pat) {

        writeMsr(0x277, pat);
        asm volatile ("wbinvd" ::: .{ // Drop cache lines filled under the old memory types.

                .memory = true,

            });

    }

    asm volatile ("fninit"); // Reset the x87 floating-point state.
    const mxcsr: u32 = 0x1f80;

    asm volatile ("ldmxcsr (%[value])" // Load the default SSE control flags.
        :
        : [value] "r" (&mxcsr),
        : .{

            .memory = true,

        });

}

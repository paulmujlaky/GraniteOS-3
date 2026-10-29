const std = @import("std");

const abi = @import("src/kernel/abi.zig");

pub fn build(b: *std.Build) void {

    const optimize = b.standardOptimizeOption(.{

    });

    const options = b.addOptions();

    options.addOption(bool, "self_test", b.option(bool, "self-test", "Run the embedded kernel and service acceptance workload") orelse true);

    const application = b.addExecutable(.{

        .name = "probe",

        .use_llvm = true,
        .use_lld = true,

        .root_module = b.createModule(.{

            .root_source_file = b.path("src/user/main.zig"),
            .target = b.resolveTargetQuery(.{

                .cpu_arch = .x86_64,
                .os_tag = .freestanding,
                .abi = .none,
                .cpu_model = .baseline,

            }),
            .optimize = optimize,

            .red_zone = false,
            .stack_check = false,
            .stack_protector = false,
            .code_model = .large,

        }),

    });

    application.root_module.addAssemblyFile(b.path("src/user/asm/entry.S"));

    application.root_module.addAnonymousImport("abi", .{

        .root_source_file = b.path("src/kernel/abi.zig"),

    });

    application.setLinkerScript(b.path("src/user/asm/link.ld"));
    b.installArtifact(application);

    const target = b.resolveTargetQuery(.{

        .cpu_arch = .x86_64,
        .os_tag = .uefi,
        .abi = .msvc,
        .cpu_model = .baseline,

    });

    const module = b.createModule(.{

        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,

        .red_zone = false,
        .stack_check = false,
        .stack_protector = false,

    });

    const boot = b.addExecutable(.{

        .name = "BOOTX64",
        .root_module = module,

    });

    module.addOptions("options", options);

    module.addAnonymousImport("application", .{

        .root_source_file = application.getEmittedBin(),

    });

    const api = b.createModule(.{

        .root_source_file = b.path("src/api/root.zig"),
        .target = application.root_module.resolved_target,
        .optimize = optimize,

        .red_zone = false,
        .stack_check = false,
        .stack_protector = false,
        .code_model = .large,

    });

    api.addAnonymousImport("abi", .{

        .root_source_file = b.path("src/kernel/abi.zig"),

    });

    const gui = b.createModule(.{

        .root_source_file = b.path("src/gui/root.zig"),
        .target = application.root_module.resolved_target,
        .optimize = optimize,

        .red_zone = false,
        .stack_check = false,
        .stack_protector = false,
        .code_model = .large,

    });

    gui.addImport("api", api);

    const media = b.createModule(.{

        .root_source_file = b.path("src/media/root.zig"),
        .target = application.root_module.resolved_target,
        .optimize = optimize,

        .red_zone = false,
        .stack_check = false,
        .stack_protector = false,
        .code_model = .large,

    });

    const pictures = b.createModule(.{

        .root_source_file = b.path("src/pictures/root.zig"),

    });

    const images = std.enums.values(abi.Image);

    // The supervisor comes first; the kernel starts it rather than embedding it as an image.
    for (0..images.len + 1) |index| {

        const name = if (index == 0) "supervisor" else @tagName(images[index - 1]);
        const app = index != 0 and images[index - 1].application();

        const program = b.addExecutable(.{

            .name = name,

            .use_llvm = true,
            .use_lld = true,

            .root_module = b.createModule(.{

                .root_source_file = b.path(b.fmt("src/{s}/{s}.zig", .{

                    if (app) "apps" else "services", name,

                })),
                .target = application.root_module.resolved_target,
                .optimize = optimize,

                // The boot volume holds every program, so they leave out debug info, which nothing in the guest reads.
                .strip = true,

                .red_zone = false,
                .stack_check = false,
                .stack_protector = false,
                .code_model = .large,

            }),

        });

        program.root_module.addImport("api", api);
        program.root_module.addImport("gui", gui);
        program.root_module.addImport("media", media);
        program.root_module.addImport("pictures", pictures);
        program.root_module.addOptions("options", options);
        program.root_module.addAssemblyFile(b.path("src/user/asm/entry.S"));
        program.setLinkerScript(b.path("src/user/asm/link.ld"));
        b.installArtifact(program);

        module.addAnonymousImport(name, .{

            .root_source_file = program.getEmittedBin(),

        });

    }

    boot.subsystem = .EfiApplication;
    module.addAssemblyFile(b.path("src/arch/x86/asm/entry.S"));
    module.addAssemblyFile(b.path("src/arch/x86/asm/interrupt.S"));
    module.addAssemblyFile(b.path("src/arch/x86/asm/startup.S"));

    const install = b.addInstallArtifact(boot, .{

        .dest_dir = .{

            .override = .{

                .custom = "esp/EFI/BOOT",

            },

        },
        .dest_sub_path = "BOOTX64.EFI",

    });

    b.getInstallStep().dependOn(&install.step);

    const tests = b.addTest(.{

        .root_module = b.createModule(.{

            .root_source_file = b.path("src/tests.zig"),
            .target = b.graph.host,
            .optimize = optimize,

        }),

    });

    b.step("test", "Test boot contracts and kernel policies").dependOn(&b.addRunArtifact(tests).step);

}

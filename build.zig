const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Native executable
    const exe = b.addExecutable(.{
        .name = "zircon",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(exe);

    // Freestanding WebAssembly artifact
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });
    const wasm = b.addExecutable(.{
        .name = "zircon",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/wasm.zig"),
            .target = wasm_target,
            .optimize = .ReleaseSmall,
        }),
    });
    wasm.entry = .disabled;
    wasm.root_module.export_symbol_names = &.{
        "zircon_init",
        "zircon_reset",
        "zircon_load_byte",
        "zircon_step",
        "zircon_step_back",
        "zircon_get_pc",
        "zircon_set_pc",
        "zircon_get_reg",
        "zircon_get_cycles",
        "zircon_get_inst_count",
        "zircon_is_halted",
        "zircon_get_ram_ptr",
        "zircon_get_ram_size",
    };
    b.installArtifact(wasm);

    // Test runner
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}

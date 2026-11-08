// Copyright (c) 2026 jk9576. All rights reserved.
// Zircon: Freestanding RISC-V (RV32I) Micro-Emulator & Stepper
// Licensed under the MIT License.

const std = @import("std");
pub const cpu = @import("cpu.zig");

// Global freestanding instance for WebAssembly
var global_cpu: cpu.CPU = undefined;
var initialized: bool = false;

pub export fn zircon_init() void {
    global_cpu = cpu.CPU.init();
    initialized = true;
}

pub export fn zircon_reset() void {
    global_cpu.reset();
}

pub export fn zircon_load_byte(offset: u32, byte: u8) i32 {
    if (offset >= cpu.RAM_SIZE) return -1;
    global_cpu.ram[offset] = byte;
    return 0;
}

pub export fn zircon_step() i32 {
    if (!initialized) zircon_init();
    const ok = global_cpu.step() catch return -1;
    return if (ok) 1 else 0;
}

pub export fn zircon_step_back() i32 {
    if (!initialized) return 0;
    return if (global_cpu.stepBack()) 1 else 0;
}

pub export fn zircon_get_pc() u32 {
    return global_cpu.pc;
}

pub export fn zircon_set_pc(new_pc: u32) void {
    global_cpu.pc = new_pc;
}

pub export fn zircon_get_reg(idx: u32) u32 {
    if (idx >= 32) return 0;
    return global_cpu.readReg(@truncate(idx));
}

pub export fn zircon_get_cycles() u32 {
    return @truncate(global_cpu.cycles);
}

pub export fn zircon_get_inst_count() u32 {
    return @truncate(global_cpu.inst_count);
}

pub export fn zircon_is_halted() i32 {
    return if (global_cpu.halted) 1 else 0;
}

pub export fn zircon_get_ram_ptr() [*]u8 {
    return &global_cpu.ram;
}

pub export fn zircon_get_ram_size() u32 {
    return cpu.RAM_SIZE;
}

pub fn main() !void {
    var c = cpu.CPU.init();

    // Small demonstration program:
    // addi x1, x0, 10
    // addi x2, x0, 20
    // add  x3, x1, x2
    // ecall
    const prog = [_]u8{
        0x93, 0x00, 0xa0, 0x00, // addi x1, x0, 10
        0x13, 0x01, 0x40, 0x01, // addi x2, x0, 20
        0xb3, 0x81, 0x20, 0x00, // add  x3, x1, x2 (0x002081b3)
        0x73, 0x00, 0x00, 0x00, // ecall
    };

    try c.loadProgram(&prog, 0);

    while (try c.step()) {}

    std.debug.print("Zircon RV32I Execution Finished.\n", .{});
    std.debug.print("PC: 0x{X:0>8}, Cycles: {}, x1: {}, x2: {}, x3: {}\n", .{
        c.pc,
        c.cycles,
        c.readReg(1),
        c.readReg(2),
        c.readReg(3),
    });
}

test "RV32I basic ALU and stepping" {
    var c = cpu.CPU.init();
    const prog = [_]u8{
        0x93, 0x00, 0xa0, 0x00, // addi x1, x0, 10
        0x13, 0x01, 0x40, 0x01, // addi x2, x0, 20
        0xb3, 0x81, 0x20, 0x00, // add  x3, x1, x2 (0x002081b3)
        0x33, 0x02, 0x11, 0x40, // sub  x4, x2, x1 (0x40110233)
        0x73, 0x00, 0x00, 0x00, // ecall
    };

    try c.loadProgram(&prog, 0);

    // Step 1: addi x1, x0, 10
    _ = try c.step();
    try std.testing.expectEqual(@as(u32, 10), c.readReg(1));

    // Step 2: addi x2, x0, 20
    _ = try c.step();
    try std.testing.expectEqual(@as(u32, 20), c.readReg(2));

    // Step 3: add x3, x1, x2 -> 30
    _ = try c.step();
    try std.testing.expectEqual(@as(u32, 30), c.readReg(3));

    // Step 4: sub x4, x2, x1 -> 10
    _ = try c.step();
    try std.testing.expectEqual(@as(u32, 10), c.readReg(4));

    // Test reversible step back
    try std.testing.expect(c.stepBack());
    try std.testing.expectEqual(@as(u32, 0), c.readReg(4));
    try std.testing.expectEqual(@as(u32, 30), c.readReg(3));
}

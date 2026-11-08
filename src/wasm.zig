// Copyright (c) 2026 jk9576. All rights reserved.
// Zircon: Freestanding RISC-V (RV32I) Micro-Emulator & Stepper
// Licensed under the MIT License.

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

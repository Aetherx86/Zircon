// Copyright (c) 2026 jk9576. All rights reserved.
// Zircon: Freestanding RISC-V (RV32I) Micro-Emulator & Stepper
// Licensed under the MIT License.

pub const cpu = @import("cpu.zig");
const isa = @import("isa.zig");
const disasm = @import("disasm.zig");
const asmz = @import("asm.zig");

/// Size of the shared text buffer used for assembler source input,
/// disassembly output and assembler diagnostics.
pub const TEXT_CAPACITY: usize = 16 * 1024;

// Global freestanding instance for WebAssembly
var global_cpu: cpu.CPU = undefined;
var initialized: bool = false;
var text_buf: [TEXT_CAPACITY]u8 = undefined;
// Left undefined so the label table lives in zero-initialised memory rather
// than the data section; `Assembler.assemble` initialises every field it reads.
var assembler: asmz.Assembler = undefined;

fn ensureInit() void {
    if (!initialized) zircon_init();
}

// ---------------------------------------------------------------------------
// 0.1.0 exports (names and signatures unchanged)
// ---------------------------------------------------------------------------

pub export fn zircon_init() void {
    global_cpu = cpu.CPU.init();
    initialized = true;
}

pub export fn zircon_reset() void {
    global_cpu.reset();
    initialized = true;
}

pub export fn zircon_load_byte(offset: u32, byte: u8) i32 {
    if (offset >= cpu.RAM_SIZE) return -1;
    ensureInit();
    global_cpu.ram[offset] = byte;
    return 0;
}

pub export fn zircon_step() i32 {
    ensureInit();
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

// ---------------------------------------------------------------------------
// 0.2.0 exports
// ---------------------------------------------------------------------------

/// Packed version: major << 16 | minor << 8 | patch.
pub export fn zircon_get_version() u32 {
    return (cpu.version_major << 16) | (cpu.version_minor << 8) | cpu.version_patch;
}

/// Trap cause (0 none, 1 pc out of bounds, 2 illegal instruction, 3 access
/// fault, 4 misaligned fetch, 0x73 ecall, 0x74 ebreak).
pub export fn zircon_get_trap_code() u32 {
    return global_cpu.trap_code;
}

/// Faulting address, instruction word, or the pc of an ecall/ebreak.
pub export fn zircon_get_trap_value() u32 {
    return global_cpu.trap_value;
}

/// Low 32 bits of a pipeline statistic or counter; see `cpu.StatId`.
/// Unknown ids return 0.
pub export fn zircon_get_stat(id: u32) u32 {
    if (id > @backingInt(cpu.StatId.history_len)) return 0;
    return @truncate(global_cpu.stat(@fromBackingInt(@intCast(id))));
}

/// Runs up to `max_steps` instructions; returns how many retired.
pub export fn zircon_run(max_steps: u32) u32 {
    ensureInit();
    return @intCast(global_cpu.run(max_steps));
}

pub export fn zircon_get_text_ptr() [*]u8 {
    return &text_buf;
}

pub export fn zircon_get_text_capacity() u32 {
    return TEXT_CAPACITY;
}

/// Disassembles `word` as if located at `pc` into the text buffer and returns
/// the length of the line.
pub export fn zircon_disasm(word: u32, pc: u32) u32 {
    return @intCast(disasm.disassemble(word, pc, &text_buf).len);
}

/// Assembles `src_len` bytes of source from the text buffer into RAM at
/// `base`. On success returns the image size in bytes, sets pc to `base`,
/// clears any halt/trap state and empties the step-back history (whose memory
/// undo entries would refer to the previous program); registers, counters and
/// RAM outside the image are left alone. On failure returns
/// the negated length of a `line N: message` diagnostic written to the text
/// buffer, and leaves RAM untouched.
pub export fn zircon_assemble(src_len: u32, base: u32) i32 {
    ensureInit();
    var diag_buf: [128]u8 = undefined;
    if (src_len > TEXT_CAPACITY or base > cpu.RAM_SIZE) {
        const msg = "line 0: source too long or base outside RAM";
        @memcpy(text_buf[0..msg.len], msg);
        return -@as(i32, msg.len);
    }
    const n = assembler.assemble(text_buf[0..src_len], base, global_cpu.ram[base..]) catch {
        const diag = assembler.diagnostic(&diag_buf);
        @memcpy(text_buf[0..diag.len], diag);
        return -@as(i32, @intCast(diag.len));
    };
    global_cpu.pc = base;
    global_cpu.halted = false;
    global_cpu.trap_code = 0;
    global_cpu.trap_value = 0;
    global_cpu.history_len = 0;
    global_cpu.hit_breakpoint = false;
    return @intCast(n);
}

// ---------------------------------------------------------------------------
// 0.3.0 exports
// ---------------------------------------------------------------------------

/// Write a general-purpose register `x1..x31` (`x0` and out-of-range indices are ignored).
pub export fn zircon_set_reg(idx: u32, val: u32) void {
    if (idx == 0 or idx >= 32) return;
    ensureInit();
    global_cpu.writeReg(@truncate(idx), val);
}

/// Register a PC breakpoint (up to 16). Returns 1 on success, 0 if table is full.
pub export fn zircon_add_breakpoint(addr: u32) i32 {
    ensureInit();
    return if (global_cpu.addBreakpoint(addr)) 1 else 0;
}

/// Remove a previously set PC breakpoint. Returns 1 if removed, 0 if not present.
pub export fn zircon_remove_breakpoint(addr: u32) i32 {
    if (!initialized) return 0;
    return if (global_cpu.removeBreakpoint(addr)) 1 else 0;
}

/// Remove all active PC breakpoints.
pub export fn zircon_clear_breakpoints() void {
    if (!initialized) return;
    global_cpu.clearBreakpoints();
}

/// Returns 1 if the most recent `zircon_run` stopped at a breakpoint, 0 otherwise.
pub export fn zircon_hit_breakpoint() i32 {
    if (!initialized) return 0;
    return if (global_cpu.hit_breakpoint) 1 else 0;
}

const std = @import("std");
const testing = std.testing;

fn putSource(src: []const u8) u32 {
    @memcpy(zircon_get_text_ptr()[0..src.len], src);
    return @intCast(src.len);
}

test "wasm exports: assemble, run, statistics and step back" {
    zircon_init();
    try testing.expectEqual(@as(u32, 0x000300), zircon_get_version());
    const len = putSource(
        \\        li   x1, 5
        \\        li   x2, 0
        \\loop:   add  x2, x2, x1
        \\        addi x1, x1, -1
        \\        bnez x1, loop
        \\        sw   x2, 64(x0)
        \\        ecall
    );
    try testing.expectEqual(@as(i32, 28), zircon_assemble(len, 0));
    try testing.expectEqual(@as(u32, 0), zircon_get_pc());
    const retired = zircon_run(1000);
    try testing.expectEqual(@as(u32, 2 + 5 * 3 + 2), retired);
    try testing.expectEqual(@as(i32, 1), zircon_is_halted());
    try testing.expectEqual(@as(u32, 0x73), zircon_get_trap_code());
    try testing.expectEqual(@as(u32, 15), zircon_get_reg(2));
    try testing.expectEqual(@as(u8, 15), zircon_get_ram_ptr()[64]);
    // Four taken branches cost two bubbles each.
    try testing.expectEqual(@as(u32, 4), zircon_get_stat(@backingInt(cpu.StatId.branches_taken)));
    try testing.expectEqual(@as(u32, 8), zircon_get_stat(@backingInt(cpu.StatId.flush_cycles)));
    try testing.expectEqual(retired + 8, zircon_get_cycles());
    try testing.expectEqual(@as(u32, 0), zircon_get_stat(999));

    // Undo ecall, then the store: memory is restored.
    try testing.expectEqual(@as(i32, 1), zircon_step_back());
    try testing.expectEqual(@as(i32, 0), zircon_is_halted());
    try testing.expectEqual(@as(i32, 1), zircon_step_back());
    try testing.expectEqual(@as(u8, 0), zircon_get_ram_ptr()[64]);
    try testing.expectEqual(@as(i32, 1), zircon_step());
    try testing.expectEqual(@as(u8, 15), zircon_get_ram_ptr()[64]);
}

test "wasm exports: disassembly and assembler diagnostics" {
    zircon_init();
    const n = zircon_disasm(0x002081b3, 0);
    try testing.expectEqualStrings("add x3, x1, x2", zircon_get_text_ptr()[0..n]);

    zircon_get_ram_ptr()[0] = 0x5a;
    const len = putSource("nop\naddi x1, x0, 5000\n");
    const r = zircon_assemble(len, 0);
    try testing.expect(r < 0);
    try testing.expectEqualStrings("line 2: immediate out of range (-2048..2047)", zircon_get_text_ptr()[0..@intCast(-r)]);
    try testing.expectEqual(@as(u8, 0x5a), zircon_get_ram_ptr()[0]);
    try testing.expect(zircon_assemble(TEXT_CAPACITY + 1, 0) < 0);
    try testing.expect(zircon_assemble(0, cpu.RAM_SIZE + 4) < 0);
}

test "wasm exports: faults halt with a trap code instead of spinning" {
    zircon_init();
    const len = putSource("addi x1, x0, 1\n.word 0xffffffff\n");
    try testing.expectEqual(@as(i32, 8), zircon_assemble(len, 0x100));
    try testing.expectEqual(@as(i32, 1), zircon_step());
    try testing.expectEqual(@as(i32, -1), zircon_step());
    try testing.expectEqual(@as(i32, 1), zircon_is_halted());
    try testing.expectEqual(@as(u32, 2), zircon_get_trap_code());
    try testing.expectEqual(@as(u32, 0xffffffff), zircon_get_trap_value());
    try testing.expectEqual(@as(u32, 0x104), zircon_get_pc());
    try testing.expectEqual(@as(i32, 0), zircon_step());
    // Clearing the fault keeps the retired addi.
    try testing.expectEqual(@as(i32, 1), zircon_step_back());
    try testing.expectEqual(@as(u32, 1), zircon_get_reg(1));
    try testing.expectEqual(@as(u32, 0), zircon_get_trap_code());
}

test "wasm exports: reset without init keeps loaded bytes" {
    initialized = false;
    zircon_reset();
    try testing.expectEqual(@as(i32, 0), zircon_load_byte(0, 0x73));
    try testing.expectEqual(@as(i32, -1), zircon_load_byte(cpu.RAM_SIZE, 0));
    try testing.expectEqual(@as(i32, 1), zircon_step());
    try testing.expectEqual(@as(u32, 0x73), zircon_get_trap_code());
}

test "wasm exports: register seeding and breakpoints" {
    zircon_init();
    const len = putSource(
        \\        addi x1, x1, 5
        \\        addi x1, x1, 10
        \\        ecall
    );
    try testing.expectEqual(@as(i32, 12), zircon_assemble(len, 0));
    zircon_set_reg(1, 27);
    try testing.expectEqual(@as(i32, 1), zircon_add_breakpoint(4));
    const n1 = zircon_run(100);
    try testing.expectEqual(@as(u32, 1), n1);
    try testing.expectEqual(@as(i32, 1), zircon_hit_breakpoint());
    try testing.expectEqual(@as(u32, 4), zircon_get_pc());
    try testing.expectEqual(@as(u32, 32), zircon_get_reg(1));

    try testing.expectEqual(@as(i32, 1), zircon_remove_breakpoint(4));
    const n2 = zircon_run(100);
    try testing.expectEqual(@as(u32, 2), n2);
    try testing.expectEqual(@as(i32, 0), zircon_hit_breakpoint());
    try testing.expectEqual(@as(u32, 42), zircon_get_reg(1));
    zircon_clear_breakpoints();
}

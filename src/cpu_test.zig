// Copyright (c) 2026 jk9576. All rights reserved.
// Zircon: Freestanding RISC-V (RV32I) Micro-Emulator & Stepper
// Licensed under the MIT License.
//
// Instruction-semantics, trap, reverse-execution and timing-model tests.

const std = @import("std");
const testing = std.testing;
const cpu = @import("cpu.zig");
const isa = @import("isa.zig");
const asmz = @import("asm.zig");

const CPU = cpu.CPU;

fn newCpu() !*CPU {
    const c = try testing.allocator.create(CPU);
    c.reset();
    return c;
}

fn assemble(c: *CPU, src: []const u8) !void {
    var a = asmz.Assembler{};
    _ = a.assemble(src, 0, &c.ram) catch |e| {
        std.debug.print("assembly failed: line {d}: {s}\n", .{ a.err_line, a.err_msg });
        return e;
    };
    c.pc = 0;
}

/// Executes a single instruction with x1 = a and x2 = b and returns x3.
fn exec1(c: *CPU, word: u32, a: u32, b: u32) !u32 {
    c.reset();
    std.mem.writeInt(u32, c.ram[0..4], word, .little);
    c.regs[1] = a;
    c.regs[2] = b;
    try testing.expect(try c.step());
    return c.readReg(3);
}

const Vec = struct { op: isa.Op, a: u32, b: u32, want: u32 };

test "RV32I register-register semantics" {
    const c = try newCpu();
    defer testing.allocator.destroy(c);
    const vectors = [_]Vec{
        .{ .op = .add, .a = 0x7fffffff, .b = 1, .want = 0x80000000 },
        .{ .op = .add, .a = 0xffffffff, .b = 1, .want = 0 },
        .{ .op = .sub, .a = 0, .b = 1, .want = 0xffffffff },
        .{ .op = .sll, .a = 1, .b = 33, .want = 2 },
        .{ .op = .slt, .a = 0xffffffff, .b = 1, .want = 1 },
        .{ .op = .slt, .a = 1, .b = 0xffffffff, .want = 0 },
        .{ .op = .sltu, .a = 0xffffffff, .b = 1, .want = 0 },
        .{ .op = .sltu, .a = 1, .b = 0xffffffff, .want = 1 },
        .{ .op = .xor, .a = 0xf0f0f0f0, .b = 0xff00ff00, .want = 0x0ff00ff0 },
        .{ .op = .srl, .a = 0x80000000, .b = 31, .want = 1 },
        .{ .op = .sra, .a = 0x80000000, .b = 31, .want = 0xffffffff },
        .{ .op = .sra, .a = 0x80000000, .b = 32, .want = 0x80000000 },
        .{ .op = .@"or", .a = 0xf0f0f0f0, .b = 0x0f, .want = 0xf0f0f0ff },
        .{ .op = .@"and", .a = 0xf0f0f0f0, .b = 0xff, .want = 0xf0 },
    };
    for (vectors) |v| {
        try testing.expectEqual(v.want, try exec1(c, isa.encodeR(v.op, 3, 1, 2), v.a, v.b));
    }
}

test "RV32I immediate semantics" {
    const c = try newCpu();
    defer testing.allocator.destroy(c);
    try testing.expectEqual(@as(u32, 4), try exec1(c, isa.encodeI(.addi, 3, 1, -1), 5, 0));
    try testing.expectEqual(@as(u32, 1), try exec1(c, isa.encodeI(.slti, 3, 1, 0), 0xffffffff, 0));
    // sltiu compares against the sign-extended immediate as unsigned.
    try testing.expectEqual(@as(u32, 1), try exec1(c, isa.encodeI(.sltiu, 3, 1, -1), 5, 0));
    try testing.expectEqual(@as(u32, 0xfffffffa), try exec1(c, isa.encodeI(.xori, 3, 1, -1), 5, 0));
    try testing.expectEqual(@as(u32, 0xfffff805), try exec1(c, isa.encodeI(.ori, 3, 1, -2048), 5, 0));
    try testing.expectEqual(@as(u32, 0x7ff), try exec1(c, isa.encodeI(.andi, 3, 1, 0x7ff), 0xffffffff, 0));
    try testing.expectEqual(@as(u32, 0x80000000), try exec1(c, isa.encodeShift(.slli, 3, 1, 31), 1, 0));
    try testing.expectEqual(@as(u32, 0x0fffffff), try exec1(c, isa.encodeShift(.srli, 3, 1, 4), 0xffffffff, 0));
    try testing.expectEqual(@as(u32, 0xf8000000), try exec1(c, isa.encodeShift(.srai, 3, 1, 4), 0x80000000, 0));
    // lui / auipc
    try testing.expectEqual(@as(u32, 0xabcde000), try exec1(c, isa.encodeU(.lui, 3, 0xabcde), 0, 0));
    try testing.expectEqual(@as(u32, 0x00001000), try exec1(c, isa.encodeU(.auipc, 3, 1), 0, 0));
    // Writes to x0 are discarded.
    _ = try exec1(c, isa.encodeI(.addi, 0, 1, 1), 5, 0);
    try testing.expectEqual(@as(u32, 0), c.readReg(0));
}

test "RV32I loads and stores" {
    const c = try newCpu();
    defer testing.allocator.destroy(c);
    try assemble(c,
        \\        li   x1, 0x400
        \\        li   x2, 0x8081f0ff
        \\        sw   x2, 0(x1)
        \\        lb   x3, 0(x1)
        \\        lbu  x4, 0(x1)
        \\        lh   x5, 2(x1)
        \\        lhu  x6, 2(x1)
        \\        lw   x7, 0(x1)
        \\        sb   x0, 1(x1)
        \\        sh   x2, 6(x1)
        \\        lw   x8, 0(x1)
        \\        lw   x9, 4(x1)
        \\        lw   x10, -4(x1)
        \\        ecall
    );
    _ = c.run(100);
    try testing.expectEqual(@as(u32, 0x73), c.trap_code);
    try testing.expectEqual(@as(u32, 0xffffffff), c.readReg(3));
    try testing.expectEqual(@as(u32, 0xff), c.readReg(4));
    try testing.expectEqual(@as(u32, 0xffff8081), c.readReg(5));
    try testing.expectEqual(@as(u32, 0x8081), c.readReg(6));
    try testing.expectEqual(@as(u32, 0x8081f0ff), c.readReg(7));
    try testing.expectEqual(@as(u32, 0x808100ff), c.readReg(8));
    try testing.expectEqual(@as(u32, 0xf0ff0000), c.readReg(9));
    try testing.expectEqual(@as(u32, 0), c.readReg(10));
    try testing.expectEqual(@as(u64, 8), c.stats.loads);
    try testing.expectEqual(@as(u64, 3), c.stats.stores);
}

test "RV32I control transfer" {
    const c = try newCpu();
    defer testing.allocator.destroy(c);
    try assemble(c,
        \\        li   x1, -1
        \\        li   x2, 1
        \\        blt  x1, x2, signed_ok     # -1 < 1 signed: taken
        \\        ebreak
        \\signed_ok:
        \\        bltu x1, x2, fail          # 0xffffffff < 1 unsigned: not taken
        \\        bgeu x1, x2, unsigned_ok
        \\fail:   ebreak
        \\unsigned_ok:
        \\        jal  x5, func              # x5 = 0x20
        \\        la   x6, func2
        \\        addi x6, x6, 1             # odd address: jalr clears bit 0
        \\        jalr x7, 0(x6)             # x7 = 0x30
        \\        ecall
        \\func:   jalr x0, 0(x5)
        \\func2:  jalr x0, 0(x7)
    );
    _ = c.run(100);
    try testing.expectEqual(@as(u32, 0x73), c.trap_code);
    try testing.expectEqual(@as(u32, 0x20), c.readReg(5)); // return address of the jal
    try testing.expectEqual(@as(u32, 0x30), c.readReg(7)); // return address of the jalr
    try testing.expectEqual(@as(u64, 3), c.stats.branches);
    try testing.expectEqual(@as(u64, 2), c.stats.branches_taken);
    try testing.expectEqual(@as(u64, 4), c.stats.jumps);
}

fn refMulDiv(op: isa.Op, a: u32, b: u32) u32 {
    const sa: i128 = @as(i32, @bitCast(a));
    const sb: i128 = @as(i32, @bitCast(b));
    const ua: i128 = a;
    const ub: i128 = b;
    return switch (op) {
        .mul => @truncate(@as(u128, @bitCast(ua * ub))),
        .mulh => @truncate(@as(u128, @bitCast(sa * sb)) >> 32),
        .mulhsu => @truncate(@as(u128, @bitCast(sa * ub)) >> 32),
        .mulhu => @truncate(@as(u128, @bitCast(ua * ub)) >> 32),
        .div => if (b == 0) 0xffffffff else @truncate(@as(u128, @bitCast(@divTrunc(sa, sb)))),
        .divu => if (b == 0) 0xffffffff else @truncate(@as(u128, @bitCast(@divTrunc(ua, ub)))),
        .rem => if (b == 0) a else @truncate(@as(u128, @bitCast(@rem(sa, sb)))),
        .remu => if (b == 0) a else @truncate(@as(u128, @bitCast(@rem(ua, ub)))),
        else => unreachable,
    };
}

test "RV32M edge cases from the specification" {
    const c = try newCpu();
    defer testing.allocator.destroy(c);
    const min: u32 = 0x80000000;
    const vectors = [_]Vec{
        .{ .op = .div, .a = 7, .b = 0, .want = 0xffffffff },
        .{ .op = .divu, .a = 7, .b = 0, .want = 0xffffffff },
        .{ .op = .rem, .a = 7, .b = 0, .want = 7 },
        .{ .op = .remu, .a = 7, .b = 0, .want = 7 },
        .{ .op = .div, .a = min, .b = 0xffffffff, .want = min },
        .{ .op = .rem, .a = min, .b = 0xffffffff, .want = 0 },
        .{ .op = .div, .a = @bitCast(@as(i32, -7)), .b = 2, .want = @bitCast(@as(i32, -3)) },
        .{ .op = .rem, .a = @bitCast(@as(i32, -7)), .b = 2, .want = @bitCast(@as(i32, -1)) },
        .{ .op = .divu, .a = 0xfffffffe, .b = 2, .want = 0x7fffffff },
        .{ .op = .mul, .a = 0xffffffff, .b = 0xffffffff, .want = 1 },
        .{ .op = .mulh, .a = 0xffffffff, .b = 0xffffffff, .want = 0 },
        .{ .op = .mulhu, .a = 0xffffffff, .b = 0xffffffff, .want = 0xfffffffe },
        .{ .op = .mulhsu, .a = 0xffffffff, .b = 0xffffffff, .want = 0xffffffff },
        .{ .op = .mulh, .a = min, .b = min, .want = 0x40000000 },
    };
    for (vectors) |v| {
        try testing.expectEqual(v.want, try exec1(c, isa.encodeR(v.op, 3, 1, 2), v.a, v.b));
    }
    try testing.expectEqual(@as(u64, 1), c.stats.muldiv);
}

test "RV32M differential test against 128-bit reference arithmetic" {
    const c = try newCpu();
    defer testing.allocator.destroy(c);
    var prng = std.Random.DefaultPrng.init(0x5eed_0101);
    const rnd = prng.random();
    const ops = [_]isa.Op{ .mul, .mulh, .mulhsu, .mulhu, .div, .divu, .rem, .remu };
    const specials = [_]u32{ 0, 1, 2, 0xffffffff, 0x80000000, 0x7fffffff, 0xfffffffe };
    var n: usize = 0;
    while (n < 20000) : (n += 1) {
        const a = if (rnd.uintLessThan(u8, 4) == 0) specials[rnd.uintLessThan(usize, specials.len)] else rnd.int(u32);
        const b = if (rnd.uintLessThan(u8, 4) == 0) specials[rnd.uintLessThan(usize, specials.len)] else rnd.int(u32);
        const op = ops[n % ops.len];
        try testing.expectEqual(refMulDiv(op, a, b), try exec1(c, isa.encodeR(op, 3, 1, 2), a, b));
    }
}

test "Zicntr counters are readable, writes trap" {
    const c = try newCpu();
    defer testing.allocator.destroy(c);
    try assemble(c,
        \\        lw   x1, 0(x0)
        \\        add  x2, x1, x1      # load-use stall
        \\        rdinstret x3
        \\        rdcycle   x4
        \\        rdcycleh  x5
        \\        csrrs x0, time, x0   # a plain read with rd = x0 is fine
        \\        csrrsi x6, instret, 0
        \\        ecall
    );
    _ = c.run(100);
    try testing.expectEqual(@as(u32, 0x73), c.trap_code);
    try testing.expectEqual(@as(u32, 2), c.readReg(3));
    try testing.expectEqual(@as(u32, 4), c.readReg(4)); // 3 retired + 1 stall
    try testing.expectEqual(@as(u32, 0), c.readReg(5));
    try testing.expectEqual(@as(u32, 6), c.readReg(6));

    const illegal = [_][]const u8{
        "csrw cycle, x1",
        "csrrs x1, cycle, x2",
        "csrrci x1, instret, 1",
        "csrrwi x0, cycle, 0",
        "csrr x1, 0x300",
    };
    for (illegal) |src| {
        c.reset();
        try assemble(c, src);
        c.regs[2] = 0;
        try testing.expectError(error.IllegalInstruction, c.step());
        try testing.expectEqual(@as(u32, 2), c.trap_code);
        try testing.expectEqual(@as(u32, 0), c.readReg(1));
    }
}

test "fences retire as no-ops" {
    const c = try newCpu();
    defer testing.allocator.destroy(c);
    try assemble(c, "fence\nfence rw, w\nfence.tso\nfence.i\necall");
    try testing.expectEqual(@as(u64, 5), c.run(10));
    try testing.expectEqual(@as(u32, 0x73), c.trap_code);
}

test "faults halt without changing architectural state" {
    const c = try newCpu();
    defer testing.allocator.destroy(c);

    // Load whose address wraps past 4 GiB (would overflow a 32-bit bound check).
    try assemble(c, "li x1, -4\nlw x2, 0(x1)");
    _ = try c.step();
    const before = c.regs;
    const hist = c.history_len;
    try testing.expectError(error.AccessFault, c.step());
    try testing.expectEqual(@as(u32, 3), c.trap_code);
    try testing.expectEqual(@as(u32, 0xfffffffc), c.trap_value);
    try testing.expectEqual(before, c.regs);
    try testing.expectEqual(@as(u32, 4), c.pc);
    try testing.expectEqual(hist, c.history_len);
    try testing.expect(!(try c.step())); // halted

    // Store straddling the end of RAM.
    c.reset();
    try assemble(c, "li x1, 0xfffe\nsw x1, 0(x1)"); // li expands to lui + addi
    _ = try c.step();
    _ = try c.step();
    try testing.expectError(error.AccessFault, c.step());
    try testing.expectEqual(@as(u32, 0xfffe), c.trap_value);
    try testing.expectEqual(@as(u8, 0), c.ram[0xfffe]);

    // Jump to a 2-byte-aligned target.
    c.reset();
    try assemble(c, "jal x1, 6");
    try testing.expectError(error.MisalignedFetch, c.step());
    try testing.expectEqual(@as(u32, 4), c.trap_code);
    try testing.expectEqual(@as(u32, 6), c.trap_value);
    try testing.expectEqual(@as(u32, 0), c.readReg(1));

    // Taken branch to a misaligned target faults, a not-taken one does not.
    c.reset();
    try assemble(c, "beq x0, x0, 6");
    try testing.expectError(error.MisalignedFetch, c.step());
    c.reset();
    try assemble(c, "bne x0, x0, 6\necall");
    try testing.expect(try c.step());

    // Misaligned pc set by the host.
    c.reset();
    c.pc = 2;
    try testing.expectError(error.MisalignedFetch, c.step());

    // Illegal instruction.
    c.reset();
    try assemble(c, ".word 0");
    try testing.expectError(error.IllegalInstruction, c.step());
    try testing.expectEqual(@as(u32, 2), c.trap_code);
}

test "the last word of RAM is executable and pc past it halts" {
    const c = try newCpu();
    defer testing.allocator.destroy(c);
    c.pc = cpu.RAM_SIZE - 4;
    std.mem.writeInt(u32, c.ram[cpu.RAM_SIZE - 4 ..][0..4], isa.encodeI(.addi, 1, 0, 9), .little);
    try testing.expect(try c.step());
    try testing.expectEqual(@as(u32, 9), c.readReg(1));
    try testing.expectEqual(@as(u32, cpu.RAM_SIZE), c.pc);
    try testing.expect(!(try c.step()));
    try testing.expectEqual(@as(u32, 1), c.trap_code);
    try testing.expectEqual(@as(u32, cpu.RAM_SIZE), c.trap_value);
    // Step back clears the halt without undoing the addi.
    try testing.expect(c.stepBack());
    try testing.expectEqual(@as(u32, 9), c.readReg(1));
    try testing.expect(c.stepBack());
    try testing.expectEqual(@as(u32, 0), c.readReg(1));
}

test "loadProgram rejects images that do not fit" {
    const c = try newCpu();
    defer testing.allocator.destroy(c);
    const four = [_]u8{ 1, 2, 3, 4 };
    try testing.expectError(error.ProgramOutOfBounds, c.loadProgram(&four, cpu.RAM_SIZE - 3));
    try testing.expectError(error.ProgramOutOfBounds, c.loadProgram(&four, 0xffffffff));
    try c.loadProgram(&four, cpu.RAM_SIZE - 4);
}

fn stateHash(c: *const CPU) u64 {
    var h = std.hash.Wyhash.init(0);
    h.update(&c.ram);
    h.update(std.mem.asBytes(&c.regs));
    h.update(std.mem.asBytes(&c.pc));
    h.update(std.mem.asBytes(&c.cycles));
    h.update(std.mem.asBytes(&c.inst_count));
    h.update(std.mem.asBytes(&c.stats));
    h.update(std.mem.asBytes(&c.pipe));
    return h.final();
}

const sort_program =
    \\        la   s0, data
    \\        li   s1, 12              # element count
    \\outer:  addi s1, s1, -1
    \\        blez s1, done
    \\        mv   t0, s0
    \\        mv   t1, s1
    \\inner:  lw   t2, 0(t0)
    \\        lw   t3, 4(t0)
    \\        ble  t2, t3, noswap
    \\        sw   t3, 0(t0)
    \\        sw   t2, 4(t0)
    \\noswap: addi t0, t0, 4
    \\        addi t1, t1, -1
    \\        bnez t1, inner
    \\        j    outer
    \\done:   ecall
    \\data:   .word 9, -3, 7, 0, 12, 5, -8, 1, 4, 4, 100, -100
;

test "step back restores registers, memory, counters and statistics exactly" {
    const c = try newCpu();
    defer testing.allocator.destroy(c);
    try assemble(c, sort_program);
    var hashes: [cpu.MAX_HISTORY]u64 = undefined;
    var n: usize = 0;
    while (n < cpu.MAX_HISTORY) : (n += 1) {
        hashes[n] = stateHash(c);
        try testing.expect(try c.step());
    }
    try testing.expect(c.stats.stores > 0);
    while (n > 0) {
        n -= 1;
        try testing.expect(c.stepBack());
        try testing.expectEqual(hashes[n], stateHash(c));
    }
    try testing.expect(!c.stepBack());
}

test "replaying after step back reproduces the original run" {
    const c = try newCpu();
    defer testing.allocator.destroy(c);
    try assemble(c, sort_program);
    _ = c.run(1_000_000);
    try testing.expectEqual(@as(u32, 0x73), c.trap_code);
    const final = stateHash(c);
    // Sorted ascending.
    const data_addr: usize = 0x44;
    var prev: i32 = std.math.minInt(i32);
    for (0..12) |i| {
        const v: i32 = @bitCast(std.mem.readInt(u32, c.ram[data_addr + 4 * i ..][0..4], .little));
        try testing.expect(v >= prev);
        prev = v;
    }
    var k: usize = 0;
    while (k < 100) : (k += 1) try testing.expect(c.stepBack());
    _ = c.run(1_000_000);
    try testing.expectEqual(final, stateHash(c));
}

test "history ring keeps the most recent MAX_HISTORY steps" {
    const c = try newCpu();
    defer testing.allocator.destroy(c);
    try assemble(c, "loop: addi x1, x1, 1\nj loop");
    _ = c.run(1000);
    try testing.expectEqual(@as(u32, 500), c.readReg(1));
    var k: usize = 0;
    while (c.stepBack()) k += 1;
    try testing.expectEqual(cpu.MAX_HISTORY, k);
    try testing.expectEqual(@as(u32, 500 - cpu.MAX_HISTORY / 2), c.readReg(1));
}

// ---------------------------------------------------------------------------
// Pipeline timing model
// ---------------------------------------------------------------------------

fn runTiming(src: []const u8) !CPU {
    const c = try newCpu();
    defer testing.allocator.destroy(c);
    try assemble(c, src);
    _ = c.run(10_000);
    try testing.expectEqual(@as(u32, 0x73), c.trap_code);
    try testing.expectEqual(c.inst_count + c.stats.load_use_stalls + c.stats.flush_cycles, c.cycles);
    return c.*;
}

test "load-use hazard costs one stall and forwards from MEM/WB" {
    const r = try runTiming("lw x1, 0(x0)\nadd x2, x1, x1\necall");
    try testing.expectEqual(@as(u64, 1), r.stats.load_use_stalls);
    try testing.expectEqual(@as(u64, 2), r.stats.forwarded_operands);
    try testing.expectEqual(@as(u64, 4), r.cycles);
}

test "an independent instruction hides the load latency" {
    const r = try runTiming("lw x1, 0(x0)\naddi x3, x0, 1\nadd x2, x1, x3\necall");
    try testing.expectEqual(@as(u64, 0), r.stats.load_use_stalls);
    try testing.expectEqual(@as(u64, 2), r.stats.forwarded_operands);
    try testing.expectEqual(@as(u64, 4), r.cycles);
}

test "results three instructions back come from the register file" {
    const r = try runTiming("addi x1, x0, 1\nnop\nnop\nadd x2, x1, x1\necall");
    try testing.expectEqual(@as(u64, 0), r.stats.forwarded_operands);
    const r2 = try runTiming("addi x1, x0, 1\nnop\nadd x2, x1, x0\necall");
    try testing.expectEqual(@as(u64, 1), r2.stats.forwarded_operands);
}

test "x0 never creates hazards" {
    const r = try runTiming("lw x0, 0(x0)\nadd x2, x0, x0\necall");
    try testing.expectEqual(@as(u64, 0), r.stats.load_use_stalls);
    try testing.expectEqual(@as(u64, 0), r.stats.forwarded_operands);
}

test "control transfers flush the front end" {
    // jal: 1 bubble, taken branch: 2, not-taken branch: 0, jalr: 2.
    const r = try runTiming(
        \\        jal  x1, a
        \\a:      beq  x0, x0, b
        \\b:      bne  x0, x0, c
        \\c:      la   x5, d
        \\        jalr x0, 0(x5)
        \\d:      ecall
    );
    try testing.expectEqual(@as(u64, 5), r.stats.flush_cycles);
    try testing.expectEqual(@as(u64, 7), r.inst_count);
    try testing.expectEqual(@as(u64, 12), r.cycles);
    // The jalr consumes x5 from the addi of `la` one cycle earlier.
    try testing.expect(r.stats.forwarded_operands >= 1);
}

test "a jump's link register reaches its target through forwarding" {
    const r = try runTiming("jal x1, t\nt: add x2, x1, x0\necall");
    try testing.expectEqual(@as(u64, 1), r.stats.forwarded_operands);
}

test "legacy decoder still classifies formats" {
    const d = CPU.decode(0x0ff0000f);
    try testing.expectEqual(cpu.Opcode.misc_mem, d.opcode);
    try testing.expectEqual(cpu.InstructionFormat.i_type, d.format);
    const b = CPU.decode(isa.encodeB(.bne, 1, 2, -8));
    try testing.expectEqual(@as(i32, -8), b.imm);
    try testing.expectEqual(cpu.InstructionFormat.b_type, b.format);
}

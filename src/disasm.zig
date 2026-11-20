// Copyright (c) 2026 jk9576. All rights reserved.
// Zircon: Freestanding RISC-V (RV32I) Micro-Emulator & Stepper
// Licensed under the MIT License.
//
// Allocation-free RV32IM disassembler. Every line it produces is accepted by
// the Zircon assembler and re-encodes to exactly the same 32-bit word, so it
// prints canonical (non-pseudo) forms, absolute branch targets, and `.word`
// for anything that is not a legal instruction.

const std = @import("std");
const isa = @import("isa.zig");

/// A buffer of this size always holds a complete line.
pub const max_line = 48;

const Out = struct {
    buf: []u8,
    len: usize = 0,

    fn char(o: *Out, c: u8) void {
        if (o.len < o.buf.len) {
            o.buf[o.len] = c;
            o.len += 1;
        }
    }

    fn str(o: *Out, s: []const u8) void {
        for (s) |c| o.char(c);
    }

    fn dec(o: *Out, v: i64) void {
        var tmp: [24]u8 = undefined;
        var n: usize = 0;
        var mag: u64 = if (v < 0) @intCast(-v) else @intCast(v);
        if (v < 0) o.char('-');
        while (true) {
            tmp[n] = @intCast('0' + mag % 10);
            n += 1;
            mag /= 10;
            if (mag == 0) break;
        }
        while (n > 0) {
            n -= 1;
            o.char(tmp[n]);
        }
    }

    fn hex(o: *Out, v: u32, min_digits: u5) void {
        o.str("0x");
        var digits: u5 = 8;
        while (digits > min_digits and digits > 1 and (v >> (@as(u5, digits - 1) * 4)) & 0xf == 0) digits -= 1;
        while (digits > 0) {
            digits -= 1;
            const nib: u4 = @truncate(v >> (@as(u5, digits) * 4));
            o.char("0123456789abcdef"[nib]);
        }
    }

    fn reg(o: *Out, r: u5) void {
        o.char('x');
        o.dec(r);
    }

    fn sep(o: *Out) void {
        o.str(", ");
    }

    fn csr(o: *Out, addr: u12) void {
        if (isa.csrName(addr)) |n| o.str(n) else o.hex(addr, 1);
    }

    fn fenceSet(o: *Out, set: u4) void {
        if (set == 0) {
            o.char('0');
            return;
        }
        if (set & 8 != 0) o.char('i');
        if (set & 4 != 0) o.char('o');
        if (set & 2 != 0) o.char('r');
        if (set & 1 != 0) o.char('w');
    }
};

/// Writes the assembly text for `raw`, located at address `pc`, into `buf`
/// and returns the written slice. Output is truncated if `buf` is shorter than
/// `max_line`.
pub fn disassemble(raw: u32, pc: u32, buf: []u8) []u8 {
    var o = Out{ .buf = buf };
    const inst = isa.decode(raw);
    const k = isa.kind(inst.op);

    // Fences only have a canonical spelling for a handful of encodings.
    const canonical = switch (k) {
        .none => false,
        .fence => (raw & 0xf00fff80) == 0 or raw == 0x8330000f,
        .fence_i => raw == isa.encoded_fence_i,
        else => true,
    };
    if (!canonical) {
        o.str(".word ");
        o.hex(raw, 8);
        return buf[0..o.len];
    }

    if (raw == 0x8330000f) {
        o.str("fence.tso");
        return buf[0..o.len];
    }

    o.str(isa.mnemonic(inst.op));
    switch (k) {
        .none => unreachable,
        .system, .fence_i => {},
        .fence => {
            o.char(' ');
            o.fenceSet(@truncate(raw >> 24));
            o.sep();
            o.fenceSet(@truncate(raw >> 20));
        },
        .upper => {
            o.char(' ');
            o.reg(inst.rd);
            o.sep();
            o.hex(raw >> 12, 1);
        },
        .jump => {
            o.char(' ');
            o.reg(inst.rd);
            o.sep();
            o.hex(pc +% @as(u32, @bitCast(inst.imm)), 1);
        },
        .jump_reg, .load => {
            o.char(' ');
            o.reg(inst.rd);
            o.sep();
            o.dec(inst.imm);
            o.char('(');
            o.reg(inst.rs1);
            o.char(')');
        },
        .store => {
            o.char(' ');
            o.reg(inst.rs2);
            o.sep();
            o.dec(inst.imm);
            o.char('(');
            o.reg(inst.rs1);
            o.char(')');
        },
        .branch => {
            o.char(' ');
            o.reg(inst.rs1);
            o.sep();
            o.reg(inst.rs2);
            o.sep();
            o.hex(pc +% @as(u32, @bitCast(inst.imm)), 1);
        },
        .alu_imm, .shift_imm => {
            o.char(' ');
            o.reg(inst.rd);
            o.sep();
            o.reg(inst.rs1);
            o.sep();
            o.dec(inst.imm);
        },
        .alu_reg => {
            o.char(' ');
            o.reg(inst.rd);
            o.sep();
            o.reg(inst.rs1);
            o.sep();
            o.reg(inst.rs2);
        },
        .csr_reg => {
            o.char(' ');
            o.reg(inst.rd);
            o.sep();
            o.csr(inst.csr);
            o.sep();
            o.reg(inst.rs1);
        },
        .csr_imm => {
            o.char(' ');
            o.reg(inst.rd);
            o.sep();
            o.csr(inst.csr);
            o.sep();
            o.dec(inst.rs1);
        },
    }
    return buf[0..o.len];
}

const testing = std.testing;

fn expectDis(raw: u32, pc: u32, want: []const u8) !void {
    var buf: [max_line]u8 = undefined;
    try testing.expectEqualStrings(want, disassemble(raw, pc, &buf));
}

test "disassembles known words" {
    try expectDis(0x00a00093, 0, "addi x1, x0, 10");
    try expectDis(0x002081b3, 0, "add x3, x1, x2");
    try expectDis(0x40110233, 0, "sub x4, x2, x1");
    try expectDis(0x0020a023, 0, "sw x2, 0(x1)");
    try expectDis(0x0000a183, 0, "lw x3, 0(x1)");
    try expectDis(0xffc12083, 0, "lw x1, -4(x2)");
    try expectDis(0x00000073, 0, "ecall");
    try expectDis(0x00100073, 0, "ebreak");
    try expectDis(0x123450b7, 0, "lui x1, 0x12345");
    try expectDis(0x022081b3, 0, "mul x3, x1, x2");
    try expectDis(0x0220c1b3, 0, "div x3, x1, x2");
    try expectDis(0xc00022f3, 0, "csrrs x5, cycle, x0");
    try expectDis(0x0ff0000f, 0, "fence iorw, iorw");
    try expectDis(0x8330000f, 0, "fence.tso");
    try expectDis(0x0000100f, 0, "fence.i");
    try expectDis(0x00000000, 0, ".word 0x00000000");
    try expectDis(0xffffffff, 0, ".word 0xffffffff");
    try expectDis(0x4030d093, 0, "srai x1, x1, 3");
    // beq x0, x0, -8 at 0x100 targets 0xf8
    try expectDis(isa.encodeB(.beq, 0, 0, -8), 0x100, "beq x0, x0, 0xf8");
    // jal x1, -4 at 0 wraps to the top of the address space
    try expectDis(isa.encodeJ(1, -4), 0, "jal x1, 0xfffffffc");
}

test "short buffers are truncated, never overrun" {
    var small: [5]u8 = undefined;
    try testing.expectEqualStrings("addi ", disassemble(0x00a00093, 0, &small));
    var empty: [0]u8 = undefined;
    try testing.expectEqual(@as(usize, 0), disassemble(0x00a00093, 0, &empty).len);
}

test "every line fits in max_line" {
    var prng = std.Random.DefaultPrng.init(0x5eed_0003);
    const rnd = prng.random();
    var big: [256]u8 = undefined;
    var n: usize = 0;
    while (n < 20000) : (n += 1) {
        const line = disassemble(rnd.int(u32), rnd.int(u32), &big);
        try testing.expect(line.len <= max_line);
    }
}

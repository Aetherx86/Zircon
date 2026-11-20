// Copyright (c) 2026 jk9576. All rights reserved.
// Zircon: Freestanding RISC-V (RV32I) Micro-Emulator & Stepper
// Licensed under the MIT License.
//
// Shared RV32IM + Zicsr + Zifencei instruction table. The emulator, the
// disassembler and the assembler all classify and encode instructions through
// this file, so the three can never disagree about which bit patterns are legal.

const std = @import("std");

pub const Op = enum(u8) {
    illegal,
    lui,
    auipc,
    jal,
    jalr,
    beq,
    bne,
    blt,
    bge,
    bltu,
    bgeu,
    lb,
    lh,
    lw,
    lbu,
    lhu,
    sb,
    sh,
    sw,
    addi,
    slti,
    sltiu,
    xori,
    ori,
    andi,
    slli,
    srli,
    srai,
    add,
    sub,
    sll,
    slt,
    sltu,
    xor,
    srl,
    sra,
    @"or",
    @"and",
    mul,
    mulh,
    mulhsu,
    mulhu,
    div,
    divu,
    rem,
    remu,
    fence,
    fence_i,
    ecall,
    ebreak,
    csrrw,
    csrrs,
    csrrc,
    csrrwi,
    csrrsi,
    csrrci,
};

/// Operand shape of an instruction.
pub const Kind = enum {
    none,
    upper,
    jump,
    jump_reg,
    branch,
    load,
    store,
    alu_imm,
    shift_imm,
    alu_reg,
    fence,
    fence_i,
    system,
    csr_reg,
    csr_imm,
};

pub fn kind(op: Op) Kind {
    return switch (op) {
        .illegal => .none,
        .lui, .auipc => .upper,
        .jal => .jump,
        .jalr => .jump_reg,
        .beq, .bne, .blt, .bge, .bltu, .bgeu => .branch,
        .lb, .lh, .lw, .lbu, .lhu => .load,
        .sb, .sh, .sw => .store,
        .addi, .slti, .sltiu, .xori, .ori, .andi => .alu_imm,
        .slli, .srli, .srai => .shift_imm,
        .add, .sub, .sll, .slt, .sltu, .xor, .srl, .sra, .@"or", .@"and" => .alu_reg,
        .mul, .mulh, .mulhsu, .mulhu, .div, .divu, .rem, .remu => .alu_reg,
        .fence => .fence,
        .fence_i => .fence_i,
        .ecall, .ebreak => .system,
        .csrrw, .csrrs, .csrrc => .csr_reg,
        .csrrwi, .csrrsi, .csrrci => .csr_imm,
    };
}

/// True for the RV32M multiply/divide instructions.
pub fn isMulDiv(op: Op) bool {
    return switch (op) {
        .mul, .mulh, .mulhsu, .mulhu, .div, .divu, .rem, .remu => true,
        else => false,
    };
}

pub fn mnemonic(op: Op) []const u8 {
    return switch (op) {
        .fence_i => "fence.i",
        else => @tagName(op),
    };
}

/// Looks up a base (non-pseudo) mnemonic. Expects lowercase input.
pub fn opFromMnemonic(name: []const u8) ?Op {
    if (std.mem.eql(u8, name, "fence.i")) return .fence_i;
    for (std.enums.values(Op)) |op| {
        if (op != .illegal and op != .fence_i and std.mem.eql(u8, @tagName(op), name)) return op;
    }
    return null;
}

pub const Fields = struct {
    opcode: u7,
    funct3: u3 = 0,
    funct7: u7 = 0,
};

/// Fixed encoding fields of each instruction.
pub fn fields(op: Op) Fields {
    return switch (op) {
        .illegal => .{ .opcode = 0 },
        .lui => .{ .opcode = 0x37 },
        .auipc => .{ .opcode = 0x17 },
        .jal => .{ .opcode = 0x6f },
        .jalr => .{ .opcode = 0x67 },
        .beq => .{ .opcode = 0x63, .funct3 = 0 },
        .bne => .{ .opcode = 0x63, .funct3 = 1 },
        .blt => .{ .opcode = 0x63, .funct3 = 4 },
        .bge => .{ .opcode = 0x63, .funct3 = 5 },
        .bltu => .{ .opcode = 0x63, .funct3 = 6 },
        .bgeu => .{ .opcode = 0x63, .funct3 = 7 },
        .lb => .{ .opcode = 0x03, .funct3 = 0 },
        .lh => .{ .opcode = 0x03, .funct3 = 1 },
        .lw => .{ .opcode = 0x03, .funct3 = 2 },
        .lbu => .{ .opcode = 0x03, .funct3 = 4 },
        .lhu => .{ .opcode = 0x03, .funct3 = 5 },
        .sb => .{ .opcode = 0x23, .funct3 = 0 },
        .sh => .{ .opcode = 0x23, .funct3 = 1 },
        .sw => .{ .opcode = 0x23, .funct3 = 2 },
        .addi => .{ .opcode = 0x13, .funct3 = 0 },
        .slti => .{ .opcode = 0x13, .funct3 = 2 },
        .sltiu => .{ .opcode = 0x13, .funct3 = 3 },
        .xori => .{ .opcode = 0x13, .funct3 = 4 },
        .ori => .{ .opcode = 0x13, .funct3 = 6 },
        .andi => .{ .opcode = 0x13, .funct3 = 7 },
        .slli => .{ .opcode = 0x13, .funct3 = 1 },
        .srli => .{ .opcode = 0x13, .funct3 = 5 },
        .srai => .{ .opcode = 0x13, .funct3 = 5, .funct7 = 0x20 },
        .add => .{ .opcode = 0x33, .funct3 = 0 },
        .sub => .{ .opcode = 0x33, .funct3 = 0, .funct7 = 0x20 },
        .sll => .{ .opcode = 0x33, .funct3 = 1 },
        .slt => .{ .opcode = 0x33, .funct3 = 2 },
        .sltu => .{ .opcode = 0x33, .funct3 = 3 },
        .xor => .{ .opcode = 0x33, .funct3 = 4 },
        .srl => .{ .opcode = 0x33, .funct3 = 5 },
        .sra => .{ .opcode = 0x33, .funct3 = 5, .funct7 = 0x20 },
        .@"or" => .{ .opcode = 0x33, .funct3 = 6 },
        .@"and" => .{ .opcode = 0x33, .funct3 = 7 },
        .mul => .{ .opcode = 0x33, .funct3 = 0, .funct7 = 1 },
        .mulh => .{ .opcode = 0x33, .funct3 = 1, .funct7 = 1 },
        .mulhsu => .{ .opcode = 0x33, .funct3 = 2, .funct7 = 1 },
        .mulhu => .{ .opcode = 0x33, .funct3 = 3, .funct7 = 1 },
        .div => .{ .opcode = 0x33, .funct3 = 4, .funct7 = 1 },
        .divu => .{ .opcode = 0x33, .funct3 = 5, .funct7 = 1 },
        .rem => .{ .opcode = 0x33, .funct3 = 6, .funct7 = 1 },
        .remu => .{ .opcode = 0x33, .funct3 = 7, .funct7 = 1 },
        .fence => .{ .opcode = 0x0f, .funct3 = 0 },
        .fence_i => .{ .opcode = 0x0f, .funct3 = 1 },
        .ecall => .{ .opcode = 0x73, .funct3 = 0 },
        .ebreak => .{ .opcode = 0x73, .funct3 = 0 },
        .csrrw => .{ .opcode = 0x73, .funct3 = 1 },
        .csrrs => .{ .opcode = 0x73, .funct3 = 2 },
        .csrrc => .{ .opcode = 0x73, .funct3 = 3 },
        .csrrwi => .{ .opcode = 0x73, .funct3 = 5 },
        .csrrsi => .{ .opcode = 0x73, .funct3 = 6 },
        .csrrci => .{ .opcode = 0x73, .funct3 = 7 },
    };
}

/// Fully classified instruction. `imm` holds the sign-extended immediate for
/// I/S/B/J types, the upper 20 bits shifted into place for U types, the shift
/// amount for shift-immediates, and the raw fm/pred/succ bits for FENCE.
/// For CSR immediates, `rs1` holds the 5-bit zero-extended uimm.
pub const Inst = struct {
    op: Op,
    raw: u32,
    rd: u5,
    rs1: u5,
    rs2: u5,
    imm: i32 = 0,
    csr: u12 = 0,
};

pub fn immI(raw: u32) i32 {
    return @as(i32, @bitCast(raw)) >> 20;
}

pub fn immS(raw: u32) i32 {
    const hi = (@as(i32, @bitCast(raw)) >> 25) << 5;
    return hi | @as(i32, @intCast((raw >> 7) & 0x1f));
}

pub fn immB(raw: u32) i32 {
    const sign = (@as(i32, @bitCast(raw)) >> 31) << 12;
    const low = (((raw >> 7) & 0x1) << 11) | (((raw >> 25) & 0x3f) << 5) | (((raw >> 8) & 0xf) << 1);
    return sign | @as(i32, @intCast(low));
}

pub fn immU(raw: u32) i32 {
    return @bitCast(raw & 0xfffff000);
}

pub fn immJ(raw: u32) i32 {
    const sign = (@as(i32, @bitCast(raw)) >> 31) << 20;
    const low = (raw & 0xff000) | (((raw >> 20) & 0x1) << 11) | (((raw >> 21) & 0x3ff) << 1);
    return sign | @as(i32, @intCast(low));
}

pub fn decode(raw: u32) Inst {
    const rd: u5 = @truncate(raw >> 7);
    const funct3: u3 = @truncate(raw >> 12);
    const rs1: u5 = @truncate(raw >> 15);
    const rs2: u5 = @truncate(raw >> 20);
    const funct7: u7 = @truncate(raw >> 25);
    var inst = Inst{ .op = .illegal, .raw = raw, .rd = rd, .rs1 = rs1, .rs2 = rs2 };

    switch (raw & 0x7f) {
        0x37 => {
            inst.op = .lui;
            inst.imm = immU(raw);
        },
        0x17 => {
            inst.op = .auipc;
            inst.imm = immU(raw);
        },
        0x6f => {
            inst.op = .jal;
            inst.imm = immJ(raw);
        },
        0x67 => if (funct3 == 0) {
            inst.op = .jalr;
            inst.imm = immI(raw);
        },
        0x63 => {
            inst.op = switch (funct3) {
                0 => .beq,
                1 => .bne,
                4 => .blt,
                5 => .bge,
                6 => .bltu,
                7 => .bgeu,
                else => .illegal,
            };
            inst.imm = immB(raw);
        },
        0x03 => {
            inst.op = switch (funct3) {
                0 => .lb,
                1 => .lh,
                2 => .lw,
                4 => .lbu,
                5 => .lhu,
                else => .illegal,
            };
            inst.imm = immI(raw);
        },
        0x23 => {
            inst.op = switch (funct3) {
                0 => .sb,
                1 => .sh,
                2 => .sw,
                else => .illegal,
            };
            inst.imm = immS(raw);
        },
        0x13 => {
            inst.imm = immI(raw);
            inst.op = switch (funct3) {
                0 => .addi,
                2 => .slti,
                3 => .sltiu,
                4 => .xori,
                6 => .ori,
                7 => .andi,
                1 => if (funct7 == 0) .slli else .illegal,
                5 => if (funct7 == 0) .srli else if (funct7 == 0x20) .srai else .illegal,
            };
            if (funct3 == 1 or funct3 == 5) inst.imm = rs2;
        },
        0x33 => {
            inst.op = switch (funct7) {
                0x00 => switch (funct3) {
                    0 => .add,
                    1 => .sll,
                    2 => .slt,
                    3 => .sltu,
                    4 => .xor,
                    5 => .srl,
                    6 => .@"or",
                    7 => .@"and",
                },
                0x20 => switch (funct3) {
                    0 => .sub,
                    5 => .sra,
                    else => .illegal,
                },
                0x01 => switch (funct3) {
                    0 => .mul,
                    1 => .mulh,
                    2 => .mulhsu,
                    3 => .mulhu,
                    4 => .div,
                    5 => .divu,
                    6 => .rem,
                    7 => .remu,
                },
                else => .illegal,
            };
        },
        0x0f => {
            inst.op = switch (funct3) {
                0 => .fence,
                1 => .fence_i,
                else => .illegal,
            };
            inst.imm = @intCast(raw >> 20);
        },
        0x73 => {
            inst.csr = @truncate(raw >> 20);
            inst.op = switch (funct3) {
                0 => if (raw == 0x00000073) .ecall else if (raw == 0x00100073) .ebreak else .illegal,
                1 => .csrrw,
                2 => .csrrs,
                3 => .csrrc,
                5 => .csrrwi,
                6 => .csrrsi,
                7 => .csrrci,
                4 => .illegal,
            };
        },
        else => {},
    }
    return inst;
}

// ---------------------------------------------------------------------------
// Encoders. Callers are responsible for range checks (see the fits* helpers).
// ---------------------------------------------------------------------------

fn base(op: Op, rd: u5, rs1: u5) u32 {
    const f = fields(op);
    return (@as(u32, f.funct7) << 25) | (@as(u32, rs1) << 15) | (@as(u32, f.funct3) << 12) |
        (@as(u32, rd) << 7) | f.opcode;
}

pub fn encodeR(op: Op, rd: u5, rs1: u5, rs2: u5) u32 {
    return base(op, rd, rs1) | (@as(u32, rs2) << 20);
}

pub fn encodeI(op: Op, rd: u5, rs1: u5, imm: i32) u32 {
    const f = fields(op);
    const imm12: u32 = @as(u32, @bitCast(imm)) & 0xfff;
    return (imm12 << 20) | (@as(u32, rs1) << 15) | (@as(u32, f.funct3) << 12) | (@as(u32, rd) << 7) | f.opcode;
}

pub fn encodeShift(op: Op, rd: u5, rs1: u5, shamt: u5) u32 {
    return base(op, rd, rs1) | (@as(u32, shamt) << 20);
}

pub fn encodeS(op: Op, rs1: u5, rs2: u5, imm: i32) u32 {
    const f = fields(op);
    const u: u32 = @bitCast(imm);
    return (((u >> 5) & 0x7f) << 25) | (@as(u32, rs2) << 20) | (@as(u32, rs1) << 15) |
        (@as(u32, f.funct3) << 12) | ((u & 0x1f) << 7) | f.opcode;
}

pub fn encodeB(op: Op, rs1: u5, rs2: u5, offset: i32) u32 {
    const f = fields(op);
    const u: u32 = @bitCast(offset);
    return (((u >> 12) & 1) << 31) | (((u >> 5) & 0x3f) << 25) | (@as(u32, rs2) << 20) |
        (@as(u32, rs1) << 15) | (@as(u32, f.funct3) << 12) | (((u >> 1) & 0xf) << 8) |
        (((u >> 11) & 1) << 7) | f.opcode;
}

pub fn encodeU(op: Op, rd: u5, imm20: u20) u32 {
    return (@as(u32, imm20) << 12) | (@as(u32, rd) << 7) | fields(op).opcode;
}

pub fn encodeJ(rd: u5, offset: i32) u32 {
    const u: u32 = @bitCast(offset);
    return (((u >> 20) & 1) << 31) | (((u >> 1) & 0x3ff) << 21) | (((u >> 11) & 1) << 20) |
        (u & 0xff000) | (@as(u32, rd) << 7) | 0x6f;
}

pub fn encodeCsr(op: Op, rd: u5, csr: u12, src: u5) u32 {
    const f = fields(op);
    return (@as(u32, csr) << 20) | (@as(u32, src) << 15) | (@as(u32, f.funct3) << 12) |
        (@as(u32, rd) << 7) | f.opcode;
}

pub fn encodeFence(fm: u4, pred: u4, succ: u4) u32 {
    return (@as(u32, fm) << 28) | (@as(u32, pred) << 24) | (@as(u32, succ) << 20) | 0x0f;
}

pub const encoded_fence_i: u32 = 0x0000100f;
pub const encoded_ecall: u32 = 0x00000073;
pub const encoded_ebreak: u32 = 0x00100073;

pub fn fitsI(v: i64) bool {
    return v >= -2048 and v <= 2047;
}

pub fn fitsB(v: i64) bool {
    return v >= -4096 and v <= 4094 and @rem(v, 2) == 0;
}

pub fn fitsJ(v: i64) bool {
    return v >= -1048576 and v <= 1048574 and @rem(v, 2) == 0;
}

// ---------------------------------------------------------------------------
// Register and CSR names
// ---------------------------------------------------------------------------

pub const abi_names = [32][]const u8{
    "zero", "ra", "sp",  "gp",  "tp", "t0", "t1", "t2",
    "s0",   "s1", "a0",  "a1",  "a2", "a3", "a4", "a5",
    "a6",   "a7", "s2",  "s3",  "s4", "s5", "s6", "s7",
    "s8",   "s9", "s10", "s11", "t3", "t4", "t5", "t6",
};

/// Parses `x0`..`x31`, ABI names and `fp`. Expects lowercase input.
pub fn parseReg(name: []const u8) ?u5 {
    if (name.len >= 2 and name.len <= 3 and name[0] == 'x') {
        var v: u32 = 0;
        for (name[1..]) |c| {
            if (c < '0' or c > '9') return null;
            v = v * 10 + (c - '0');
        }
        if (name.len == 3 and name[1] == '0') return null;
        if (v < 32) return @intCast(v);
        return null;
    }
    if (std.mem.eql(u8, name, "fp")) return 8;
    for (abi_names, 0..) |n, i| {
        if (std.mem.eql(u8, n, name)) return @intCast(i);
    }
    return null;
}

pub const Csr = struct {
    pub const cycle: u12 = 0xc00;
    pub const time: u12 = 0xc01;
    pub const instret: u12 = 0xc02;
    pub const cycleh: u12 = 0xc80;
    pub const timeh: u12 = 0xc81;
    pub const instreth: u12 = 0xc82;
};

const csr_table = [_]struct { name: []const u8, addr: u12 }{
    .{ .name = "cycle", .addr = Csr.cycle },
    .{ .name = "time", .addr = Csr.time },
    .{ .name = "instret", .addr = Csr.instret },
    .{ .name = "cycleh", .addr = Csr.cycleh },
    .{ .name = "timeh", .addr = Csr.timeh },
    .{ .name = "instreth", .addr = Csr.instreth },
};

pub fn csrName(addr: u12) ?[]const u8 {
    for (csr_table) |e| {
        if (e.addr == addr) return e.name;
    }
    return null;
}

pub fn csrFromName(name: []const u8) ?u12 {
    for (csr_table) |e| {
        if (std.mem.eql(u8, e.name, name)) return e.addr;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "decode recognises every op from its own encoding" {
    var prng = std.Random.DefaultPrng.init(0x5eed_0001);
    const rnd = prng.random();
    for (std.enums.values(Op)) |op| {
        if (op == .illegal) continue;
        var n: usize = 0;
        while (n < 200) : (n += 1) {
            const rd = rnd.int(u5);
            const rs1 = rnd.int(u5);
            const rs2 = rnd.int(u5);
            const imm12 = rnd.intRangeAtMost(i32, -2048, 2047);
            const word: u32 = switch (kind(op)) {
                .none => unreachable,
                .upper => encodeU(op, rd, rnd.int(u20)),
                .jump => encodeJ(rd, rnd.intRangeAtMost(i32, -524288, 524287) * 2),
                .jump_reg, .load, .alu_imm => encodeI(op, rd, rs1, imm12),
                .branch => encodeB(op, rs1, rs2, rnd.intRangeAtMost(i32, -2048, 2047) * 2),
                .store => encodeS(op, rs1, rs2, imm12),
                .shift_imm => encodeShift(op, rd, rs1, rs2),
                .alu_reg => encodeR(op, rd, rs1, rs2),
                .fence => encodeFence(0, rnd.int(u4), rnd.int(u4)),
                .fence_i => encoded_fence_i,
                .system => if (op == .ecall) encoded_ecall else encoded_ebreak,
                .csr_reg, .csr_imm => encodeCsr(op, rd, rnd.int(u12), rs1),
            };
            const inst = decode(word);
            try testing.expectEqual(op, inst.op);
        }
    }
}

test "immediate encoders and decoders are inverse" {
    var prng = std.Random.DefaultPrng.init(0x5eed_0002);
    const rnd = prng.random();
    var n: usize = 0;
    while (n < 5000) : (n += 1) {
        const i = rnd.intRangeAtMost(i32, -2048, 2047);
        try testing.expectEqual(i, decode(encodeI(.addi, 1, 2, i)).imm);
        try testing.expectEqual(i, decode(encodeS(.sw, 1, 2, i)).imm);
        const b = rnd.intRangeAtMost(i32, -2048, 2047) * 2;
        try testing.expectEqual(b, decode(encodeB(.bne, 1, 2, b)).imm);
        const j = rnd.intRangeAtMost(i32, -524288, 524287) * 2;
        try testing.expectEqual(j, decode(encodeJ(1, j)).imm);
    }
}

test "known encodings" {
    try testing.expectEqual(@as(u32, 0x00a00093), encodeI(.addi, 1, 0, 10));
    try testing.expectEqual(@as(u32, 0x002081b3), encodeR(.add, 3, 1, 2));
    try testing.expectEqual(@as(u32, 0x40110233), encodeR(.sub, 4, 2, 1));
    try testing.expectEqual(@as(u32, 0x0020a023), encodeS(.sw, 1, 2, 0));
    try testing.expectEqual(@as(u32, 0x0000a183), encodeI(.lw, 3, 1, 0));
    try testing.expectEqual(@as(u32, 0x022081b3), encodeR(.mul, 3, 1, 2));
    try testing.expectEqual(@as(u32, 0x0ff0000f), encodeFence(0, 0xf, 0xf));
    try testing.expectEqual(@as(u32, 0xc00022f3), encodeCsr(.csrrs, 5, Csr.cycle, 0));
}

test "reserved encodings decode as illegal" {
    const illegal = [_]u32{
        0x00000000, // all zeros
        0xffffffff, // all ones
        0x0000000b, // custom-0 opcode
        0x00001067, // jalr with funct3=1
        0x00002063, // branch funct3=2
        0x00003003, // load funct3=3 (ld is RV64)
        0x00003023, // store funct3=3 (sd is RV64)
        0x40001013, // slli with funct7=0x20
        0x20005013, // srli/srai with funct7=0x10
        0x40001033, // sll with funct7=0x20
        0x04000033, // add with funct7=0x02
        0x00004073, // system funct3=4
        0x30200073, // mret (no privileged modes)
        0x10500073, // wfi
        0x0000200f, // misc-mem funct3=2
    };
    for (illegal) |w| {
        try testing.expectEqual(Op.illegal, decode(w).op);
    }
}

test "mnemonic lookup" {
    try testing.expectEqual(@as(?Op, .xor), opFromMnemonic("xor"));
    try testing.expectEqual(@as(?Op, .fence_i), opFromMnemonic("fence.i"));
    try testing.expectEqual(@as(?Op, .csrrci), opFromMnemonic("csrrci"));
    try testing.expectEqual(@as(?Op, null), opFromMnemonic("fence_i"));
    try testing.expectEqual(@as(?Op, null), opFromMnemonic("illegal"));
    try testing.expectEqual(@as(?Op, null), opFromMnemonic("nop"));
}

test "register and csr names" {
    try testing.expectEqual(@as(?u5, 0), parseReg("zero"));
    try testing.expectEqual(@as(?u5, 8), parseReg("fp"));
    try testing.expectEqual(@as(?u5, 8), parseReg("s0"));
    try testing.expectEqual(@as(?u5, 27), parseReg("s11"));
    try testing.expectEqual(@as(?u5, 31), parseReg("x31"));
    try testing.expectEqual(@as(?u5, null), parseReg("x32"));
    try testing.expectEqual(@as(?u5, null), parseReg("x01"));
    try testing.expectEqual(@as(?u5, null), parseReg("x"));
    try testing.expectEqual(@as(?u5, null), parseReg("s12"));
    try testing.expectEqual(@as(?u12, 0xc82), csrFromName("instreth"));
    try testing.expectEqualStrings("cycle", csrName(0xc00).?);
    try testing.expectEqual(@as(?[]const u8, null), csrName(0x300));
}

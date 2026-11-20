// Copyright (c) 2026 jk9576. All rights reserved.
// Zircon: Freestanding RISC-V (RV32I) Micro-Emulator & Stepper
// Licensed under the MIT License.
//
// Allocation-free three-pass RV32IM assembler. Pass one collects labels,
// pass two validates every operand against the final label values without
// touching the output, and pass three writes the bytes. A failed assembly
// therefore never leaves partially written output behind.

const std = @import("std");
const isa = @import("isa.zig");

pub const max_labels = 1024;
pub const max_operands = 32;

pub const Error = error{AsmFailed};

const Label = struct {
    name: []const u8,
    addr: u32,
};

const Pass = enum { scan, check, emit };

pub const Assembler = struct {
    labels: [max_labels]Label = undefined,
    label_count: usize = 0,
    /// 1-based source line of the last error, or 0.
    err_line: u32 = 0,
    /// Static description of the last error.
    err_msg: []const u8 = "",

    pass: Pass = .scan,
    pc: u32 = 0,
    base: u32 = 0,
    out: []u8 = &.{},

    /// Assembles `src` as if loaded at address `base` and writes the image to
    /// `out` (which represents addresses `base .. base + out.len`). Returns the
    /// number of bytes produced.
    pub fn assemble(self: *Assembler, src: []const u8, base: u32, out: []u8) Error!usize {
        self.label_count = 0;
        self.err_line = 0;
        self.err_msg = "";
        self.base = base;
        self.out = out;
        for ([_]Pass{ .scan, .check, .emit }) |p| {
            self.pass = p;
            self.pc = base;
            var line_no: u32 = 0;
            var it = std.mem.splitScalar(u8, src, '\n');
            while (it.next()) |line_text| {
                line_no +|= 1;
                self.line(line_text) catch |e| {
                    self.err_line = line_no;
                    return e;
                };
            }
        }
        return self.pc - base;
    }

    /// Formats the last error as `line N: message`.
    pub fn diagnostic(self: *const Assembler, buf: []u8) []u8 {
        var len: usize = 0;
        var digits: [10]u8 = undefined;
        var n: usize = 0;
        var v = self.err_line;
        while (true) {
            digits[n] = @intCast('0' + v % 10);
            n += 1;
            v /= 10;
            if (v == 0) break;
        }
        for ("line ") |c| appendByte(buf, &len, c);
        while (n > 0) {
            n -= 1;
            appendByte(buf, &len, digits[n]);
        }
        for (": ") |c| appendByte(buf, &len, c);
        for (self.err_msg) |c| appendByte(buf, &len, c);
        return buf[0..len];
    }

    /// Address of a label defined by the last successful assembly.
    pub fn lookup(self: *const Assembler, name: []const u8) ?u32 {
        for (self.labels[0..self.label_count]) |l| {
            if (std.mem.eql(u8, l.name, name)) return l.addr;
        }
        return null;
    }

    fn fail(self: *Assembler, msg: []const u8) Error {
        self.err_msg = msg;
        return error.AsmFailed;
    }

    // -----------------------------------------------------------------------
    // Line structure
    // -----------------------------------------------------------------------

    fn line(self: *Assembler, raw: []const u8) Error!void {
        var text = trim(stripComment(raw));
        while (std.mem.indexOfScalar(u8, text, ':')) |colon| {
            const name = trim(text[0..colon]);
            if (!isIdent(name)) break;
            try self.define(name);
            text = trim(text[colon + 1 ..]);
        }
        if (text.len == 0) return;

        var split: usize = 0;
        while (split < text.len and !isSpace(text[split])) split += 1;
        var mn_buf: [16]u8 = undefined;
        if (split > mn_buf.len) return self.fail("unknown instruction or directive");
        const mn = lowerInto(&mn_buf, text[0..split]);

        var ops_buf: [max_operands][]const u8 = undefined;
        var n_ops: usize = 0;
        const rest = trim(text[split..]);
        if (rest.len != 0) {
            var it = std.mem.splitScalar(u8, rest, ',');
            while (it.next()) |op| {
                if (n_ops == max_operands) return self.fail("too many operands");
                const t = trim(op);
                if (t.len == 0) return self.fail("empty operand");
                ops_buf[n_ops] = t;
                n_ops += 1;
            }
        }
        const ops = ops_buf[0..n_ops];

        if (mn[0] == '.') return self.directive(mn, ops);
        if (isa.opFromMnemonic(mn)) |op| return self.instruction(op, ops);
        return self.pseudo(mn, ops);
    }

    fn define(self: *Assembler, name: []const u8) Error!void {
        if (self.pass != .scan) return;
        if (self.lookup(name) != null) return self.fail("duplicate label");
        if (self.label_count == max_labels) return self.fail("too many labels");
        self.labels[self.label_count] = .{ .name = name, .addr = self.pc };
        self.label_count += 1;
    }

    // -----------------------------------------------------------------------
    // Output
    // -----------------------------------------------------------------------

    fn reserve(self: *Assembler, n: u32) Error!usize {
        const off: u64 = self.pc - self.base;
        if (off + n > self.out.len) return self.fail("program does not fit in memory");
        if (@as(u64, self.pc) + n > std.math.maxInt(u32)) return self.fail("address overflow");
        self.pc += n;
        return @intCast(off);
    }

    fn data(self: *Assembler, v: u32, n: u32) Error!void {
        const off = try self.reserve(n);
        if (self.pass != .emit) return;
        var i: u32 = 0;
        while (i < n) : (i += 1) self.out[off + i] = @truncate(v >> @intCast(8 * i));
    }

    fn word(self: *Assembler, w: u32) Error!void {
        if (self.pc & 3 != 0) return self.fail("instruction is not 4-byte aligned");
        return self.data(w, 4);
    }

    // -----------------------------------------------------------------------
    // Operands
    // -----------------------------------------------------------------------

    fn reg(self: *Assembler, tok: []const u8) Error!u5 {
        var buf: [8]u8 = undefined;
        if (tok.len > buf.len) return self.fail("expected a register");
        return isa.parseReg(lowerInto(&buf, tok)) orelse self.fail("expected a register");
    }

    fn number(self: *Assembler, tok: []const u8) Error!i64 {
        const v = parseNumber(tok) orelse return self.fail("invalid number");
        if (v < std.math.minInt(i32) or v > std.math.maxInt(u32)) return self.fail("number out of 32-bit range");
        return v;
    }

    /// A number, a label, or `label+N` / `label-N`.
    fn value(self: *Assembler, tok: []const u8) Error!i64 {
        if (tok.len == 0) return self.fail("expected a value");
        const c = tok[0];
        if ((c >= '0' and c <= '9') or c == '-' or c == '+') return self.number(tok);
        var end: usize = 0;
        while (end < tok.len and isIdentChar(tok[end])) end += 1;
        const name = tok[0..end];
        if (!isIdent(name)) return self.fail("expected a value");
        var addend: i64 = 0;
        const rest = trim(tok[end..]);
        if (rest.len != 0) {
            if (rest[0] != '+' and rest[0] != '-') return self.fail("expected a value");
            addend = try self.number(trim(rest[1..]));
            if (rest[0] == '-') addend = -addend;
        }
        const sym: i64 = if (self.lookup(name)) |a| a else if (self.pass == .scan) self.pc else return self.fail("undefined symbol");
        return sym + addend;
    }

    fn address(self: *Assembler, tok: []const u8) Error!u32 {
        const v = try self.value(tok);
        return @truncate(@as(u64, @bitCast(v)));
    }

    /// Range check that is deferred to the check pass, where labels are final.
    fn range(self: *Assembler, ok: bool, msg: []const u8) Error!void {
        if (!ok and self.pass != .scan) return self.fail(msg);
    }

    fn immediate(self: *Assembler, tok: []const u8, lo: i64, hi: i64, msg: []const u8) Error!i64 {
        const v = try self.value(tok);
        try self.range(v >= lo and v <= hi, msg);
        return std.math.clamp(v, lo, hi);
    }

    const Mem = struct { off: i32, base: u5 };

    fn mem(self: *Assembler, tok: []const u8) Error!Mem {
        const open = std.mem.indexOfScalar(u8, tok, '(') orelse return self.fail("expected offset(register)");
        if (tok[tok.len - 1] != ')') return self.fail("expected offset(register)");
        const off_tok = trim(tok[0..open]);
        const r = try self.reg(trim(tok[open + 1 .. tok.len - 1]));
        const off: i64 = if (off_tok.len == 0) 0 else try self.immediate(off_tok, -2048, 2047, "offset out of range (-2048..2047)");
        return .{ .off = @intCast(off), .base = r };
    }

    fn csr(self: *Assembler, tok: []const u8) Error!u12 {
        var buf: [16]u8 = undefined;
        if (tok.len <= buf.len) {
            if (isa.csrFromName(lowerInto(&buf, tok))) |a| return a;
        }
        const v = try self.number(tok);
        if (v < 0 or v > 0xfff) return self.fail("csr number out of range (0..4095)");
        return @intCast(v);
    }

    fn fenceSet(self: *Assembler, tok: []const u8) Error!u4 {
        if (std.mem.eql(u8, tok, "0")) return 0;
        var set: u4 = 0;
        for (tok) |c| {
            const bit: u4 = switch (std.ascii.toLower(c)) {
                'i' => 8,
                'o' => 4,
                'r' => 2,
                'w' => 1,
                else => return self.fail("fence set must use the letters i, o, r, w"),
            };
            if (set & bit != 0) return self.fail("fence set repeats a letter");
            set |= bit;
        }
        return set;
    }

    fn arity(self: *Assembler, ops: []const []const u8, n: usize) Error!void {
        if (ops.len != n) return self.fail("wrong number of operands");
    }

    // -----------------------------------------------------------------------
    // Encoders with range checks
    // -----------------------------------------------------------------------

    fn emitI(self: *Assembler, op: isa.Op, rd: u5, rs1: u5, imm: i64) Error!void {
        try self.range(isa.fitsI(imm), "immediate out of range (-2048..2047)");
        const v: i32 = if (isa.fitsI(imm)) @intCast(imm) else 0;
        return self.word(isa.encodeI(op, rd, rs1, v));
    }

    fn emitB(self: *Assembler, op: isa.Op, rs1: u5, rs2: u5, target: u32) Error!void {
        const off: i32 = @bitCast(target -% self.pc);
        try self.range(isa.fitsB(off), "branch target out of range or misaligned");
        return self.word(isa.encodeB(op, rs1, rs2, if (isa.fitsB(off)) off else 0));
    }

    fn emitJ(self: *Assembler, rd: u5, target: u32) Error!void {
        const off: i32 = @bitCast(target -% self.pc);
        try self.range(isa.fitsJ(off), "jump target out of range or misaligned");
        return self.word(isa.encodeJ(rd, if (isa.fitsJ(off)) off else 0));
    }

    fn emitCsrRead(self: *Assembler, rd: u5, addr: u12) Error!void {
        return self.word(isa.encodeCsr(.csrrs, rd, addr, 0));
    }

    /// Splits a 32-bit value into the `lui`/`auipc` upper part and the
    /// sign-extended low 12 bits that `addi` adds back.
    fn hiLo(v: u32) struct { hi: u20, lo: i32 } {
        const hi: u20 = @truncate((v +% 0x800) >> 12);
        return .{ .hi = hi, .lo = @bitCast(v -% (@as(u32, hi) << 12)) };
    }

    // -----------------------------------------------------------------------
    // Base instructions
    // -----------------------------------------------------------------------

    fn instruction(self: *Assembler, op: isa.Op, ops: []const []const u8) Error!void {
        switch (isa.kind(op)) {
            .none => unreachable,
            .upper => {
                try self.arity(ops, 2);
                const rd = try self.reg(ops[0]);
                const v = try self.immediate(ops[1], -0x80000, 0xfffff, "upper immediate out of range (0..0xfffff)");
                return self.word(isa.encodeU(op, rd, @truncate(@as(u64, @bitCast(v)))));
            },
            .jump => {
                if (ops.len == 1) return self.emitJ(1, try self.address(ops[0]));
                try self.arity(ops, 2);
                return self.emitJ(try self.reg(ops[0]), try self.address(ops[1]));
            },
            .jump_reg => switch (ops.len) {
                1 => return self.emitI(op, 1, try self.reg(ops[0]), 0),
                2 => {
                    const rd = try self.reg(ops[0]);
                    if (std.mem.indexOfScalar(u8, ops[1], '(') != null) {
                        const m = try self.mem(ops[1]);
                        return self.emitI(op, rd, m.base, m.off);
                    }
                    return self.emitI(op, rd, try self.reg(ops[1]), 0);
                },
                3 => return self.emitI(op, try self.reg(ops[0]), try self.reg(ops[1]), try self.value(ops[2])),
                else => return self.fail("wrong number of operands"),
            },
            .branch => {
                try self.arity(ops, 3);
                return self.emitB(op, try self.reg(ops[0]), try self.reg(ops[1]), try self.address(ops[2]));
            },
            .load => {
                try self.arity(ops, 2);
                const rd = try self.reg(ops[0]);
                const m = try self.mem(ops[1]);
                return self.emitI(op, rd, m.base, m.off);
            },
            .store => {
                try self.arity(ops, 2);
                const rs2 = try self.reg(ops[0]);
                const m = try self.mem(ops[1]);
                return self.word(isa.encodeS(op, m.base, rs2, m.off));
            },
            .alu_imm => {
                try self.arity(ops, 3);
                return self.emitI(op, try self.reg(ops[0]), try self.reg(ops[1]), try self.value(ops[2]));
            },
            .shift_imm => {
                try self.arity(ops, 3);
                const rd = try self.reg(ops[0]);
                const rs1 = try self.reg(ops[1]);
                const sh = try self.immediate(ops[2], 0, 31, "shift amount out of range (0..31)");
                return self.word(isa.encodeShift(op, rd, rs1, @intCast(sh)));
            },
            .alu_reg => {
                try self.arity(ops, 3);
                return self.word(isa.encodeR(op, try self.reg(ops[0]), try self.reg(ops[1]), try self.reg(ops[2])));
            },
            .fence => {
                if (ops.len == 0) return self.word(isa.encodeFence(0, 0xf, 0xf));
                try self.arity(ops, 2);
                return self.word(isa.encodeFence(0, try self.fenceSet(ops[0]), try self.fenceSet(ops[1])));
            },
            .fence_i => {
                try self.arity(ops, 0);
                return self.word(isa.encoded_fence_i);
            },
            .system => {
                try self.arity(ops, 0);
                return self.word(if (op == .ecall) isa.encoded_ecall else isa.encoded_ebreak);
            },
            .csr_reg => {
                try self.arity(ops, 3);
                return self.word(isa.encodeCsr(op, try self.reg(ops[0]), try self.csr(ops[1]), try self.reg(ops[2])));
            },
            .csr_imm => {
                try self.arity(ops, 3);
                const rd = try self.reg(ops[0]);
                const addr = try self.csr(ops[1]);
                const uimm = try self.immediate(ops[2], 0, 31, "csr immediate out of range (0..31)");
                return self.word(isa.encodeCsr(op, rd, addr, @intCast(uimm)));
            },
        }
    }

    // -----------------------------------------------------------------------
    // Pseudo-instructions
    // -----------------------------------------------------------------------

    fn pseudo(self: *Assembler, mn: []const u8, ops: []const []const u8) Error!void {
        const eql = std.mem.eql;
        if (eql(u8, mn, "nop")) {
            try self.arity(ops, 0);
            return self.word(isa.encodeI(.addi, 0, 0, 0));
        }
        if (eql(u8, mn, "fence.tso")) {
            try self.arity(ops, 0);
            return self.word(isa.encodeFence(8, 3, 3));
        }
        if (eql(u8, mn, "ret")) {
            try self.arity(ops, 0);
            return self.word(isa.encodeI(.jalr, 0, 1, 0));
        }
        if (eql(u8, mn, "li")) {
            try self.arity(ops, 2);
            const rd = try self.reg(ops[0]);
            const c = ops[1][0];
            if (!((c >= '0' and c <= '9') or c == '-' or c == '+')) return self.fail("li needs a numeric immediate (use la for labels)");
            const v: u32 = @truncate(@as(u64, @bitCast(try self.number(ops[1]))));
            const s: i32 = @bitCast(v);
            if (isa.fitsI(s)) return self.word(isa.encodeI(.addi, rd, 0, s));
            const parts = hiLo(v);
            try self.word(isa.encodeU(.lui, rd, parts.hi));
            if (parts.lo != 0) try self.word(isa.encodeI(.addi, rd, rd, parts.lo));
            return;
        }
        if (eql(u8, mn, "la")) {
            try self.arity(ops, 2);
            const rd = try self.reg(ops[0]);
            const parts = hiLo((try self.address(ops[1])) -% self.pc);
            try self.word(isa.encodeU(.auipc, rd, parts.hi));
            return self.word(isa.encodeI(.addi, rd, rd, parts.lo));
        }

        const RegReg = struct { name: []const u8, op: isa.Op, form: enum { rd_rs_imm, rd_x0_rs, rd_rs_x0 }, imm: i32 = 0 };
        const unary = [_]RegReg{
            .{ .name = "mv", .op = .addi, .form = .rd_rs_imm, .imm = 0 },
            .{ .name = "not", .op = .xori, .form = .rd_rs_imm, .imm = -1 },
            .{ .name = "seqz", .op = .sltiu, .form = .rd_rs_imm, .imm = 1 },
            .{ .name = "neg", .op = .sub, .form = .rd_x0_rs },
            .{ .name = "snez", .op = .sltu, .form = .rd_x0_rs },
            .{ .name = "sgtz", .op = .slt, .form = .rd_x0_rs },
            .{ .name = "sltz", .op = .slt, .form = .rd_rs_x0 },
        };
        for (unary) |u| {
            if (!eql(u8, mn, u.name)) continue;
            try self.arity(ops, 2);
            const rd = try self.reg(ops[0]);
            const rs = try self.reg(ops[1]);
            return self.word(switch (u.form) {
                .rd_rs_imm => isa.encodeI(u.op, rd, rs, u.imm),
                .rd_x0_rs => isa.encodeR(u.op, rd, 0, rs),
                .rd_rs_x0 => isa.encodeR(u.op, rd, rs, 0),
            });
        }

        // Branch against zero: `beqz rs, target` and friends.
        const ZeroBranch = struct { name: []const u8, op: isa.Op, swap: bool };
        const zero_branches = [_]ZeroBranch{
            .{ .name = "beqz", .op = .beq, .swap = false },
            .{ .name = "bnez", .op = .bne, .swap = false },
            .{ .name = "bltz", .op = .blt, .swap = false },
            .{ .name = "bgez", .op = .bge, .swap = false },
            .{ .name = "blez", .op = .bge, .swap = true },
            .{ .name = "bgtz", .op = .blt, .swap = true },
        };
        for (zero_branches) |b| {
            if (!eql(u8, mn, b.name)) continue;
            try self.arity(ops, 2);
            const rs = try self.reg(ops[0]);
            const t = try self.address(ops[1]);
            return if (b.swap) self.emitB(b.op, 0, rs, t) else self.emitB(b.op, rs, 0, t);
        }

        // Swapped-operand branches: `bgt a, b, t` is `blt b, a, t`.
        const Swapped = struct { name: []const u8, op: isa.Op };
        const swapped = [_]Swapped{
            .{ .name = "bgt", .op = .blt },
            .{ .name = "ble", .op = .bge },
            .{ .name = "bgtu", .op = .bltu },
            .{ .name = "bleu", .op = .bgeu },
        };
        for (swapped) |b| {
            if (!eql(u8, mn, b.name)) continue;
            try self.arity(ops, 3);
            const a = try self.reg(ops[0]);
            const c = try self.reg(ops[1]);
            return self.emitB(b.op, c, a, try self.address(ops[2]));
        }

        if (eql(u8, mn, "j") or eql(u8, mn, "tail") or eql(u8, mn, "call")) {
            try self.arity(ops, 1);
            return self.emitJ(if (mn[0] == 'c') 1 else 0, try self.address(ops[0]));
        }
        if (eql(u8, mn, "jr")) {
            try self.arity(ops, 1);
            return self.word(isa.encodeI(.jalr, 0, try self.reg(ops[0]), 0));
        }

        const Counter = struct { name: []const u8, csr: u12 };
        const counters = [_]Counter{
            .{ .name = "rdcycle", .csr = isa.Csr.cycle },
            .{ .name = "rdcycleh", .csr = isa.Csr.cycleh },
            .{ .name = "rdtime", .csr = isa.Csr.time },
            .{ .name = "rdtimeh", .csr = isa.Csr.timeh },
            .{ .name = "rdinstret", .csr = isa.Csr.instret },
            .{ .name = "rdinstreth", .csr = isa.Csr.instreth },
        };
        for (counters) |c| {
            if (!eql(u8, mn, c.name)) continue;
            try self.arity(ops, 1);
            return self.emitCsrRead(try self.reg(ops[0]), c.csr);
        }
        if (eql(u8, mn, "csrr")) {
            try self.arity(ops, 2);
            return self.emitCsrRead(try self.reg(ops[0]), try self.csr(ops[1]));
        }
        if (eql(u8, mn, "csrw")) {
            try self.arity(ops, 2);
            return self.word(isa.encodeCsr(.csrrw, 0, try self.csr(ops[0]), try self.reg(ops[1])));
        }
        return self.fail("unknown instruction");
    }

    // -----------------------------------------------------------------------
    // Directives
    // -----------------------------------------------------------------------

    fn directive(self: *Assembler, name: []const u8, ops: []const []const u8) Error!void {
        const eql = std.mem.eql;
        const Data = struct { name: []const u8, size: u32, lo: i64, hi: i64 };
        const data_dirs = [_]Data{
            .{ .name = ".word", .size = 4, .lo = std.math.minInt(i32), .hi = std.math.maxInt(u32) },
            .{ .name = ".4byte", .size = 4, .lo = std.math.minInt(i32), .hi = std.math.maxInt(u32) },
            .{ .name = ".half", .size = 2, .lo = std.math.minInt(i16), .hi = std.math.maxInt(u16) },
            .{ .name = ".2byte", .size = 2, .lo = std.math.minInt(i16), .hi = std.math.maxInt(u16) },
            .{ .name = ".byte", .size = 1, .lo = std.math.minInt(i8), .hi = std.math.maxInt(u8) },
        };
        for (data_dirs) |d| {
            if (!eql(u8, name, d.name)) continue;
            if (ops.len == 0) return self.fail("wrong number of operands");
            for (ops) |tok| {
                const v = try self.immediate(tok, d.lo, d.hi, "value does not fit the data size");
                try self.data(@truncate(@as(u64, @bitCast(v))), d.size);
            }
            return;
        }
        if (eql(u8, name, ".space") or eql(u8, name, ".zero")) {
            try self.arity(ops, 1);
            const n = try self.number(ops[0]);
            if (n < 0 or n > 0x10000) return self.fail("size out of range (0..65536)");
            return self.fill(@intCast(n));
        }
        if (eql(u8, name, ".align") or eql(u8, name, ".p2align") or eql(u8, name, ".balign")) {
            try self.arity(ops, 1);
            const n = try self.number(ops[0]);
            const boundary: u32 = if (name[1] == 'b') blk: {
                if (n < 1 or n > 0x10000 or !std.math.isPowerOfTwo(n)) return self.fail("alignment must be a power of two up to 65536");
                break :blk @intCast(n);
            } else blk: {
                if (n < 0 or n > 16) return self.fail("alignment exponent out of range (0..16)");
                break :blk @as(u32, 1) << @intCast(n);
            };
            const pad = (boundary - (self.pc & (boundary - 1))) & (boundary - 1);
            return self.fill(pad);
        }
        const ignored = [_][]const u8{ ".text", ".data", ".section", ".globl", ".global", ".option", ".file", ".type", ".size" };
        for (ignored) |d| {
            if (eql(u8, name, d)) return;
        }
        return self.fail("unknown directive");
    }

    fn fill(self: *Assembler, n: u32) Error!void {
        const off = try self.reserve(n);
        if (self.pass == .emit) @memset(self.out[off .. off + n], 0);
    }
};

fn appendByte(buf: []u8, len: *usize, c: u8) void {
    if (len.* < buf.len) {
        buf[len.*] = c;
        len.* += 1;
    }
}

/// Parses an optionally signed decimal, `0x` hexadecimal, `0o` octal or `0b`
/// binary integer. Returns null on malformed input or magnitudes above 2^40.
pub fn parseNumber(tok: []const u8) ?i64 {
    var s = tok;
    var negative = false;
    if (s.len > 0 and (s[0] == '-' or s[0] == '+')) {
        negative = s[0] == '-';
        s = s[1..];
    }
    var radix: u64 = 10;
    if (s.len > 2 and s[0] == '0') {
        switch (s[1]) {
            'x', 'X' => radix = 16,
            'o', 'O' => radix = 8,
            'b', 'B' => radix = 2,
            else => {},
        }
        if (radix != 10) s = s[2..];
    }
    if (s.len == 0) return null;
    var mag: u64 = 0;
    for (s) |c| {
        const d: u64 = switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            else => return null,
        };
        if (d >= radix) return null;
        mag = mag * radix + d;
        if (mag > (1 << 40)) return null;
    }
    const v: i64 = @intCast(mag);
    return if (negative) -v else v;
}

fn stripComment(s: []const u8) []const u8 {
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        switch (s[i]) {
            '#', ';' => return s[0..i],
            '/' => if (i + 1 < s.len and s[i + 1] == '/') return s[0..i],
            else => {},
        }
    }
    return s;
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\x0b' or c == '\x0c';
}

fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\x0b\x0c");
}

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '.' or c == '$';
}

fn isIdent(s: []const u8) bool {
    if (s.len == 0 or std.ascii.isDigit(s[0])) return false;
    for (s) |c| {
        if (!isIdentChar(c)) return false;
    }
    return true;
}

fn lowerInto(buf: []u8, s: []const u8) []u8 {
    for (s, 0..) |c, i| buf[i] = std.ascii.toLower(c);
    return buf[0..s.len];
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const disasm = @import("disasm.zig");

fn assembleWords(a: *Assembler, src: []const u8, base: u32, out: []u8) ![]const u8 {
    const n = try a.assemble(src, base, out);
    return out[0..n];
}

fn expectWords(src: []const u8, base: u32, want: []const u32) !void {
    var a = Assembler{};
    var out: [256]u8 = undefined;
    const bytes = a.assemble(src, base, &out) catch |e| {
        std.debug.print("unexpected failure: line {d}: {s}\n", .{ a.err_line, a.err_msg });
        return e;
    };
    try testing.expectEqual(want.len * 4, bytes);
    for (want, 0..) |w, i| {
        try testing.expectEqual(w, std.mem.readInt(u32, out[i * 4 ..][0..4], .little));
    }
}

fn expectError(src: []const u8, line_no: u32, msg: []const u8) !void {
    var a = Assembler{};
    var out: [9000]u8 = @splat(0xaa);
    try testing.expectError(error.AsmFailed, a.assemble(src, 0, &out));
    try testing.expectEqual(line_no, a.err_line);
    try testing.expectEqualStrings(msg, a.err_msg);
    // A failed assembly never writes output.
    for (out) |b| try testing.expectEqual(@as(u8, 0xaa), b);
}

test "assembles the original demo program" {
    try expectWords(
        \\addi x1, x0, 10
        \\addi x2, x0, 20
        \\add  x3, x1, x2
        \\sub  x4, x2, x1
        \\ecall
    , 0, &.{ 0x00a00093, 0x01400113, 0x002081b3, 0x40110233, 0x00000073 });
}

test "labels, ABI names, comments and memory operands" {
    try expectWords(
        \\        li   a0, 3          # counter
        \\loop:   addi a0, a0, -1     ; decrement
        \\        sw   a0, 8(sp)      // spill
        \\        lw   t0, (sp)
        \\        bnez a0, loop
        \\done:   ebreak
    , 0x100, &.{
        isa.encodeI(.addi, 10, 0, 3),
        isa.encodeI(.addi, 10, 10, -1),
        isa.encodeS(.sw, 2, 10, 8),
        isa.encodeI(.lw, 5, 2, 0),
        isa.encodeB(.bne, 10, 0, -12),
        isa.encoded_ebreak,
    });
}

test "pseudo-instructions expand to canonical encodings" {
    try expectWords(
        \\nop
        \\mv x5, x6
        \\not x5, x6
        \\neg x5, x6
        \\seqz x5, x6
        \\snez x5, x6
        \\sltz x5, x6
        \\sgtz x5, x6
        \\ret
        \\jr x7
        \\rdcycle x8
        \\rdinstreth x9
        \\csrr x10, time
    , 0, &.{
        0x00000013,
        isa.encodeI(.addi, 5, 6, 0),
        isa.encodeI(.xori, 5, 6, -1),
        isa.encodeR(.sub, 5, 0, 6),
        isa.encodeI(.sltiu, 5, 6, 1),
        isa.encodeR(.sltu, 5, 0, 6),
        isa.encodeR(.slt, 5, 6, 0),
        isa.encodeR(.slt, 5, 0, 6),
        0x00008067,
        isa.encodeI(.jalr, 0, 7, 0),
        isa.encodeCsr(.csrrs, 8, isa.Csr.cycle, 0),
        isa.encodeCsr(.csrrs, 9, isa.Csr.instreth, 0),
        isa.encodeCsr(.csrrs, 10, isa.Csr.time, 0),
    });
}

test "branch pseudo-instructions and jumps resolve forward labels" {
    try expectWords(
        \\start: beqz x1, end
        \\       bgt  x1, x2, end
        \\       bleu x1, x2, start
        \\       blez x3, end
        \\       call end
        \\       j start
        \\end:   jal x0, end
    , 0, &.{
        isa.encodeB(.beq, 1, 0, 24),
        isa.encodeB(.blt, 2, 1, 20),
        isa.encodeB(.bgeu, 2, 1, -8),
        isa.encodeB(.bge, 0, 3, 12),
        isa.encodeJ(1, 8),
        isa.encodeJ(0, -20),
        isa.encodeJ(0, 0),
    });
}

test "li picks the shortest sequence and la is pc-relative" {
    try expectWords("li x1, -2048", 0, &.{isa.encodeI(.addi, 1, 0, -2048)});
    try expectWords("li x1, 0x12345000", 0, &.{isa.encodeU(.lui, 1, 0x12345)});
    // 0x12345fff = lui 0x12346 ; addi -1
    try expectWords("li x1, 0x12345fff", 0, &.{ isa.encodeU(.lui, 1, 0x12346), isa.encodeI(.addi, 1, 1, -1) });
    try expectWords("li x1, 0xffffffff", 0, &.{isa.encodeI(.addi, 1, 0, -1)});
    try expectWords("li x1, 0x80000000", 0, &.{isa.encodeU(.lui, 1, 0x80000)});
    try expectWords(
        \\la a0, buf
        \\ecall
        \\buf: .word 0xdeadbeef
    , 0x200, &.{ isa.encodeU(.auipc, 10, 0), isa.encodeI(.addi, 10, 10, 12), isa.encoded_ecall, 0xdeadbeef });
}

test "li values execute to the requested constant" {
    const cpu_mod = @import("cpu.zig");
    var prng = std.Random.DefaultPrng.init(0x5eed_0004);
    const rnd = prng.random();
    var src_buf: [64]u8 = undefined;
    var n: usize = 0;
    while (n < 2000) : (n += 1) {
        const v = rnd.int(u32);
        const src = try std.fmt.bufPrint(&src_buf, "li x7, {d}\necall", .{v});
        var a = Assembler{};
        var c = cpu_mod.CPU.init();
        _ = try a.assemble(src, 0, &c.ram);
        _ = c.run(10);
        try testing.expectEqual(v, c.readReg(7));
    }
}

test "data directives and alignment" {
    var a = Assembler{};
    var out: [32]u8 = undefined;
    const bytes = try assembleWords(&a,
        \\.byte 1, 0xff, -1
        \\.align 2
        \\.half 0x1234
        \\.balign 8
        \\.word label, -1
        \\label: .space 2
    , 0, &out);
    try testing.expectEqualSlices(u8, &.{
        1,    0xff, 0xff, 0,
        0x34, 0x12, 0,    0,
        16,   0,    0,    0,
        0xff, 0xff, 0xff, 0xff,
        0,    0,
    }, bytes);
    try testing.expectEqual(@as(?u32, 16), a.lookup("label"));
}

test "errors carry the source line and leave output untouched" {
    try expectError("nop\nfoo x1, x2", 2, "unknown instruction");
    try expectError("addi x1, x0, 4096", 1, "immediate out of range (-2048..2047)");
    try expectError("addi x1, x0", 1, "wrong number of operands");
    try expectError("addi x1, x40, 1", 1, "expected a register");
    try expectError("beq x0, x0, nowhere", 1, "undefined symbol");
    try expectError("a: nop\na: nop", 2, "duplicate label");
    try expectError(".byte 1\nnop", 2, "instruction is not 4-byte aligned");
    try expectError("slli x1, x1, 32", 1, "shift amount out of range (0..31)");
    try expectError("lw x1, 4096(x2)", 1, "offset out of range (-2048..2047)");
    try expectError("lw x1, 4(x2", 1, "expected offset(register)");
    try expectError(".space 10000", 1, "program does not fit in memory");
    try expectError("li x1, label\nlabel:", 1, "li needs a numeric immediate (use la for labels)");
    try expectError("add x1, x2, x3, x4", 1, "wrong number of operands");
    try expectError(".byte 1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1", 1, "too many operands");
    try expectError("add x1, , x3", 1, "empty operand");
    try expectError("li x1, 0x100000000", 1, "number out of 32-bit range");
    try expectError(".bogus 1", 1, "unknown directive");
    try expectError("fence rw, rx", 1, "fence set must use the letters i, o, r, w");
    try expectError("thisisaverylongmnemonic x1", 1, "unknown instruction or directive");
    // Branch out of range only becomes known once the label is resolved.
    try expectError("beq x0, x0, far\n.space 8000\nfar:", 1, "branch target out of range or misaligned");
}

test "number parsing" {
    try testing.expectEqual(@as(?i64, 42), parseNumber("42"));
    try testing.expectEqual(@as(?i64, -42), parseNumber("-42"));
    try testing.expectEqual(@as(?i64, 255), parseNumber("0xFf"));
    try testing.expectEqual(@as(?i64, 5), parseNumber("0b101"));
    try testing.expectEqual(@as(?i64, 8), parseNumber("0o10"));
    try testing.expectEqual(@as(?i64, 0), parseNumber("0"));
    try testing.expectEqual(@as(?i64, 0), parseNumber("+0"));
    try testing.expectEqual(@as(?i64, null), parseNumber("0x"));
    try testing.expectEqual(@as(?i64, null), parseNumber("-"));
    try testing.expectEqual(@as(?i64, null), parseNumber("12a"));
    try testing.expectEqual(@as(?i64, null), parseNumber("0b102"));
    try testing.expectEqual(@as(?i64, null), parseNumber("99999999999999999999999"));
}

test "diagnostic formatting" {
    var a = Assembler{};
    var out: [16]u8 = undefined;
    try testing.expectError(error.AsmFailed, a.assemble("\n\naddi x1", 0, &out));
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("line 3: wrong number of operands", a.diagnostic(&buf));
    var short: [6]u8 = undefined;
    try testing.expectEqualStrings("line 3", a.diagnostic(&short));
}

test "label capacity is enforced" {
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(testing.allocator);
    var i: usize = 0;
    while (i <= max_labels) : (i += 1) {
        var b: [32]u8 = undefined;
        try src.appendSlice(testing.allocator, try std.fmt.bufPrint(&b, "l{d}:\n", .{i}));
    }
    var a = Assembler{};
    var out: [4]u8 = undefined;
    try testing.expectError(error.AsmFailed, a.assemble(src.items, 0, &out));
    try testing.expectEqualStrings("too many labels", a.err_msg);
}

test "disassembly round-trips through the assembler for every 32-bit pattern sampled" {
    var prng = std.Random.DefaultPrng.init(0x5eed_0005);
    const rnd = prng.random();
    var a = Assembler{};
    var line_buf: [disasm.max_line]u8 = undefined;
    var out: [4]u8 = undefined;
    var n: usize = 0;
    while (n < 200000) : (n += 1) {
        // Bias half the samples toward legal opcodes so every format is exercised.
        var w = rnd.int(u32);
        if (n % 2 == 0) {
            const opcodes = [_]u32{ 0x37, 0x17, 0x6f, 0x67, 0x63, 0x03, 0x23, 0x13, 0x33, 0x0f, 0x73 };
            w = (w & ~@as(u32, 0x7f)) | opcodes[rnd.uintLessThan(usize, opcodes.len)];
            if (n % 6 == 0) w &= 0x03ffffff; // favour funct7 = 0 / 1
        }
        const pc = rnd.uintLessThan(u32, 0xffff_f000) & ~@as(u32, 3);
        const text = disasm.disassemble(w, pc, &line_buf);
        const len = a.assemble(text, pc, &out) catch |e| {
            std.debug.print("round-trip failed for 0x{x:0>8} at 0x{x}: '{s}' -> {s}\n", .{ w, pc, text, a.err_msg });
            return e;
        };
        try testing.expectEqual(@as(usize, 4), len);
        try testing.expectEqual(w, std.mem.readInt(u32, &out, .little));
    }
}

test "hostile input never crashes the assembler" {
    var prng = std.Random.DefaultPrng.init(0x5eed_0006);
    const rnd = prng.random();
    const alphabet = "abcdefgilmnorsuwxjtz0123456789 ,()+-:#.;\n\t\r$_";
    var src: [96]u8 = undefined;
    var out: [128]u8 = undefined;
    var a = Assembler{};
    var n: usize = 0;
    while (n < 50000) : (n += 1) {
        const len = rnd.uintLessThan(usize, src.len);
        for (src[0..len]) |*c| {
            c.* = if (rnd.boolean()) alphabet[rnd.uintLessThan(usize, alphabet.len)] else rnd.int(u8);
        }
        if (a.assemble(src[0..len], rnd.int(u32) & ~@as(u32, 3), &out)) |bytes| {
            try testing.expect(bytes <= out.len);
        } else |_| {
            try testing.expect(a.err_line >= 1 and a.err_msg.len > 0);
        }
    }
}

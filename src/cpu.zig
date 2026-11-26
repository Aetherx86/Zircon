// Copyright (c) 2026 jk9576. All rights reserved.
// Zircon: Freestanding RISC-V (RV32I) Micro-Emulator & Stepper
// Licensed under the MIT License.

const std = @import("std");
pub const isa = @import("isa.zig");

pub const version = "0.3.0";
pub const version_major: u32 = 0;
pub const version_minor: u32 = 3;
pub const version_patch: u32 = 0;

pub const RAM_SIZE: usize = 64 * 1024; // 64 KiB unified memory
pub const MAX_HISTORY: usize = 256;
pub const MAX_BREAKPOINTS: usize = 16;

const ram_size_u32: u32 = @intCast(RAM_SIZE);

pub const Opcode = enum(u7) {
    load = 0b0000011,
    misc_mem = 0b0001111,
    imm = 0b0010011,
    auipc = 0b0010111,
    store = 0b0100011,
    op = 0b0110011,
    lui = 0b0110111,
    branch = 0b1100011,
    jalr = 0b1100111,
    jal = 0b1101111,
    system = 0b1110011,
    _,
};

pub const InstructionFormat = enum {
    r_type,
    i_type,
    s_type,
    b_type,
    u_type,
    j_type,
    unknown,
};

pub const DecodedInst = struct {
    raw: u32,
    opcode: Opcode,
    format: InstructionFormat,
    rd: u5,
    rs1: u5,
    rs2: u5,
    funct3: u3,
    funct7: u7,
    imm: i32,
};

/// Trap causes reported through `CPU.trap_code`. The values 1, 0x73 and 0x74
/// are unchanged from 0.1.0.
pub const Trap = enum(u32) {
    none = 0,
    pc_out_of_bounds = 1,
    illegal_instruction = 2,
    access_fault = 3,
    misaligned_fetch = 4,
    ecall = 0x73,
    ebreak = 0x74,
    _,

    pub fn name(t: Trap) []const u8 {
        return switch (t) {
            .none => "none",
            .pc_out_of_bounds => "pc_out_of_bounds",
            .illegal_instruction => "illegal_instruction",
            .access_fault => "access_fault",
            .misaligned_fetch => "misaligned_fetch",
            .ecall => "ecall",
            .ebreak => "ebreak",
            _ => "unknown",
        };
    }

    /// Traps that stop the machine before the instruction retires, leaving
    /// architectural state untouched.
    pub fn isFault(t: Trap) bool {
        return switch (t) {
            .pc_out_of_bounds, .illegal_instruction, .access_fault, .misaligned_fetch => true,
            else => false,
        };
    }
};

pub const StepError = error{ IllegalInstruction, AccessFault, MisalignedFetch };

/// Hazard and event counters gathered by the pipeline timing model.
pub const Stats = struct {
    load_use_stalls: u64 = 0,
    flush_cycles: u64 = 0,
    forwarded_operands: u64 = 0,
    branches: u64 = 0,
    branches_taken: u64 = 0,
    jumps: u64 = 0,
    loads: u64 = 0,
    stores: u64 = 0,
    muldiv: u64 = 0,
};

/// Stable identifiers for `Stats` fields, used by the WASM `zircon_get_stat` export.
pub const StatId = enum(u32) {
    load_use_stalls = 0,
    flush_cycles = 1,
    forwarded_operands = 2,
    branches = 3,
    branches_taken = 4,
    jumps = 5,
    loads = 6,
    stores = 7,
    muldiv = 8,
    cycles_hi = 9,
    inst_count_hi = 10,
    history_len = 11,
};

/// A recently retired instruction whose result may still be in flight.
pub const Producer = struct {
    rd: u5 = 0,
    ex_cycle: u64 = 0,
    is_load: bool = false,
};

/// State of the classic five-stage (IF ID EX MEM WB) in-order pipeline model:
/// full forwarding into EX, branches and JALR resolved in EX (2 bubbles when
/// taken), JAL resolved in ID (1 bubble), static not-taken prediction, and a
/// one-cycle load-use interlock.
pub const Pipeline = struct {
    last_ex: u64 = 0,
    p1: Producer = .{},
    p2: Producer = .{},
};

/// One memory write captured so that `stepBack` can restore RAM.
pub const MemUndo = struct {
    addr: u32 = 0,
    old: u32 = 0,
    size: u3 = 0,
};

pub const Snapshot = struct {
    pc: u32,
    regs: [32]u32,
    cycles: u64,
    inst_count: u64,
    stats: Stats = .{},
    pipe: Pipeline = .{},
    undo: MemUndo = .{},
};

pub const CPU = struct {
    regs: [32]u32,
    pc: u32,
    cycles: u64,
    inst_count: u64,
    halted: bool,
    trap_code: u32,
    trap_value: u32,
    stats: Stats,
    pipe: Pipeline,
    ram: [RAM_SIZE]u8,
    history: [MAX_HISTORY]Snapshot,
    history_head: usize,
    history_len: usize,
    breakpoints: [MAX_BREAKPOINTS]u32,
    breakpoint_count: usize,
    hit_breakpoint: bool,

    pub fn init() CPU {
        var cpu: CPU = undefined;
        cpu.reset();
        return cpu;
    }

    pub fn reset(self: *CPU) void {
        @memset(&self.regs, 0);
        self.pc = 0;
        self.cycles = 0;
        self.inst_count = 0;
        self.halted = false;
        self.trap_code = 0;
        self.trap_value = 0;
        self.stats = .{};
        self.pipe = .{};
        @memset(&self.ram, 0);
        self.history_head = 0;
        self.history_len = 0;
        @memset(&self.breakpoints, 0);
        self.breakpoint_count = 0;
        self.hit_breakpoint = false;
    }

    pub fn addBreakpoint(self: *CPU, addr: u32) bool {
        if (self.hasBreakpoint(addr)) return true;
        if (self.breakpoint_count >= MAX_BREAKPOINTS) return false;
        self.breakpoints[self.breakpoint_count] = addr;
        self.breakpoint_count += 1;
        return true;
    }

    pub fn removeBreakpoint(self: *CPU, addr: u32) bool {
        for (0..self.breakpoint_count) |i| {
            if (self.breakpoints[i] == addr) {
                self.breakpoint_count -= 1;
                self.breakpoints[i] = self.breakpoints[self.breakpoint_count];
                return true;
            }
        }
        return false;
    }

    pub fn clearBreakpoints(self: *CPU) void {
        self.breakpoint_count = 0;
        self.hit_breakpoint = false;
    }

    pub fn hasBreakpoint(self: *const CPU, addr: u32) bool {
        for (self.breakpoints[0..self.breakpoint_count]) |bp| {
            if (bp == addr) return true;
        }
        return false;
    }

    pub fn loadProgram(self: *CPU, program: []const u8, base_addr: u32) !void {
        if (base_addr > RAM_SIZE or program.len > RAM_SIZE - base_addr) {
            return error.ProgramOutOfBounds;
        }
        @memcpy(self.ram[base_addr .. base_addr + program.len], program);
        self.pc = base_addr;
    }

    fn capture(self: *const CPU) Snapshot {
        return .{
            .pc = self.pc,
            .regs = self.regs,
            .cycles = self.cycles,
            .inst_count = self.inst_count,
            .stats = self.stats,
            .pipe = self.pipe,
        };
    }

    fn pushSnapshot(self: *CPU, snap: Snapshot) void {
        self.history[self.history_head] = snap;
        self.history_head = (self.history_head + 1) % MAX_HISTORY;
        if (self.history_len < MAX_HISTORY) {
            self.history_len += 1;
        }
    }

    /// Records the current state (without a memory undo entry) in the ring.
    pub fn saveSnapshot(self: *CPU) void {
        self.pushSnapshot(self.capture());
    }

    /// Undoes the most recent step. A fault that stopped the machine before
    /// retiring anything is simply cleared; otherwise the last retired
    /// instruction is rolled back, including any byte it stored to RAM.
    pub fn stepBack(self: *CPU) bool {
        if (self.halted and @as(Trap, @fromBackingInt(@intCast(self.trap_code))).isFault()) {
            self.halted = false;
            self.trap_code = 0;
            self.trap_value = 0;
            return true;
        }
        if (self.history_len == 0) return false;
        self.history_head = (self.history_head + MAX_HISTORY - 1) % MAX_HISTORY;
        self.history_len -= 1;
        const snap = self.history[self.history_head];
        self.pc = snap.pc;
        self.regs = snap.regs;
        self.cycles = snap.cycles;
        self.inst_count = snap.inst_count;
        self.stats = snap.stats;
        self.pipe = snap.pipe;
        if (snap.undo.size != 0) {
            self.rawWrite(snap.undo.addr, snap.undo.old, snap.undo.size);
        }
        self.halted = false;
        self.trap_code = 0;
        self.trap_value = 0;
        return true;
    }

    pub inline fn readReg(self: *const CPU, idx: u5) u32 {
        if (idx == 0) return 0;
        return self.regs[idx];
    }

    pub inline fn writeReg(self: *CPU, idx: u5, val: u32) void {
        if (idx != 0) {
            self.regs[idx] = val;
        }
    }

    inline fn inBounds(addr: u32, size: u3) bool {
        return size <= ram_size_u32 and addr <= ram_size_u32 - size;
    }

    pub fn readMem(self: *const CPU, addr: u32, size: u3) !u32 {
        if (!inBounds(addr, size)) return error.AccessFault;
        return switch (size) {
            1 => self.ram[addr],
            2 => std.mem.readInt(u16, self.ram[addr..][0..2], .little),
            4 => std.mem.readInt(u32, self.ram[addr..][0..4], .little),
            else => error.InvalidAccessSize,
        };
    }

    pub fn writeMem(self: *CPU, addr: u32, val: u32, size: u3) !void {
        if (!inBounds(addr, size)) return error.AccessFault;
        switch (size) {
            1, 2, 4 => self.rawWrite(addr, val, size),
            else => return error.InvalidAccessSize,
        }
    }

    fn rawWrite(self: *CPU, addr: u32, val: u32, size: u3) void {
        switch (size) {
            1 => self.ram[addr] = @truncate(val),
            2 => std.mem.writeInt(u16, self.ram[addr..][0..2], @truncate(val), .little),
            else => std.mem.writeInt(u32, self.ram[addr..][0..4], val, .little),
        }
    }

    /// Legacy field decoder kept for API compatibility. `isa.decode` provides
    /// the full RV32IM classification used by the emulator.
    pub fn decode(raw: u32) DecodedInst {
        const op_raw: u7 = @truncate(raw & 0x7F);
        const opcode: Opcode = @fromBackingInt(@intCast(op_raw));
        const rd: u5 = @truncate((raw >> 7) & 0x1F);
        const funct3: u3 = @truncate((raw >> 12) & 0x07);
        const rs1: u5 = @truncate((raw >> 15) & 0x1F);
        const rs2: u5 = @truncate((raw >> 20) & 0x1F);
        const funct7: u7 = @truncate((raw >> 25) & 0x7F);

        var format: InstructionFormat = .unknown;
        var imm: i32 = 0;

        switch (opcode) {
            .op => format = .r_type,
            .imm, .load, .jalr, .system, .misc_mem => {
                format = .i_type;
                imm = isa.immI(raw);
            },
            .store => {
                format = .s_type;
                imm = isa.immS(raw);
            },
            .branch => {
                format = .b_type;
                imm = isa.immB(raw);
            },
            .lui, .auipc => {
                format = .u_type;
                imm = isa.immU(raw);
            },
            .jal => {
                format = .j_type;
                imm = isa.immJ(raw);
            },
            _ => {},
        }

        return DecodedInst{
            .raw = raw,
            .opcode = opcode,
            .format = format,
            .rd = rd,
            .rs1 = rs1,
            .rs2 = rs2,
            .funct3 = funct3,
            .funct7 = funct7,
            .imm = imm,
        };
    }

    fn fault(self: *CPU, trap: Trap, value: u32) StepError {
        self.halted = true;
        self.trap_code = @backingInt(trap);
        self.trap_value = value;
        return switch (trap) {
            .access_fault => error.AccessFault,
            .misaligned_fetch => error.MisalignedFetch,
            else => error.IllegalInstruction,
        };
    }

    fn load(self: *CPU, addr: u32, size: u3) StepError!u32 {
        if (!inBounds(addr, size)) return self.fault(.access_fault, addr);
        return self.readMem(addr, size) catch unreachable;
    }

    fn readCounter(self: *const CPU, csr: u12) ?u32 {
        return switch (csr) {
            isa.Csr.cycle, isa.Csr.time => @truncate(self.cycles),
            isa.Csr.cycleh, isa.Csr.timeh => @truncate(self.cycles >> 32),
            isa.Csr.instret => @truncate(self.inst_count),
            isa.Csr.instreth => @truncate(self.inst_count >> 32),
            else => null,
        };
    }

    /// Executes one instruction. Returns false if the machine is (or just
    /// became) halted without executing anything; returns an error when the
    /// instruction faults, in which case the machine halts with a trap code and
    /// no architectural state is modified.
    pub fn step(self: *CPU) StepError!bool {
        if (self.halted) return false;
        if (self.pc > ram_size_u32 - 4) {
            self.halted = true;
            self.trap_code = @backingInt(Trap.pc_out_of_bounds);
            self.trap_value = self.pc;
            return false;
        }
        if (self.pc & 3 != 0) return self.fault(.misaligned_fetch, self.pc);

        var snap = self.capture();
        const raw = std.mem.readInt(u32, self.ram[self.pc..][0..4], .little);
        const inst = isa.decode(raw);
        const pc = self.pc;
        var next_pc = pc +% 4;
        const r1 = self.readReg(inst.rs1);
        const r2 = self.readReg(inst.rs2);

        // Timing-model inputs.
        var src1: u5 = 0;
        var src2: u5 = 0;
        var dest: u5 = 0;
        var penalty: u64 = 0;
        var stats = self.stats;

        switch (isa.kind(inst.op)) {
            .none => return self.fault(.illegal_instruction, raw),
            .upper => {
                const val: u32 = if (inst.op == .lui) @bitCast(inst.imm) else pc +% @as(u32, @bitCast(inst.imm));
                self.writeReg(inst.rd, val);
                dest = inst.rd;
            },
            .jump => {
                const target = pc +% @as(u32, @bitCast(inst.imm));
                if (target & 3 != 0) return self.fault(.misaligned_fetch, target);
                self.writeReg(inst.rd, pc +% 4);
                dest = inst.rd;
                next_pc = target;
                penalty = 1;
                stats.jumps += 1;
            },
            .jump_reg => {
                const target = (r1 +% @as(u32, @bitCast(inst.imm))) & ~@as(u32, 1);
                if (target & 3 != 0) return self.fault(.misaligned_fetch, target);
                self.writeReg(inst.rd, pc +% 4);
                src1 = inst.rs1;
                dest = inst.rd;
                next_pc = target;
                penalty = 2;
                stats.jumps += 1;
            },
            .branch => {
                const s1: i32 = @bitCast(r1);
                const s2: i32 = @bitCast(r2);
                const take = switch (inst.op) {
                    .beq => r1 == r2,
                    .bne => r1 != r2,
                    .blt => s1 < s2,
                    .bge => s1 >= s2,
                    .bltu => r1 < r2,
                    .bgeu => r1 >= r2,
                    else => unreachable,
                };
                src1 = inst.rs1;
                src2 = inst.rs2;
                stats.branches += 1;
                if (take) {
                    const target = pc +% @as(u32, @bitCast(inst.imm));
                    if (target & 3 != 0) return self.fault(.misaligned_fetch, target);
                    next_pc = target;
                    penalty = 2;
                    stats.branches_taken += 1;
                }
            },
            .load => {
                const addr = r1 +% @as(u32, @bitCast(inst.imm));
                const val: u32 = switch (inst.op) {
                    .lb => @bitCast(@as(i32, @as(i8, @bitCast(@as(u8, @truncate(try self.load(addr, 1))))))),
                    .lh => @bitCast(@as(i32, @as(i16, @bitCast(@as(u16, @truncate(try self.load(addr, 2))))))),
                    .lw => try self.load(addr, 4),
                    .lbu => try self.load(addr, 1),
                    .lhu => try self.load(addr, 2),
                    else => unreachable,
                };
                self.writeReg(inst.rd, val);
                src1 = inst.rs1;
                dest = inst.rd;
                stats.loads += 1;
            },
            .store => {
                const addr = r1 +% @as(u32, @bitCast(inst.imm));
                const size: u3 = switch (inst.op) {
                    .sb => 1,
                    .sh => 2,
                    .sw => 4,
                    else => unreachable,
                };
                if (!inBounds(addr, size)) return self.fault(.access_fault, addr);
                snap.undo = .{ .addr = addr, .old = self.readMem(addr, size) catch unreachable, .size = size };
                self.rawWrite(addr, r2, size);
                src1 = inst.rs1;
                src2 = inst.rs2;
                stats.stores += 1;
            },
            .alu_imm, .shift_imm => {
                const imm: u32 = @bitCast(inst.imm);
                const shamt: u5 = @truncate(imm);
                const val: u32 = switch (inst.op) {
                    .addi => r1 +% imm,
                    .slti => @intFromBool(@as(i32, @bitCast(r1)) < inst.imm),
                    .sltiu => @intFromBool(r1 < imm),
                    .xori => r1 ^ imm,
                    .ori => r1 | imm,
                    .andi => r1 & imm,
                    .slli => r1 << shamt,
                    .srli => r1 >> shamt,
                    .srai => @bitCast(@as(i32, @bitCast(r1)) >> shamt),
                    else => unreachable,
                };
                self.writeReg(inst.rd, val);
                src1 = inst.rs1;
                dest = inst.rd;
            },
            .alu_reg => {
                self.writeReg(inst.rd, aluReg(inst.op, r1, r2));
                src1 = inst.rs1;
                src2 = inst.rs2;
                dest = inst.rd;
                if (isa.isMulDiv(inst.op)) stats.muldiv += 1;
            },
            .fence, .fence_i => {
                // Single hart with no caches: memory and instruction fetch are
                // always coherent, so both fences retire as no-ops.
            },
            .system => {
                self.halted = true;
                self.trap_code = @backingInt(if (inst.op == .ecall) Trap.ecall else Trap.ebreak);
                self.trap_value = pc;
            },
            .csr_reg, .csr_imm => {
                // Only the read-only Zicntr counters exist. Any attempt to
                // write them, or to touch another CSR, is illegal.
                const writes = switch (inst.op) {
                    .csrrw, .csrrwi => true,
                    else => inst.rs1 != 0,
                };
                const value = self.readCounter(inst.csr) orelse return self.fault(.illegal_instruction, raw);
                if (writes) return self.fault(.illegal_instruction, raw);
                self.writeReg(inst.rd, value);
                dest = inst.rd;
            },
        }

        // Pipeline timing model.
        var ex = self.pipe.last_ex + 1;
        const p1 = self.pipe.p1;
        const p2 = self.pipe.p2;
        var stall: u64 = 0;
        if (p1.is_load and p1.rd != 0 and (src1 == p1.rd or src2 == p1.rd) and ex - p1.ex_cycle < 2) {
            stall = 2 - (ex - p1.ex_cycle);
            ex += stall;
        }
        for ([2]u5{ src1, src2 }) |s| {
            if (s == 0) continue;
            const producer: ?Producer = if (p1.rd == s) p1 else if (p2.rd == s) p2 else null;
            if (producer) |p| {
                if (ex - p.ex_cycle <= 2) stats.forwarded_operands += 1;
            }
        }
        stats.load_use_stalls += stall;
        stats.flush_cycles += penalty;

        self.pipe = .{
            .last_ex = ex + penalty,
            .p1 = .{ .rd = dest, .ex_cycle = ex, .is_load = isa.kind(inst.op) == .load },
            .p2 = p1,
        };
        self.stats = stats;
        self.pushSnapshot(snap);
        self.pc = next_pc;
        self.cycles += 1 + stall + penalty;
        self.inst_count += 1;
        return true;
    }

    /// Runs until the machine halts, faults, or `max_steps` instructions retire.
    /// Returns the number of instructions retired.
    pub fn run(self: *CPU, max_steps: u64) u64 {
        self.hit_breakpoint = false;
        var n: u64 = 0;
        while (n < max_steps) : (n += 1) {
            if (self.breakpoint_count > 0 and self.hasBreakpoint(self.pc)) {
                self.hit_breakpoint = true;
                break;
            }
            const ok = self.step() catch break;
            if (!ok) break;
        }
        return n;
    }

    pub fn stat(self: *const CPU, id: StatId) u64 {
        return switch (id) {
            .load_use_stalls => self.stats.load_use_stalls,
            .flush_cycles => self.stats.flush_cycles,
            .forwarded_operands => self.stats.forwarded_operands,
            .branches => self.stats.branches,
            .branches_taken => self.stats.branches_taken,
            .jumps => self.stats.jumps,
            .loads => self.stats.loads,
            .stores => self.stats.stores,
            .muldiv => self.stats.muldiv,
            .cycles_hi => self.cycles >> 32,
            .inst_count_hi => self.inst_count >> 32,
            .history_len => self.history_len,
        };
    }
};

/// RV32I register-register ALU and RV32M multiply/divide semantics.
pub fn aluReg(op: isa.Op, r1: u32, r2: u32) u32 {
    const s1: i32 = @bitCast(r1);
    const s2: i32 = @bitCast(r2);
    const shamt: u5 = @truncate(r2);
    return switch (op) {
        .add => r1 +% r2,
        .sub => r1 -% r2,
        .sll => r1 << shamt,
        .slt => @intFromBool(s1 < s2),
        .sltu => @intFromBool(r1 < r2),
        .xor => r1 ^ r2,
        .srl => r1 >> shamt,
        .sra => @bitCast(s1 >> shamt),
        .@"or" => r1 | r2,
        .@"and" => r1 & r2,
        .mul => r1 *% r2,
        .mulh => @truncate(@as(u64, @bitCast(@as(i64, s1) * @as(i64, s2))) >> 32),
        .mulhsu => @truncate(@as(u64, @bitCast(@as(i64, s1) * @as(i64, r2))) >> 32),
        .mulhu => @truncate((@as(u64, r1) * @as(u64, r2)) >> 32),
        .div => if (s2 == 0)
            0xffffffff
        else if (s1 == std.math.minInt(i32) and s2 == -1)
            r1
        else
            @bitCast(@divTrunc(s1, s2)),
        .divu => if (r2 == 0) 0xffffffff else r1 / r2,
        .rem => if (s2 == 0)
            r1
        else if (s1 == std.math.minInt(i32) and s2 == -1)
            0
        else
            @bitCast(@rem(s1, s2)),
        .remu => if (r2 == 0) r1 else r1 % r2,
        else => unreachable,
    };
}

// Copyright (c) 2026 jk9576. All rights reserved.
// Zircon: Freestanding RISC-V (RV32I) Micro-Emulator & Stepper
// Licensed under the MIT License.

const std = @import("std");

pub const RAM_SIZE: usize = 64 * 1024; // 64 KiB unified memory
pub const MAX_HISTORY: usize = 256;

pub const Opcode = enum(u7) {
    load = 0b0000011,
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

pub const Snapshot = struct {
    pc: u32,
    regs: [32]u32,
    cycles: u64,
    inst_count: u64,
};

pub const CPU = struct {
    regs: [32]u32,
    pc: u32,
    cycles: u64,
    inst_count: u64,
    halted: bool,
    trap_code: u32,
    ram: [RAM_SIZE]u8,
    history: [MAX_HISTORY]Snapshot,
    history_head: usize,
    history_len: usize,

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
        @memset(&self.ram, 0);
        self.history_head = 0;
        self.history_len = 0;
    }

    pub fn loadProgram(self: *CPU, program: []const u8, base_addr: u32) !void {
        if (@as(usize, base_addr) + program.len > RAM_SIZE) {
            return error.ProgramOutOfBounds;
        }
        @memcpy(self.ram[base_addr .. base_addr + program.len], program);
        self.pc = base_addr;
    }

    pub fn saveSnapshot(self: *CPU) void {
        self.history[self.history_head] = Snapshot{
            .pc = self.pc,
            .regs = self.regs,
            .cycles = self.cycles,
            .inst_count = self.inst_count,
        };
        self.history_head = (self.history_head + 1) % MAX_HISTORY;
        if (self.history_len < MAX_HISTORY) {
            self.history_len += 1;
        }
    }

    pub fn stepBack(self: *CPU) bool {
        if (self.history_len == 0) return false;
        self.history_head = (self.history_head + MAX_HISTORY - 1) % MAX_HISTORY;
        self.history_len -= 1;
        const snap = self.history[self.history_head];
        self.pc = snap.pc;
        self.regs = snap.regs;
        self.cycles = snap.cycles;
        self.inst_count = snap.inst_count;
        self.halted = false;
        self.trap_code = 0;
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

    pub fn readMem(self: *const CPU, addr: u32, size: u3) !u32 {
        if (@as(usize, addr) + size > RAM_SIZE) return error.AccessFault;
        return switch (size) {
            1 => self.ram[addr],
            2 => std.mem.readInt(u16, self.ram[addr..][0..2], .little),
            4 => std.mem.readInt(u32, self.ram[addr..][0..4], .little),
            else => error.InvalidAccessSize,
        };
    }

    pub fn writeMem(self: *CPU, addr: u32, val: u32, size: u3) !void {
        if (@as(usize, addr) + size > RAM_SIZE) return error.AccessFault;
        switch (size) {
            1 => self.ram[addr] = @truncate(val),
            2 => std.mem.writeInt(u16, self.ram[addr..][0..2], @truncate(val), .little),
            4 => std.mem.writeInt(u32, self.ram[addr..][0..4], val, .little),
            else => return error.InvalidAccessSize,
        }
    }

    pub fn decode(raw: u32) DecodedInst {
        const op_raw: u7 = @truncate(raw & 0x7F);
        const opcode: Opcode = @enumFromInt(op_raw);
        const rd: u5 = @truncate((raw >> 7) & 0x1F);
        const funct3: u3 = @truncate((raw >> 12) & 0x07);
        const rs1: u5 = @truncate((raw >> 15) & 0x1F);
        const rs2: u5 = @truncate((raw >> 20) & 0x1F);
        const funct7: u7 = @truncate((raw >> 25) & 0x7F);

        var format: InstructionFormat = .unknown;
        var imm: i32 = 0;

        switch (opcode) {
            .op => {
                format = .r_type;
            },
            .imm, .load, .jalr => {
                format = .i_type;
                imm = @as(i32, @bitCast(raw)) >> 20;
            },
            .store => {
                format = .s_type;
                const imm4_0 = (raw >> 7) & 0x1F;
                const imm11_5 = (raw >> 25) & 0x7F;
                const combined = (imm11_5 << 5) | imm4_0;
                imm = (@as(i32, @bitCast(combined << 20))) >> 20;
            },
            .branch => {
                format = .b_type;
                const imm11 = (raw >> 7) & 0x1;
                const imm4_1 = (raw >> 8) & 0xF;
                const imm10_5 = (raw >> 25) & 0x3F;
                const imm12 = (raw >> 31) & 0x1;
                const combined = (imm12 << 12) | (imm11 << 11) | (imm10_5 << 5) | (imm4_1 << 1);
                imm = (@as(i32, @bitCast(combined << 19))) >> 19;
            },
            .lui, .auipc => {
                format = .u_type;
                imm = @as(i32, @bitCast(raw & 0xFFFFF000));
            },
            .jal => {
                format = .j_type;
                const imm19_12 = (raw >> 12) & 0xFF;
                const imm11 = (raw >> 20) & 0x1;
                const imm10_1 = (raw >> 21) & 0x3FF;
                const imm20 = (raw >> 31) & 0x1;
                const combined = (imm20 << 20) | (imm19_12 << 12) | (imm11 << 11) | (imm10_1 << 1);
                imm = (@as(i32, @bitCast(combined << 11))) >> 11;
            },
            .system => {
                format = .i_type;
                imm = @as(i32, @bitCast(raw)) >> 20;
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

    pub fn step(self: *CPU) !bool {
        if (self.halted) return false;
        if (self.pc >= RAM_SIZE - 4) {
            self.halted = true;
            self.trap_code = 1;
            return false;
        }

        self.saveSnapshot();

        const raw_inst = try self.readMem(self.pc, 4);
        const inst = decode(raw_inst);
        var next_pc = self.pc + 4;

        switch (inst.opcode) {
            .lui => {
                self.writeReg(inst.rd, @bitCast(inst.imm));
            },
            .auipc => {
                const res = @as(i32, @bitCast(self.pc)) +% inst.imm;
                self.writeReg(inst.rd, @bitCast(res));
            },
            .jal => {
                self.writeReg(inst.rd, self.pc + 4);
                next_pc = @bitCast(@as(i32, @bitCast(self.pc)) +% inst.imm);
            },
            .jalr => {
                const target = (@as(i32, @bitCast(self.readReg(inst.rs1))) +% inst.imm) & ~@as(i32, 1);
                self.writeReg(inst.rd, self.pc + 4);
                next_pc = @bitCast(target);
            },
            .branch => {
                const r1 = self.readReg(inst.rs1);
                const r2 = self.readReg(inst.rs2);
                const take: bool = switch (inst.funct3) {
                    0b000 => r1 == r2, // BEQ
                    0b001 => r1 != r2, // BNE
                    0b100 => @as(i32, @bitCast(r1)) < @as(i32, @bitCast(r2)), // BLT
                    0b101 => @as(i32, @bitCast(r1)) >= @as(i32, @bitCast(r2)), // BGE
                    0b110 => r1 < r2, // BLTU
                    0b111 => r1 >= r2, // BGEU
                    else => false,
                };
                if (take) {
                    next_pc = @bitCast(@as(i32, @bitCast(self.pc)) +% inst.imm);
                }
            },
            .load => {
                const base = @as(i32, @bitCast(self.readReg(inst.rs1)));
                const addr: u32 = @bitCast(base +% inst.imm);
                const val = switch (inst.funct3) {
                    0b000 => blk: { // LB
                        const byte: i8 = @bitCast(@as(u8, @truncate(try self.readMem(addr, 1))));
                        break :blk @as(u32, @bitCast(@as(i32, byte)));
                    },
                    0b001 => blk: { // LH
                        const half: i16 = @bitCast(@as(u16, @truncate(try self.readMem(addr, 2))));
                        break :blk @as(u32, @bitCast(@as(i32, half)));
                    },
                    0b010 => try self.readMem(addr, 4), // LW
                    0b100 => try self.readMem(addr, 1), // LBU
                    0b101 => try self.readMem(addr, 2), // LHU
                    else => return error.IllegalInstruction,
                };
                self.writeReg(inst.rd, val);
            },
            .store => {
                const base = @as(i32, @bitCast(self.readReg(inst.rs1)));
                const addr: u32 = @bitCast(base +% inst.imm);
                const val = self.readReg(inst.rs2);
                switch (inst.funct3) {
                    0b000 => try self.writeMem(addr, val, 1), // SB
                    0b001 => try self.writeMem(addr, val, 2), // SH
                    0b010 => try self.writeMem(addr, val, 4), // SW
                    else => return error.IllegalInstruction,
                }
            },
            .imm => {
                const r1 = self.readReg(inst.rs1);
                const imm_val = inst.imm;
                const shamt: u5 = @truncate(@as(u32, @bitCast(imm_val)) & 0x1F);
                const val: u32 = switch (inst.funct3) {
                    0b000 => @bitCast(@as(i32, @bitCast(r1)) +% imm_val), // ADDI
                    0b010 => if (@as(i32, @bitCast(r1)) < imm_val) 1 else 0, // SLTI
                    0b011 => if (r1 < @as(u32, @bitCast(imm_val))) 1 else 0, // SLTIU
                    0b100 => r1 ^ @as(u32, @bitCast(imm_val)), // XORI
                    0b110 => r1 | @as(u32, @bitCast(imm_val)), // ORI
                    0b111 => r1 & @as(u32, @bitCast(imm_val)), // ANDI
                    0b001 => r1 << shamt, // SLLI
                    0b101 => if ((inst.funct7 & 0x20) != 0) // SRAI / SRLI
                        @bitCast(@as(i32, @bitCast(r1)) >> shamt)
                    else
                        r1 >> shamt,
                };
                self.writeReg(inst.rd, val);
            },
            .op => {
                const r1 = self.readReg(inst.rs1);
                const r2 = self.readReg(inst.rs2);
                const shamt: u5 = @truncate(r2 & 0x1F);
                const val: u32 = switch (inst.funct3) {
                    0b000 => if ((inst.funct7 & 0x20) != 0)
                        @bitCast(@as(i32, @bitCast(r1)) -% @as(i32, @bitCast(r2))) // SUB
                    else
                        @bitCast(@as(i32, @bitCast(r1)) +% @as(i32, @bitCast(r2))), // ADD
                    0b001 => r1 << shamt, // SLL
                    0b010 => if (@as(i32, @bitCast(r1)) < @as(i32, @bitCast(r2))) 1 else 0, // SLT
                    0b011 => if (r1 < r2) 1 else 0, // SLTU
                    0b100 => r1 ^ r2, // XOR
                    0b101 => if ((inst.funct7 & 0x20) != 0)
                        @bitCast(@as(i32, @bitCast(r1)) >> shamt) // SRA
                    else
                        r1 >> shamt, // SRL
                    0b110 => r1 | r2, // OR
                    0b111 => r1 & r2, // AND
                };
                self.writeReg(inst.rd, val);
            },
            .system => {
                if (inst.raw == 0x00000073) { // ECALL
                    // Exit emulation or trigger supervisor trap
                    self.halted = true;
                    self.trap_code = 0x73;
                } else if (inst.raw == 0x00100073) { // EBREAK
                    self.halted = true;
                    self.trap_code = 0x74;
                }
            },
            _ => return error.IllegalInstruction,
        }

        self.pc = next_pc;
        self.cycles += 1;
        self.inst_count += 1;
        return true;
    }
};

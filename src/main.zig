// Copyright (c) 2026 jk9576. All rights reserved.
// Zircon: Freestanding RISC-V (RV32I) Micro-Emulator & Stepper
// Licensed under the MIT License.

const std = @import("std");
pub const cpu = @import("cpu.zig");
pub const isa = @import("isa.zig");
pub const disasm = @import("disasm.zig");
pub const asmz = @import("asm.zig");

const Io = std.Io;
const Writer = Io.Writer;

const usage =
    \\Zircon RV32IM micro-emulator and pipeline stepper
    \\
    \\Usage:
    \\  zircon                                  run the built-in demo program
    \\  zircon run <file> [--base ADDR] [--max-steps N] [--break ADDR] [--reg R=VAL] [--json] [--trace]
    \\  zircon asm <file.s> -o <out.bin> [--base ADDR]
    \\  zircon disasm <file> [--base ADDR] [--json]
    \\  zircon version
    \\  zircon help
    \\
    \\Files ending in .s or .S are assembled first; any other file is loaded
    \\as a raw little-endian memory image at the base address (default 0).
    \\
    \\Exit status of `run`: 0 halted by ecall/ebreak, 1 fault, 3 step limit, 4 breakpoint.
    \\Usage, input and assembly errors exit with status 2.
    \\
;

const UsageError = error{Usage};

const RegInit = struct { reg: u5, val: u32 };

const Options = struct {
    path: ?[]const u8 = null,
    out: ?[]const u8 = null,
    base: u32 = 0,
    max_steps: u64 = 1_000_000,
    json: bool = false,
    trace: bool = false,
    breakpoints: [cpu.MAX_BREAKPOINTS]u32 = @splat(0),
    breakpoint_count: usize = 0,
    reg_inits: [32]RegInit = @splat(.{ .reg = 0, .val = 0 }),
    reg_init_count: usize = 0,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var out_buf: [4096]u8 = undefined;
    var out_file = Io.File.stdout().writerStreaming(io, &out_buf);
    const out = &out_file.interface;
    var err_buf: [1024]u8 = undefined;
    var err_file = Io.File.stderr().writerStreaming(io, &err_buf);
    const err = &err_file.interface;

    const status = dispatch(io, arena, args, out, err) catch |e| blk: {
        switch (e) {
            error.Usage => try err.writeAll(usage),
            error.Reported => {},
            else => try err.print("zircon: {s}\n", .{@errorName(e)}),
        }
        break :blk 2;
    };
    try out.flush();
    try err.flush();
    if (status != 0) std.process.exit(status);
}

fn dispatch(io: Io, arena: std.mem.Allocator, args: []const [:0]const u8, out: *Writer, err: *Writer) !u8 {
    if (args.len < 2) {
        try demo(out);
        return 0;
    }
    const cmd = args[1];
    if (eql(cmd, "help") or eql(cmd, "--help") or eql(cmd, "-h")) {
        try out.writeAll(usage);
        return 0;
    }
    if (eql(cmd, "version") or eql(cmd, "--version")) {
        try out.print("zircon {s}\n", .{cpu.version});
        return 0;
    }
    if (eql(cmd, "demo")) {
        try demo(out);
        return 0;
    }
    const opts = try parseOptions(args[2..], err);
    if (eql(cmd, "run")) return cmdRun(io, arena, opts, out, err);
    if (eql(cmd, "asm")) return cmdAsm(io, arena, opts, out, err);
    if (eql(cmd, "disasm")) return cmdDisasm(io, arena, opts, out, err);
    return error.Usage;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn parseRegName(name: []const u8) ?u5 {
    if (name.len >= 2 and (name[0] == 'x' or name[0] == 'X')) {
        const n = std.fmt.parseInt(u8, name[1..], 10) catch return null;
        if (n < 32) return @intCast(n);
        return null;
    }
    for (isa.abi_names, 0..) |abi, i| {
        if (std.ascii.eqlIgnoreCase(name, abi)) return @intCast(i);
    }
    return null;
}

fn parseOptions(args: []const [:0]const u8, err: *Writer) !Options {
    var o = Options{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (eql(a, "--json")) {
            o.json = true;
        } else if (eql(a, "--trace")) {
            o.trace = true;
        } else if (eql(a, "--base") or eql(a, "--max-steps") or eql(a, "-o") or eql(a, "--break") or eql(a, "--reg")) {
            i += 1;
            if (i == args.len) return error.Usage;
            const v = args[i];
            if (eql(a, "-o")) {
                o.out = v;
            } else if (eql(a, "--base")) {
                o.base = std.fmt.parseInt(u32, v, 0) catch return report(err, "invalid --base value: {s}\n", .{v});
                if (o.base >= cpu.RAM_SIZE) return report(err, "--base must be below 0x{x}\n", .{cpu.RAM_SIZE});
            } else if (eql(a, "--break")) {
                const addr = std.fmt.parseInt(u32, v, 0) catch return report(err, "invalid --break address: {s}\n", .{v});
                if (o.breakpoint_count >= cpu.MAX_BREAKPOINTS) return report(err, "too many --break addresses (max {d})\n", .{cpu.MAX_BREAKPOINTS});
                o.breakpoints[o.breakpoint_count] = addr;
                o.breakpoint_count += 1;
            } else if (eql(a, "--reg")) {
                const eq_pos = std.mem.indexOfScalar(u8, v, '=') orelse return report(err, "--reg expects NAME=VALUE: {s}\n", .{v});
                const reg = parseRegName(v[0..eq_pos]) orelse return report(err, "unknown register in --reg: {s}\n", .{v[0..eq_pos]});
                const val = std.fmt.parseInt(u32, v[eq_pos + 1 ..], 0) catch return report(err, "invalid value in --reg: {s}\n", .{v[eq_pos + 1 ..]});
                if (o.reg_init_count >= 32) return report(err, "too many --reg options\n", .{});
                o.reg_inits[o.reg_init_count] = .{ .reg = reg, .val = val };
                o.reg_init_count += 1;
            } else {
                o.max_steps = std.fmt.parseInt(u64, v, 0) catch return report(err, "invalid --max-steps value: {s}\n", .{v});
            }
        } else if (a.len > 0 and a[0] == '-') {
            return report(err, "unknown option: {s}\n", .{a});
        } else if (o.path == null) {
            o.path = a;
        } else {
            return error.Usage;
        }
    }
    if (o.path == null) return error.Usage;
    return o;
}

fn report(err: *Writer, comptime fmt: []const u8, args: anytype) error{ Reported, WriteFailed } {
    try err.print("zircon: " ++ fmt, args);
    return error.Reported;
}

fn isSource(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".s") or std.mem.endsWith(u8, path, ".S");
}

/// Loads a raw image or assembles a source file. Returns the image bytes.
fn loadImage(io: Io, arena: std.mem.Allocator, opts: Options, err: *Writer) ![]u8 {
    const path = opts.path.?;
    const bytes = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(4 * 1024 * 1024)) catch |e|
        return report(err, "cannot read {s}: {s}\n", .{ path, @errorName(e) });
    const room = cpu.RAM_SIZE - opts.base;
    if (!isSource(path)) {
        if (bytes.len > room) return report(err, "{s}: image of {d} bytes does not fit at base 0x{x}\n", .{ path, bytes.len, opts.base });
        return bytes;
    }
    const image = try arena.alloc(u8, room);
    const assembler = try arena.create(asmz.Assembler);
    assembler.* = .{};
    const n = assembler.assemble(bytes, opts.base, image) catch {
        var buf: [160]u8 = undefined;
        return report(err, "{s}: {s}\n", .{ path, assembler.diagnostic(&buf) });
    };
    return image[0..n];
}

fn cmdAsm(io: Io, arena: std.mem.Allocator, opts: Options, out: *Writer, err: *Writer) !u8 {
    const dest = opts.out orelse return report(err, "asm needs -o <out.bin>\n", .{});
    if (!isSource(opts.path.?)) return report(err, "asm expects a .s source file\n", .{});
    const image = try loadImage(io, arena, opts, err);
    Io.Dir.cwd().writeFile(io, .{ .sub_path = dest, .data = image }) catch |e|
        return report(err, "cannot write {s}: {s}\n", .{ dest, @errorName(e) });
    if (opts.json) {
        try out.print("{{\"output\":{f},\"base\":{d},\"bytes\":{d}}}\n", .{ std.json.fmt(dest, .{}), opts.base, image.len });
    } else {
        try out.print("wrote {d} bytes to {s} (base 0x{x:0>8})\n", .{ image.len, dest, opts.base });
    }
    return 0;
}

fn cmdDisasm(io: Io, arena: std.mem.Allocator, opts: Options, out: *Writer, err: *Writer) !u8 {
    const image = try loadImage(io, arena, opts, err);
    var line: [disasm.max_line]u8 = undefined;
    var off: usize = 0;
    if (opts.json) try out.writeAll("[");
    while (off < image.len) {
        const addr: u32 = opts.base + @as(u32, @intCast(off));
        if (opts.json and off != 0) try out.writeAll(",");
        if (image.len - off < 4) {
            const b = image[off];
            if (opts.json) {
                try out.print("{{\"addr\":{d},\"byte\":{d},\"asm\":\".byte 0x{x:0>2}\"}}", .{ addr, b, b });
            } else {
                try out.print("{x:0>8}:  {x:0>2}        .byte 0x{x:0>2}\n", .{ addr, b, b });
            }
            off += 1;
            continue;
        }
        const w = std.mem.readInt(u32, image[off..][0..4], .little);
        const text = disasm.disassemble(w, addr, &line);
        if (opts.json) {
            try out.print("{{\"addr\":{d},\"word\":{d},\"asm\":\"{s}\"}}", .{ addr, w, text });
        } else {
            try out.print("{x:0>8}:  {x:0>8}  {s}\n", .{ addr, w, text });
        }
        off += 4;
    }
    if (opts.json) try out.writeAll("]\n");
    return 0;
}

fn cmdRun(io: Io, arena: std.mem.Allocator, opts: Options, out: *Writer, err: *Writer) !u8 {
    if (opts.json and opts.trace) return report(err, "--trace cannot be combined with --json\n", .{});
    const image = try loadImage(io, arena, opts, err);
    const c = try arena.create(cpu.CPU);
    c.reset();
    try c.loadProgram(image, opts.base);
    for (opts.reg_inits[0..opts.reg_init_count]) |ri| {
        c.writeReg(ri.reg, ri.val);
    }
    for (opts.breakpoints[0..opts.breakpoint_count]) |bp| {
        _ = c.addBreakpoint(bp);
    }

    var line: [disasm.max_line]u8 = undefined;
    var steps: u64 = 0;
    while (steps < opts.max_steps and !c.halted) : (steps += 1) {
        if (c.breakpoint_count > 0 and c.hasBreakpoint(c.pc)) {
            c.hit_breakpoint = true;
            break;
        }
        if (opts.trace and c.pc <= cpu.RAM_SIZE - 4 and c.pc & 3 == 0) {
            const w = std.mem.readInt(u32, c.ram[c.pc..][0..4], .little);
            try out.print("{x:0>8}:  {x:0>8}  {s}\n", .{ c.pc, w, disasm.disassemble(w, c.pc, &line) });
        }
        const ok = c.step() catch break;
        if (!ok) break;
    }

    const trap: cpu.Trap = @fromBackingInt(@intCast(c.trap_code));
    const status: []const u8 = if (c.hit_breakpoint) "breakpoint" else if (!c.halted) "step_limit" else if (trap.isFault()) "fault" else "halted";
    const code: u8 = if (c.hit_breakpoint) 4 else if (!c.halted) 3 else if (trap.isFault()) 1 else 0;
    const cpi: f64 = if (c.inst_count == 0) 0 else @as(f64, @floatFromInt(c.cycles)) / @as(f64, @floatFromInt(c.inst_count));
    const s = c.stats;

    if (opts.json) {
        try out.print("{{\"version\":\"{s}\",\"status\":\"{s}\",\"trap\":{{\"code\":{d},\"name\":\"{s}\",\"value\":{d}}},", .{
            cpu.version, status, c.trap_code, trap.name(), c.trap_value,
        });
        try out.print("\"pc\":{d},\"instret\":{d},\"cycles\":{d},\"cpi\":{d:.4},", .{ c.pc, c.inst_count, c.cycles, cpi });
        try out.print("\"stats\":{{\"load_use_stalls\":{d},\"flush_cycles\":{d},\"forwarded_operands\":{d},", .{
            s.load_use_stalls, s.flush_cycles, s.forwarded_operands,
        });
        try out.print("\"branches\":{d},\"branches_taken\":{d},\"jumps\":{d},\"loads\":{d},\"stores\":{d},\"muldiv\":{d}}},", .{
            s.branches, s.branches_taken, s.jumps, s.loads, s.stores, s.muldiv,
        });
        try out.writeAll("\"regs\":[");
        for (0..32) |i| {
            if (i != 0) try out.writeAll(",");
            try out.print("{d}", .{c.readReg(@intCast(i))});
        }
        try out.writeAll("]}\n");
        return code;
    }

    try out.print("status: {s} ({s}) at pc 0x{x:0>8}", .{ status, trap.name(), c.pc });
    if (c.halted) try out.print(", trap value 0x{x:0>8}", .{c.trap_value});
    try out.print("\ninstret: {d}  cycles: {d}  cpi: {d:.3}\n", .{ c.inst_count, c.cycles, cpi });
    try out.print("pipeline: load-use stalls {d}, flush cycles {d}, forwarded operands {d}\n", .{
        s.load_use_stalls, s.flush_cycles, s.forwarded_operands,
    });
    try out.print("events: branches {d} (taken {d}), jumps {d}, loads {d}, stores {d}, mul/div {d}\n", .{
        s.branches, s.branches_taken, s.jumps, s.loads, s.stores, s.muldiv,
    });
    try out.writeAll("registers (non-zero):\n");
    for (1..32) |i| {
        const v = c.readReg(@intCast(i));
        if (v == 0) continue;
        try out.print("  x{d:<2} {s:<4} = 0x{x:0>8}  {d}\n", .{ i, isa.abi_names[i], v, @as(i32, @bitCast(v)) });
    }
    return code;
}

fn demo(out: *Writer) !void {
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

    try out.writeAll("Zircon RV32I Execution Finished.\n");
    try out.print("PC: 0x{X:0>8}, Cycles: {}, x1: {}, x2: {}, x3: {}\n", .{
        c.pc,
        c.cycles,
        c.readReg(1),
        c.readReg(2),
        c.readReg(3),
    });
}

test {
    _ = isa;
    _ = disasm;
    _ = asmz;
    _ = @import("cpu_test.zig");
    _ = @import("wasm.zig");
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

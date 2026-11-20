// Smoke test for the freestanding WebAssembly artifact.
// Usage: node tests/wasm_smoke.mjs [path/to/zircon.wasm]
import { readFileSync } from "node:fs";
import assert from "node:assert/strict";

const path = process.argv[2] ?? "zig-out/bin/zircon.wasm";
const bytes = readFileSync(path);
const module = new WebAssembly.Module(bytes);

// The artifact must instantiate with an empty import object.
assert.deepEqual(WebAssembly.Module.imports(module), [], "module must not import anything");
const { exports: z } = new WebAssembly.Instance(module, { env: {} });

// 0.1.0 exports keep their names and parameter counts.
const v010 = {
  zircon_init: 0, zircon_reset: 0, zircon_load_byte: 2, zircon_step: 0, zircon_step_back: 0,
  zircon_get_pc: 0, zircon_set_pc: 1, zircon_get_reg: 1, zircon_get_cycles: 0,
  zircon_get_inst_count: 0, zircon_is_halted: 0, zircon_get_ram_ptr: 0, zircon_get_ram_size: 0,
};
const v020 = {
  zircon_get_version: 0, zircon_get_trap_code: 0, zircon_get_trap_value: 0, zircon_get_stat: 1,
  zircon_run: 1, zircon_get_text_ptr: 0, zircon_get_text_capacity: 0, zircon_disasm: 2,
  zircon_assemble: 2,
};
for (const [name, arity] of Object.entries({ ...v010, ...v020 })) {
  assert.equal(typeof z[name], "function", `missing export ${name}`);
  assert.equal(z[name].length, arity, `${name} arity`);
}
assert.ok(z.memory instanceof WebAssembly.Memory);
let checks = 0;
const ok = (cond, msg) => { assert.ok(cond, msg); checks++; };
const eq = (a, b, msg) => { assert.equal(a, b, msg); checks++; };

// Byte-level loading exactly as the 0.1.0 workbench does it.
z.zircon_init();
const memProgram = [
  0x93, 0x00, 0x00, 0x10, // addi x1, x0, 256
  0x13, 0x01, 0xa0, 0x02, // addi x2, x0, 42
  0x23, 0xa0, 0x20, 0x00, // sw   x2, 0(x1)
  0x83, 0xa1, 0x00, 0x00, // lw   x3, 0(x1)
  0x73, 0x00, 0x10, 0x00, // ebreak
];
z.zircon_reset();
memProgram.forEach((b, i) => eq(z.zircon_load_byte(i, b), 0, "load_byte"));
eq(z.zircon_load_byte(z.zircon_get_ram_size(), 0), -1, "load_byte out of range");
while (!z.zircon_is_halted()) eq(z.zircon_step(), 1, "step");
eq(z.zircon_get_reg(3), 42, "lw result");
eq(z.zircon_get_inst_count(), 5, "instret");
eq(z.zircon_get_trap_code(), 0x74, "ebreak trap");
const ram = () => new Uint8Array(z.memory.buffer, z.zircon_get_ram_ptr(), z.zircon_get_ram_size());
eq(ram()[256], 42, "stored byte");
// Step back past the store: memory is restored too.
eq(z.zircon_step_back(), 1, "undo ebreak");
eq(z.zircon_step_back(), 1, "undo lw");
eq(z.zircon_step_back(), 1, "undo sw");
eq(ram()[256], 0, "store undone");
eq(z.zircon_get_reg(2), 42, "x2 kept");

// Assembler, run loop and statistics.
const enc = new TextEncoder();
const putText = (s) => {
  const b = enc.encode(s);
  new Uint8Array(z.memory.buffer, z.zircon_get_text_ptr(), z.zircon_get_text_capacity()).set(b);
  return b.length;
};
const getText = (n) => new TextDecoder().decode(new Uint8Array(z.memory.buffer, z.zircon_get_text_ptr(), n));
z.zircon_reset();
const src = `
        li   a0, 10          # fib(10)
        li   t0, 0
        li   t1, 1
loop:   beqz a0, done
        add  t2, t0, t1
        mv   t0, t1
        mv   t1, t2
        addi a0, a0, -1
        j    loop
done:   mul  a1, t0, t0
        ecall
`;
const size = z.zircon_assemble(putText(src), 0x100);
eq(size, 44, "assembled size");
eq(z.zircon_get_pc(), 0x100, "pc set to base");
const retired = z.zircon_run(10000);
eq(z.zircon_get_trap_code(), 0x73, "ecall");
eq(z.zircon_get_reg(5), 55, "fib(10)");
eq(z.zircon_get_reg(11), 3025, "mul");
eq(retired, z.zircon_get_inst_count(), "run return value");
const stat = (id) => z.zircon_get_stat(id);
eq(stat(8), 1, "one mul");
eq(retired, 66, "retired count");
eq(stat(4), 1, "one taken branch");
eq(stat(5), 10, "ten jumps");
eq(stat(1), 12, "flush cycles: 1 taken branch x 2 + 10 jal x 1");
eq(z.zircon_get_cycles(), retired + stat(0) + stat(1), "cycle identity");
eq(stat(11), retired, "history depth");

// Disassembler.
eq(getText(z.zircon_disasm(0x002081b3, 0)), "add x3, x1, x2", "disasm");
eq(getText(z.zircon_disasm(0xfe000ee3, 0x40)), "beq x0, x0, 0x3c", "disasm branch");

// Diagnostics leave RAM alone.
const before = ram()[0x100];
const r = z.zircon_assemble(putText("nop\nlw x1, 0(x99)\n"), 0x100);
ok(r < 0, "assembler error");
eq(getText(-r), "line 2: expected a register", "diagnostic");
eq(ram()[0x100], before, "ram untouched");

// Faults halt instead of spinning.
z.zircon_reset();
eq(z.zircon_step(), -1, "illegal all-zero word");
eq(z.zircon_is_halted(), 1, "halted on fault");
eq(z.zircon_get_trap_code(), 2, "illegal instruction trap");
eq(z.zircon_step(), 0, "stays halted");

eq(z.zircon_get_version(), 0x000200, "version");
console.log(`wasm smoke test: ${checks} checks passed (${bytes.length} bytes, ${Object.keys(v010).length + Object.keys(v020).length} exports)`);

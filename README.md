# Zircon

Freestanding RISC-V (RV32IM) Micro-Emulator & Stepper

A bare-metal RV32IM user-mode instruction emulator and bidirectional pipeline stepper compiled directly to a compact (about 25 KB) freestanding WebAssembly artifact with zero imports (`wasm32-freestanding`, `ReleaseSmall`). It powers the workbench at [aetherx86.github.io/zircon](https://aetherx86.github.io/zircon/).

## Architecture

- Zero Libc Imports: Runs in freestanding linear memory with zero external runtime dependencies; the module instantiates with an empty import object.
- Unified Memory Layout: Linear memory doubles as RAM (64 KiB), register file (x0 through x31, PC), and execution state.
- Bidirectional Stepper: A 256-entry snapshot ring buffer records registers, PC, counters, pipeline state and the bytes overwritten by each store, so stepping backward restores memory as well as registers.
- Shared Instruction Table: `src/isa.zig` classifies and encodes every RV32IM, Zicsr and Zifencei instruction; the emulator, disassembler and assembler all use it, so they agree on which bit patterns are legal.
- Pipeline Timing Model: Cycle counts come from a five-stage in-order pipeline model with hazard and forwarding statistics (see below).
- Fixed-Size Allocations: The emulator, assembler (1024-label table) and disassembler operate within fixed buffers and never allocate.

## Exported WebAssembly API

```c
// 0.1.0 (unchanged names and signatures)
void zircon_init(void);
void zircon_reset(void);
int32_t zircon_load_byte(uint32_t offset, uint8_t byte);
int32_t zircon_step(void);          // 1 retired, 0 halted, -1 fault
int32_t zircon_step_back(void);
uint32_t zircon_get_pc(void);
void zircon_set_pc(uint32_t new_pc);
uint32_t zircon_get_reg(uint32_t idx);
uint32_t zircon_get_cycles(void);
uint32_t zircon_get_inst_count(void);
int32_t zircon_is_halted(void);
uint8_t* zircon_get_ram_ptr(void);
uint32_t zircon_get_ram_size(void);

// 0.2.0
uint32_t zircon_get_version(void);       // major << 16 | minor << 8 | patch
uint32_t zircon_get_trap_code(void);
uint32_t zircon_get_trap_value(void);    // faulting address / instruction word, or ecall/ebreak pc
uint32_t zircon_get_stat(uint32_t id);   // low 32 bits, ids listed below; unknown ids return 0
uint32_t zircon_run(uint32_t max_steps); // instructions retired before halt, fault or limit
uint8_t* zircon_get_text_ptr(void);      // 16 KiB shared text buffer
uint32_t zircon_get_text_capacity(void);
uint32_t zircon_disasm(uint32_t word, uint32_t pc);        // writes one line to the text buffer, returns its length
int32_t zircon_assemble(uint32_t src_len, uint32_t base);  // see below
```

`zircon_assemble` reads `src_len` bytes of assembly from the text buffer and writes the image into RAM at `base`. On success it returns the image size, sets the PC to `base`, clears any halt state and empties the step-back history. On failure it returns the negated length of a `line N: message` diagnostic that it places in the text buffer, and RAM is left untouched.

Trap codes: `0` none, `1` PC out of bounds, `2` illegal instruction, `3` load/store access fault, `4` misaligned instruction fetch (including jumps and taken branches to non-4-byte-aligned targets), `0x73` ecall, `0x74` ebreak.

Statistic ids for `zircon_get_stat`: `0` load-use stalls, `1` flush cycles, `2` forwarded operands, `3` branches, `4` taken branches, `5` jumps, `6` loads, `7` stores, `8` mul/div operations, `9` cycles (high 32 bits), `10` instructions retired (high 32 bits), `11` step-back history depth.

## Building and Testing

```bash
# Unit, property and differential tests
zig build test

# Native CLI (zig-out/bin/zircon) and the WebAssembly artifact (zig-out/bin/zircon.wasm)
zig build -Doptimize=ReleaseSmall

# Instantiate the built .wasm under Node.js and exercise every export
zig build wasm-smoke
```

The WebAssembly module is always compiled with `ReleaseSmall`, whatever `-Doptimize` says. A prebuilt copy is kept at the repository root as `zircon.wasm`.

## What is new in 0.2.0

### RV32M, counters, fences and precise traps

The core now implements the RV32M multiply/divide extension with the specification's division-by-zero and overflow results, the read-only Zicntr counters (`cycle`, `time`, `instret` and their `h` halves, where `time` mirrors `cycle`), and `fence`, `fence.tso` and `fence.i` as no-ops. Reserved encodings (for example `slli` with a non-zero `funct7`, `jalr` with `funct3 != 0`, or `mret`) are rejected as illegal instead of silently executing. A fault halts the machine with a trap code and value and leaves registers, memory and the PC untouched; `zircon_step_back` on a faulted machine just clears the fault. Bounds checks no longer overflow on addresses near 4 GiB, and the last word of RAM is now executable.

### Pipeline timing model and hazard statistics

`cycles` follows a classic five-stage in-order pipeline (IF, ID, EX, MEM, WB) with full forwarding into EX, a one-cycle load-use interlock (also for store data), static not-taken prediction, branches and `jalr` resolved in EX (2 flush cycles when they redirect) and `jal` resolved in ID (1 flush cycle). The 4-cycle fill latency is not counted, so `cycles = instret + load-use stalls + flush cycles` always holds. All counters are part of each snapshot, so stepping back rewinds them too.

### Assembler and disassembler

A three-pass assembler supports labels, ABI register names, `#`, `;` and `//` comments, `.word`, `.half`, `.byte`, `.space`, `.align` and `.balign`, and the pseudo-instructions `nop`, `li`, `la`, `mv`, `not`, `neg`, `seqz`, `snez`, `sltz`, `sgtz`, `beqz`, `bnez`, `blez`, `bgez`, `bltz`, `bgtz`, `bgt`, `ble`, `bgtu`, `bleu`, `j`, `jr`, `ret`, `call`, `tail`, `rdcycle[h]`, `rdtime[h]`, `rdinstret[h]`, `csrr` and `csrw`. The disassembler prints canonical forms with absolute branch targets and `.word` for anything illegal; a property test checks that 200,000 sampled words survive the disassemble-assemble round trip bit for bit.

### Command-line interface

```text
zircon                                  run the built-in demo program
zircon run <file> [--base ADDR] [--max-steps N] [--json] [--trace]
zircon asm <file.s> -o <out.bin> [--base ADDR]
zircon disasm <file> [--base ADDR] [--json]
zircon version
```

Files ending in `.s` are assembled first; anything else is loaded as a raw little-endian image. `run` exits with 0 when the program stops on `ecall`/`ebreak`, 1 on a fault and 3 when the step limit is reached; usage, input and assembly errors exit with 2.

```console
$ zig build -Doptimize=ReleaseSmall
$ ./zig-out/bin/zircon run examples/sort.s
status: halted (ecall) at pc 0x00000070, trap value 0x0000006c
instret: 606  cycles: 889  cpi: 1.467
pipeline: load-use stalls 78, flush cycles 205, forwarded operands 193
events: branches 156 (taken 97), jumps 11, loads 144, stores 72, mul/div 12
registers (non-zero):
  x5  t0   = 0x000000a0  160
  x7  t2   = 0x0000012c  300
  x8  s0   = 0x00000070  112
  x10 a0   = 0x0000005d  93
  x11 a1   = 0x00000377  887
  x28 t3   = 0xffffff9c  -100
  x29 t4   = 0x00000003  3

$ ./zig-out/bin/zircon asm examples/sort.s -o sort.bin
wrote 160 bytes to sort.bin (base 0x00000000)

$ ./zig-out/bin/zircon disasm sort.bin | head -5
00000000:  00000417  auipc x8, 0x0
00000004:  07040413  addi x8, x8, 112
00000008:  00c00493  addi x9, x0, 12
0000000c:  fff48493  addi x9, x9, -1
00000010:  02905863  bge x0, x9, 0x40

$ ./zig-out/bin/zircon run sort.bin --json
{"version":"0.2.0","status":"halted","trap":{"code":115,"name":"ecall","value":108},"pc":112,"instret":606,"cycles":889,"cpi":1.4670,"stats":{"load_use_stalls":78,"flush_cycles":205,"forwarded_operands":193,"branches":156,"branches_taken":97,"jumps":11,"loads":144,"stores":72,"muldiv":12},"regs":[0,0,0,0,0,160,0,300,112,0,93,887,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,4294967196,3,0,0]}
```

`--trace` prints each instruction before it executes; `disasm --json` emits an array of `{"addr","word","asm"}` objects.

## License

MIT License - Copyright (c) 2026 Jeong Hoon Kim

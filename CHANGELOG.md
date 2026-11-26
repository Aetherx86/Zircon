# Changelog

All notable changes to this project will be documented in this file.

## [0.3.0] - 2026-11-27

### Added
- PC hardware breakpoint table (up to 16 breakpoints) in `CPU` (`addBreakpoint`, `removeBreakpoint`, `clearBreakpoints`, `hasBreakpoint`, `hit_breakpoint`) integrated into `CPU.run()`.
- CLI debugging options on `zircon run`: `--break ADDR` (repeatable, exits with status `4` / `"status":"breakpoint"`) and `--reg NAME=VALUE` (supports `x0..x31` and RISC-V ABI register names such as `a0`, `t0`, `sp`, `ra`).
- Five new freestanding WebAssembly exports (`zircon_set_reg`, `zircon_add_breakpoint`, `zircon_remove_breakpoint`, `zircon_clear_breakpoints`, `zircon_hit_breakpoint`) while preserving 100% ABI compatibility with all 22 v0.1.0/v0.2.0 exports.

## [0.2.0] - 2026-11-20

### Added
- RV32M multiply/divide extension (MUL, MULH, MULHSU, MULHU, DIV, DIVU, REM, REMU) with the specification's division-by-zero and signed-overflow results, checked by a differential test against 128-bit reference arithmetic.
- Read-only Zicntr counters (cycle, time, instret and their high halves) through CSRRS/CSRRC/CSRRSI/CSRRCI; FENCE, FENCE.TSO and FENCE.I retire as no-ops.
- Five-stage in-order pipeline timing model: load-use interlock, branch/JALR flushes (2 cycles) and JAL flushes (1 cycle), with counters for stalls, flush cycles, forwarded operands, branches, jumps, loads, stores and mul/div operations.
- Shared instruction table (`src/isa.zig`) used by the emulator, a new allocation-free disassembler and a new three-pass assembler with labels, data directives and common pseudo-instructions.
- Command-line interface: `zircon run` (with `--json`, `--trace`, `--max-steps`, `--base`), `zircon asm`, `zircon disasm` (with `--json`) and `zircon version`.
- WebAssembly exports: `zircon_get_version`, `zircon_get_trap_code`, `zircon_get_trap_value`, `zircon_get_stat`, `zircon_run`, `zircon_get_text_ptr`, `zircon_get_text_capacity`, `zircon_disasm`, `zircon_assemble`. All 0.1.0 exports keep their names and signatures.
- `zig build wasm-smoke`, a Node.js test that instantiates the built module with an empty import object and exercises every export; it also runs in CI.
- `examples/sort.s`.

### Changed
- Stepping backward now restores the bytes overwritten by a store, plus the pipeline state and statistics, instead of only registers and the PC.
- `cycles` now counts pipeline cycles (instructions retired plus stall and flush cycles) rather than equalling the instruction count.
- Faults (illegal instruction, access fault, misaligned fetch) halt the machine with a trap code and value and leave all architectural state untouched; previously `zircon_step` returned -1 without halting, so a run loop could spin forever. Stepping back from a fault clears it.
- Reserved encodings that 0.1.0 executed as something else (for example SLLI with a non-zero funct7, JALR with funct3 != 0, unknown SYSTEM instructions) now raise an illegal-instruction trap; jumps and taken branches to targets that are not 4-byte aligned raise a misaligned-fetch trap.
- The demo output of `zircon` with no arguments now goes to standard output.
- The WebAssembly artifact grows from 3.1 KB to about 25 KB.

### Fixed
- Memory bounds checks could overflow for addresses near 4 GiB on 32-bit targets such as wasm32, letting a hostile program read or write outside the emulated RAM.
- The last word of RAM (address 0xFFFC) could not be executed.
- Calling `zircon_reset` or `zircon_load_byte` before `zircon_init` let the first `zircon_step` wipe the loaded program.

## 0.1.0 - 2026-11-08

### Added
- Initial release of Zircon freestanding RISC-V (RV32I) micro-emulator and pipeline stepper.
- Freestanding WebAssembly compilation target yielding a 3.1 KB binary without libc imports.
- Reversible execution snapshot ring buffer supporting bidirectional scrubbing.
- Full base integer instruction set (R, I, S, B, U, J types and ECALL/EBREAK traps).

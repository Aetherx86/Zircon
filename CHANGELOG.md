# Changelog

All notable changes to this project will be documented in this file.

## 0.1.0 - 2026-11-08

### Added
- Initial release of Zircon freestanding RISC-V (RV32I) micro-emulator and pipeline stepper.
- Freestanding WebAssembly compilation target yielding a 3.1 KB binary without libc imports.
- Reversible execution snapshot ring buffer supporting bidirectional scrubbing.
- Full base integer instruction set (R, I, S, B, U, J types and ECALL/EBREAK traps).

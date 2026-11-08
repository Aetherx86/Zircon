# Zircon

Freestanding RISC-V (RV32I) Micro-Emulator & Stepper

A bare-metal, cycle-accurate RV32I user-mode instruction emulator and pipeline stepper compiled directly to a compact (under 4 KB) freestanding WebAssembly artifact (`-target wasm32-freestanding -O ReleaseSmall`).

## Architecture

- Zero Libc Imports: Runs in freestanding linear memory with zero external runtime dependencies.
- Unified Memory Layout: Linear memory doubles as RAM (64 KiB), register file (x0 through x31, PC), and execution state.
- Bidirectional Stepper: Circular snapshot ring buffer maintains cycle-accurate execution states for instant forward and backward scrubbing.
- Comptime Instruction Decoder: Opcode formats and jump fields are decoded directly into a static lookup matrix during compilation.
- Fixed-Size Allocations: Operates within fixed buffers, guaranteeing zero out-of-memory faults during active execution.

## Exported WebAssembly API

```c
void zircon_init(void);
void zircon_reset(void);
int32_t zircon_load_byte(uint32_t offset, uint8_t byte);
int32_t zircon_step(void);
int32_t zircon_step_back(void);
uint32_t zircon_get_pc(void);
void zircon_set_pc(uint32_t new_pc);
uint32_t zircon_get_reg(uint32_t idx);
uint32_t zircon_get_cycles(void);
uint32_t zircon_get_inst_count(void);
int32_t zircon_is_halted(void);
uint8_t* zircon_get_ram_ptr(void);
uint32_t zircon_get_ram_size(void);
```

## Building and Testing

```bash
# Run unit tests
zig build test

# Compile freestanding WebAssembly artifact
zig build -Doptimize=ReleaseSmall
```

## License

MIT License - Copyright (c) 2026 Jeong Hoon Kim

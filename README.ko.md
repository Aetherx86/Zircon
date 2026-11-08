# Zircon (자립형 RISC-V RV32I 마이크로 에뮬레이터 & 양방향 파이프라인 스텝퍼)

[English](README.md) · [라이선스](LICENSE) · [라이브 워크벤치](https://aetherx86.github.io/zircon/)

Zircon은 libc 임포트가 일체 없는 베어메탈 RISC-V (RV32I) 유저 모드 명령어 에뮬레이터이자 양방향 파이프라인 스텝퍼입니다. 컴팩트한(4 KB 미만, 3.1 KB) 단일 자립형 WebAssembly 아티팩트(`-target wasm32-freestanding -O ReleaseSmall`)로 직접 컴파일됩니다.

## 아키텍처 개요

- **Libc 제로 임포트**: 외부 런타임 종속성 없이 자립형 선형 메모리 내에서 100% 독립 실행됩니다.
- **통합 메모리 레이아웃**: 단일 선형 메모리가 RAM (64 KiB), 32개 범용 레지스터 파일(x0~x31, PC) 및 실행 상태 머신 역할을 겸합니다.
- **양방향 스텝퍼 (Time-Travel Debugging)**: 원형 스냅샷 링 버퍼를 통해 사이클 단위의 이전 실행 상태를 보존하여, 즉각적인 앞뒤 스크러빙 및 디버깅을 지원합니다.
- **Comptime 명령어 디코더**: 옵코드 포맷과 점프 분기 필드가 Zig 컴파일 타임에 정적 룩업 매트릭스로 즉시 디코딩됩니다.
- **고정 크기 메모리 보장**: 사전 할당된 정적 버퍼 내에서만 동작하여 실행 중 OOM(Out of Memory) 결함이 발생하지 않습니다.

## WebAssembly C-ABI 인터페이스

```c
void zircon_init(void);
void zircon_reset(void);
int32_t zircon_load_byte(uint32_t offset, uint8_t byte);
int32_t zircon_step(void);
int32_t zircon_step_back(void);
uint32_t zircon_get_pc(void);
void zircon_set_pc(uint32_t new_pc);
uint32_t zircon_get_reg(uint32_t idx);
```

## 빌드 및 검증

Zig 0.13.0 이상이 필요합니다:

```bash
# 단위 테스트 실행
zig build test

# 자립형 WebAssembly 바이너리 빌드 (3.1 KB)
zig build -Doptimize=ReleaseSmall -Dtarget=wasm32-freestanding
```

## 라이선스

MIT License. Copyright (c) 2026 Jeong Hoon Kim (Aether Systems & Research Lab).

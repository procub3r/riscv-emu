# riscv-emu

A RISC-V emulator written in Zig.

## Dependencies

For testing

- Get `riscv64-*` (whichever one you prefer) from [riscv-gnu-toolchain releases](https://github.com/riscv-collab/riscv-gnu-toolchain/releases) (most recent release should be fine).
- Add the `bin/` folder from the extracted archive to PATH.

## Build

Clone with `--recurse-submodules` to pull [riscv-tests](https://github.com/riscv-software-src/riscv-tests/) for testing.

```bash
zig build test  # Test the emulator
zig build run   # Tells you to run `zig build test` :D
```

## TODO

- [x] Make a test execution environment
- [ ] Implement RV32I spec fully

#!/usr/bin/env python3
"""Run ROM images on an emulated NMOS 6502 with this board's memory map.

    $0000-$7FFF  SRAM (32 KiB)
    $8000-$BFFF  latch U5 (write-only, low 4 bits; reads float -> $FF)
    $C000-$FFFF  28C64 (8 KiB, mirrored twice; writes ignored)

    uv run python tools/sim.py          run all checks (also: make test)
"""
import sys
from pathlib import Path

from py65.devices.mpu6502 import MPU

BUILD = Path(__file__).resolve().parent.parent / "build"
CLOCK_HZ = 625_000


class Board:
    """Address decoding as wired; optional fault injection on RAM address lines."""

    def __init__(self, rom: bytes, ram_stuck_low_bits: int = 0):
        assert len(rom) == 0x2000
        self.rom = rom
        self.ram = bytearray(0x8000)
        self.ram_mask = 0x7FFF & ~ram_stuck_low_bits
        self.latch_writes: list[tuple[int, int]] = []  # (cycle, value)
        self.mpu: MPU | None = None

    def __getitem__(self, addr: int) -> int:
        if addr < 0x8000:
            return self.ram[addr & self.ram_mask]
        if addr < 0xC000:
            return 0xFF
        return self.rom[addr & 0x1FFF]

    def __setitem__(self, addr: int, value: int) -> None:
        if addr < 0x8000:
            self.ram[addr & self.ram_mask] = value & 0xFF
        elif addr < 0xC000:
            cycle = self.mpu.processorCycles if self.mpu else 0
            self.latch_writes.append((cycle, value & 0x0F))


def run(image: str, seconds: float, **faults) -> Board:
    board = Board((BUILD / image).read_bytes(), **faults)
    mpu = MPU(memory=board)
    board.mpu = mpu
    mpu.pc = board[0xFFFC] | (board[0xFFFD] << 8)
    limit = int(seconds * CLOCK_HZ)
    while mpu.processorCycles < limit:
        mpu.step()
    return board


def values(board: Board) -> list[int]:
    return [v for _c, v in board.latch_writes]


def check(name: str, ok: bool, detail: str) -> bool:
    print(f"  [{'PASS' if ok else 'FAIL'}] {name}: {detail}")
    return ok


def main() -> int:
    results = []

    b = run("blink.bin", 3)
    v = values(b)
    results.append(check("blink", v[:4] == [0x0F, 0x00, 0x0F, 0x00],
                         f"latch {['%X' % x for x in v[:6]]}"))

    b = run("count.bin", 3)
    v = values(b)
    results.append(check("count", v[:8] == list(range(8)),
                         f"latch {['%X' % x for x in v[:10]]}"))

    b = run("ramtest.bin", 8)
    v = values(b)
    first_ok = next((c for c, x in b.latch_writes if x == 0x0E), None)
    results.append(check("ramtest (good RAM)", v[:5] == [0x0F, 0x0E, 0x0D, 0x0B, 0x07],
                         f"latch {['%X' % x for x in v[:8]]}, PASS shown after "
                         f"{first_ok / CLOCK_HZ:.1f} s" if first_ok else f"latch {v[:8]}"))

    for bit in range(15):
        b = run("ramtest.bin", 8, ram_stuck_low_bits=1 << bit)
        v = values(b)
        ok = v == [0x0F, 0x0C]
        results.append(check(f"ramtest (A{bit} stuck low)", ok,
                             f"latch {['%X' % x for x in v[:4]]} -> "
                             f"{'address fault shown (QA+QB)' if ok else 'NOT reported correctly'}"))

    print(f"{sum(results)}/{len(results)} checks passed")
    return 0 if all(results) else 1


if __name__ == "__main__":
    sys.exit(main())

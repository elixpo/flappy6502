"""Shared helpers for hand-assembled 28C64 test images.

A program is a list of (address, bytes, source) rows. Image offset 0 = CPU $E000.
"""
from pathlib import Path

ROM_BASE = 0xE000
ROM_SIZE = 0x2000
BRANCHES = {0x10, 0x30, 0x50, 0x70, 0x90, 0xB0, 0xD0, 0xF0}


def labels(program) -> dict:
    return {src.split(":")[0]: addr for addr, _d, src in program if ":" in src.split(";")[0]}


def check(program) -> None:
    """Rows must be contiguous and every branch must land on its named label."""
    names = labels(program)
    expected = program[0][0]
    for addr, data, src in program:
        assert addr == expected, f"gap/overlap at ${addr:04X} (expected ${expected:04X})"
        expected = addr + len(data)
        if data[0] in BRANCHES:
            target = addr + 2 + (data[1] - 256 if data[1] > 127 else data[1])
            label = src.split(";")[0].split()[-1]
            assert names[label] == target, f"bad branch at ${addr:04X}"


def build(program, vectors) -> bytes:
    check(program)
    rom = bytearray([0xFF] * ROM_SIZE)
    for addr, data, _src in program:
        rom[addr - ROM_BASE:addr - ROM_BASE + len(data)] = data
    for addr, target in vectors.items():
        rom[addr - ROM_BASE] = target & 0xFF
        rom[addr - ROM_BASE + 1] = target >> 8
    return bytes(rom)


def write(name: str, program, vectors) -> None:
    image = build(program, vectors)
    out = Path(__file__).resolve().parent.parent / "build" / f"{name}.bin"
    out.parent.mkdir(exist_ok=True)
    out.write_bytes(image)
    last_addr, last_data, _ = program[-1]
    print(f"wrote {out} ({len(image)} bytes, program {last_addr + len(last_data) - ROM_BASE} bytes)")
    for addr, data, src in program:
        print(f"  ${addr:04X}  {' '.join(f'{b:02X}' for b in data):<9} {src}")
    print("  vectors: " + ", ".join(f"${a:04X}->${t:04X}" for a, t in vectors.items()))

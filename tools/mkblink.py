#!/usr/bin/env python3
"""Build the stage-2 ROM test image (blink the LCD latch) for the 28C64.

No assembler is needed: the program is hand-assembled below. Output is a full
8192-byte image for the Nano28C64 programmer. Image offset 0 = CPU $E000.

    python3 tools/mkblink.py            -> build/blink.bin
"""
from pathlib import Path

ROM_BASE = 0xE000
ROM_SIZE = 0x2000

# addr   bytes        source
PROGRAM = [
    (0xE000, [0x78],             "reset:  sei"),
    (0xE001, [0xD8],             "        cld"),
    (0xE002, [0xA2, 0xFF],       "        ldx #$FF"),
    (0xE004, [0x9A],             "        txs"),
    (0xE005, [0xA9, 0x0F],       "loop:   lda #$0F        ; latch QA-QD high (LED off)"),
    (0xE007, [0x8D, 0x00, 0x80], "        sta $8000"),
    (0xE00A, [0xA0, 0x00],       "        ldy #0"),
    (0xE00C, [0xA2, 0x00],       "        ldx #0"),
    (0xE00E, [0xCA],             "d1:     dex"),
    (0xE00F, [0xD0, 0xFD],       "        bne d1"),
    (0xE011, [0x88],             "        dey"),
    (0xE012, [0xD0, 0xFA],       "        bne d1          ; ~329k cycles = ~0.53 s at 625 kHz"),
    (0xE014, [0xA9, 0x00],       "        lda #$00        ; latch QA-QD low (LED on)"),
    (0xE016, [0x8D, 0x00, 0x80], "        sta $8000"),
    (0xE019, [0xA0, 0x00],       "        ldy #0"),
    (0xE01B, [0xA2, 0x00],       "        ldx #0"),
    (0xE01D, [0xCA],             "d2:     dex"),
    (0xE01E, [0xD0, 0xFD],       "        bne d2"),
    (0xE020, [0x88],             "        dey"),
    (0xE021, [0xD0, 0xFA],       "        bne d2"),
    (0xE023, [0x4C, 0x05, 0xE0], "        jmp loop"),
    (0xE026, [0x40],             "stub:   rti             ; NMI / IRQ go here"),
]

VECTORS = {
    0xFFFA: 0xE026,  # NMI
    0xFFFC: 0xE000,  # RESET
    0xFFFE: 0xE026,  # IRQ/BRK
}


def build() -> bytes:
    rom = bytearray([0xFF] * ROM_SIZE)
    expected = ROM_BASE
    for addr, data, _src in PROGRAM:
        assert addr == expected, f"gap/overlap at ${addr:04X} (expected ${expected:04X})"
        rom[addr - ROM_BASE:addr - ROM_BASE + len(data)] = data
        expected = addr + len(data)
    for addr, target in VECTORS.items():
        rom[addr - ROM_BASE] = target & 0xFF
        rom[addr - ROM_BASE + 1] = target >> 8
    return bytes(rom)


def check_branches() -> None:
    """Verify every relative branch lands on the intended label."""
    labels = {src.split(":")[0]: addr for addr, _d, src in PROGRAM if ":" in src.split(";")[0]}
    for addr, data, src in PROGRAM:
        if data[0] == 0xD0:  # BNE
            target = addr + 2 + (data[1] - 256 if data[1] > 127 else data[1])
            label = src.split()[-1] if ";" not in src else src.split(";")[0].split()[-1]
            assert labels[label] == target, f"bad branch at ${addr:04X}"


if __name__ == "__main__":
    check_branches()
    image = build()
    out = Path(__file__).resolve().parent.parent / "build" / "blink.bin"
    out.parent.mkdir(exist_ok=True)
    out.write_bytes(image)
    print(f"wrote {out} ({len(image)} bytes, program {PROGRAM[-1][0] + 1 - ROM_BASE} bytes)")
    for addr, data, src in PROGRAM:
        print(f"  ${addr:04X}  {' '.join(f'{b:02X}' for b in data):<9} {src}")
    print("  vectors: " + ", ".join(f"${a:04X}->${t:04X}" for a, t in VECTORS.items()))

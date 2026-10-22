#!/usr/bin/env python3
"""Stage-2 ROM test #2: 4-bit binary counter on the LCD latch.

The counter lives in A (no RAM yet) and is written to $8000 every ~0.26 s.
With the LED wired +5V -> 470R -> LED -> Qx, the LED is ON when that bit is 0.

    QA (U5 14) toggles every ~0.26 s   (fast)
    QB (U5 13) toggles every ~0.53 s
    QC (U5 12) toggles every ~1.05 s
    QD (U5 11) toggles every ~2.1 s    (slow)

Move the LED between the four pins (or fit four LEDs) to check D0-D3 each.

    python3 tools/mkcount.py            -> build/count.bin
"""
from rom import write

PROGRAM = [
    (0xE000, [0x78],             "reset:  sei"),
    (0xE001, [0xD8],             "        cld"),
    (0xE002, [0xA2, 0xFF],       "        ldx #$FF"),
    (0xE004, [0x9A],             "        txs"),
    (0xE005, [0xA9, 0x00],       "        lda #0          ; A = counter"),
    (0xE007, [0x8D, 0x00, 0x80], "loop:   sta $8000       ; QA-QD = low 4 bits of A"),
    (0xE00A, [0xA0, 0x80],       "        ldy #$80"),
    (0xE00C, [0xA2, 0x00],       "        ldx #0"),
    (0xE00E, [0xCA],             "d1:     dex"),
    (0xE00F, [0xD0, 0xFD],       "        bne d1"),
    (0xE011, [0x88],             "        dey"),
    (0xE012, [0xD0, 0xFA],       "        bne d1          ; ~164k cycles = ~0.26 s at 625 kHz"),
    (0xE014, [0x18],             "        clc"),
    (0xE015, [0x69, 0x01],       "        adc #1          ; next count"),
    (0xE017, [0x4C, 0x07, 0xE0], "        jmp loop"),
    (0xE01A, [0x40],             "stub:   rti             ; NMI / IRQ go here"),
]

VECTORS = {
    0xFFFA: 0xE01A,  # NMI
    0xFFFC: 0xE000,  # RESET
    0xFFFE: 0xE01A,  # IRQ/BRK
}

if __name__ == "__main__":
    write("count", PROGRAM, VECTORS)

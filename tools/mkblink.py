#!/usr/bin/env python3
"""Stage-2 ROM test: blink the LCD latch (all 4 outputs together, ~0.5 s on/off).

    python3 tools/mkblink.py            -> build/blink.bin   (CRC-16 B37E)
"""
from rom import write

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

if __name__ == "__main__":
    write("blink", PROGRAM, VECTORS)

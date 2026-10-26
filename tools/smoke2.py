#!/usr/bin/env python3
"""Quick smoke test of build/flappy.bin on the stage-7 (auto-clock SPI) wiring.

Writes to $A000-$BFFF clock the panel with the latch value from the PREVIOUS write,
then load the latch. Renders the screen with the 20 px fixed HUD and measures frames/s.

    uv run python tools/smoke2.py        -> build/v2_*.png
    uv run python tools/smoke2.py bb     bit-bang build (flappy_bb.bin, SCL = latch bit 1)
"""
import sys

from py65.devices.mpu6502 import MPU

from png import write_png
from sim import BUILD, check
from simgame import LiveLcd

CLOCK, TFA, RING = 1_250_000, 20, 300
BB = len(sys.argv) > 1 and sys.argv[1] == "bb"


class Board2:
    def __init__(self, rom):
        self.rom, self.ram, self.latch = rom, bytearray(0x8000), 0
        self.lcd = LiveLcd()
        self.bits = self.n = 0
        self.mpu = None

    def __getitem__(self, a):
        if a < 0x8000:
            return self.ram[a]
        return 0xFF if a < 0xC000 else self.rom[a & 0x1FFF]

    def __setitem__(self, a, v):
        if a < 0x8000:
            self.ram[a] = v & 0xFF
            return
        if a >= 0xC000:
            return
        if BB:                                # SCL = latch bit 1, sampled on its rising edge
            v &= 0x0F
            if v & 0x08:
                self.n = 0
            elif v & 0x02 and not self.latch & 0x02:
                self.bits = (self.bits << 1) | (v & 1)
                self.n += 1
                if self.n == 8:
                    self.lcd.feed(self.mpu.processorCycles, (v >> 2) & 1, self.bits & 0xFF)
                    self.n = 0
            self.latch = v
            return
        if a >= 0xA000:                       # SCL pulse samples the old latch value
            old = self.latch
            if old & 0x08:
                self.n = 0
            else:
                self.bits = (self.bits << 1) | (old & 1)
                self.n += 1
                if self.n == 8:
                    self.lcd.feed(self.mpu.processorCycles, (old >> 2) & 1, self.bits & 0xFF)
                    self.n = 0
        self.latch = v & 0x0F


def screen(lcd):
    off = (lcd.vsp - TFA) % RING
    return [[row[x] if x < TFA else row[TFA + (x - TFA + off) % RING] for x in range(320)]
            for row in lcd.fb]


def main():
    b = Board2((BUILD / ("flappy_bb.bin" if BB else "flappy.bin")).read_bytes())
    mpu = MPU(memory=b)
    b.mpu = mpu
    mpu.pc = b[0xFFFC] | b[0xFFFD] << 8

    def run(t, presses=()):
        lim = int(t * CLOCK)
        while mpu.processorCycles < lim:
            mpu.step()
            for p in presses:
                if p[0] <= mpu.processorCycles / CLOCK and not p[1]:
                    p[1] = True
                    mpu.nmi()

    r = []
    run(14 if BB else 8)
    s = screen(b.lcd)
    write_png(BUILD / ("bb_1_ready.png" if BB else "v2_1_ready.png"), s)
    def c(hex6):                              # expected panel colour for '#RRGGBB'
        v = int(hex6[1:], 16)
        if not BB:
            return ((v >> 19) << 11) | (((v >> 10) & 63) << 5) | ((v >> 3) & 31)
        r, g, bl = v >> 20, (v >> 12) & 15, (v >> 4) & 15
        return (r << 1 | r >> 3) << 11 | (g << 2 | g >> 2) << 5 | (bl << 1 | bl >> 3)

    r.append(check("boot: HUD, sky, ground, bird", s[5][5] == c("#3B2E2E")
                   and s[10][100] == c("#4EC0CA") and s[235][100] == c("#DED895")
                   and s[103][92] == c("#F8F8F8"),
                   f"HUD {s[5][5]:04X} sky {s[10][100]:04X} dirt {s[235][100]:04X} "
                   f"eye {s[103][92]:04X} -> build/v2_1_ready.png"))

    t0 = mpu.processorCycles / CLOCK
    # flap roughly every 0.35 s to stay airborne for a while
    presses = [[t0 + 0.35 * i, False] for i in range(40)]
    f0 = len(b.lcd.scrolls)
    run(t0 + 6, presses)
    fr = b.lcd.scrolls[f0 + 2:]
    fps = (len(fr) - 1) / ((fr[-1] - fr[0]) / CLOCK) if len(fr) > 2 else 0
    s = screen(b.lcd)
    write_png(BUILD / ("bb_2_play.png" if BB else "v2_2_play.png"), s)
    r.append(check("plays: frames/s", fps > (10 if BB else 15),
                   f"{fps:.1f} fps at 1.25 MHz ({fps * 0.8:.1f} at 1 MHz), bird row {b.ram[0x25]}, "
                   f"score {b.ram[0x30]:02X} -> build/v2_2_play.png"))
    print(f"{sum(r)}/{len(r)} smoke checks passed")
    return 0 if all(r) else 1


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Play build/flappy512.bin on the emulated board (bit-bang wiring, SCL = latch bit 1).

A bot reads the emulated panel (not the game's RAM) to find the next gap and presses
the button (NMI). Checks: boot screen, frames/s, scoring, death, restart.

    uv run python tools/sim512.py        -> build/f512_*.png   (~2 minutes)
"""
import re
import sys

from py65.devices.mpu6502 import MPU

from png import write_png
from sim import BUILD, check
from simgame import LiveLcd

CLOCK, TFA, RING = 1_250_000, 64, 256   # 10 MHz crystal / 8
YH, VH, SCORE = 0x04, 0x05, 0x09


class Board:
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
        elif a < 0xC000:
            v &= 0x0F
            if v & 0x08:                      # CS high: frame ends
                self.n = 0
            elif v & 0x02 and not self.latch & 0x02:
                self.bits = (self.bits << 1) | (v & 1)
                self.n += 1
                if self.n == 8:
                    self.lcd.feed(self.mpu.processorCycles, (v >> 2) & 1, self.bits & 0xFF)
                    self.n = 0
            self.latch = v


def line(lcd, x):
    """Frame-memory line shown at screen column x."""
    return x if x < TFA else TFA + (x - TFA + lcd.vsp - TFA) % RING


def screen(lcd):
    # the panel runs without INVON: it shows the complement of what is sent
    return [[row[line(lcd, x)] ^ 0xFFFF for x in range(320)] for row in lcd.fb]


def next_gap(lcd):
    """Top row of the gap in the first pipe column at or right of the bird, or None."""
    for x in range(TFA, TFA + 90):
        col = [lcd.fb[r][line(lcd, x)] for r in range(160)]
        if 0 in col:                          # white (sent 0) = pipe
            return next((r for r in range(160) if col[r] and (r == 0 or not col[r - 1])), None)
    return None


def labels():
    lst = (BUILD / "flappy512.lst").read_text()
    m = {}
    for name in ("dead", "loop"):
        h = re.search(rf"^([0-9A-F]{{6}})r 1 .*\b{name}:", lst, re.M)
        m[name] = 0xFE00 + int(h.group(1), 16)
    return m


def main():
    rom = (BUILD / "flappy512.bin").read_bytes()
    used = len(rom[0x1E00:0x1FFA].rstrip(b"\xff")) + 6
    b = Board(rom)
    mpu = MPU(memory=b)
    b.mpu = mpu
    mpu.pc = b[0xFFFC] | b[0xFFFD] << 8
    lab = labels()
    r = [check("size: code + vectors <= 512 bytes", used <= 512, f"{used} bytes")]

    def t():
        return mpu.processorCycles / CLOCK

    def run(until, bot=False, stop=None):
        lim = int(until * CLOCK)
        frames = len(b.lcd.scrolls)
        while mpu.processorCycles < lim:
            mpu.step()
            if stop and stop():
                return True
            if bot and len(b.lcd.scrolls) != frames:
                frames = len(b.lcd.scrolls)
                g = next_gap(b.lcd)
                target = (g + 34) if g is not None else 80
                if b.ram[YH] > target and b.ram[VH] < 0x80:
                    mpu.nmi()
        return False

    waiting = lambda: lab["dead"] <= mpu.pc < lab["loop"]
    run(30, stop=lambda: waiting() and mpu.processorCycles > 1_000_000)
    s = screen(b.lcd)
    write_png(BUILD / "f512_1_boot.png", s)
    BLACK, WHITE = 0x0000, 0xFFFF
    r.append(check("boot: black sky, white ground line, waiting for a press",
                   waiting() and s[10][100] == BLACK and s[200][300] == BLACK
                   and s[161][5] == WHITE and s[161][300] == WHITE,
                   f"{t():.1f} s at 1.25 MHz -> build/f512_1_boot.png"))

    run(t() + 0.2)                            # a person presses a while later
    mpu.nmi()
    t0, f0 = t(), len(b.lcd.scrolls)
    run(t0 + 40, bot=True, stop=lambda: b.ram[SCORE] >= 5 * 9)
    fr = b.lcd.scrolls[f0 + 2:]
    fps = (len(fr) - 1) / ((fr[-1] - fr[0]) / CLOCK) if len(fr) > 2 else 0
    s = screen(b.lcd)
    write_png(BUILD / "f512_2_play.png", s)
    pts = b.ram[SCORE] // 9
    r.append(check("plays: bot passes 5 pipes", pts >= 5,
                   f"{pts} points in {t() - t0:.1f} s, {fps:.1f} frames/s at 1.25 MHz "
                   f"-> build/f512_2_play.png"))
    r.append(check("score bar drawn", s[2][7] == WHITE and s[2 + 9 * (pts - 1)][7] == WHITE,
                   "one 8x8 block per point, top left"))

    died = run(t() + 20, stop=waiting)        # no presses: falls to the ground
    write_png(BUILD / "f512_3_dead.png", screen(b.lcd))
    r.append(check("collision: game over without presses", died,
                   f"bird row {b.ram[YH]} -> build/f512_3_dead.png"))

    run(t() + 0.2)
    mpu.nmi()
    run(t() + 3, bot=True)
    s = screen(b.lcd)
    write_png(BUILD / "f512_4_restart.png", s)
    r.append(check("restart: score cleared, playing again",
                   not waiting() and b.ram[SCORE] == 0 and s[30][7] == BLACK,
                   f"score {b.ram[SCORE] // 9} -> build/f512_4_restart.png"))
    print(f"{sum(r)}/{len(r)} checks passed")
    return 0 if all(r) else 1


if __name__ == "__main__":
    sys.exit(main())

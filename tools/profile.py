#!/usr/bin/env python3
"""Profile build/flappy_bb.bin (bit-bang build) on the emulated board.

Boots, starts the game, lets a bot aim for the gaps for N seconds of game time
(1.25 MHz), and prints frames/s plus the inclusive cost of each frame stage.

    uv run python tools/profile.py [seconds]
"""
import subprocess
import sys
from pathlib import Path

from py65.devices.mpu6502 import MPU

sys.argv = [sys.argv[0], "bb"] + sys.argv[1:]
import smoke2  # noqa: E402  (bit-bang board model)

ROOT = Path(__file__).resolve().parent.parent
CC65 = Path.home() / ".local/opt/cc65/bin"
C = 1_250_000
STAGES = ("pipe_col", "delay_col", "put_bird", "erase_v", "new_cols",
          "hud_update", "collide", "scorechk", "send_scroll", "physics")


def labels():
    tmp = ROOT / "build"
    subprocess.run([CC65 / "ca65", "-g", "-I", "asm", "-o", tmp / "prof.o", "asm/flappy_bb.s"],
                   cwd=ROOT, check=True)
    subprocess.run([CC65 / "ld65", "-C", "asm/rom.cfg", "-o", tmp / "prof.bin",
                    "-Ln", tmp / "prof.lbl", tmp / "prof.o"], cwd=ROOT, check=True)
    out = {}
    for line in (tmp / "prof.lbl").read_text().splitlines():
        _al, addr, name = line.split()
        out[name[1:]] = int(addr, 16)
    return out


def main():
    secs = float(sys.argv[2]) if len(sys.argv) > 2 else 12
    L = labels()
    b = smoke2.Board2((ROOT / "build/flappy_bb.bin").read_bytes())
    m = MPU(memory=b)
    b.mpu = m
    m.pc = b[0xFFFC] | b[0xFFFD] << 8
    nxt = C
    while len(b.lcd.scrolls) < 3:          # press every 0.5 s until play starts
        m.step()
        if m.processorCycles > nxt:
            m.nmi()
            nxt += C // 2
    print(f"play starts {m.processorCycles / C:.1f} s after reset")
    cost = {k: [] for k in STAGES}
    entry = {L[k]: k for k in STAGES}
    active, f0, t0 = [], len(b.lcd.scrolls), m.processorCycles
    last = f0
    while m.processorCycles < t0 + secs * C:
        name = entry.get(m.pc)
        if name:
            active.append((name, m.sp, m.processorCycles))
        m.step()
        while active and m.sp > active[-1][1]:
            n, _sp, c = active.pop()
            cost[n].append(m.processorCycles - c)
        if len(b.lcd.scrolls) != last:      # bot: aim for the middle of the next gap
            last = len(b.lcd.scrolls)
            s = b.ram[0x22] | b.ram[0x23] << 8
            gaps, yp = b.ram[0x29:0x2C], b.ram[0x25]
            vy = int.from_bytes(b.ram[0x26:0x28], "little", signed=True)
            tgt = 90
            for sx in range(60, 320):
                q = (sx - 20 + s) % 300
                if q % 100 < 30 and gaps[q // 100] != 0xFF:
                    tgt = gaps[q // 100] + 35
                    break
            if yp > tgt and vy >= 0:
                m.nmi()
    fr = len(b.lcd.scrolls) - f0
    print(f"{fr} frames in {secs:.0f} s = {fr / secs:.1f} frames/s at 1.25 MHz "
          f"({fr / secs * 0.8:.1f} at 1 MHz), score {b.ram[0x31]:02X}{b.ram[0x30]:02X}")
    for n, v in cost.items():
        if v:
            v2 = sorted(v)
            print(f"  {n:11s} calls {len(v):4d}  avg {sum(v) / len(v):7.0f}  "
                  f"median {v2[len(v2) // 2]:7d}  max {v2[-1]:7d}")


if __name__ == "__main__":
    main()

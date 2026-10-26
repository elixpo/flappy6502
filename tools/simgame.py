#!/usr/bin/env python3
"""Play build/flappy.bin on the emulated board.

A live ST7789 model follows every SPI byte, including the hardware scroll
(VSCRSADD), so the PNG snapshots show exactly what the panel would show.
The button is the NMI; a bot can press it, reading the game's RAM to aim.

    uv run python tools/simgame.py          all checks + snapshots in build/game_*.png

Takes ~3 minutes: py65 runs ~0.5 M cycles/s, and the boot screen fill alone is
~15 M cycles. Progress is printed as it goes.
"""
import sys

from py65.devices.mpu6502 import MPU

from png import write_png
from sim import BUILD, Board, check

CLOCK = 1_250_000
SYM = {"yp": 0x35, "vy": 0x36, "scr": 0x32, "cgap": 0x39, "score": 0x3E, "flap": 0x30}
BIRD_X, BIRD_W, GAP, PIPE_W = 80, 18, 80, 30


class LiveLcd:
    """ST7789 subset: CASET, RASET, RAMWR, MADCTL, VSCRSADD; logical 320x240 (MV=1)."""

    def __init__(self):
        self.fb = [[0] * 320 for _ in range(240)]
        self.cmd = None
        self.data = []
        self.vsp = 0
        self.xs = self.xe = self.ys = self.ye = 0
        self.x = self.y = 0
        self.scrolls = []          # cycle of every VSCRSADD = one frame
        self.hi = None
        self.bpp12 = False         # COLMOD $x3: 12 bits per pixel (RGB444)
        self.nib = []

    def feed(self, cycle, dc, b):
        if dc == 0:
            self.cmd, self.data, self.hi, self.nib = b, [], None, []
            if b == 0x2C:
                self.x, self.y = self.xs, self.ys
            return
        if self.cmd == 0x2C and self.bpp12:
            self.nib += [b >> 4, b & 15]
            while len(self.nib) >= 3:
                r, g, bl = self.nib[:3]
                del self.nib[:3]
                self._put((r << 1 | r >> 3) << 11 | (g << 2 | g >> 2) << 5 | (bl << 1 | bl >> 3))
            return
        if self.cmd == 0x2C:
            if self.hi is None:
                self.hi = b
                return
            self._put(self.hi << 8 | b)
            self.hi = None
            return
        self.data.append(b)
        d = self.data
        if self.cmd == 0x3A and len(d) == 1:
            self.bpp12 = (b & 7) == 3
        if self.cmd == 0x2A and len(d) == 4:
            self.xs, self.xe = d[0] << 8 | d[1], d[2] << 8 | d[3]
        elif self.cmd == 0x2B and len(d) == 4:
            self.ys, self.ye = d[0] << 8 | d[1], d[2] << 8 | d[3]
        elif self.cmd == 0x37 and len(d) == 2:
            self.vsp = d[0] << 8 | d[1]
            self.scrolls.append(cycle)

    def _put(self, c):
        if self.x < 320 and self.y < 240:
            self.fb[self.y][self.x] = c
        self.x += 1
        if self.x > self.xe:
            self.x, self.y = self.xs, self.y + 1

    def screen(self):
        """What the panel shows: screen x = (memory line - VSP) mod 320."""
        return [[row[(x + self.vsp) % 320] for x in range(320)] for row in self.fb]


class Spi:
    def __init__(self, sink):
        self.prev = self.bits = self.n = 0
        self.sink = sink

    def write(self, cycle, v):
        if v & 0x08:
            self.n = 0
        elif v & 0x02 and not self.prev & 0x02:
            self.bits = (self.bits << 1) | (v & 1)
            self.n += 1
            if self.n == 8:
                self.sink(cycle, (v >> 2) & 1, self.bits & 0xFF)
                self.n = 0
        self.prev = v


class Game:
    def __init__(self):
        self.board = Board((BUILD / "flappy.bin").read_bytes())
        self.lcd = LiveLcd()
        self.board.spi = Spi(self.lcd.feed)
        self.board.latch_writes = [None] * 20000      # keep Board from storing writes
        self.mpu = MPU(memory=self.board)
        self.board.mpu = self.mpu
        self.mpu.pc = self.board[0xFFFC] | self.board[0xFFFD] << 8

    @property
    def t(self):
        return self.mpu.processorCycles / CLOCK

    def ram(self, name, n=1):
        a = SYM[name]
        v = self.board.ram[a:a + n]
        return v[0] if n == 1 else bytes(v)

    def press(self):
        self.mpu.nmi()

    def run_until(self, t, bot=None):
        mpu, limit = self.mpu, int(t * CLOCK)
        frames = len(self.lcd.scrolls)
        next_note = mpu.processorCycles + 5 * CLOCK
        while mpu.processorCycles < limit:
            if mpu.processorCycles >= next_note:
                next_note += 5 * CLOCK
                print(f"    ... {self.t:5.1f} s simulated, {len(self.lcd.scrolls)} frames, "
                      f"score {self.ram('score', 2)[::-1].hex()}", flush=True)
            mpu.step()
            if bot and len(self.lcd.scrolls) != frames:
                frames = len(self.lcd.scrolls)
                bot(self)

    def snap(self, name):
        write_png(BUILD / f"game_{name}.png", self.lcd.screen())


class Bot:
    """Flap when the bird sinks below the middle of the next gap."""

    def __init__(self):
        self.cool = 0

    def __call__(self, g):
        self.cool -= 1
        scr = g.board.ram[0x32] | g.board.ram[0x33] << 8
        gaps = g.ram("cgap", 2)
        target = 100
        for sx in range(BIRD_X - PIPE_W, 320):
            lx = (scr + sx) % 320
            if lx % 160 < PIPE_W and gaps[lx // 160] != 0xFF:
                target = gaps[lx // 160] + GAP // 2 - BIRD_W // 2 + 6
                break
        vy = int.from_bytes(g.board.ram[0x36:0x38], "little", signed=True)
        if g.ram("yp") > target and vy >= 0 and self.cool <= 0:
            g.press()
            self.cool = 3


def main() -> int:
    r = []
    g = Game()

    print("  booting (filling sky + ground, ~30 s of real time)...", flush=True)
    # 1. boot: background + hovering bird, waiting for the first flap
    g.run_until(20)
    s = g.lcd.screen()
    ok = s[10][10] == 0x4E19 and s[235][10] == 0xDED2 and s[100 + 3][BIRD_X + 12] == 0xFFDF \
        and len(g.lcd.scrolls) == 1 and g.ram("yp") == 100
    g.snap("1_ready")
    r.append(check("boot screen, bird hovering, no frames yet", ok,
                   "sky, ground and bird drawn -> build/game_1_ready.png"))

    # 2. the bot plays
    g.press()
    start = g.t
    g.run_until(start + 6, Bot())
    g.snap("2_playing")
    bot = Bot()
    g.run_until(start + 40, bot)
    frames = [c for c in g.lcd.scrolls if c / CLOCK > start]
    fps = (len(frames) - 1) / ((frames[-1] - frames[0]) / CLOCK) if len(frames) > 2 else 0
    score = g.ram("score", 2)
    sc = (score[1] & 0x0F) * 100 + (score[0] >> 4) * 10 + (score[0] & 0x0F)
    g.snap("3_later")
    r.append(check("bot plays 40 s", sc >= 3,
                   f"score {sc}, {fps:.1f} frames/s at 1.25 MHz ({fps / 2:.1f} at 625 kHz), "
                   f"scroll {fps * 2:.0f} px/s -> build/game_2_playing.png, game_3_later.png"))

    # 3. no more presses: the bird falls, game over shows the score and STAYS
    def score_px(scr):
        return sum(1 for y in range(60, 90) for x in range(127, 193) if scr[y][x] == 0xFFFF)

    t = g.t
    while g.lcd.screen and g.t < t + 15 and score_px(g.lcd.screen()) == 0:
        g.run_until(g.t + 1)
    died_t = g.t
    g.run_until(died_t + 0.3)
    g.press()                                   # inside the ~1 s hold-off: ignored
    frames = len(g.lcd.scrolls)
    g.run_until(died_t + 10)
    g.snap("4_gameover")
    s = g.lcd.screen()
    r.append(check("game over waits for a press (early press ignored)",
                   score_px(s) > 100 and len(g.lcd.scrolls) == frames,
                   f"{score_px(s)} score pixels still shown after 10 s, "
                   f"{len(g.lcd.scrolls) - frames} frames -> build/game_4_gameover.png"))

    # 4. one press: clean restart AND play starts straight away (no second press)
    g.press()
    frames = len(g.lcd.scrolls)
    g.run_until(g.t + 5)
    g.snap("5_restart")
    s = g.lcd.screen()
    pipe_px = sum(1 for y in range(200) for x in range(250)
                  if s[y][x] in (0x75E5, 0x9F2B, 0x5404))
    played = len(g.lcd.scrolls) - frames
    r.append(check("one press restarts and plays", pipe_px == 0 and score_px(s) == 0 and played > 5,
                   f"old pipes left {pipe_px} px, score px {score_px(s)}, "
                   f"{played} frames played without a 2nd press -> build/game_5_restart.png"))

    print(f"{sum(r)}/{len(r)} game checks passed")
    return 0 if all(r) else 1


if __name__ == "__main__":
    sys.exit(main())

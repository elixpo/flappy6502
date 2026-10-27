# Hardware Plan — W65C02 Flappy Bird (Phases 1 & 2)

Status: design, not yet built. Covers the address map, IC choice and pin-by-pin
wiring. The display init sequence (Phase 3) and the game (Phase 4) come later.

## Decisions at a glance

| Decision | Choice | Why |
|---|---|---|
| RAM | **HY62CT08081E-D70C** (32K×8, 70 ns, 62256 pinout) | One chip, no inversion, CMOS levels. The 74LS189 route needs 3–5 chips for 16–32 bytes (see below). |
| ROM | **AT28C64B-15** (8 KiB, 150 ns) | Already programmed by Nano28C64 from an 8 KiB `.bin`. |
| Decoder | **one 74xx00** (quad NAND; HC, HCT or LS all work) | All four gates are used: ROM select, I/O select, R/W invert and write strobe. |
| Display port | **74LS161 used as a 4-bit output latch** | The 74LS161 has a synchronous parallel load, so with `/LOAD` driven by the address decode it acts as a D-register. No VIA or 74HC574 needed. |
| SPI | Software bit-bang through that latch | Uses no extra chips. It is slow (see throughput); a hardware shifter is an optional later upgrade. |
| Button | **NMI** | Edge-triggered and needs no input port chip. The handler `INC flap / RTI` is 3 bytes. |
| 74HC245 | **Not used** | No buffering is needed with this few loads. Keep it spare (for example as a buffer for an Arduino bus monitor). |
| 74LS189 | Option B, **user to decide** | 16 bytes is enough, but it needs 8 inverters. See below. |

Total: **5 ICs** (CPU, ROM, SRAM, 74xx00, 74LS161) plus your existing clock
module. Option B makes it 8 ICs.

### RAM choice: SRAM (option A) or 2× 74LS189 (option B)

**16 bytes is enough for this game**, given the hardware-scroll design below.
The difficulty is the electrical side of the 74LS189, not the amount of memory.

| | A: HY62CT08081E | B: 2× 74LS189 (16 × 8) |
|---|---|---|
| Chips for RAM | 1 | **4**: 2× 74LS189 + **2× 74LS04 or 74HC04** (8 inverters) |
| Decode | `/CS` = A15, `/WE` = `/WSTB`, `/OE` = WR | `/ME` = A15, `/WE` = `/WSTB` (the same nets) |
| Readback | normal | the 189 outputs the **complement** of what was written, so the inverters must sit on the **D-input side** (bus → 7404 → 189 D). Output-side inverters would drive the bus all the time. |
| Levels | CMOS | LS V_OH ≈ 3.4 V into the W65C02S. Check its V_IH; add 4.7 kΩ pull-ups on D0–D7 if it is marginal. |
| Memory map | ZP `$00–$FF`, stack `$0100–$01FF` | All 16 bytes mirror everywhere: `$00–$0F` and the stack `$0100–$010F` are **the same cells**. Use `LDX #$0F / TXS` so the stack grows down from cell 15, and give variables cells 0 and up. |
| Stack room | plenty | NMI = 3 bytes + JSR = 2 bytes, so ≥ 5 cells. Using SOB for the button instead of NMI (see below) brings this down to 2 cells. |
| Risk | none | if the stack ever runs into a variable, the corruption is silent and hard to find |

Option B's variable budget, with X and Y used as loop counters:

| Variable | Bytes |
|---|---|
| bird `y` (8.8 fixed point) | 2 |
| `vy` | 1 |
| column counter (also gives the score) | 2 |
| `gap0`, `gap1` (the 2 pipes on screen) | 2 |
| SPI shift temp | 1 |
| pixel count | 2 |
| **Total** | **10** |

That leaves 6 cells of stack: enough for one JSR level plus NMI, or two levels
with SOB.

**The software cannot work around the inversion.** The CPU pushes return
addresses itself (JSR, NMI), so it would pull back inverted addresses. Also,
`INC`/`DEC`/`ASL` on an inverting cell produce garbage. So option B needs those
8 inverters. If you have no 74x04, a spare 74xx00 can act as 4 inverters, so
you would need two more 74xx00 chips.

**Recommendation: A.** Option B can be built, but it adds 3 more chips, and the
16-byte stack and variable overlap makes it hard to debug at single-step speed.
If you want B as the challenge, the rest of this plan is unchanged.

### Button alternative: SOB instead of NMI

Wire the button to SOB (pin 38) with the same RC network, and tie NMIB high
through 3.3 kΩ. A falling edge on SOB sets the CPU's V flag.

Once per frame:

```
bvc noflap
clv
; ...flap...
noflap:
```

This uses no stack and no RAM. One rule: no `ADC`/`SBC`/`BIT`/`PLP` between
the frame's poll and the end of the frame (do the physics right after the
poll). Otherwise those instructions clear a press that arrived in that window.

---

## Phase 1 — Memory map

| Range | Size | Device | Decode condition |
|---|---|---|---|
| `$0000–$00FF` | 256 B | SRAM: zero page (variables) | A15 = 0 |
| `$0100–$01FF` | 256 B | SRAM: stack | A15 = 0 |
| `$0200–$7FFF` | ~31.5 KB | SRAM: free (unused by the game) | A15 = 0 |
| `$8000–$BFFF` | 16 KB | **LCD output latch**, write-only, mirrored. Use `$8000`. | A15 = 1, A14 = 0 |
| `$C000–$DFFF` | 8 KB | ROM (mirror; A13 not decoded) | A15 = 1, A14 = 1 |
| `$E000–$FFFF` | 8 KB | **ROM** (assemble here) | A15 = 1, A14 = 1 |

Vectors (in ROM, image offset = address − `$E000`):

| Vector | Address | Image offset | Points to |
|---|---|---|---|
| NMI (flap button) | `$FFFA/B` | `$1FFA/B` | `nmi` handler |
| RESET | `$FFFC/D` | `$1FFC/D` | `reset` (code at `$E000`) |
| IRQ/BRK | `$FFFE/F` | `$1FFE/F` | `RTI` stub (IRQ is unused but pulled up) |

ROM image: assemble with `.org $E000` and pad to exactly **8192 bytes**, then
flash it with Nano28C64. The code must start with `LDX #$FF / TXS`, because the
SRAM contents and the stack pointer are undefined at power-up.

Reading from `$8000–$BFFF` drives nothing onto the bus (the bus floats), so the
software must never read the latch. It keeps its own copy of the port value in
zero page.

### Decoder (one 74xx00, all four gates)

```
G1:  /ROMCS = NAND(A15, A14)        low for $C000–$FFFF
G2:  /IOSEL = NAND(A15, /ROMCS)     low for $8000–$BFFF
G3:   WR    = NAND(RWB, RWB)        high on writes; low on reads (= /RD)
G4:  /WSTB  = NAND(PHI2, WR)        low only during PHI2-high of a write cycle
```

| Device pin | Driven by |
|---|---|
| ROM `/CE` | `/ROMCS` (G1) |
| ROM `/OE` | `WR` (G3): ROM drives the bus only on reads |
| ROM `/WE` | **tied to VCC** (no writes in circuit) |
| SRAM `/CS` | **A15 directly** |
| SRAM `/OE` | `WR` (G3) |
| SRAM `/WE` | `/WSTB` (G4) |
| 74LS161 `/LOAD` | `/IOSEL` (G2) |
| 74LS161 `CLK` | `/WSTB` (G4) |

How the latch works: on every write, `/WSTB` rises when PHI2 falls, which is
while the data is still valid on the bus. The 74LS161 is clocked on that rising
edge:

- If `/LOAD` is low (the address is in `$8000–$BFFF`), D0–D3 are loaded.
- Otherwise, because ENP and ENT are tied low, the count holds and nothing changes.

So writes to RAM also clock the 74LS161, and this is harmless.

### Bus-contention check

| Cycle | ROM | SRAM | Latch | Result |
|---|---|---|---|---|
| Read `$0000–$7FFF` | /CE high | drives | — | OK |
| Read `$8000–$BFFF` | /CE high | /CS high | not a bus driver | floats (never done) |
| Read `$C000–$FFFF` | drives | /CS high | — | OK |
| Write anywhere | /OE high | /OE high (writes only if A15 = 0) | loads only if `$8000–$BFFF` | CPU is the only driver |

Timing: SRAM writes are qualified by PHI2, so address changes during PHI2-low
cannot corrupt RAM. The ROM is 150 ns and the SRAM is 70 ns, so 1 MHz has a
large margin and 2 MHz should be fine. Above that, recheck the ROM access time
against the PHI2 period minus the NAND delays.

---

## Phase 2 — Bill of materials

| # | IC | Purpose | Supply | Owned? |
|---|---|---|---|---|
| U1 | **Rockwell R6502P** (NMOS 6502, 1 MHz grade) | CPU | 5 V | yes (marking `R6502P 2 11450`). **NMOS with dynamic registers, so it needs a clock of roughly 100 kHz or more.** |
| U6 | 74LS161 (second one) | divides the 10 MHz oscillator to the CPU clock | 5 V | yes |
| X1 | 10 MHz **bare crystal** (2-pin) | clock source | — | yes |
| U9 | 74LS04 | crystal oscillator (2 inverters + 1 buffer) | 5 V | yes |
| U7 | 74HC00 (second one) | input-port decode + SYNC step gate | 5 V | yes (only needed for the gamepad / instruction stepping) |
| U8 | 74HC245 | 4-button input port | 5 V | yes (only needed for the gamepad) |
| U2 | AT28C64B-15 | 8 KiB ROM | 5 V | yes |
| U3 | HY62CT08081E-D70C | 32 KiB RAM | 5 V | yes (confirm the 62256-compatible pinout on the marking) |
| U4 | 74HC00 / 74HCT00 / 74LS00 | address decode + strobes | 5 V | **confirm you have one**; otherwise buy one |
| U5 | 74LS161 | LCD output latch | 5 V | yes |
| — | Clock module (astable / monostable) | PHI2 | 5 V | yes |
| — | SmartElex 2" 240×320 SPI IPS | display | 5 V (stated) | yes |

Passives: a 100 nF ceramic decoupling capacitor at **every** IC's VCC pin, plus
10–47 µF bulk across the rails. Also 3× 3.3 kΩ (RDY, IRQB, SOB), 2× 10 kΩ
(RESB, NMIB), 1× 100 nF (NMIB debounce), 1× 100 Ω, and two pushbuttons (reset
and flap).

### U1 — R6502P (NMOS, DIP-40)

| Pin | Name | Connect to |
|---|---|---|
| 1 | **VSS** | **GND** (on the NMOS part this is ground, not an output) |
| 2 | RDY | 3.3 kΩ to VCC, plus the optional step switch (see Clock) |
| 3 | φ1 out | NC |
| 4 | /IRQ | 3.3 kΩ to VCC |
| 5 | NC | NC |
| 6 | /NMI | flap button network (below) |
| 7 | SYNC | NC, or the single-step circuit / Arduino monitor |
| 8 | VCC | +5 V, plus 100 nF to pin 21 (NMOS draws ~100+ mA, so add 10 µF nearby) |
| 9–20 | A0–A11 | ROM and SRAM A0–A11 |
| 21 | VSS | GND |
| 22 | A12 | ROM A12, SRAM A12 |
| 23 | A13 | SRAM A13 (not to the ROM) |
| 24 | A14 | SRAM A14, U4 G1 input |
| 25 | A15 | SRAM /CS, U4 G1 and G2 inputs |
| 26–33 | D7…D0 | ROM and SRAM D7…D0; **D0–D3 also to 74LS161 A–D** |
| 34 | R/W | U4 G3 (both inputs) |
| 35 | NC | NC |
| 36 | NC | NC |
| 37 | **φ0 in** | clock from U6 (below) |
| 38 | SO | 3.3 kΩ to VCC |
| 39 | **φ2 out** | **U4 pin 12** (G4). On the NMOS part, decode from φ2 *out*, not from the clock input. |
| 40 | /RES | reset network (below) |

Every place this document says "PHI2" means the **pin-39 φ2 output**.

NMOS software rules:
- Use only the original 6502 instruction set: no `STZ`, `BRA`, `PHX/PHY`, `(zp)` addressing, `TSB/TRB`, `INC A` or `WAI`.
- Start the reset handler with `SEI`, `CLD`, then `LDX #$FF` (or `#$0F` for the 74LS189 option) and `TXS`.

### U2 — AT28C64B (DIP-28)

| Pin | Name | Connect to | | Pin | Name | Connect to |
|---|---|---|---|---|---|---|
| 1 | RDY/BUSY | NC | | 15 | D3 | CPU D3 |
| 2 | A12 | CPU A12 | | 16 | D4 | CPU D4 |
| 3 | A7 | CPU A7 | | 17 | D5 | CPU D5 |
| 4 | A6 | CPU A6 | | 18 | D6 | CPU D6 |
| 5 | A5 | CPU A5 | | 19 | D7 | CPU D7 |
| 6 | A4 | CPU A4 | | 20 | /CE | U4 pin 3 (/ROMCS) |
| 7 | A3 | CPU A3 | | 21 | A10 | CPU A10 |
| 8 | A2 | CPU A2 | | 22 | /OE | U4 pin 8 (WR) |
| 9 | A1 | CPU A1 | | 23 | A11 | CPU A11 |
| 10 | A0 | CPU A0 | | 24 | A9 | CPU A9 |
| 11 | D0 | CPU D0 | | 25 | A8 | CPU A8 |
| 12 | D1 | CPU D1 | | 26 | NC | NC |
| 13 | D2 | CPU D2 | | 27 | /WE | **+5 V** |
| 14 | GND | GND | | 28 | VCC | +5 V, plus 100 nF |

### U3 — HY62CT08081E SRAM (DIP-28, 62256 pinout)

The pinout is the same as the ROM except for these pins:

| Pin | Name | Connect to |
|---|---|---|
| 1 | A14 | CPU A14 |
| 20 | /CS | **CPU A15** |
| 22 | /OE | U4 pin 8 (WR) |
| 26 | A13 | CPU A13 |
| 27 | /WE | U4 pin 11 (/WSTB) |
| 14 / 28 | GND / VCC | GND / +5 V, plus 100 nF |

A0–A12 and D0–D7 are wired exactly as on the ROM.

### U4 — 74xx00

| Pin | Connect to | Pin | Connect to |
|---|---|---|---|
| 1 (1A) | A15 | 8 (3Y) → **WR** | ROM /OE, SRAM /OE, pin 13 |
| 2 (1B) | A14 | 9 (3A) | RWB |
| 3 (1Y) → **/ROMCS** | ROM /CE, pin 5 | 10 (3B) | RWB |
| 4 (2A) | A15 | 11 (4Y) → **/WSTB** | SRAM /WE, 74LS161 CLK |
| 5 (2B) | pin 3 | 12 (4A) | PHI2 |
| 6 (2Y) → **/IOSEL** | 74LS161 /LOAD | 13 (4B) | pin 8 |
| 7 | GND | 14 | +5 V, plus 100 nF |

### U5 — 74LS161 (output latch at `$8000`)

| Pin | Name | Connect to |
|---|---|---|
| 1 | /CLR | CPU RESB (the latch clears to 0 on reset) |
| 2 | CLK | U4 pin 11 (/WSTB) |
| 3 | A | CPU D0 |
| 4 | B | CPU D1 |
| 5 | C | CPU D2 |
| 6 | D | CPU D3 |
| 7 | ENP | **GND** (never count) |
| 8 | GND | GND |
| 9 | /LOAD | U4 pin 6 (/IOSEL) |
| 10 | ENT | **GND** |
| 11 | QD | LCD **CS** (bit 3) |
| 12 | QC | LCD **DC** (bit 2) |
| 13 | QB | LCD **SCL** (bit 1) |
| 14 | QA | LCD **SDA** (bit 0) |
| 15 | RCO | NC |
| 16 | VCC | +5 V, plus 100 nF |

Port bit map at `$8000`: `bit0 = SDA`, `bit1 = SCL`, `bit2 = DC (1 = data)`,
`bit3 = CS (active low)`. Bits 4–7 are ignored.

### LCD module

| LCD pin | Connect to | Notes |
|---|---|---|
| VCC | +5 V | You report it is 5 V capable. Check the board has an LDO. |
| GND | GND | |
| SDA | U5 QA | SPI MOSI |
| SCL | U5 QB | SPI clock, mode 0 (idle low, sampled on the rising edge) |
| DC | U5 QC | |
| CS | U5 QD | |
| RST | **CPU RESB** | Resets with the CPU. Firmware then waits ≥ 120 ms before sending commands. |
| EN | **TBD from the datasheet** | Probably backlight enable. Try tying it to VCC through 1 kΩ, but confirm first. |
| TE | NC | Not needed. |

Logic levels: 74LS161 outputs are about 3.4 V high, so they are safe **if** the
module really accepts 5 V logic. Do **not** use resistor dividers here, because
3.4 V × divider falls below the ST7789 V_IH. If the module turns out to be
3.3 V-only on its I/O pins, add a 74HC4050 or a 74LVC245 powered at 3.3 V
between U5 and the LCD.

### Reset

- RESB to +5 V through 10 kΩ.
- Pushbutton from RESB to GND.
- 1 µF from RESB to GND (gives a power-on reset of roughly 10 ms).

At 1 kHz, hold reset at least 2 clock cycles (2 ms): press the button for a
moment, or let the RC handle power-on. RESB also clears U5 and resets the LCD.

### Flap button (NMI)

- NMIB to +5 V through 10 kΩ.
- 100 nF from NMIB to GND.
- Button from NMIB to GND through 100 Ω.

NMI is edge-triggered on the falling edge, so a bounce at worst fires the
handler a few times, and each time it only sets a flag:

```
nmi:  inc flap     ; main loop: lda flap / beq none / lda #0 / sta flap / ...flap...
      rti
```

The game starts automatically after reset, and the button only flaps, which
matches your current behaviour. A press during reset is ignored, because NMI is
only serviced after the reset sequence finishes.

### Clock

**The 1 kHz clock module cannot drive the R6502P.** NMOS 6502 registers are
dynamic and lose state when φ0 is held or run too slowly (roughly 100 kHz
minimum; check the maximum cycle time in the R6502 datasheet).

Instead, divide the 10 MHz oscillator with a spare 74LS161 (U6) wired as a free-running counter:

| U6 pin | Connect to |
|---|---|
| 1 /CLR | +5 V |
| 2 CLK | 10 MHz oscillator output |
| 3–6 A–D | GND |
| 7 ENP | +5 V |
| 9 /LOAD | +5 V |
| 10 ENT | +5 V |
| 11 **QD** | ÷16 = **625 kHz**, 50 % duty → CPU pin 37 (φ0). **Start here.** |
| 12 QC | ÷8 = 1.25 MHz (25 % over the 1 MHz rating; try it later) |
| 13 QB | ÷4 = 2.5 MHz (too fast for an R6502P) |
| 16 / 8 | +5 V / GND, plus 100 nF |

The clock source is a 10 MHz crystal plus a 74LS04 (U9), wired as a two-inverter
TTL oscillator:

| U9 pin | Connect to |
|---|---|
| 1 (1A) | 470 Ω to pin 2; crystal leg A |
| 2 (1Y) | 100 nF coupling capacitor to pin 3 |
| 3 (2A) | 470 Ω to pin 4 |
| 4 (2Y) | crystal leg B; pin 5 |
| 5 (3A) | pin 4 |
| 6 (3Y) | **10 MHz** → U6 pin 2 (CLK) |
| 9, 11, 13 | GND (unused inputs) |
| 7 / 14 | GND / +5 V, plus 100 nF |

If it won't start, try 330 Ω–1 kΩ for both resistors and 10–100 nF for the
coupling capacitor. Pull the crystal out to check: the output should stop. If
it keeps running, it is oscillating on the RC values instead of the crystal.

**Debugging without slowing the clock: single-step with RDY.** On the NMOS
6502, pulling RDY low freezes the CPU on its next read cycle while the clock
keeps running, so the internal state survives.

Single-cycle stepping:
- RDY to +5 V through 3.3 kΩ.
- A toggle switch "RUN/STEP" pulls RDY low.
- A debounced "STEP" button (your existing clock module's monostable output is ideal) briefly releases it.

The bus is then frozen, so you can read the address and data lines with LEDs or
the Arduino Mega. To step whole instructions instead, AND the step gate with
SYNC (pin 7) so the CPU halts only on opcode fetches.

Writes don't halt under RDY on the NMOS part; the CPU stops on the next read,
which is fine for debugging.

---

## SPI throughput (why the clock must go up for the game)

Bit-bang loop per bit: build the value, `STA $8000` (SCL low), `ORA #2`, then
`STA $8000` (SCL high). That is about **25 cycles per bit, or 200 cycles per
byte**.

| Task | Bytes | @ 1 kHz | @ 1 MHz |
|---|---|---|---|
| Init sequence (~30 bytes) | 30 | ~6 s | 6 ms |
| 16×16 test square (RGB565) | 512 | ~100 s | 0.1 s |
| Full-screen fill | 153,600 | **8.5 h** | **~31 s** |
| Bird 8×8, erase + draw | 256 | 51 s | 51 ms |

Where this leaves each phase:

- **Phase 3 bring-up at 1 kHz:** init plus one small square is practical.
- **Full-colour fills:** need the 1 MHz oscillator. Solid black and white can use a faster loop (`STX/STY` toggling only SCL, about 8 cycles per bit), so a full-screen fill takes about 10 s at 1 MHz.
- **Game:** needs at least 1 MHz, with a black background, small sprites, a reduced play area, and redrawing only the pixel columns that change. If the frame rate is still too low, add a hardware shifter (74HC165 plus a 74LS161 counter clocked from PHI2, about 8 cycles per byte instead of 200).

## Game optimisations taken from `guide` (the x86 512-byte attempt)

| `guide` trick | What we do here |
|---|---|
| Slide the whole screen 1 px left each frame and paint one new column (`rep movsb`) | **Use the ST7789's hardware vertical scroll.** Commands: `VSCRDEF 0x33` defines the area, `VSCSAD 0x37` sets the start line. Mount the panel in landscape so its 320-line axis runs horizontally. One scroll step is about 3 command bytes, with no pixel copying. *(Confirm once the controller is identified.)* |
| Pipes every 128 px, so the column counter mod 128 gives the phase | Choose a pipe period that **divides 320** (80 or 160). Then the line that wraps around already holds a pipe or sky in the same place. Sky lines need **zero** pixel writes. Pipe lines only need the old gap filled in (pipe colour) and the new gap cut out (sky), about 2 × gap height pixels. |
| Ground stripes drawn from the column counter | Draw the ground once at start-up. It sits inside every scroll line, so it scrolls for free. |
| Y in 1/256 px (8.8): high byte = screen row, no division | Same: `y` is 2 bytes, gravity is added to `vy`, `vy` is added to `y`. |
| No score variable: score = column counter >> 7 | Same idea: score = column counter ÷ pipe period. With period 128 this would be a shift, but 128 does not divide 320. With period 80 or 160, keep a tiny pipe counter instead. Digits need a font, which costs bytes; decide in Phase 4. |
| Collision by reading pixels from the hidden buffer | **Not possible**: we have no MISO, and the ST7789 cannot be read back over this wiring. Use geometry instead: if the pipe phase overlaps the bird's column and `y` is outside `gap`, the bird is dead. This costs a few bytes because there is only one pipe near the bird. |
| Bird drawn on top, outside the scrolled buffer | The bird stays at a fixed screen x while the GRAM scrolls under it. Each frame, repaint 1 column of bird colour at its right edge, 1 column of sky at its left edge, plus `dy` rows top and bottom. That is about 50 px (~20k cycles at 1 MHz). Behind a live bird there is always sky, so no save/restore is needed. |
| Random gap from the PIT counter | No timer here. Use an 8-bit LFSR, or mix in the frame counter and the cycle count until the first press. |
| Start with the world pre-drawn, the bird hanging until the first flap | Same: skip gravity until the first press. |

Estimated cost per frame at 1 MHz with bit-banged SPI:

| Frame type | Cycles | Frame rate |
|---|---|---|
| Sky line | ~25k | ~40 fps |
| Pipe line | ~70k | ~14 fps |

Unlike the full-repaint numbers in the throughput table, this is **playable**,
which makes a hardware SPI shifter optional.

**Clock correction:** the CPU now runs at **625 kHz** (or 1.25 MHz), not
1 kHz. Multiply the "@ 1 MHz" figures by 1.6 at 625 kHz.

| Item | @ 625 kHz |
|---|---|
| Display init + test square | well under 1 s |
| Full-screen fill | ~50 s |
| Game, sky frames | ~25 fps |
| Game, pipe frames | ~9 fps |

1.25 MHz roughly doubles those rates.

## Gamepad input port (up to 4 buttons, later; uses parts already owned)

This uses the 74HC245 as a read-only input port at `$8000`. It shares the
address with the LCD latch: writes go to the latch, reads come from the buttons.

The decode uses a **second 74HC00 (U7)**:

| Gate | Function | Output → |
|---|---|---|
| G5 | `IOSEL = NAND(/IOSEL, /IOSEL)` (the inverse of U4 pin 6) | G6 input |
| G6 | `/IORD = NAND(IOSEL, R/W)` | 74HC245 pin 19 `/OE` |

`/IORD` is low only on reads in `$8000–$BFFF`.

74HC245 wiring:

| Pin | Connect to |
|---|---|
| 1 DIR | +5 V (A → B) |
| 2–5 A1–A4 | buttons: each has a 10 kΩ pull-up and switches to GND (reads 0 when pressed). Bit 0 = FLAP/A, bit 1 = UP, bit 2 = DOWN, bit 3 = START |
| 6–9 A5–A8 | +5 V (unused) |
| 18…11 B1…B8 | CPU D0…D7 |
| 19 /OE | U7 G6 output |
| 10 / 20 | GND / +5 V, plus 100 nF |

Reading the buttons:

```
lda $8000
eor #$FF
```

After this, a 1 bit means pressed. Polling once per frame debounces the
buttons, so no RC network is needed. The NMI and SOB button wiring is then
optional. U7's two spare gates can build the SYNC AND-gate for instruction
stepping.

## Resolved (2026-10-22)

- CPU: Rockwell R6502P (NMOS).
- 74HC00 and inverters (74x04) are on hand.
- LCD I/O pins are 5 V capable, so they wire directly to U5.
- Clock: 10 MHz can ÷16 via a 74LS161 for running. The 1 kHz module is reused as the RDY step-button source.

## Open items

1. **SRAM (option A) or 2× 74LS189 + 2× 74x04 (option B)?** With an NMOS CPU, the 189's LS output levels are no longer a concern (V_IH = 2.0 V).
2. LCD datasheet or listing: the controller (ST7789?), what `EN` does, and whether hardware scrolling (`0x33`/`0x37`) is supported.
3. Confirm the SRAM marking and pinout (only if option A).

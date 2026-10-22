# Handoff: W65C02 + 28C64 + SmartElex SPI IPS Flappy Bird

## Mission

Design a minimalist, standalone Flappy Bird-style game running on a **W65C02** CPU with a **28C64 EEPROM**, driving a **SmartElex 2-inch 240 × 320 SPI IPS TFT**. The target is an extremely small 6502 program—ideally **512 bytes of assembled machine code**—with plain graphics and one button.

This handoff is for the next agent to continue the engineering design from the hardware upward. Do not jump straight into game code.

## User's required order of work

Follow this order strictly:

1. **Define the W65C02 memory/address space** with the 28C64 EEPROM, including reset/interrupt vectors and address decoding.
2. **Choose all required ICs and settle the complete hardware architecture** before wiring. Minimise chip count, but do not omit components required for a reliable design.
3. **Bring up the display** by implementing its initialisation sequence and drawing solid RGB colour(s) on the screen. Verify the SPI interface before writing the game.
4. Only after display bring-up works, design and implement the tiny game.

## Existing hardware / constraints

Known to be available:
- W65C02 CPU (user has referred to W65C02 / W65C02S; verify exact part and supply voltage)
- 28C64 EEPROM
- 74HC245 bus transceiver
- Breadboards and basic wiring
- A clock source / circuit configurable in **astable and bistable modes**, with a maximum of about **1 kHz initially**. User wants this slow clock to step through instructions and debug. Clock speed can be increased later.
- SmartElex 2-inch IPS TFT module with pins: `VCC, GND, EN, DC, SCL, CS, TE, RST, SDA`
- One physical game button is intended for start/flap input.
- Arduino Mega has been considered for monitoring/debugging, but **must not run the game**. Treat it as optional instrumentation only; do not add it to the runtime architecture unless there is a clear reason.

Confirmed by user (2026-10-22) — see `hardware_plan.md` for the resulting Phase 1/2 design:
- SRAM is available: HY62CT08081E-D70C (32K×8, 70 ns). It will be used; 74LS189s were evaluated and rejected.
- 74HC245 will be omitted. 74LS161 counters are available (one is used as the LCD output latch).
- EEPROM is AT28C64B-15, programmed via the Nano28C64 programmer from an 8 KiB `.bin`/`.hex`.
- Single button: game auto-starts on boot, button = flap only (wired to NMI).
- User has confirmed the LCD pins run at 5 V.
- **CPU is a Rockwell R6502P (NMOS 6502, 1 MHz grade), not a W65C02S.** It needs ≥ ~100 kHz, so it cannot run at 1 kHz; clock it from a 10 MHz can ÷16 (625 kHz) and debug by single-stepping with RDY. Use only the original NMOS instruction set (no 65C02 opcodes).
- 74HC00 and 74x04 inverters are on hand.

Not yet confirmed:
- Exact W65C02 variant and operating voltage.
- Exact SmartElex SKU/controller. A likely match is the SmartElex LHS200KP-IF05 with ST7789P3 controller and 4-wire SPI, but this is **not confirmed** solely from brand, resolution and pin names. Verify against the module label/listing/datasheet before committing the driver.
- Exact function and electrical requirements of `EN`; do not assume it means backlight enable without documentation.
- Display logic voltage and whether the board includes a regulator/level shifters.

## Design goals

- Standalone game executed by W65C02; no Arduino/Raspberry Pi/second processor running graphics.
- 28C64 stores the firmware; total ROM is 8 KiB, but preferred assembled game executable target is **512 bytes** if realistically achievable.
- No full framebuffer in CPU RAM. Use the display controller's internal GRAM and draw simple regions/pixels directly.
- Plain graphics: solid background, block bird, block pipes, no textures, no sound, no elaborate font/menu.
- One button: start, flap, and restart.
- First display milestone: initialisation sequence, then fill the display with a known RGB565 colour (and ideally test several colours / solid rectangles).
- Slow 1 kHz clock for bring-up and single-step/debug. Ensure all timing assumptions are compatible with this clock; distinguish CPU clock timing from SPI clock timing.
- Minimise added ICs without compromising bus correctness, reset behaviour, electrical compatibility, or display protocol requirements.

## Critical engineering cautions

1. **The 28C64 is 8 KiB, not 512 KiB.** The 512-byte target refers to the desired program size, not total capacity.
2. A W65C02 needs valid reset/interrupt vector placement and a correct address map. The 28C64's 13 address inputs must be mapped deliberately; determine whether it will occupy the top 8 KiB (`$E000–$FFFF`) or another range. For a simple 6502 map, top-of-memory placement is often convenient because reset/IRQ/NMI vectors live at `$FFFA–$FFFF`, but decode logic must ensure ROM appears at those addresses.
3. **Do not assume the CPU can run from EEPROM alone.** A 6502 normally needs writable memory for stack and variables. Plan for SRAM or a carefully justified minimal alternative. A 512-byte program does not remove the need for writable RAM.
4. The W65C02 does not provide a native SPI peripheral. Decide whether to use a W65C22 VIA (if selected/available), discrete latches/shift registers/counters, or software bit-banging. Compare chip count, code size, wiring complexity, and throughput. A 74HC595 alone is not a complete SPI controller; clocking, byte loading and control still need a design.
5. A 240 × 320 RGB565 full framebuffer would require 153,600 bytes, so do not plan to store one in the CPU. Landscape logical dimensions may be 320 × 240 depending on the controller's rotation support.
6. SPI LCD controller commands are not enough to identify the exact module. Verify the controller (likely ST7789P3 only if the SKU/datasheet matches), reset/init requirements, SPI mode, maximum SPI clock, RGB/BGR order, offsets, and `EN` pin behaviour.
7. Check voltage compatibility. Many TFT modules use 3.3 V logic. Do not directly apply 5 V signals to display inputs unless the module explicitly supports it. Confirm the CPU voltage and choose suitable level shifting/buffering.
8. The display may require long serial transfers to fill the screen. At a 1 kHz **CPU** clock, a software SPI driver will be extremely slow if it toggles each SPI bit in CPU instructions. Keep initial testing simple (e.g. small rectangle / solid-colour area), and calculate expected transfer time. Do not confuse the manual CPU clock with the SPI bit clock; hardware SPI clocking can potentially be faster if the design supports it.
9. Ensure the CPU clock circuit's astable/bistable modes have safe logic levels, a clean reset, and no accidental clock glitches when switching modes. Provide a reliable reset circuit and a safe manual single-step scheme if applicable.
10. Treat `TE` as optional initially. Do not connect it unless the design needs tearing synchronisation.

## Required deliverables from the next agent

### Phase 1 — Address map and CPU minimum system
Provide:
- Proposed memory map with exact address ranges.
- 28C64 wiring and mapping, including A0–A12, D0–D7, `/CE`, `/OE`, `/WE`.
- Address decoder design using minimal practical logic ICs.
- Correct reset, IRQ, NMI vector considerations.
- Minimum RAM recommendation and exact address range.
- Read/write control and bus timing notes appropriate for W65C02 and EEPROM.
- Explain whether the existing 74HC245 is needed and how its direction/output-enable are controlled; avoid bus contention.

### Phase 2 — Complete IC/BOM and architecture
Provide:
- Every IC required, purpose, voltage, and whether it is already owned or a new purchase.
- Exact connections for CPU, ROM, RAM, decoder, display interface, button, reset and clock.
- Decide and justify among VIA, discrete SPI hardware, or software SPI.
- Safe voltage-level strategy for all display signals.
- Pin-by-pin wiring tables; do not skip grounds, decoupling capacitors, pull-ups/pull-downs or reset circuitry.
- Keep hardware minimal but robust and breadboard-buildable.

### Phase 3 — Display bring-up
Provide:
- Verified controller and datasheet references (do not state ST7789P3 as certain until confirmed).
- Minimal reset and initialisation command sequence for the actual controller/module.
- SPI mode, bit order, data/command control, chip-select behaviour, RGB565 pixel format, row/column address windows, orientation/offsets, and any module-specific setup.
- Minimal test firmware that fills the screen with a known RGB565 colour; then test at least red, green, blue, black and white if practical.
- Assembled byte count for this test program and the split between initialisation code and test fill routine.
- Expected run time at the initial 1 kHz CPU clock; identify any need for hardware-assisted SPI to make full-screen tests practical.

### Phase 4 — Game (only after the display works)
Provide:
- A 512-byte feasibility assessment based on the chosen SPI interface.
- Minimal game design, RAM variables, state machine and button debounce strategy.
- Actual assembler source and build steps, with exact assembled size.
- If 512 bytes is not realistic, report the smallest verified build and explain what prevents 512 bytes. Do not claim a byte count without assembling it.
- Keep graphics block-based and avoid a framebuffer.

## Working style

- Work incrementally and state assumptions explicitly.
- Do not invent the display controller or pin electrical behaviour.
- Do not start with game source code before the address map, BOM, and display bring-up plan are settled.
- Prefer datasheets and verified timing/electrical specifications over guesses.
- Do not add a microcontroller to run the game.
- Keep the user's stated order of operations: **address space → complete hardware/ICs → RGB display initialisation → game**.

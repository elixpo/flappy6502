#!/usr/bin/env python3
"""Generate hardware/flappy6502.kicad_sch: the full working build as a KiCad schematic.

Every pin gets a short stub and a net label (same label = same net), so no wire ever
crosses a part and labels sit outside the symbol bodies. Unused pins get no-connect flags.

    uv run --with kiutils python tools/gen_schematic.py
    kicad-cli sch erc hardware/flappy6502.kicad_sch
"""
from copy import deepcopy
from math import cos, radians, sin
from pathlib import Path
from uuid import NAMESPACE_URL, uuid5

from kiutils.items.common import Effects, Font, Justify, PageSettings, Position, Property, TitleBlock
from kiutils.items.schitems import (Connection, LocalLabel, NoConnect, SchematicSymbol,
                                    SymbolProjectInstance, SymbolProjectPath, Text)
from kiutils.schematic import Schematic
from kiutils.symbol import SymbolLib

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "hardware" / "flappy6502.kicad_sch"
PROJECT = "flappy6502"
LIB = "/usr/share/kicad/symbols/{}.kicad_sym"
G = 2.54


def uid(s):
    return str(uuid5(NAMESPACE_URL, f"flappy6502/{s}"))


def eff(size=1.27, hide=False, bold=False, left=False):
    return Effects(font=Font(height=size, width=size, bold=bold), hide=hide,
                   justify=Justify(horizontally="left") if left else Justify())


# ---- custom R6502 symbol (DIP-40, pin 1 top-left, pin 40 top-right) ----
R6502_PINS = ["VSS", "RDY", "PHI1", "~{IRQ}", "NC", "~{NMI}", "SYNC", "VCC",
              "A0", "A1", "A2", "A3", "A4", "A5", "A6", "A7", "A8", "A9", "A10", "A11",
              "VSS", "A12", "A13", "A14", "A15", "D7", "D6", "D5", "D4", "D3",
              "D2", "D1", "D0", "R/~{W}", "NC", "NC", "PHI0", "SO", "PHI2", "~{RES}"]


def r6502_lib(path):
    pins = []
    for n, name in enumerate(R6502_PINS, 1):
        if n <= 20:
            x, y, a = -15.24, 24.13 - (n - 1) * G, 0
        else:
            x, y, a = 15.24, 24.13 - (40 - n) * G, 180
        kind = "power_in" if name in ("VSS", "VCC") else "bidirectional"
        pins.append(f'(pin {kind} line (at {x} {y:.2f} {a}) (length 5.08) '
                    f'(name "{name}" (effects (font (size 1.27 1.27)))) '
                    f'(number "{n}" (effects (font (size 1.27 1.27)))))')
    path.write_text(
        '(kicad_symbol_lib (version 20231120) (generator "flappy6502")\n'
        ' (symbol "R6502" (in_bom yes) (on_board yes)\n'
        '  (property "Reference" "U" (at 0 27.94 0) (effects (font (size 1.27 1.27))))\n'
        '  (property "Value" "R6502" (at 0 -27.94 0) (effects (font (size 1.27 1.27))))\n'
        '  (symbol "R6502_0_1" (rectangle (start -10.16 26.67) (end 10.16 -26.67)'
        ' (stroke (width 0.254) (type default)) (fill (type background))))\n'
        '  (symbol "R6502_1_1" ' + " ".join(pins) + ')))\n')


def load(lib, entry, path=None):
    symbols = SymbolLib.from_file(path or LIB.format(lib)).symbols
    s = deepcopy(next(x for x in symbols if x.entryName == entry))
    s.libraryNickname = lib
    return s


class Sheet:
    def __init__(self):
        self.sch = Schematic.create_new()
        self.sch.version = 20231120
        self.sch.generator = "flappy6502"
        self.sch.uuid = uid("root")
        self.sch.paper = PageSettings(paperSize="A2")
        self.sch.titleBlock = TitleBlock(title="flappy6502 - R6502 Flappy Bird breadboard computer",
                                         date="2026-10-27", revision="1",
                                         comments={1: "Label-based nets: same label = same net",
                                                   2: "Final working build (bit-banged SPI, flappy_bb.bin)"})
        self.libs = {}

    def place(self, sym, ref, value, x, y, nets, unit=None):
        """Place one unit; nets = {pin number: net name or None for no-connect}."""
        key = f"{sym.libraryNickname}:{sym.entryName}"
        if key not in self.libs:
            self.libs[key] = sym
            self.sch.libSymbols.append(sym)
        x, y = round(x / G) * G, round(y / G) * G
        units = [u for u in sym.units if u.unitId in (0, unit or 1)]
        tag = f"{ref}-{unit or 1}"
        ys = [p.position.Y for u in units for p in u.pins] or [0]
        upright = all((p.position.angle or 0) % 180 == 90 for u in units for p in u.pins)
        hide = ref.startswith("#")
        if upright:                                  # 2-pin vertical part: text to its right
            rpos, vpos, side = Position(x + 3, y - 1.3, 0), Position(x + 3, y + 1.3, 0), True
        else:                                        # above / below the pin stubs
            rpos, vpos, side = Position(x, y - max(ys) - 5, 0), Position(x, y - min(ys) + 5, 0), False
        props = [Property("Reference", ref, position=rpos, effects=eff(1.5, hide, True, side)),
                 Property("Value", value, position=vpos, effects=eff(1.27, hide, left=side)),
                 Property("Footprint", "", position=Position(x, y, 0), effects=eff(hide=True)),
                 Property("Datasheet", "", position=Position(x, y, 0), effects=eff(hide=True))]
        pins = {}
        for u in units:
            for p in u.pins:
                pins[p.number] = uid(f"{tag}-pin-{p.number}")
        self.sch.schematicSymbols.append(SchematicSymbol(
            libraryNickname=sym.libraryNickname, entryName=sym.entryName,
            position=Position(x, y, 0), unit=unit or 1, inBom=True, onBoard=True,
            uuid=uid(tag), properties=props, pins=pins,
            instances=[SymbolProjectInstance(name=PROJECT, paths=[
                SymbolProjectPath(f"/{self.sch.uuid}", ref, unit or 1)])]))
        for u in units:
            for p in u.pins:
                px, py = x + p.position.X, y - p.position.Y
                a = radians(p.position.angle or 0)
                ox, oy = -round(cos(a)), round(sin(a))      # outward, schematic y down
                net = nets.get(p.number, "NC")
                if net is None or net == "NC":
                    self.sch.noConnects.append(NoConnect(position=Position(px, py),
                                                         uuid=uid(f"nc-{tag}-{p.number}")))
                    continue
                ex, ey = px + ox * G, py + oy * G
                self.sch.graphicalItems.append(Connection(
                    type="wire", points=[Position(px, py), Position(ex, ey)],
                    uuid=uid(f"w-{tag}-{p.number}")))
                ang = {(1, 0): 0, (-1, 0): 180, (0, -1): 90, (0, 1): 270}[(ox, oy)]
                self.sch.labels.append(LocalLabel(text=net, position=Position(ex, ey, ang),
                                                  effects=eff(1.0), uuid=uid(f"l-{tag}-{p.number}")))

    def note(self, text, x, y, size=1.5, bold=False):
        self.sch.texts.append(Text(text=text, position=Position(x, y, 0),
                                   effects=eff(size, bold=bold, left=True), uuid=uid(f"t-{text}-{x}-{y}")))


def two(sh, sym, ref, value, x, y, a, b):
    sh.place(sym, ref, value, x, y, {"1": a, "2": b})


def main():
    tmp = ROOT / "build" / "r6502.kicad_sym"
    tmp.parent.mkdir(exist_ok=True)
    r6502_lib(tmp)
    cpu = load("flappy6502", "R6502", tmp)
    rom = load("Memory_EEPROM", "KM28C64A")
    ram = load("Memory_RAM", "KM62256CLP")
    nand = load("74xx", "74LS00")
    inv = load("74xx", "74LS04")
    cnt = load("74xx", "74LS161")
    R, C, CP = load("Device", "R"), load("Device", "C"), load("Device", "C_Polarized")
    xtal, sw = load("Device", "Crystal"), load("Switch", "SW_Push")
    lcd, pwr = load("Connector_Generic", "Conn_01x09"), load("Connector_Generic", "Conn_01x02")

    sh = Sheet()
    A = {f"A{i}": f"A{i}" for i in range(16)}
    D = {f"D{i}": f"D{i}" for i in range(8)}

    # CPU (custom symbol, pins by number)
    cpu_nets = {"1": "GND", "2": "RDY", "3": None, "4": "~{IRQ}", "5": None, "6": "~{NMI}",
                "7": None, "8": "+5V", "21": "GND", "34": "R~{W}", "35": None, "36": None,
                "37": "PHI0", "38": "SO", "39": "PHI2", "40": "~{RES}"}
    for n in range(9, 21):
        cpu_nets[str(n)] = f"A{n - 9}"
    for n, a in zip(range(22, 26), (12, 13, 14, 15)):
        cpu_nets[str(n)] = f"A{a}"
    for n in range(26, 34):
        cpu_nets[str(n)] = f"D{33 - n}"
    sh.place(cpu, "U1", "R6502 (NMOS)", 75, 95, cpu_nets)

    # 28C64 EEPROM and 62256 SRAM: same address/data pinout
    mem = {"2": "A12", "3": "A7", "4": "A6", "5": "A5", "6": "A4", "7": "A3", "8": "A2",
           "9": "A1", "10": "A0", "11": "D0", "12": "D1", "13": "D2", "14": "GND", "15": "D3",
           "16": "D4", "17": "D5", "18": "D6", "19": "D7", "21": "A10", "23": "A11",
           "24": "A9", "25": "A8", "28": "+5V"}
    sh.place(rom, "U2", "AT28C64B-15 ($E000-$FFFF)", 175, 95,
             {**mem, "1": None, "20": "~{ROMCS}", "22": "WR", "26": None, "27": "+5V"})
    sh.place(ram, "U3", "HY62CT08081E ($0000-$7FFF)", 270, 95,
             {**mem, "1": "A14", "20": "A15", "22": "WR", "26": "A13", "27": "~{WSTB}"})

    # 74LS00 decoder
    dec = [("1", "2", "3", "A15", "A14", "~{ROMCS}"), ("4", "5", "6", "A15", "~{ROMCS}", "~{IOSEL}"),
           ("9", "10", "8", "R~{W}", "R~{W}", "WR"), ("12", "13", "11", "PHI2", "WR", "~{WSTB}")]
    for u, (i1, i2, o, n1, n2, no) in enumerate(dec, 1):
        sh.place(nand, "U4", "74LS00 decoder", 45 + (u - 1) * 45, 190, {i1: n1, i2: n2, o: no}, unit=u)
    sh.place(nand, "U4", "74LS00", 230, 190, {"14": "+5V", "7": "GND"}, unit=5)

    # 74LS161 LCD latch at $8000
    sh.place(cnt, "U5", "74LS161 LCD latch ($8000)", 370, 95,
             {"1": "~{RES}", "2": "~{WSTB}", "3": "D0", "4": "D1", "5": "D2", "6": "D3",
              "7": "GND", "10": "GND", "9": "~{IOSEL}", "14": "LCD_SDA", "13": "LCD_SCL",
              "12": "LCD_DC", "11": "LCD_CS", "15": None, "16": "+5V", "8": "GND"})

    # 74LS161 clock divider: 10 MHz / 8 = 1.25 MHz on QC (QD = 625 kHz)
    sh.place(cnt, "U6", "74LS161 clock divider", 300, 195,
             {"1": "+5V", "2": "CLK10M", "3": "GND", "4": "GND", "5": "GND", "6": "GND",
              "7": "+5V", "10": "+5V", "9": "+5V", "14": None, "13": None, "12": "PHI0",
              "11": None, "15": None, "16": "+5V", "8": "GND"})

    # 74LS04: crystal oscillator (3 inverters) + LCD RST/EN driver (2 inverters)
    osc = [(1, "1", "2", "~{RES}", "RSTB"), (2, "3", "4", "RSTB", "LCD_RST"),
           (3, "5", "6", "GND", None), (4, "9", "8", "OSC_A", "OSC_B"),
           (5, "11", "10", "OSC_C", "OSC_D"), (6, "13", "12", "OSC_D", "CLK10M")]
    for i, (u, a, y, na, ny) in enumerate(osc):
        sh.place(inv, "U7", "74LS04", 45 + i * 45, 265, {a: na, y: ny}, unit=u)
    sh.place(inv, "U7", "74LS04", 320, 265, {"14": "+5V", "7": "GND"}, unit=7)
    two(sh, R, "R1", "560", 45, 315, "OSC_A", "OSC_B")
    two(sh, C, "C1", "100n", 70, 315, "OSC_B", "OSC_C")
    two(sh, R, "R2", "560", 95, 315, "OSC_C", "OSC_D")
    two(sh, xtal, "Y1", "10 MHz", 125, 315, "OSC_A", "OSC_D")

    # pull-ups, reset, flap button
    for i, (ref, net) in enumerate((("R3", "RDY"), ("R4", "~{IRQ}"), ("R5", "~{NMI}"), ("R6", "SO"))):
        two(sh, R, ref, "3.3k", 170 + i * 25, 315, "+5V", net)
    two(sh, R, "R7", "10k", 280, 315, "+5V", "~{RES}")
    two(sh, CP, "C2", "10u", 305, 315, "~{RES}", "GND")
    two(sh, sw, "SW1", "RESET", 335, 315, "~{RES}", "GND")
    two(sh, C, "C3", "100n", 370, 315, "~{NMI}", "GND")
    two(sh, sw, "SW2", "FLAP", 400, 315, "~{NMI}", "GND")
    two(sh, C, "C4", "10p", 435, 315, "~{WSTB}", "GND")      # at latch pin 2: kills ringing

    # LCD module (SmartElex LHS200KP-IF05, ST7789P3): no 5 V into its inputs
    sh.place(lcd, "J1", "LCD (SmartElex ST7789P3)", 470, 95,
             {"1": "LCD_SDA", "2": "LCD_RST", "3": None, "4": "LCD_CS", "5": "LCD_SCL",
              "6": "LCD_DC", "7": "LCD_RST", "8": "GND", "9": "+5V"})
    two(sh, CP, "C5", "10u", 500, 95, "+5V", "GND")
    two(sh, C, "C6", "100n", 525, 95, "+5V", "GND")

    # power in + decoupling
    sh.place(pwr, "J2", "5V 2A in", 400, 195, {"1": "+5V", "2": "GND"})
    flag = load("power", "PWR_FLAG")
    sh.place(flag, "#FLG1", "PWR_FLAG", 480, 195, {"1": "+5V"})
    sh.place(flag, "#FLG2", "PWR_FLAG", 505, 195, {"1": "GND"})
    two(sh, CP, "C7", "470u", 430, 195, "+5V", "GND")
    two(sh, CP, "C8", "10u", 455, 195, "+5V", "GND")
    for i in range(7):
        two(sh, C, f"C{9 + i}", "100n", 45 + i * 25, 365, "+5V", "GND")

    sh.note("J1 pins: 1 SDA 2 RST 3 TE 4 CS 5 SCL 6 DC 7 EN 8 GND 9 VCC", 440, 140)
    sh.note("flappy6502 - R6502 + 28C64 + 32K SRAM + 74LS logic -> ST7789 LCD (bit-banged SPI)",
            20, 15, 2.5, True)
    sh.note("Memory map: RAM $0000-$7FFF, LCD latch $8000 (bit0 SDA, bit1 SCL, bit2 DC, bit3 CS), "
            "ROM $E000-$FFFF", 20, 22)
    sh.note("CPU clock PHI0 = U6 QC (1.25 MHz) or QD pin 11 (625 kHz). C4 sits at U5 pin 2.", 20, 27)
    sh.note("LCD rule: never feed the module 5 V; RST and EN come from U7 (low during reset).", 20, 32)
    sh.note("Decoupling: C9-C15 100n at each IC (U1-U7); C8 10u at the CPU.", 45, 345)
    sh.sch.to_file(OUT)
    print(f"wrote {OUT}")


if __name__ == "__main__":
    main()

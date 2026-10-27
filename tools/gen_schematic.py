#!/usr/bin/env python3
"""Generate hardware/flappy6502.kicad_sch: the full working build on one A3 sheet,
every connection drawn as a wire.

Layout: parts in evenly spaced rows. Under each row is a channel with one horizontal
track per net. Each side pin leaves on its own lane (the top pin farthest out, so a
side's lanes never cross that side's leads), then drops straight to its track. Nets
used in several rows join through vertical risers in the free left margin. Up/down
power pins use +5V/GND symbols, and each channel's +5V/GND tracks carry one symbol
each. No wire passes through a part, and all text sits outside the parts.

    uv run --with kiutils python tools/gen_schematic.py
    (prints the ERC summary and a pin-by-pin netlist check)
"""
import re
import subprocess
from copy import deepcopy
from math import cos, radians, sin
from pathlib import Path
from uuid import NAMESPACE_URL, uuid5

from kiutils.items.common import Effects, Font, Justify, PageSettings, Position, Property, TitleBlock
from kiutils.items.schitems import (BusEntry, Connection, Junction, LocalLabel, NoConnect, SchematicSymbol,
                                    SymbolProjectInstance, SymbolProjectPath, Text)
from kiutils.schematic import Schematic
from kiutils.symbol import SymbolLib

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "hardware" / "flappy6502.kicad_sch"
PROJECT = "flappy6502"
LIB = "/usr/share/kicad/symbols/{}.kicad_sym"
G, P = 2.54, 1.27                     # pin grid, lane/track pitch
POWER = ("+5V", "GND")
PAGE_W, PAGE_H = 420.0, 297.0         # A3


def uid(s):
    return str(uuid5(NAMESPACE_URL, f"flappy6502/{s}"))


def eff(size=1.27, hide=False, bold=False, just=None):
    return Effects(font=Font(height=size, width=size, bold=bold), hide=hide,
                   justify=Justify(horizontally=just) if just else Justify())


def snap(v, g=P):
    return round(round(v / g) * g, 3)


R6502_PINS = ["VSS", "RDY", "PHI1", "~{IRQ}", "NC", "~{NMI}", "SYNC", "VCC",
              "A0", "A1", "A2", "A3", "A4", "A5", "A6", "A7", "A8", "A9", "A10", "A11",
              "VSS", "A12", "A13", "A14", "A15", "D7", "D6", "D5", "D4", "D3",
              "D2", "D1", "D0", "R/~{W}", "NC", "NC", "PHI0", "SO", "PHI2", "~{RES}"]


def r6502_lib(path):
    """Custom DIP-40 R6502 symbol (KiCad ships no 6502)."""
    pins = []
    for n, name in enumerate(R6502_PINS, 1):
        x, y, a = (-15.24, 24.13 - (n - 1) * G, 0) if n <= 20 else (15.24, 24.13 - (40 - n) * G, 180)
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
    s = deepcopy(next(x for x in SymbolLib.from_file(path or LIB.format(lib)).symbols
                      if x.entryName == entry))
    s.libraryNickname = lib
    return s


class Part:
    """One placed unit: pins in local coords (y down) and its routing lanes."""

    def __init__(self, sym, ref, value, nets, unit=1):
        self.sym, self.ref, self.value, self.nets, self.unit = sym, ref, value, nets, unit
        self.pins = []
        for u in sym.units:
            if u.unitId in (0, unit):
                for p in u.pins:
                    a = radians(p.position.angle or 0)
                    self.pins.append((p.number, p.position.X, -p.position.Y, -round(cos(a)), round(sin(a))))
        self.lane = {}
        for side in (-1, 1):
            routed = sorted((p for p in self.pins if p[3] == side and nets.get(p[0])), key=lambda p: p[2])
            for r, p in enumerate(routed):
                self.lane[p[0]] = side * P * (len(routed) - r)
        xs = [p[1] + self.lane.get(p[0], 0) for p in self.pins]
        xs += [p[1] - 2 * G for p in self.pins if p[4] == -1 and nets.get(p[0]) not in POWER and nets.get(p[0])]
        body = [p[1] for p in self.pins]
        self.left = min(xs + [min(body) - G]) - P
        self.right = max(xs + [max(body) + G]) + P
        if all(p[3] == 0 for p in self.pins):          # upright 2-pin part: text on its right
            self.right += 9
        self.top = min(p[2] for p in self.pins) - (7 if any(p[4] == -1 for p in self.pins) else 3)
        self.bottom = max(p[2] for p in self.pins) + (6 if any(p[4] == 1 for p in self.pins) else 1)

    @property
    def width(self):
        return self.right - self.left


class Sheet:
    def __init__(self):
        sch = self.sch = Schematic.create_new()
        sch.version, sch.generator, sch.uuid = 20231120, "flappy6502", uid("root")
        sch.paper = PageSettings(paperSize="A3")
        sch.titleBlock = TitleBlock(
            title="flappy6502 - R6502 Flappy Bird breadboard computer", date="2026-10-27", revision="3",
            comments={1: "Map: RAM $0000-7FFF, LCD latch $8000 (b0 SDA b1 SCL b2 DC b3 CS), ROM $E000-FFFF",
                      2: "Clock: 10 MHz crystal on U7 -> U6 /8 = 1.25 MHz PHI0 (U6 pin 11 = 625 kHz)",
                      3: "LCD never fed 5 V (RST/EN from U7). C4 10p at U5 pin 2. C9-C15: 100n per IC",
                      4: "All connections drawn; risers at left join rows; dots = junctions. roms/flappy_bb.bin"})
        self.libs, self.n = set(), 0

    def symbol(self, sym, ref, value, x, y, unit=1, angle=0, show=True, ref_at=None, val_at=None, side=False):
        key = f"{sym.libraryNickname}:{sym.entryName}"
        if key not in self.libs:
            self.libs.add(key)
            self.sch.libSymbols.append(sym)
        self.n += 1
        tag = f"{ref}-{unit}-{self.n}"
        rx, ry = ref_at or (x, y)
        vx, vy = val_at or (x, y)
        props = [Property("Reference", ref, position=Position(rx, ry, 0), effects=eff(1.27, not show, True, "left")),
                 Property("Value", value, position=Position(vx, vy, 0), effects=eff(1.0, not show, just="left")),
                 Property("Footprint", "", position=Position(x, y, 0), effects=eff(hide=True)),
                 Property("Datasheet", "", position=Position(x, y, 0), effects=eff(hide=True))]
        pins = {p.number: uid(f"{tag}-{p.number}") for u in sym.units if u.unitId in (0, unit) for p in u.pins}
        self.sch.schematicSymbols.append(SchematicSymbol(
            libraryNickname=sym.libraryNickname, entryName=sym.entryName,
            position=Position(x, y, angle), unit=unit, inBom=not ref.startswith("#"),
            onBoard=not ref.startswith("#"), uuid=uid(tag), properties=props, pins=pins,
            instances=[SymbolProjectInstance(name=PROJECT, paths=[SymbolProjectPath(f"/{self.sch.uuid}", ref, unit)])]))

    def wire(self, *pts):
        pts = [(round(x, 3), round(y, 3)) for x, y in pts]
        for a, b in zip(pts, pts[1:]):
            if a != b:
                self.n += 1
                self.sch.graphicalItems.append(Connection(type="wire", points=[Position(*a), Position(*b)],
                                                          uuid=uid(f"w{self.n}")))

    def dot(self, x, y):
        self.n += 1
        self.sch.junctions.append(Junction(position=Position(round(x, 3), round(y, 3)), uuid=uid(f"j{self.n}")))

    def note(self, text, x, y, size=1.5, bold=False):
        self.n += 1
        self.sch.texts.append(Text(text=text, position=Position(x, y, 0), effects=eff(size, bold=bold, just="left"),
                                   uuid=uid(f"t{self.n}")))


def build_parts():
    tmp = ROOT / "build" / "r6502.kicad_sym"
    tmp.parent.mkdir(exist_ok=True)
    r6502_lib(tmp)
    cpu = load("flappy6502", "R6502", tmp)
    rom, ram = load("Memory_EEPROM", "KM28C64A"), load("Memory_RAM", "KM62256CLP")
    nand, inv, cnt = load("74xx", "74LS00"), load("74xx", "74LS04"), load("74xx", "74LS161")
    R, C, CP = load("Device", "R"), load("Device", "C"), load("Device", "C_Polarized")
    xtal, sw = load("Device", "Crystal"), load("Switch", "SW_Push")
    lcd, pwr = load("Connector_Generic", "Conn_01x09"), load("Connector_Generic", "Conn_01x02")

    cpu_nets = {"1": "GND", "2": "RDY", "4": "~{IRQ}", "6": "~{NMI}", "8": "+5V", "21": "GND",
                "34": "R~{W}", "37": "PHI0", "38": "SO", "39": "PHI2", "40": "~{RES}"}
    cpu_nets.update({str(n): f"A{n - 9}" for n in range(9, 21)})
    cpu_nets.update({str(n): f"A{a}" for n, a in zip(range(22, 26), (12, 13, 14, 15))})
    cpu_nets.update({str(n): f"D{33 - n}" for n in range(26, 34)})
    mem = {"2": "A12", "3": "A7", "4": "A6", "5": "A5", "6": "A4", "7": "A3", "8": "A2", "9": "A1",
           "10": "A0", "11": "D0", "12": "D1", "13": "D2", "14": "GND", "15": "D3", "16": "D4",
           "17": "D5", "18": "D6", "19": "D7", "21": "A10", "23": "A11", "24": "A9", "25": "A8", "28": "+5V"}
    two = lambda s, ref, val, a, b: Part(s, ref, val, {"1": a, "2": b})
    rows = [
        [Part(cpu, "U1", "R6502 (NMOS CPU)", cpu_nets),
         Part(rom, "U2", "AT28C64B ROM $E000", {**mem, "20": "~{ROMCS}", "22": "WR", "27": "+5V"}),
         Part(ram, "U3", "HY62C SRAM $0000", {**mem, "1": "A14", "20": "A15", "22": "WR", "26": "A13",
                                             "27": "~{WSTB}"}),
         two(R, "R3", "3.3k", "+5V", "RDY"), two(R, "R4", "3.3k", "+5V", "~{IRQ}"),
         two(R, "R5", "3.3k", "+5V", "~{NMI}"), two(R, "R6", "3.3k", "+5V", "SO"),
         Part(pwr, "J2", "5V in", {"1": "+5V", "2": "GND"}),
         two(CP, "C7", "470u", "+5V", "GND"), two(CP, "C8", "10u", "+5V", "GND"),
         two(CP, "C5", "10u", "+5V", "GND"), two(C, "C6", "100n", "+5V", "GND")],
        [Part(nand, "U4", "74LS00", {"1": "A15", "2": "A14", "3": "~{ROMCS}"}, 1),
         Part(nand, "U4", "74LS00", {"4": "A15", "5": "~{ROMCS}", "6": "~{IOSEL}"}, 2),
         Part(nand, "U4", "74LS00", {"9": "R~{W}", "10": "R~{W}", "8": "WR"}, 3),
         Part(nand, "U4", "74LS00", {"12": "PHI2", "13": "WR", "11": "~{WSTB}"}, 4),
         Part(nand, "U4", "74LS00", {"14": "+5V", "7": "GND"}, 5),
         Part(cnt, "U5", "74LS161 LCD latch $8000",
              {"1": "~{RES}", "2": "~{WSTB}", "3": "D0", "4": "D1", "5": "D2", "6": "D3", "7": "GND",
               "10": "GND", "9": "~{IOSEL}", "14": "LCD_SDA", "13": "LCD_SCL", "12": "LCD_DC",
               "11": "LCD_CS", "16": "+5V", "8": "GND"}),
         Part(lcd, "J1", "LCD ST7789P3",
              {"1": "LCD_SDA", "2": "LCD_RST", "4": "LCD_CS", "5": "LCD_SCL", "6": "LCD_DC",
               "7": "LCD_RST", "8": "GND", "9": "+5V"}),
         Part(cnt, "U6", "74LS161 clock /8",
              {"1": "+5V", "2": "CLK10M", "3": "GND", "4": "GND", "5": "GND", "6": "GND", "7": "+5V",
               "10": "+5V", "9": "+5V", "12": "PHI0", "16": "+5V", "8": "GND"}),
         Part(inv, "U7", "74LS04", {"1": "~{RES}", "2": "RSTB"}, 1),
         Part(inv, "U7", "74LS04", {"3": "RSTB", "4": "LCD_RST"}, 2),
         Part(inv, "U7", "74LS04", {"9": "OSC_A", "8": "OSC_B"}, 4),
         Part(inv, "U7", "74LS04", {"11": "OSC_C", "10": "OSC_D"}, 5),
         Part(inv, "U7", "74LS04", {"13": "OSC_D", "12": "CLK10M"}, 6)],
        [Part(inv, "U7", "74LS04", {"5": "GND"}, 3),
         Part(inv, "U7", "74LS04", {"14": "+5V", "7": "GND"}, 7),
         two(R, "R1", "560", "OSC_A", "OSC_B"), two(C, "C1", "100n", "OSC_B", "OSC_C"),
         two(R, "R2", "560", "OSC_C", "OSC_D"),
         Part(xtal, "Y1", "10 MHz", {"1": "OSC_A", "2": "OSC_D"}),
         two(R, "R7", "10k", "+5V", "~{RES}"), two(CP, "C2", "10u", "~{RES}", "GND"),
         Part(sw, "SW1", "RESET", {"1": "~{RES}", "2": "GND"}),
         two(C, "C3", "100n", "~{NMI}", "GND"), Part(sw, "SW2", "FLAP", {"1": "~{NMI}", "2": "GND"}),
         two(C, "C4", "10p", "~{WSTB}", "GND")]
        + [two(C, f"C{9 + i}", "100n", "+5V", "GND") for i in range(7)],   # power only: right end
    ]
    return rows


def main():
    rows = build_parts()
    p5v, pgnd, flag = load("power", "+5V"), load("power", "GND"), load("power", "PWR_FLAG")
    sh = Sheet()

    # nets used in more than one row (not power) get a riser in the left margin
    row_nets = [{n for p in row for n in p.nets.values() if n} for row in rows]
    multi = sorted({n for i, a in enumerate(row_nets) for n in a - set(POWER)
                    if any(n in b for j, b in enumerate(row_nets) if j != i)})
    x_riser0 = 16.0
    riser_x = {n: snap(x_riser0 + i * P) for i, n in enumerate(multi)}
    x_power = snap(x_riser0 + len(multi) * P + 4)      # power symbols just right of the risers
    x_start, x_end = x_power + 6, PAGE_W - 14

    # vertical budget: each row = parts band + channel; spread the spare space evenly
    def chan_nets(i):
        return {n for p in rows[i] for n in p.nets.values() if n}
    bands = [max(p.bottom for p in r) - min(p.top for p in r) for r in rows]
    def chan_tracks(i):
        nets = chan_nets(i)
        n = len(nets)
        for prefix in ("A", "D"):
            m = [x for x in nets if re.fullmatch(prefix + r"\d+", x) and x not in riser_x]
            if len(m) > 3:
                n += 3 - len(m)
        return n
    chans = [chan_tracks(i) * P + G for i in range(len(rows))]
    y_top, y_bot = 16.0, PAGE_H - 9
    spare = (y_bot - y_top - sum(bands) - sum(chans)) / (len(rows) + 1)
    assert spare > 0.2, f"rows do not fit on A3 (spare {spare:.1f} mm)"

    gapv = min(spare, 4.0)                             # compact rows; spare space ends up at the bottom
    y = y_top + gapv
    channel_y = []                                     # per row: {net: track y}
    drops_all = []
    for i, row in enumerate(rows):
        widths = sum(p.width for p in row)
        limit = x_end
        gap = (limit - x_start - widths) / (len(row) + 1)
        assert gap > 0, f"row {i + 1} too wide by {-gap * (len(row) + 1):.1f} mm"
        oy = snap(y - min(p.top for p in row), G)
        x = x_start + gap
        drops = {}
        for p in row:
            ox = snap(x - p.left, G)
            upright = all(q[3] == 0 for q in p.pins)
            if upright:
                ra, va = (ox + 2.5, oy - 1.0), (ox + 2.5, oy + 1.2)
            else:
                ra, va = (ox + p.left + P, oy + p.top + 0.5), (ox + p.left + P, oy + p.top + 2.3)
            if ox + p.right > PAGE_W - 190:            # keep clear of the title block
                assert oy + p.bottom < PAGE_H - 44, f"{p.ref} runs into the title block"
            sh.symbol(p.sym, p.ref, p.value, ox, oy, p.unit, ref_at=ra, val_at=va)
            bottom = oy + max(q[2] for q in p.pins)
            for num, lx, ly, dx, dy in p.pins:
                px, py = ox + lx, oy + ly
                net = p.nets.get(num)
                if not net:
                    sh.sch.noConnects.append(NoConnect(position=Position(px, py), uuid=uid(f"nc{p.ref}{p.unit}{num}")))
                    continue
                if dy and net in POWER:
                    s = p5v if net == "+5V" else pgnd
                    flip = (net == "+5V") != (dy == -1)
                    sh.symbol(s, f"#PWR{sh.n:03d}", net, px, py, angle=180 if flip else 0, show=False)
                elif dy == -1:                         # up: round the body on the left, then down
                    lane = px - 2 * G
                    sh.wire((px, py), (px, py - G), (lane, py - G), (lane, bottom + G))
                    drops.setdefault(net, []).append((lane, bottom + G))
                elif dy == 1:
                    drops.setdefault(net, []).append((px, py))
                else:
                    lane = px + p.lane[num]
                    sh.wire((px, py), (lane, py))
                    drops.setdefault(net, []).append((lane, py))
            x = ox + p.right + gap
        y = oy + max(p.bottom for p in row) + P
        # track order, top to bottom: +5V, local nets, multi-row nets (rightmost riser first), GND
        buses = {}                                     # row-local A/D members ride a bus
        for prefix in ("A", "D"):
            members = [n for n in drops if re.fullmatch(prefix + r"\d+", n) and n not in riser_x]
            if len(members) > 3:
                buses[prefix] = sorted(members, key=lambda n: int(n[1:]))
        on_bus = {n for m in buses.values() for n in m}
        local = sorted(n for n in drops if n not in POWER and n not in riser_x and n not in on_bus)
        inter = sorted((n for n in drops if n in riser_x), key=lambda n: -riser_x[n])
        bus_rows = list(buses)
        order = (["+5V"] if "+5V" in drops else []) + local + inter + (["GND"] if "GND" in drops else [])
        ty = {}
        k = 0
        for b in bus_rows:                             # bus lines first, 2 pitches apart
            ty["BUS_" + b] = snap(y + (k + 1) * P)
            k += 3
        for n in order:
            ty[n] = snap(y + k * P)
            k += 1
        for b, members in buses.items():
            yb = ty["BUS_" + b]
            xs = [px for m in members for px, _ in drops[m]]
            lo, hi = members[0][1:], members[-1][1:]
            self_bus = f"{b}[{lo}..{hi}]"
            sh.n += 1
            sh.sch.graphicalItems.append(Connection(type="bus", points=[Position(min(xs), yb),
                                                    Position(max(xs) + P / 2, yb)], uuid=uid(f"bus{sh.n}")))
            sh.n += 1
            sh.sch.labels.append(LocalLabel(text=self_bus, position=Position(min(xs), yb, 180),
                                            effects=eff(1.0), uuid=uid(f"lab{sh.n}")))
            for m in members:
                for px, py in drops[m]:
                    sh.wire((px, py), (px, yb - P))
                    sh.n += 1
                    sh.sch.busEntries.append(BusEntry(position=Position(px, yb - P), size=Position(P / 2, P),
                                                      uuid=uid(f"be{sh.n}")))
                    sh.n += 1
                    sh.sch.labels.append(LocalLabel(text=m, position=Position(px, yb - P - 0.3, 90),
                                                    effects=eff(0.8), uuid=uid(f"lab{sh.n}")))
            for m in members:
                del drops[m]
        channel_y.append(ty)
        drops_all.append(drops)
        for n in order:
            pts = drops[n]
            xmax = max(px for px, _ in pts)
            xmin = riser_x.get(n) if n in riser_x else (x_power if n in POWER else min(px for px, _ in pts))
            sh.wire((xmin, ty[n]), (xmax, ty[n]))
            for px, py in pts:
                sh.wire((px, py), (px, ty[n]))
                if xmin < px < xmax:
                    sh.dot(px, ty[n])
            if n in POWER:                             # symbol at the track's left end
                up = n == "+5V"
                sh.symbol(p5v if up else pgnd, f"#PWR{sh.n:03d}", n, x_power, ty[n], show=False)
                if i == 0:                             # PWR_FLAGs once, on the power-input row
                    sh.symbol(flag, f"#FLG{sh.n:03d}", "PWR_FLAG", x_power + G, ty[n],
                              angle=0 if up else 180, show=False)
                    sh.dot(x_power + G, ty[n])
        y = max(ty.values()) + G + gapv

    # risers: join every multi-row net's tracks; name each at its top end
    for n, rx in riser_x.items():
        ys = sorted(c[n] for c in channel_y if n in c)
        sh.wire((rx, ys[0]), (rx, ys[-1]))
        for yy in ys[1:-1]:
            sh.dot(rx, yy)
        sh.n += 1
        sh.sch.labels.append(LocalLabel(text=n, position=Position(rx, ys[0], 90), effects=eff(1.0),
                                        uuid=uid(f"lab{sh.n}")))

    sh.sch.to_file(OUT)
    print(f"wrote {OUT}")
    verify([p for r in rows for p in r])


def verify(parts):
    erc = ROOT / "build" / "erc.rpt"
    subprocess.run(["kicad-cli", "sch", "erc", "-o", erc, OUT], capture_output=True)
    kinds = re.findall(r"^\[(\w+)\]", erc.read_text(), re.M)
    print("ERC:", {k: kinds.count(k) for k in sorted(set(kinds))} or "clean")
    net_file = ROOT / "build" / "flappy6502.net"
    subprocess.run(["kicad-cli", "sch", "export", "netlist", "-o", net_file, OUT], capture_output=True)
    got = {}
    for block in re.split(r"\(net\s+\(code", net_file.read_text())[1:]:
        name = re.search(r'\(name "([^"]*)"\)', block).group(1).lstrip("/")
        for ref, pin in re.findall(r'\(node\s+\(ref "([^"]+)"\)\s+\(pin "([^"]+)"\)', block):
            got[(ref, pin)] = name
    want = {(p.ref, n): net for p in parts for n, net in p.nets.items() if net}
    # compare groupings (KiCad names unlabeled nets itself): each intended net must map
    # to exactly one KiCad net, and no two intended nets may share one
    groups = {}
    for k, v in want.items():
        groups.setdefault(v, set()).add(got.get(k))
    split = {v: g for v, g in groups.items() if len(g) != 1 or None in g}
    owner = {}
    merged = set()
    for v, g in groups.items():
        for kn in g:
            if kn in owner and owner[kn] != v:
                merged.add((owner[kn], v))
            owner[kn] = v
    print(f"netlist: {len(groups)} nets, {len(want)} pins; split {len(split)}, merged {len(merged)}")
    for v, g in list(split.items())[:8]:
        print("  split", v, "->", g)
    for a, b in list(merged)[:8]:
        print("  merged", a, "+", b)


if __name__ == "__main__":
    main()

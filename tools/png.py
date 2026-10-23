"""Minimal PNG writer (no Pillow): RGB565 pixel grids -> PNG files."""
import struct
import zlib
from pathlib import Path


def rgb565_to_rgb(c: int) -> tuple[int, int, int]:
    r, g, b = (c >> 11) & 0x1F, (c >> 5) & 0x3F, c & 0x1F
    return (r << 3 | r >> 2, g << 2 | g >> 4, b << 3 | b >> 2)


def write_png(path: Path, rows: list[list[int]], scale: int = 1) -> None:
    """rows = list of rows of RGB565 values."""
    h, w = len(rows) * scale, len(rows[0]) * scale
    raw = bytearray()
    for row in rows:
        line = bytearray([0])  # filter: none
        for c in row:
            line += bytes(rgb565_to_rgb(c)) * scale
        raw += bytes(line) * scale

    def chunk(kind: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))

    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(raw), 9)) + chunk(b"IEND", b"")
    path.parent.mkdir(exist_ok=True)
    path.write_bytes(png)

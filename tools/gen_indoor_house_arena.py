#!/usr/bin/env python3
"""Paint the battlefield's indoor house arena as original pixel art.

Writes assets/battle/indoor_house_arena.png at the theatre's native
640x360. Nothing here is sampled from a ROM: the palette and the two
raised platforms are this mod's own, the same legal posture as
src/Vfx.lua and drawPokeball.

The playing area the seats already use (Battlefield.PITCH_*) is the
contract this picture is authored against -- ally platform covers the
left mon column, foe the right -- so a regenerate does not move anyone.
"""
from __future__ import annotations

import struct
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "assets" / "battle" / "indoor_house_arena.png"

W, H = 640, 360

PITCH_LEFT, PITCH_RIGHT = 121, 517
PITCH_TOP, PITCH_BOTTOM = 90, 273
MON_COLUMN_ALLY, MON_COLUMN_FOE = 220, 418

WALL_TOP = (214, 186, 142)
WALL_MID = (198, 164, 118)
WALL_DK = (168, 128, 88)
TRIM = (148, 64, 56)
TRIM_DK = (112, 42, 38)
RAIL = (92, 58, 34)
RAIL_LT = (120, 78, 46)
FLOOR_A = (176, 118, 68)
FLOOR_B = (156, 100, 56)
FLOOR_DK = (128, 80, 44)
FLOOR_LT = (196, 140, 86)
PLAT = (188, 132, 76)
PLAT_LT = (210, 158, 98)
PLAT_DK = (132, 84, 46)
PLAT_SH = (88, 54, 30)
WINDOW = (168, 210, 226)
WINDOW_DK = (92, 132, 156)
SILL = (120, 78, 46)
CURTAIN = (176, 72, 68)
CURTAIN_DK = (132, 48, 46)
POT = (92, 68, 48)
LEAF = (62, 122, 64)
LEAF_DK = (40, 88, 46)


def _hash(x: int, y: int, salt: int = 0) -> float:
    h = (x % 1024) * 1664525 + (y % 1024) * 1013904223 + (salt % 1024) * 22695477
    h %= 2147483647
    h = (h * 48271) % 2147483647
    h = (h * 48271) % 2147483647
    return h / 2147483647


def _lerp(a: tuple[int, int, int], b: tuple[int, int, int], t: float) -> tuple[int, int, int]:
    t = 0.0 if t < 0 else 1.0 if t > 1 else t
    return (
        int(a[0] + (b[0] - a[0]) * t),
        int(a[1] + (b[1] - a[1]) * t),
        int(a[2] + (b[2] - a[2]) * t),
    )


def _in_ellipse(x: int, y: int, cx: int, cy: int, rx: int, ry: int) -> bool:
    if rx <= 0 or ry <= 0:
        return False
    dx, dy = x - cx, y - cy
    return (dx * dx) / float(rx * rx) + (dy * dy) / float(ry * ry) <= 1.0


class Canvas:
    def __init__(self, w: int, h: int, fill: tuple[int, int, int]) -> None:
        self.w, self.h = w, h
        self.px = [fill] * (w * h)

    def get(self, x: int, y: int) -> tuple[int, int, int]:
        return self.px[y * self.w + x]

    def put(self, x: int, y: int, c: tuple[int, int, int]) -> None:
        if 0 <= x < self.w and 0 <= y < self.h:
            self.px[y * self.w + x] = c

    def rect(self, x: int, y: int, w: int, h: int, c: tuple[int, int, int]) -> None:
        x0, y0 = max(0, x), max(0, y)
        x1, y1 = min(self.w, x + w), min(self.h, y + h)
        for yy in range(y0, y1):
            row = yy * self.w
            for xx in range(x0, x1):
                self.px[row + xx] = c

    def ellipse(self, cx: int, cy: int, rx: int, ry: int, color) -> None:
        if rx <= 0 or ry <= 0:
            return
        y0, y1 = max(0, cy - ry), min(self.h, cy + ry + 1)
        rx2, ry2 = float(rx * rx), float(ry * ry)
        for y in range(y0, y1):
            dy = y - cy
            inner = 1.0 - (dy * dy) / ry2
            if inner < 0:
                continue
            dx = int((rx2 * inner) ** 0.5)
            x0, x1 = max(0, cx - dx), min(self.w, cx + dx + 1)
            row = y * self.w
            if callable(color):
                for x in range(x0, x1):
                    self.px[row + x] = color(x, y)
            else:
                for x in range(x0, x1):
                    self.px[row + x] = color

    def to_png(self, path: Path) -> None:
        raw = bytearray()
        for y in range(self.h):
            raw.append(0)
            row = y * self.w
            for x in range(self.w):
                raw.extend(self.px[row + x])

        def chunk(tag: bytes, data: bytes) -> bytes:
            crc = zlib.crc32(tag + data) & 0xFFFFFFFF
            return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", crc)

        ihdr = struct.pack(">IIBBBBB", self.w, self.h, 8, 2, 0, 0, 0)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(
            b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", ihdr)
            + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
            + chunk(b"IEND", b"")
        )


def paint_wall(c: Canvas) -> None:
    band = 96
    for y in range(band):
        t = y / float(band - 1)
        col = _lerp(WALL_TOP, WALL_MID, t)
        for x in range(c.w):
            if ((x // 8) + (y // 10)) % 5 == 0 and 18 < y < 78:
                c.put(x, y, WALL_DK)
            else:
                c.put(x, y, col)
    c.rect(0, 82, c.w, 8, TRIM)
    c.rect(0, 88, c.w, 3, TRIM_DK)
    c.rect(0, 91, c.w, 6, RAIL)
    c.rect(0, 91, c.w, 2, RAIL_LT)


def paint_window(c: Canvas, cx: int) -> None:
    x, y, w, h = cx - 28, 22, 56, 44
    c.rect(x - 3, y - 3, w + 6, h + 8, SILL)
    c.rect(x, y, w, h, WINDOW)
    c.rect(x + w // 2 - 1, y, 2, h, WINDOW_DK)
    c.rect(x, y + h // 2 - 1, w, 2, WINDOW_DK)
    c.rect(x - 6, y, 8, h, CURTAIN)
    c.rect(x + w - 2, y, 8, h, CURTAIN)
    c.rect(x - 6, y, 8, 6, CURTAIN_DK)
    c.rect(x + w - 2, y, 8, 6, CURTAIN_DK)
    c.rect(x - 4, y + h, w + 8, 4, SILL)


def paint_floor(c: Canvas) -> None:
    for y in range(97, c.h):
        for x in range(c.w):
            plank = (x // 10 + y // 3) & 1
            col = FLOOR_A if plank == 0 else FLOOR_B
            if x % 10 == 0:
                col = FLOOR_DK
            elif _hash(x, y, 3) < 0.04:
                col = FLOOR_LT
            c.put(x, y, col)


def paint_platform(c: Canvas, cx: int, cy: int, rx: int, ry: int) -> None:
    c.ellipse(cx + 3, cy + 8, rx, ry, PLAT_SH)

    def fill(x: int, y: int) -> tuple[int, int, int]:
        t = (y - (cy - ry)) / float(max(1, 2 * ry))
        base = _lerp(PLAT_LT, PLAT, t)
        if _in_ellipse(x, y, cx, cy, rx - 4, ry - 5):
            if ((x + y) // 6) & 1:
                return _lerp(base, PLAT_DK, 0.18)
            return base
        return PLAT_DK

    c.ellipse(cx, cy, rx, ry, fill)


def paint_plant(c: Canvas, x: int, y: int) -> None:
    c.rect(x - 5, y - 2, 10, 8, POT)
    c.rect(x - 4, y - 4, 8, 3, RAIL)
    c.ellipse(x, y - 12, 8, 7, LEAF)
    c.ellipse(x - 6, y - 10, 5, 5, LEAF_DK)
    c.ellipse(x + 6, y - 11, 5, 5, LEAF)


def paint() -> Canvas:
    c = Canvas(W, H, FLOOR_A)
    paint_wall(c)
    paint_floor(c)
    paint_window(c, 220)
    paint_window(c, 420)
    paint_platform(c, MON_COLUMN_FOE, 162, 90, 72)
    paint_platform(c, MON_COLUMN_ALLY, 188, 102, 82)
    paint_plant(c, 36, 118)
    paint_plant(c, 604, 118)
    return c


def main() -> None:
    canvas = paint()
    canvas.to_png(OUT)
    print(f"wrote {OUT} ({OUT.stat().st_size} bytes, {W}x{H})")
    browns = 0
    total = 0
    for y in range(PITCH_TOP, PITCH_BOTTOM):
        for x in range(PITCH_LEFT, PITCH_RIGHT):
            r, g, b = canvas.get(x, y)
            total += 1
            if r > g + 8 and r > b + 8:
                browns += 1
    frac = browns / float(total)
    if frac < 0.45:
        raise SystemExit(f"pitch is only {frac:.0%} wood -- platforms missed the floor")
    print(f"pitch wood coverage {frac:.0%}")


if __name__ == "__main__":
    main()

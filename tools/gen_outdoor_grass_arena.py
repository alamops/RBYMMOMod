#!/usr/bin/env python3
"""Paint the battlefield's outdoor grass arena as original pixel art.

Writes assets/battle/outdoor_grass_arena.png at the theatre's native
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
OUT = ROOT / "assets" / "battle" / "outdoor_grass_arena.png"

W, H = 640, 360

# Layout contract (must match src/Battlefield.lua).
PITCH_LEFT, PITCH_RIGHT = 121, 517
PITCH_TOP, PITCH_BOTTOM = 90, 273
MON_COLUMN_ALLY, MON_COLUMN_FOE = 220, 418
FIELD_BOTTOM = 280

# Original palette -- Kanto-morning grass, not a ROM dump.
SKY_TOP = (118, 178, 226)
SKY_MID = (168, 208, 236)
SKY_HZ = (214, 226, 230)
CLOUD = (240, 244, 248)
CLOUD_EDGE = (198, 216, 230)
HILL_FAR = (102, 160, 112)
HILL_MID = (74, 136, 86)
HILL_NEAR = (54, 114, 70)
DIRT = (176, 132, 78)
DIRT_LT = (200, 158, 98)
DIRT_DK = (148, 106, 60)
DIRT_SH = (118, 82, 48)
GRASS_HI = (132, 204, 102)
GRASS_A = (92, 176, 82)
GRASS_B = (70, 154, 70)
GRASS_EDGE = (46, 112, 50)
GRASS_SH = (36, 82, 40)
LIP = (156, 112, 62)
LIP_LT = (188, 148, 88)
LEAF_DK = (24, 86, 44)
LEAF = (40, 116, 56)
LEAF_LT = (72, 150, 74)
TRUNK = (98, 66, 40)
TRUNK_DK = (72, 48, 28)
FLOWER_Y = (236, 214, 70)
FLOWER_W = (242, 238, 224)
FLOWER_P = (226, 134, 166)
ROCK = (136, 136, 144)
ROCK_LT = (176, 176, 184)
ROCK_DK = (96, 96, 104)


def _hash(x: int, y: int, salt: int = 0) -> float:
    """Deterministic 0..1, same idea as Vfx.rand01 -- no RNG drift."""
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

    def ellipse(
        self,
        cx: int,
        cy: int,
        rx: int,
        ry: int,
        color,
    ) -> None:
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


def paint_sky(c: Canvas) -> None:
    band = 88
    for y in range(band):
        t = y / float(band - 1)
        if t < 0.5:
            col = _lerp(SKY_TOP, SKY_MID, t / 0.5)
        else:
            col = _lerp(SKY_MID, SKY_HZ, (t - 0.5) / 0.5)
        # Fine Bayer-ish dither only near the horizon so the wash stays soft.
        dither = _lerp(col, SKY_HZ, 0.18)
        use_dither = t > 0.55 and x_dither_row(y)
        for x in range(c.w):
            c.put(x, y, dither if use_dither and ((x >> 1) + y) & 1 else col)

    def cloud(cx: int, cy: int, s: int) -> None:
        c.ellipse(cx, cy + 1, s, max(3, s // 3), CLOUD_EDGE)
        c.ellipse(cx - s // 3, cy, int(s * 0.7), max(3, s // 4), CLOUD)
        c.ellipse(cx + s // 4, cy, int(s * 0.55), max(3, s // 5), CLOUD)
        c.ellipse(cx, cy - 2, int(s * 0.4), max(2, s // 6), CLOUD)

    cloud(86, 20, 36)
    cloud(300, 14, 44)
    cloud(534, 22, 32)


def x_dither_row(y: int) -> bool:
    return (y % 3) != 0


def paint_hills(c: Canvas) -> None:
    for cx, cy, rx, ry in (
        (70, 84, 120, 26),
        (210, 80, 140, 30),
        (390, 82, 150, 28),
        (560, 86, 130, 24),
    ):
        c.ellipse(cx, cy, rx, ry, HILL_FAR)
    for cx, cy, rx, ry in (
        (20, 96, 100, 20),
        (160, 93, 110, 22),
        (330, 91, 120, 24),
        (490, 94, 110, 20),
        (630, 97, 90, 18),
    ):
        c.ellipse(cx, cy, rx, ry, HILL_MID)
    # Irregular far tree-line -- overlapping canopies, not a dotted row.
    for i in range(28):
        x = 6 + i * 24 + int(_hash(i, 3, 1) * 8 - 4)
        r = 8 + int(_hash(i, 5, 2) * 7)
        c.ellipse(x, 100, r, int(r * 0.78), HILL_NEAR)
        c.ellipse(x - r // 4, 96, int(r * 0.7), int(r * 0.55), HILL_NEAR)


def paint_dirt(c: Canvas) -> None:
    for y in range(98, c.h):
        t = (y - 98) / float(c.h - 98)
        base = _lerp(DIRT_LT, DIRT, min(1.0, t * 1.05))
        for x in range(c.w):
            n = _hash(x, y, 7)
            n2 = _hash(x // 3, y // 2, 8)
            if n < 0.045:
                col = DIRT_LT
            elif n > 0.96:
                col = DIRT_DK
            elif n2 > 0.82:
                col = _lerp(base, DIRT_DK, 0.35)
            else:
                col = base
            c.put(x, y, col)
    # Worn path between the two mounds, so the dirt reads as a route, not a void.
    for y in range(150, 210):
        for x in range(280, 360):
            if _hash(x, y, 4) < 0.55:
                c.put(x, y, _lerp(c.get(x, y), DIRT_LT, 0.4))
    for y in range(FIELD_BOTTOM, c.h):
        t = (y - FIELD_BOTTOM) / float(max(1, c.h - FIELD_BOTTOM))
        shade = _lerp(DIRT_DK, DIRT_SH, t)
        for x in range(c.w):
            prev = c.get(x, y)
            c.put(x, y, _lerp(prev, shade, 0.4 + t * 0.4))


def paint_platform(c: Canvas, cx: int, cy: int, rx: int, ry: int) -> None:
    c.ellipse(cx + 5, cy + 8, rx + 1, int(ry * 0.86), GRASS_SH)
    c.ellipse(cx + 1, cy + 3, rx + 6, ry + 5, LIP)
    c.ellipse(cx - 1, cy + 1, rx + 4, ry + 3, LIP_LT)

    def grass(x: int, y: int) -> tuple[int, int, int]:
        # Soft horizontal bands (stadium grass) broken up by grain so they
        # do not read as a hatch.
        band = ((y + cx) // 7) % 2
        stripe = GRASS_A if band == 0 else GRASS_B
        n = _hash(x, y, 11)
        n2 = _hash(x // 2, y // 2, 12)
        if n < 0.08:
            stripe = GRASS_HI
        elif n > 0.92 or n2 > 0.88:
            stripe = _lerp(stripe, GRASS_EDGE, 0.45)
        dx, dy = (x - cx) / float(rx), (y - cy) / float(ry)
        rim = dx * dx + dy * dy
        if rim > 0.72:
            stripe = _lerp(stripe, GRASS_EDGE, (rim - 0.72) / 0.28)
        if dx < -0.2 and dy < -0.15 and rim < 0.5 and n < 0.6:
            stripe = _lerp(stripe, GRASS_HI, 0.4)
        return stripe

    c.ellipse(cx, cy, rx, ry, grass)


def paint_tree(c: Canvas, x: int, y: int, r: int) -> None:
    tw = max(3, r // 6)
    trunk_h = r // 2 + 6
    c.rect(x - tw // 2, y - trunk_h + 6, tw, trunk_h, TRUNK)
    c.rect(x - tw // 2, y - trunk_h + 6, 1, trunk_h, TRUNK_DK)
    # Three stacked scoops so it reads as a tree, not a bush.
    c.ellipse(x + 1, y - r // 3, r, int(r * 0.7), LEAF_DK)
    c.ellipse(x - r // 6, y - r // 2, int(r * 0.85), int(r * 0.62), LEAF)
    c.ellipse(x + r // 5, y - r // 2 + 2, int(r * 0.55), int(r * 0.45), LEAF)
    c.ellipse(x - r // 4, y - r // 2 - 5, int(r * 0.5), int(r * 0.4), LEAF_LT)


def paint_rock(c: Canvas, x: int, y: int, r: int) -> None:
    c.ellipse(x + 1, y + 2, r, max(2, r // 2), DIRT_SH)
    c.ellipse(x, y, r, max(3, int(r * 0.62)), ROCK)
    c.ellipse(x - r // 3, y - 1, max(2, r // 2), max(2, r // 3), ROCK_LT)
    c.put(x + r // 3, y + 1, ROCK_DK)


def paint_flower(c: Canvas, x: int, y: int, kind: int) -> None:
    col = (FLOWER_Y, FLOWER_W, FLOWER_P)[kind % 3]
    c.put(x, y, col)
    if 0 <= x + 1 < c.w:
        c.put(x + 1, y, col)
    if 0 <= y + 1 < c.h:
        c.put(x, y + 1, _lerp(col, LEAF, 0.35))


def paint_tuft(c: Canvas, x: int, y: int) -> None:
    c.put(x, y, GRASS_EDGE)
    if 0 <= y - 1 < c.h:
        c.put(x, y - 1, GRASS_A)
    if 0 <= x - 1 < c.w:
        c.put(x - 1, y, GRASS_B)
    if 0 <= x + 1 < c.w:
        c.put(x + 1, y, GRASS_B)


def paint_clump(c: Canvas, x: int, y: int, n: int, seed: int) -> None:
    """A small wild-grass clump -- three to five tufts sharing one root."""
    for i in range(n):
        dx = int(_hash(seed, i, 1) * 7) - 3
        dy = int(_hash(seed, i, 2) * 4) - 1
        paint_tuft(c, x + dx, y + dy)


def paint_decor(c: Canvas) -> None:
    # Woods in the four corners. Trainer columns (~x 20 and ~x 620) stay
    # walkable dirt -- the trees sit behind / beside them, not on them.
    for x, y, r in (
        (8, 134, 26),
        (36, 122, 20),
        (14, 176, 22),
        (58, 156, 16),
        (10, 230, 24),
        (40, 258, 18),
        (16, 292, 20),
        (632, 130, 24),
        (606, 118, 18),
        (636, 174, 22),
        (586, 154, 15),
        (628, 236, 22),
        (600, 266, 17),
        (634, 294, 19),
        (110, 108, 14),
        (150, 106, 12),
        (490, 104, 13),
        (530, 106, 14),
        (200, 102, 11),
        (440, 100, 12),
    ):
        paint_tree(c, x, y, r)

    for x, y, r in (
        (84, 206, 8),
        (94, 252, 6),
        (72, 288, 7),
        (552, 200, 8),
        (564, 256, 6),
        (548, 290, 7),
        (300, 114, 5),
        (348, 112, 5),
    ):
        paint_rock(c, x, y, r)

    for x, y, k in (
        (100, 188, 0), (105, 192, 1), (98, 196, 2),
        (538, 184, 1), (544, 190, 0), (536, 194, 2),
        (158, 120, 0), (164, 124, 1),
        (474, 118, 2), (480, 122, 0),
        (76, 304, 1), (84, 310, 0), (92, 306, 2),
        (548, 306, 2), (556, 312, 1), (564, 308, 0),
        (310, 304, 0), (320, 310, 2), (328, 306, 1),
    ):
        paint_flower(c, x, y, k)

    for i, (x, y) in enumerate((
        (108, 170), (118, 230), (130, 268),
        (250, 124), (390, 122),
        (512, 168), (524, 228), (510, 270),
        (200, 292), (440, 294),
    )):
        paint_clump(c, x, y, 4, i + 20)


def paint() -> Canvas:
    c = Canvas(W, H, SKY_TOP)
    paint_sky(c)
    paint_hills(c)
    paint_dirt(c)
    # Foe mound: higher and a little smaller. Ally mound: lower and broader.
    # Both still cover their mon column inside PITCH_*.
    paint_platform(c, MON_COLUMN_FOE, 162, 90, 72)
    paint_platform(c, MON_COLUMN_ALLY, 188, 102, 82)
    paint_decor(c)
    return c


def main() -> None:
    canvas = paint()
    canvas.to_png(OUT)
    print(f"wrote {OUT} ({OUT.stat().st_size} bytes, {W}x{H})")
    # Sanity: the pitch rect is still mostly grass-green, not dirt or sky.
    greens = 0
    total = 0
    for y in range(PITCH_TOP, PITCH_BOTTOM):
        for x in range(PITCH_LEFT, PITCH_RIGHT):
            r, g, b = canvas.get(x, y)
            total += 1
            if g > r + 8 and g > b + 8:
                greens += 1
    frac = greens / float(total)
    if frac < 0.45:
        raise SystemExit(f"pitch is only {frac:.0%} grass -- platforms missed the field")
    print(f"pitch grass coverage {frac:.0%}")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Check a driver screenshot for the lime-green portrait palette bug.

Chars.portrait used to blit raw DMG-shade sheets; skin reads as bright
green instead of the OBP-baked flesh tone.  Samples the given rectangle and
exits 0 when the portrait looks recoloured, 1 when it still looks broken.
"""

import sys
from PIL import Image


def lime_score(r: int, g: int, b: int) -> bool:
    # The failure mode: neon green skin with g dominating r and b.
    return g > 170 and g > r + 35 and g > b + 35


def flesh_score(r: int, g: int, b: int) -> bool:
    # Any mid-tone recolour that is not the lime failure mode: the OBP bake
    # spreads pixels across several tans and greys depending on sprite and
    # colour mode, so demanding peach skin rejects valid portraits (RED on a
    # trainer card is mostly jacket).
    return not lime_score(r, g, b) and (r + g + b) > 120


def main() -> int:
    if len(sys.argv) != 6:
        print(
            "usage: portrait_color_probe.py <png> <x> <y> <w> <h>",
            file=sys.stderr,
        )
        return 2

    path, x, y, w, h = sys.argv[1], *map(int, sys.argv[2:])
    img = Image.open(path).convert("RGB")
    iw, ih = img.size
    # Driver screenshots are the window framebuffer; layout constants are in
    # 160x144 game pixels (src/Ui.lua).
    sx, sy = iw / 160, ih / 144
    x = int(x * sx)
    y = int(y * sy)
    w = max(1, int(w * sx))
    h = max(1, int(h * sy))

    sprite_px = 0
    lime_px = 0
    flesh_px = 0
    for py in range(y, y + h):
        for px in range(x, x + w):
            r, g, b = img.getpixel((px, py))
            # skip paper white and glyph black; portrait pixels sit between.
            if r > 230 and g > 230 and b > 230:
                continue
            if r < 25 and g < 25 and b < 25:
                continue
            sprite_px += 1
            if lime_score(r, g, b):
                lime_px += 1
            if flesh_score(r, g, b):
                flesh_px += 1

    if sprite_px < 8:
        print(f"too few portrait pixels in {path} ({sprite_px} in {x},{y}+{w}x{h})")
        return 1

    if lime_px > sprite_px // 4:
        print(
            f"lime portrait pixels in {path}: {lime_px}/{sprite_px} "
            f"in {x},{y}+{w}x{h}"
        )
        return 1

    if flesh_px < 8:
        print(
            f"portrait pixels look unrecoloured in {path}: {flesh_px}/{sprite_px} "
            f"in {x},{y}+{w}x{h}"
        )
        return 1

    print(f"ok {path} {sprite_px} sprite px, {lime_px} lime, {flesh_px} flesh")
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Contact sheet for an e2e screenshot folder.

    python3 tests/drivers/shots_index.py <SHOT_DIR> [--title TEXT]

Writes <SHOT_DIR>/index.html: every PNG in the folder as a thumbnail linking
the full image, captioned from its filename. Files named the Gen 3 way,

    g3-<game>-<role>-<NN>-<leg>.png      (g3-firered-host-07-sees-guest.png)

are grouped by game, then by role, in leg order; anything else (the Gen 1 /
Gen 2 runners' host-*.png, trip-g2-*.png, ...) lands in one "other" group
sorted by name, so the script works on any runner's folder. Standard library
only -- it runs wherever python3 does, with no Pillow and no network, and
writes nothing but the one HTML file. Prints the path it wrote.
"""

import html
import os
import re
import sys
from collections import OrderedDict

G3_NAME = re.compile(r"^g3-(?P<game>[a-z0-9]+)-(?P<role>[a-z0-9]+)-(?P<n>\d+)-(?P<leg>.+)\.png$")

GAME_ORDER = ["firered", "leafgreen", "emerald"]
ROLE_ORDER = ["host", "guest", "a", "b", "c", "red", "fr", "em"]

GAME_LABEL = {
    "firered": "FireRed",
    "leafgreen": "LeafGreen",
    "emerald": "Emerald",
}


def order_key(value, order):
    return (order.index(value), value) if value in order else (len(order), value)


def caption(leg):
    return leg.replace("-", " ").replace("_", " ")


def collect(folder):
    groups = OrderedDict()
    other = []
    for name in sorted(os.listdir(folder)):
        if not name.lower().endswith(".png"):
            continue
        m = G3_NAME.match(name)
        if not m:
            other.append((name, caption(name[:-4])))
            continue
        game, role = m.group("game"), m.group("role")
        groups.setdefault(game, {}).setdefault(role, []).append(
            (int(m.group("n")), name, caption(m.group("leg"))))
    return groups, other


def figure(name, text, number=None):
    src = html.escape(name, quote=True)
    label = html.escape(text)
    if number is not None:
        label = "%02d &middot; %s" % (number, label)
    return (
        '<figure><a href="%s"><img src="%s" loading="lazy" alt="%s"></a>'
        '<figcaption>%s</figcaption></figure>' % (src, src, html.escape(text, quote=True), label)
    )


def render(folder, title):
    groups, other = collect(folder)
    count = sum(len(v) for g in groups.values() for v in g.values()) + len(other)
    parts = [
        "<!doctype html>",
        '<html lang="en"><head><meta charset="utf-8">',
        '<meta name="viewport" content="width=device-width, initial-scale=1">',
        "<title>%s</title>" % html.escape(title),
        "<style>",
        ":root{--bg:#f6f6f4;--fg:#1d1d1b;--muted:#6b6b66;--card:#fff;--line:#deded8}",
        "@media (prefers-color-scheme: dark){:root{--bg:#161615;--fg:#ececea;--muted:#a3a39c;"
        "--card:#232321;--line:#3a3a36}}",
        "body{margin:0;padding:16px;background:var(--bg);color:var(--fg);"
        "font:14px/1.4 -apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif}",
        "h1{font-size:20px;margin:0 0 4px}h2{font-size:17px;margin:28px 0 8px}"
        "h3{font-size:14px;margin:16px 0 8px;color:var(--muted);text-transform:uppercase;"
        "letter-spacing:.06em}",
        "p.meta{color:var(--muted);margin:0 0 12px}",
        ".grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(220px,1fr));gap:12px}",
        "figure{margin:0;background:var(--card);border:1px solid var(--line);border-radius:6px;"
        "overflow:hidden}",
        "figure img{display:block;width:100%;height:auto;image-rendering:pixelated;"
        "background:#000}",
        "figcaption{padding:6px 8px;font-size:12px;color:var(--muted);word-break:break-word}",
        "nav a{margin-right:12px;color:inherit}",
        "</style></head><body>",
        "<h1>%s</h1>" % html.escape(title),
        '<p class="meta">%d screenshot(s) in %s</p>' % (count, html.escape(os.path.abspath(folder))),
    ]
    games = sorted(groups.keys(), key=lambda g: order_key(g, GAME_ORDER))
    if len(games) + (1 if other else 0) > 1:
        links = ['<a href="#%s">%s</a>' % (g, html.escape(GAME_LABEL.get(g, g))) for g in games]
        if other:
            links.append('<a href="#other">other</a>')
        parts.append("<nav>%s</nav>" % " ".join(links))
    for game in games:
        parts.append('<h2 id="%s">%s</h2>' % (game, html.escape(GAME_LABEL.get(game, game))))
        roles = groups[game]
        for role in sorted(roles.keys(), key=lambda r: order_key(r, ROLE_ORDER)):
            parts.append("<h3>%s</h3>" % html.escape(role))
            parts.append('<div class="grid">')
            for number, name, text in sorted(roles[role]):
                parts.append(figure(name, text, number))
            parts.append("</div>")
    if other:
        parts.append('<h2 id="other">other</h2><div class="grid">')
        for name, text in other:
            parts.append(figure(name, text))
        parts.append("</div>")
    if count == 0:
        parts.append("<p>No screenshots yet.</p>")
    parts.append("</body></html>")
    return "\n".join(parts) + "\n"


def main(argv):
    args = list(argv[1:])
    title = None
    if "--title" in args:
        i = args.index("--title")
        if i + 1 >= len(args):
            print("usage: shots_index.py <SHOT_DIR> [--title TEXT]", file=sys.stderr)
            return 2
        title = args[i + 1]
        del args[i:i + 2]
    if len(args) != 1:
        print("usage: shots_index.py <SHOT_DIR> [--title TEXT]", file=sys.stderr)
        return 2
    folder = args[0]
    if not os.path.isdir(folder):
        print("shots_index: no such folder: %s" % folder, file=sys.stderr)
        return 1
    title = title or ("rby_mmo e2e screenshots - %s" % os.path.basename(os.path.abspath(folder)))
    out = os.path.join(folder, "index.html")
    with open(out, "w", encoding="utf-8") as handle:
        handle.write(render(folder, title))
    print("contact sheet: %s" % out)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

"""Draws the Nice Flight! badge icons as 24x24 RGBA PNGs with no third-party
libraries: shapes are tested per sub-pixel (4x4 supersampling) and the PNG is
encoded by hand. Original artwork, so there is nothing to license.

    python3 tools/make_icons.py            # writes NiceFlt/icons/*.png
    python3 tools/make_icons.py 96 /tmp/x  # bigger copies for eyeballing
"""
import math, os, struct, sys, zlib

SIZE = int(sys.argv[1]) if len(sys.argv) > 1 else 24
OUT = sys.argv[2] if len(sys.argv) > 2 else os.path.join(os.path.dirname(__file__), "..", "NiceFlt", "icons")
SS = 4

# shapes work in a 0..24 coordinate space whatever the output size
def circle(cx, cy, r): return lambda x, y: (x - cx) ** 2 + (y - cy) ** 2 <= r * r
def ring(cx, cy, r0, r1): return lambda x, y: r0 * r0 <= (x - cx) ** 2 + (y - cy) ** 2 <= r1 * r1
def rect(x0, y0, x1, y1): return lambda x, y: x0 <= x <= x1 and y0 <= y <= y1
def poly(pts):
    def inside(x, y):
        c, n = False, len(pts)
        for i in range(n):
            x0, y0 = pts[i]; x1, y1 = pts[(i + 1) % n]
            if (y0 > y) != (y1 > y) and x < (x1 - x0) * (y - y0) / (y1 - y0) + x0:
                c = not c
        return c
    return inside
def line(x0, y0, x1, y1, w):
    def near(x, y):
        dx, dy = x1 - x0, y1 - y0
        t = max(0, min(1, ((x - x0) * dx + (y - y0) * dy) / (dx * dx + dy * dy)))
        return (x - x0 - t * dx) ** 2 + (y - y0 - t * dy) ** 2 <= (w / 2) ** 2
    return near
def both(a, b): return lambda x, y: a(x, y) and b(x, y)
def minus(a, b): return lambda x, y: a(x, y) and not b(x, y)
def sector(cx, cy, a0, a1):
    def f(x, y):
        a = math.degrees(math.atan2(y - cy, x - cx)) % 360
        return a0 <= a <= a1
    return f

def render(layers):
    px = []
    for j in range(SIZE):
        row = []
        for i in range(SIZE):
            acc = [0.0, 0.0, 0.0, 0.0]
            for sj in range(SS):
                for si in range(SS):
                    x = (i + (si + 0.5) / SS) * 24.0 / SIZE
                    y = (j + (sj + 0.5) / SS) * 24.0 / SIZE
                    col = None
                    for shape, rgb in layers:          # later layers paint over earlier ones
                        if shape(x, y): col = rgb
                    if col:
                        acc[0] += col[0]; acc[1] += col[1]; acc[2] += col[2]; acc[3] += 1
            n = SS * SS
            if acc[3] == 0: row += [0, 0, 0, 0]
            else: row += [int(acc[0] / acc[3]), int(acc[1] / acc[3]), int(acc[2] / acc[3]), int(255 * acc[3] / n)]
        px.append(bytes(row))
    return px

def png(path, rows):
    def chunk(tag, data):
        c = struct.pack(">I", len(data)) + tag + data
        return c + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
    raw = b"".join(b"\x00" + r for r in rows)
    data = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", SIZE, SIZE, 8, 6, 0, 0, 0)) \
        + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")
    open(path, "wb").write(data)

INK, WHITE = (30, 30, 34), (255, 255, 255)
ICONS = {
    "peak": [   # two mountains, snow caps
        (poly([(1, 21), (9, 7), (17, 21)]), (110, 124, 140)),
        (poly([(9, 21), (16, 4), (23, 21)]), (78, 92, 110)),
        (poly([(16, 4), (13.2, 10.8), (15, 9.6), (16.2, 11.2), (17.4, 9.6), (18.9, 11)]), WHITE),
        (poly([(9, 7), (6.8, 10.9), (8.2, 10.2), (9.2, 11.4), (10.4, 10.2), (11.3, 11)]), WHITE),
    ],
    "dur": [    # stopwatch (white halo so it survives a dark pill)
        (rect(9.5, 0.2, 14.5, 5), WHITE),
        (line(17.6, 5.6, 19.6, 3.6, 3.8), WHITE),
        (circle(12, 13.5, 10.4), WHITE),
        (rect(10.3, 1, 13.7, 4.4), INK),
        (line(17.6, 5.6, 19.6, 3.6, 2.2), INK),
        (circle(12, 13.5, 9.5), INK),
        (circle(12, 13.5, 7.4), WHITE),
        (line(12, 13.5, 12, 8, 1.7), (200, 50, 45)),
        (line(12, 13.5, 16, 15.6, 1.7), INK),
        (circle(12, 13.5, 1.5), INK),
    ],
    "yoyo": [   # yo-yo on its string
        (line(12, 0.5, 12, 10, 3.0), WHITE),
        (line(12, 0.5, 12, 10, 1.4), INK),
        (circle(12, 15, 8.2), (210, 55, 50)),
        (ring(12, 15, 4.4, 5.6), (150, 30, 30)),
        (circle(12, 15, 2.2), WHITE),
    ],
    "reb": [    # bouncing ball with seams
        (circle(12, 12, 10.5), (235, 125, 40)),
        (line(1.5, 12, 22.5, 12, 1.5), INK),
        (line(12, 1.5, 12, 22.5, 1.5), INK),
        (both(ring(-2, 12, 8.6, 10.0), circle(12, 12, 10.5)), INK),
        (both(ring(26, 12, 8.6, 10.0), circle(12, 12, 10.5)), INK),
    ],
    "save": [   # life ring
        (ring(12, 12, 4.8, 10.8), (215, 50, 45)),
        (both(ring(12, 12, 4.8, 10.8), sector(12, 12, 22, 68)), WHITE),
        (both(ring(12, 12, 4.8, 10.8), sector(12, 12, 112, 158)), WHITE),
        (both(ring(12, 12, 4.8, 10.8), sector(12, 12, 202, 248)), WHITE),
        (both(ring(12, 12, 4.8, 10.8), sector(12, 12, 292, 338)), WHITE),
    ],
    "hat": [    # top hat with a band (white halo)
        (rect(5.7, 2.2, 18.3, 18), WHITE),
        (poly([(0.5, 17.2), (23.5, 17.2), (21.7, 22.4), (2.3, 22.4)]), WHITE),
        (rect(6.5, 3, 17.5, 18), INK),
        (rect(6.5, 13.2, 17.5, 16.2), (200, 50, 45)),
        (poly([(1.5, 18), (22.5, 18), (21, 21.5), (3, 21.5)]), INK),
    ],
    "rec": [    # trophy
        (ring(6.2, 8.5, 2.6, 4.4), (196, 140, 20)),
        (ring(17.8, 8.5, 2.6, 4.4), (196, 140, 20)),
        (poly([(6, 2.5), (18, 2.5), (16.6, 11), (13.6, 14.4), (10.4, 14.4), (7.4, 11)]), (240, 185, 45)),
        (rect(10.9, 14, 13.1, 18.4), (196, 140, 20)),
        (rect(7, 18.4, 17, 21.6), (240, 185, 45)),
        (line(9.2, 4.6, 9.8, 10, 1.4), (255, 232, 150)),
    ],
}

os.makedirs(OUT, exist_ok=True)
for name, layers in ICONS.items():
    png(os.path.join(OUT, name + ".png"), render(layers))
    print("wrote", name + ".png", SIZE)

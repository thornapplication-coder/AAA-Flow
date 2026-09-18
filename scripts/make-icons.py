import zlib, struct, math

NAVY  = (0x0b, 0x1f, 0x3a)
WHITE = (0xff, 0xff, 0xff)
BLUE  = (0x5b, 0x8d, 0xef)

def seg_dist(px, py, ax, ay, bx, by):
    vx, vy = bx - ax, by - ay
    wx, wy = px - ax, py - ay
    L = vx * vx + vy * vy
    t = 0.0 if L == 0 else max(0.0, min(1.0, (wx * vx + wy * vy) / L))
    dx, dy = wx - t * vx, wy - t * vy
    return math.sqrt(dx * dx + dy * dy)

def rrect_inside(px, py, x, y, w, h, r):
    cx = min(max(px, x + r), x + w - r)
    cy = min(max(py, y + r), y + h - r)
    return math.hypot(px - cx, py - cy) <= r + 1e-9

def render(size, scale, offset, bleed):
    """scale/offset map the 128er Entwurf in die Zielfläche (Maskable: kleiner)."""
    SS = 4                      # vierfaches Übertasten, danach gemittelt
    n = size * SS
    acc = [[[0.0, 0.0, 0.0] for _ in range(n)] for _ in range(n)]
    def to_unit(i):
        return (i + 0.5) / SS
    for yy in range(n):
        py_px = to_unit(yy)
        for xx in range(n):
            px_px = to_unit(xx)
            # Hintergrund: randlos bei Maskable, sonst abgerundet
            if bleed:
                bg = True
            else:
                bg = rrect_inside(px_px, py_px, 0, 0, size, size, size * 24 / 128)
            col = list(NAVY) if bg else [0.0, 0.0, 0.0]
            if not bg:
                acc[yy][xx] = [0.0, 0.0, 0.0]
                continue
            # in Entwurfskoordinaten zurückrechnen
            u = (px_px - offset) / scale
            v = (py_px - offset) / scale
            sw = 10 / 2
            if seg_dist(u, v, 24, 88, 48, 40) <= sw or seg_dist(u, v, 48, 40, 72, 88) <= sw:
                col = list(WHITE)
            if seg_dist(u, v, 60, 88, 84, 40) <= sw or seg_dist(u, v, 84, 40, 108, 88) <= sw:
                col = list(BLUE)
            # Der Querbalken liegt zuoberst — wie im Entwurf
            if 38 <= u <= 90 and 70 <= v <= 78:
                col = list(WHITE)
            acc[yy][xx] = col
    rows = []
    for y in range(size):
        row = bytearray()
        row.append(0)
        for x in range(size):
            r = g = b = a = 0.0
            for dy in range(SS):
                for dx in range(SS):
                    c = acc[y * SS + dy][x * SS + dx]
                    on = 1.0 if (c[0] or c[1] or c[2]) else 0.0
                    r += c[0]; g += c[1]; b += c[2]; a += on
            k = SS * SS
            if a > 0:
                row += bytes((round(r / a), round(g / a), round(b / a), round(255 * a / k)))
            else:
                row += bytes((0, 0, 0, 0))
        rows.append(bytes(row))
    return b''.join(rows)

def png(path, size, raw):
    def chunk(t, d):
        c = t + d
        return struct.pack('>I', len(d)) + c + struct.pack('>I', zlib.crc32(c) & 0xffffffff)
    ihdr = struct.pack('>IIBBBBB', size, size, 8, 6, 0, 0, 0)
    out = (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', ihdr)
           + chunk(b'IDAT', zlib.compress(raw, 9)) + chunk(b'IEND', b''))
    open(path, 'wb').write(out)
    print(path, len(out), 'bytes')

for size in (192, 512):
    s = size / 128
    png(f'public/icon-{size}.png', size, render(size, s, 0.0, False))
# Maskable: Inhalt auf 64 % der Fläche, damit jeder Zuschnitt ihn ganz zeigt
s = 512 / 128 * 0.64
png('public/icon-maskable-512.png', 512, render(512, s, 512 * 0.18, True))

#!/usr/bin/env python3
"""
Turn a raw render into a clean, square, transparent in-world sprite.

  --white-bg : flood-fill the white background to transparent (for generators
               that return an opaque white bg, e.g. Gemini), with edge feather
  then: drop faint leftover pixels, trim to the object's alpha bbox,
        pad to a centered square, downscale to a crisp source size.

Usage:
  tools/.venv/bin/python tools/process_entity.py <raw.png> [out.png] [--size 256] [--white-bg]
"""
import sys
from collections import deque
from PIL import Image

ALPHA_FLOOR = 30   # pixels fainter than this become fully transparent


def remove_white_bg(img, tol=38, feather=55):
    img = img.convert("RGBA")
    w, h = img.size
    px = img.load()

    def near_white(c, t):
        return c[0] >= 255 - t and c[1] >= 255 - t and c[2] >= 255 - t

    visited = bytearray(w * h)
    dq = deque()
    for x in range(w):
        dq.append((x, 0)); dq.append((x, h - 1))
    for y in range(h):
        dq.append((0, y)); dq.append((w - 1, y))

    # flood fill the connected white background
    while dq:
        x, y = dq.popleft()
        i = y * w + x
        if visited[i]:
            continue
        visited[i] = 1
        c = px[x, y]
        if near_white(c, tol):
            px[x, y] = (c[0], c[1], c[2], 0)
            if x + 1 < w and not visited[i + 1]: dq.append((x + 1, y))
            if x - 1 >= 0 and not visited[i - 1]: dq.append((x - 1, y))
            if y + 1 < h and not visited[i + w]: dq.append((x, y + 1))
            if y - 1 >= 0 and not visited[i - w]: dq.append((x, y - 1))

    # feather: soften light edge pixels that touch a now-transparent pixel
    for y in range(h):
        for x in range(w):
            c = px[x, y]
            if c[3] == 0:
                continue
            lum = (c[0] + c[1] + c[2]) / 3
            if lum >= 255 - feather:
                touches = False
                for nx, ny in ((x+1, y), (x-1, y), (x, y+1), (x, y-1)):
                    if 0 <= nx < w and 0 <= ny < h and px[nx, ny][3] == 0:
                        touches = True; break
                if touches:
                    a = int(max(0, min(255, (255 - lum) / feather * 255)))
                    px[x, y] = (c[0], c[1], c[2], a)
    return img


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    src = args[0]
    out = args[1] if len(args) > 1 else "graphics/entity.png"
    size = 256
    if "--size" in sys.argv:
        size = int(sys.argv[sys.argv.index("--size") + 1])

    img = Image.open(src).convert("RGBA")
    if "--white-bg" in sys.argv:
        img = remove_white_bg(img)

    px = img.load()
    w, h = img.size
    for y in range(h):
        for x in range(w):
            r, g, b, a = px[x, y]
            if a < ALPHA_FLOOR:
                px[x, y] = (r, g, b, 0)

    bbox = img.getbbox()
    if not bbox:
        raise SystemExit("image is fully transparent after processing")
    obj = img.crop(bbox)
    ow, oh = obj.size
    side = max(ow, oh)
    square = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    square.paste(obj, ((side - ow) // 2, (side - oh) // 2))
    square = square.resize((size, size), Image.LANCZOS)
    square.save(out)
    print(f"object bbox {ow}x{oh} -> square {side} -> {out} ({size}x{size})")


if __name__ == "__main__":
    main()

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


def remove_white_bg(img, lo=208, hi=246, chroma=22):
    """Global chroma-key: any low-saturation, bright pixel is the white
    background and becomes transparent — ANYWHERE in the image, so white
    trapped inside the wire loops is cleared too, not just the outer border.
    A feathered band (lo..hi) fades edge pixels so there's no white halo.

    The object's colored parts (green display, brass, red/green wires, dark
    metal) have real chroma or are darker than `lo`, so they survive.
    """
    img = img.convert("RGBA")
    w, h = img.size
    px = img.load()
    span = float(hi - lo)
    for y in range(h):
        for x in range(w):
            r, g, b, a = px[x, y]
            if a == 0:
                continue
            mx, mn = max(r, g, b), min(r, g, b)
            if (mx - mn) <= chroma and mn >= lo:    # low-saturation & bright = background
                if mn >= hi:
                    px[x, y] = (r, g, b, 0)
                else:
                    fade = int(max(0, min(255, (hi - mn) / span * 255)))
                    px[x, y] = (r, g, b, min(a, fade))
    return img


def defringe(img, passes=2, dark=120, light=205, chroma=28):
    """Peel the white anti-aliasing fringe: edge pixels that blend object with
    white background are mid-gray (below the chroma-key threshold) and survive
    as a thin light outline — most visible on a gray backdrop. For each opaque
    pixel ON the transparent boundary that is low-saturation and light, fade its
    alpha (fully at `light`, untouched at `dark`). Colored edges (wires, brass,
    display) are high-chroma and protected; the dark metal silhouette stays.
    Snapshots per pass so erosion is controlled (≈1px/pass)."""
    img = img.convert("RGBA")
    w, h = img.size
    px = img.load()
    span = float(light - dark)
    for _ in range(passes):
        clear = []
        for y in range(h):
            for x in range(w):
                r, g, b, a = px[x, y]
                if a == 0:
                    continue
                boundary = False
                for nx, ny in ((x+1, y), (x-1, y), (x, y+1), (x, y-1)):
                    if 0 <= nx < w and 0 <= ny < h and px[nx, ny][3] == 0:
                        boundary = True
                        break
                if not boundary:
                    continue
                mx, mn = max(r, g, b), min(r, g, b)
                if (mx - mn) <= chroma and mn >= dark:
                    na = 0 if mn >= light else int(a * (light - mn) / span)
                    clear.append((x, y, r, g, b, na))
        for x, y, r, g, b, na in clear:
            px[x, y] = (r, g, b, na)
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
        # lo=188 catches dimmer/slightly-shadowed off-white (e.g. chunks inside
        # the wire loops); defringe then peels the light AA fringe. Both gated so
        # dark metal + saturated wires survive.
        img = defringe(remove_white_bg(img, lo=188, chroma=32),
                       passes=3, dark=108, light=212, chroma=42)

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

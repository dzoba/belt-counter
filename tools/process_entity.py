#!/usr/bin/env python3
"""
Turn a raw 1024px entity render into a clean, square, in-world sprite.

  - drop faint baked ground shadow (alpha threshold)
  - trim to the object's alpha bounding box
  - pad to a centered square so Factorio `shift` math is simple
  - downscale to a crisp source size

Usage: tools/.venv/bin/python tools/process_entity.py <raw.png> [out.png] [--size 256]
Run with the venv python (Pillow installed there).
"""
import sys
from PIL import Image

ALPHA_FLOOR = 30   # pixels fainter than this (e.g. soft shadow) become transparent


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    src = args[0]
    out = args[1] if len(args) > 1 else "graphics/entity.png"
    size = 256
    if "--size" in sys.argv:
        size = int(sys.argv[sys.argv.index("--size") + 1])

    img = Image.open(src).convert("RGBA")
    px = img.load()
    w, h = img.size

    # knock out faint pixels (shadow halo) so the bbox is the real object
    for y in range(h):
        for x in range(w):
            r, g, b, a = px[x, y]
            if a < ALPHA_FLOOR:
                px[x, y] = (r, g, b, 0)

    bbox = img.getbbox()
    if not bbox:
        raise SystemExit("image is fully transparent after threshold")
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

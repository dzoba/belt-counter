#!/usr/bin/env python3
"""
Image-to-image asset generation via Gemini (nano-banana / gemini-2.5-flash-image).

This is the approach that worked for the belt-counter entity: feed the real
Factorio constant-combinator frame as a reference so the generated art inherits
its exact oblique camera pose, then restyle the surfaces via the prompt.

Reads GEMINI_API_KEY from the Hexfall .env (or the environment). Stdlib only;
run with any python3 (no Pillow needed here).

Usage:
  python3 tools/gen_from_ref.py <ref.png> "<prompt>" [--n 2] [--out-prefix graphics/_raw/gen]
"""
import os
import sys
import json
import base64
import urllib.request
import urllib.error

ENV_PATH = os.path.expanduser("~/dev/hexfall/.env")
MODEL = "gemini-2.5-flash-image"


def load_key():
    if os.environ.get("GEMINI_API_KEY"):
        return os.environ["GEMINI_API_KEY"]
    if os.path.exists(ENV_PATH):
        for line in open(ENV_PATH):
            if line.startswith("GEMINI_API_KEY="):
                return line.split("=", 1)[1].strip().strip('"').strip("'")
    raise SystemExit("GEMINI_API_KEY not found in env or hexfall .env")


def main():
    pos = [a for a in sys.argv[1:] if not a.startswith("--")]
    ref, prompt = pos[0], pos[1]
    n = int(sys.argv[sys.argv.index("--n") + 1]) if "--n" in sys.argv else 2
    prefix = (sys.argv[sys.argv.index("--out-prefix") + 1]
              if "--out-prefix" in sys.argv else "graphics/_raw/gen")

    key = load_key()
    ref_b64 = base64.b64encode(open(ref, "rb").read()).decode()
    url = f"https://generativelanguage.googleapis.com/v1beta/models/{MODEL}:generateContent?key={key}"

    for i in range(n):
        body = json.dumps({"contents": [{"parts": [
            {"text": prompt},
            {"inline_data": {"mime_type": "image/png", "data": ref_b64}},
        ]}]}).encode()
        req = urllib.request.Request(url, data=body,
                                     headers={"Content-Type": "application/json"}, method="POST")
        try:
            with urllib.request.urlopen(req, timeout=180) as r:
                d = json.load(r)
        except urllib.error.HTTPError as e:
            print("HTTP", e.code, e.read().decode()[:400]); continue
        parts = d.get("candidates", [{}])[0].get("content", {}).get("parts", [])
        wrote = False
        for p in parts:
            inl = p.get("inlineData") or p.get("inline_data")
            if inl:
                path = f"{prefix}_{i}.png"
                open(path, "wb").write(base64.b64decode(inl["data"]))
                print("wrote", path); wrote = True
        if not wrote:
            print("no image in response:", json.dumps(d)[:300])


if __name__ == "__main__":
    main()

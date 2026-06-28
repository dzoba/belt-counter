#!/usr/bin/env python3
"""
Generate Belt Counter sprite/icon art via an image API.

Reuses API keys from the Hexfall .env (OPENAI_API_KEY preferred, GEMINI_API_KEY
fallback). Stdlib only — no pip install required.

Usage:
    python3 tools/gen_assets.py icon          # generate icon candidates
    python3 tools/gen_assets.py entity        # generate entity sprite candidates
    python3 tools/gen_assets.py all
    python3 tools/gen_assets.py icon --provider gemini

Output goes to graphics/_raw/ (gitignored). Pick the best, then crop/downscale
into graphics/ at the sizes Factorio needs (icon 64x64, entity sprite per layout).
"""
import base64
import json
import os
import sys
import urllib.request
import urllib.error

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RAW = os.path.join(REPO, "graphics", "_raw")
ENV_PATH = os.path.expanduser("~/dev/hexfall/.env")

# Factorio-appropriate art direction. Crucial: Factorio uses an ORTHOGRAPHIC,
# front-facing camera tilted slightly downward (like the vanilla combinators) --
# NOT an isometric / corner-on / 3-quarter cube. The front face must sit square
# to the viewer with all edges parallel to the image axes.
STYLE = (
    "Factorio-style game asset, high-detail painterly industrial sci-fi machine. "
    "Rendered in Factorio's camera angle: an orthographic FRONT view seen slightly "
    "from above (about a 30-degree downward tilt), with the flat front face squarely "
    "facing the viewer and every edge parallel to the image axes. "
    "It is NOT isometric, NOT rotated to show a corner, NOT a 3/4 view -- you look "
    "straight at the front panel with just the top surface receding upward. "
    "Sitting on a fully transparent background, crisp clean edges, dark metal casing "
    "with teal/green indicator lights and riveted panels, single object centered, "
    "no cast shadow on the ground, no text."
)

PROMPTS = {
    "icon": (
        "Item icon for a 'Belt Counter' combinator: a compact dark metal combinator "
        "box whose flat front panel carries a glowing horizontal digital counter "
        "display showing scrolling green numbers, with a small conveyor-belt arrow "
        "motif beneath the digits. The front panel faces the viewer head-on. " + STYLE
    ),
    "entity": (
        "A 'Belt Counter' machine, combinator-sized: a dark metal device whose flat "
        "front panel shows a glowing green numeric tally readout, with small circuit-"
        "wire connector nubs on top. The front panel faces the viewer head-on. " + STYLE
    ),
}


def load_env():
    env = {}
    if os.path.exists(ENV_PATH):
        with open(ENV_PATH) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                env[k.strip()] = v.strip().strip('"').strip("'")
    # process env overrides file
    for k in ("OPENAI_API_KEY", "GEMINI_API_KEY"):
        if os.environ.get(k):
            env[k] = os.environ[k]
    return env


def gen_openai(prompt, key, out_prefix, n=2):
    body = json.dumps({
        "model": "gpt-image-1",
        "prompt": prompt,
        "size": "1024x1024",
        "background": "transparent",
        "n": n,
    }).encode()
    req = urllib.request.Request(
        "https://api.openai.com/v1/images/generations",
        data=body,
        headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=180) as resp:
        data = json.load(resp)
    paths = []
    for i, item in enumerate(data.get("data", [])):
        raw = base64.b64decode(item["b64_json"])
        p = os.path.join(RAW, f"{out_prefix}_openai_{i}.png")
        with open(p, "wb") as f:
            f.write(raw)
        paths.append(p)
    return paths


def gen_gemini(prompt, key, out_prefix, n=2):
    # Gemini 2.5 Flash Image ("nano-banana") generateContent endpoint.
    model = "gemini-2.5-flash-image"
    url = f"https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent?key={key}"
    paths = []
    for i in range(n):
        body = json.dumps({
            "contents": [{"parts": [{"text": prompt}]}],
        }).encode()
        req = urllib.request.Request(
            url, data=body, headers={"Content-Type": "application/json"}, method="POST"
        )
        with urllib.request.urlopen(req, timeout=180) as resp:
            data = json.load(resp)
        for part in data["candidates"][0]["content"]["parts"]:
            inline = part.get("inlineData") or part.get("inline_data")
            if inline:
                raw = base64.b64decode(inline["data"])
                p = os.path.join(RAW, f"{out_prefix}_gemini_{i}.png")
                with open(p, "wb") as f:
                    f.write(raw)
                paths.append(p)
    return paths


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    provider = "openai"
    if "--provider" in sys.argv:
        provider = sys.argv[sys.argv.index("--provider") + 1]
    targets = args or ["all"]
    if "all" in targets:
        targets = ["icon", "entity"]

    os.makedirs(RAW, exist_ok=True)
    env = load_env()

    for t in targets:
        prompt = PROMPTS[t]
        print(f"[{provider}] generating '{t}'...")
        try:
            if provider == "openai":
                key = env.get("OPENAI_API_KEY")
                if not key:
                    raise SystemExit("OPENAI_API_KEY not found in env")
                paths = gen_openai(prompt, key, t)
            elif provider == "gemini":
                key = env.get("GEMINI_API_KEY")
                if not key:
                    raise SystemExit("GEMINI_API_KEY not found in env")
                paths = gen_gemini(prompt, key, t)
            else:
                raise SystemExit(f"unknown provider {provider}")
            for p in paths:
                print("  wrote", p)
        except urllib.error.HTTPError as e:
            print("  HTTP error", e.code, e.read().decode()[:500])
        except urllib.error.URLError as e:
            print("  URL error", e)


if __name__ == "__main__":
    main()

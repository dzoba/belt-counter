#!/usr/bin/env bash
# Build a Factorio-installable mod zip: belt-counter_<version>.zip
# The zip contains a single top folder "belt-counter_<version>/" with just the
# mod files (no dev tooling, no raw art). Drop the zip into the mods/ folder on
# any machine, or load it via the in-game Mods screen.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

VERSION="$(grep -o '"version"[^,]*' info.json | head -1 | sed -E 's/.*"version"[^"]*"([^"]+)".*/\1/')"
NAME="belt-counter"
STAGE="$(mktemp -d)"
DEST="$STAGE/${NAME}_${VERSION}"
mkdir -p "$DEST"

# Mod files only.
cp info.json data.lua control.lua changelog.txt thumbnail.png "$DEST"/
cp -R prototypes scripts locale "$DEST"/
mkdir -p "$DEST/graphics"
cp graphics/icon.png graphics/entity.png "$DEST/graphics"/

OUT="$REPO_DIR/${NAME}_${VERSION}.zip"
rm -f "$OUT"
( cd "$STAGE" && zip -rq "$OUT" "${NAME}_${VERSION}" )
rm -rf "$STAGE"

echo "Built: $OUT"
unzip -l "$OUT"

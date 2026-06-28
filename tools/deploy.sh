#!/usr/bin/env bash
# Symlink this repo into the Factorio mods folder for live dev iteration.
# Factorio loads the mod by reading info.json at the symlink target's root.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODS_DIR="$HOME/Library/Application Support/factorio/mods"
LINK="$MODS_DIR/belt-counter"

if [ ! -d "$MODS_DIR" ]; then
  echo "Creating mods dir: $MODS_DIR"
  mkdir -p "$MODS_DIR"
fi

# Remove any stale link/dir at the destination, then link.
if [ -L "$LINK" ] || [ -e "$LINK" ]; then
  echo "Removing existing: $LINK"
  rm -rf "$LINK"
fi

ln -s "$REPO_DIR" "$LINK"
echo "Linked: $LINK -> $REPO_DIR"
echo
echo "Next: launch Factorio 2.0, open Mods, enable 'Belt Counter'."
echo "On load errors, check: \$HOME/Library/Application Support/factorio/factorio-current.log"

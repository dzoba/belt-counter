#!/usr/bin/env bash
# Pre-flight: everything we can verify without launching Factorio.
#   1. luac   — syntax
#   2. luacheck — undefined globals / typos (Factorio std in .luacheckrc)
#   3. tests  — pure-Lua unit tests of the counting model
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

LUA_FILES="data.lua control.lua scripts/model.lua prototypes/belt-counter.lua prototypes/styles.lua"

echo "== luac (syntax) =="
for f in $LUA_FILES; do luac -p "$f" && echo "  ok  $f"; done

echo "== luacheck =="
if command -v luacheck >/dev/null 2>&1; then
  luacheck $LUA_FILES tests/run.lua
else
  echo "  (luacheck not installed; skipping)"
fi

echo "== unit tests =="
lua tests/run.lua

echo
echo "All pre-flight checks passed."

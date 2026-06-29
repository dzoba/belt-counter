# In-game test checklist (Factorio 2.0 + Space Age)

The mod is fully static-checked (luac + luacheck) and the counting logic is
unit-tested (`lua tests/run.lua`), but the GUI and prototypes have never run in
a real game. Use this checklist when you get to your computer; it's ordered so
the cheapest checks fail first.

## 0. Install
- `tools/deploy.sh` symlinks the repo into `mods/` (Mac path), **or** drop
  `belt-counter_0.1.0.zip` into `.../factorio/mods/`.
- Launch Factorio 2.0, Mods → enable "Belt Counter", restart.
- **If it fails to load:** the error is in
  `~/Library/Application Support/factorio/factorio-current.log` (or the Steam
  equivalent). Copy the last ~30 lines back to me — prototype errors show the
  file + field.

## Easiest path: the Map Editor ("sandbox")
Main menu → Map editor (or `/editor` in a save). It skips the tech/recipe gate —
spawn the Belt Counter, belts and items straight from the editor inventory.
Two editor-specific gotchas:
- **Time must be RUNNING** (top-left time controls). The counter only ticks and
  belts only move while game time advances; if it's paused, nothing counts. You
  can also raise the tick speed there to fill the 10h/All windows quickly.
- **Quality rows need Space Age enabled** for that session; pick a quality in the
  item picker when placing items.

## 1. Fast setup (console — needs cheats enabled on the save)
```
/c local p=game.player
p.insert{name="belt-counter", count=10}
p.insert{name="transport-belt", count=50}
p.insert{name="iron-plate", count=200}
p.force.technologies["circuit-network"].researched = true   -- recipe unlock check
```
For quality testing (Space Age):
```
/c game.player.insert{name="iron-plate", count=50, quality="rare"}
/c game.player.insert{name="iron-plate", count=50, quality="uncommon"}
```

## 2. Prototype / placement
- [ ] Belt Counter appears in inventory with the gunmetal icon.
- [ ] It's craftable only after Circuit network is researched (recipe gated).
- [ ] Place it — sprite is roughly 1 tile, sits on the tile sensibly.
      **If too big/small or floating:** tweak `SCALE` / `SHIFT` at the top of
      `prototypes/belt-counter.lua` (commented as the knobs).
- [ ] R does nothing (rotation disabled) — expected.

## 3. Wiring + counting (the core)
- [ ] Lay a belt, put iron plates on it (loop it so items keep moving).
- [ ] Wire the belt to the counter with a red or green circuit wire.
- [ ] Open the belt, enable **"Read belt contents"**, set mode to **Pulse**.
- [ ] Click the counter → our window opens (see §4). The vanilla combinator
      window should NOT stay open alongside it (single-player: clean swap;
      multiplayer: may flash briefly — known, harmless).
- [ ] The rate roughly matches the belt (a full yellow belt ≈ 15/s per lane).

## 4. The window UI
- [ ] Title bar: icon + "Belt Counter" + unit dropdown + close; draggable.
- [ ] Setup reminder line (gold) with a tooltip on hover.
- [ ] Window buttons `5s 1m 10m 1h 10h All` — clicking switches the graph +
      averaging; the pressed one looks toggled.
- [ ] Unit dropdown switches items/s ↔ /min ↔ /h ↔ stacks/s and all numbers update.
- [ ] Graph: vertical bars, fills left→right over time; hover shows a value.
- [ ] Table: one row per item, **separate rows per quality**, sorted by rate,
      with a share bar. ← verify rare/uncommon show as their own rows.
- [ ] Close button + Esc both close it.

## 5. Circuit output
- [ ] Tick "Output rates to circuit network".
- [ ] Wire the counter to a lamp / another combinator; confirm it emits the
      measured items/min (per item+quality), and that turning it off clears them.
- [ ] Sanity: enabling output should NOT inflate the counter's own reading
      (feedback cancellation) — the rate stays stable when you toggle it.

## Known risk areas (from API research)
- **Quality through circuit signals** had bugs in early 2.0.x — if rare/epic
  items don't show as separate rows, note your exact Factorio version.
- **MP flash** of the vanilla combinator GUI before ours — cosmetic only.
- **GUI spacing/sizes** were written blind; minor layout tweaks may be wanted.

## What to send back
factorio-current.log on any error, a screenshot of the open window, and notes
on anything that looks off. That's enough for me to fix without the game.

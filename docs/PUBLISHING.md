# Publishing to the Factorio Mod Portal

Players install from **mods.factorio.com** via the in-game Mods browser. GitHub is
just the source. The internal name `belt-counter` is confirmed available.

## Steps

1. Sign in at https://mods.factorio.com with your Factorio account.
2. **Mods → Publish a mod** (or your profile → "Add mod").
3. Build the upload: `tools/package.sh` → `belt-counter_0.1.0.zip`.
   The zip already contains `thumbnail.png` (144×144) at its root, so the portal
   and the in-game list both pick it up automatically.
4. Upload `belt-counter_0.1.0.zip`. The portal reads the internal name, version,
   title, and dependencies from `info.json`.
5. Fill in the portal page:
   - **Category:** Circuit network (alt: Utilities)
   - **License:** MIT (already in the repo)
   - **Source URL:** https://github.com/dzoba/belt-counter
   - **Summary** and **Description:** paste from below.
6. Upload the screenshots from `docs/screenshots/` (window.png, in-world.png).
7. Publish.

For new versions later: bump `version` in `info.json`, add a `changelog.txt`
entry, re-run `tools/package.sh`, and upload the new zip on the mod's page.

---

## Summary (short, shown on the mod card)

Measure one belt's item throughput over time and by quality. Wire it to a belt,
open it for a live line graph and a per-item, per-quality rate table.

---

## Description (markdown — paste into the portal)

# Belt Counter

Factorio's production graphs cover the whole factory. **Belt Counter** measures
the throughput of a *single* belt, over time, broken down by item **and by
quality**.

## How it works

1. Craft a **Belt Counter** (unlocked with the **Circuit network** technology).
2. Wire it to a transport belt with a red or green circuit wire.
3. On that belt, enable **"Read belt contents"** and set the mode to **Pulse**.
4. Click the Belt Counter to open its readout.

In pulse mode the belt emits one signal per item, so the counter measures real
throughput. In Space Age those signals carry quality, so normal and rare iron
plates are counted separately.

## The readout

- A **line graph** over a selectable time window: 5s / 1m / 10m / 1h / 10h / All.
- A **per-item, per-quality rate table** with shares. Click an item to focus the
  graph on just that item; click it again to go back to all.
- Rate **units**: items/s, items/min, items/hour, stacks/s.
- Optional **circuit output** of the measured rate, to wire into lamps or displays.

## Requirements

- Factorio **2.0**
- **Space Age** for the per-quality breakdown (the mod still works without it,
  counting by item only)

Source & issues: https://github.com/dzoba/belt-counter (MIT).

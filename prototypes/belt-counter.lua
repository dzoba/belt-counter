-- Belt Counter prototypes.
-- We clone the base constant-combinator so we inherit its correct 2.0 sprites,
-- wire-connection points and activity-LED offsets, then reskin the inventory
-- icon and give it our own item + recipe. The in-world sprite stays the vanilla
-- combinator for now; a custom sprite can be dropped in later.
local util = require("util")

local ICON = "__belt-counter__/graphics/icon.png"

----------------------------------------------------------------------
-- Entity
----------------------------------------------------------------------
local entity = util.table.deepcopy(data.raw["constant-combinator"]["constant-combinator"])
entity.name = "belt-counter"
entity.minable = { mining_time = 0.1, result = "belt-counter" }
entity.fast_replaceable_group = nil
entity.next_upgrade = nil

-- Lock orientation. Facing is functionally irrelevant (the counter reads its
-- belt through the circuit wire, not by adjacency), and clean 4-direction art
-- wasn't worth it, so we disable rotation: one correct sprite, no wire-stub
-- mismatch. R does nothing on this building.
entity.flags = entity.flags or {}
table.insert(entity.flags, "not-rotatable")

-- Point every wire connection at the south (bottom-front) position so the real
-- circuit wire emerges near the painted stubs regardless of default facing.
-- Defensive: only if the field is present in this base version.
local cp = entity.circuit_wire_connection_points
if cp and cp[3] then
  entity.circuit_wire_connection_points = { cp[3], cp[3], cp[3], cp[3] }
end
entity.icon = ICON
entity.icon_size = 64
entity.icons = nil
entity.icon_mipmaps = nil

-- Custom in-world sprite, applied to all four directions. Factorio's camera is
-- fixed (top always recedes upward), so a rotated combinator keeps the same
-- silhouette; one clean render (Gemini image-to-image off the real constant
-- combinator, so the oblique pose matches) reads correctly from every facing.
-- graphics/entity.png is a 256x256 square, object centered. SCALE/SHIFT are the
-- in-game tweak knobs. Reference: the base combinator's metal box is ~1.1 tiles
-- (HR frame 114px @ scale 0.5); our box is ~190px in the 256 png, so
-- 190*SCALE/32 ~= 1.1 tiles -> SCALE ~= 0.18. Tune by eye in-game.
local ENTITY_SPRITE = "__belt-counter__/graphics/entity.png"
local SCALE = 0.18          -- ~1.1 tiles for the box body
local SHIFT = { 0, -0.05 }  -- slight upward nudge (negative y = up)

local function dir_sprite()
  return {
    layers = {
      {
        filename = ENTITY_SPRITE,
        priority = "high",
        width = 256,
        height = 256,
        scale = SCALE,
        shift = SHIFT,
      },
    },
  }
end

entity.sprites = {
  north = dir_sprite(),
  east  = dir_sprite(),
  south = dir_sprite(),
  west  = dir_sprite(),
}

----------------------------------------------------------------------
-- Item
----------------------------------------------------------------------
local item = util.table.deepcopy(data.raw["item"]["constant-combinator"])
item.name = "belt-counter"
item.place_result = "belt-counter"
item.icon = ICON
item.icon_size = 64
item.icons = nil
item.icon_mipmaps = nil
item.order = "c[combinators]-z[belt-counter]"
item.subgroup = item.subgroup or "circuit-network"

----------------------------------------------------------------------
-- Recipe: modeled on the constant combinator (5 copper cable + 2 electronic
-- circuit) with extra circuitry for the counting logic. Gated behind the same
-- technology that unlocks the combinators (see below), so enabled = false.
----------------------------------------------------------------------
local recipe = {
  type = "recipe",
  name = "belt-counter",
  enabled = false,
  energy_required = 0.5,
  ingredients = {
    { type = "item", name = "copper-cable", amount = 5 },
    { type = "item", name = "electronic-circuit", amount = 5 },
  },
  results = {
    { type = "item", name = "belt-counter", amount = 1 },
  },
}

data:extend({ entity, item, recipe })

-- Unlock alongside the combinators via the circuit-network technology.
local tech = data.raw.technology["circuit-network"]
if tech then
  table.insert(tech.effects, { type = "unlock-recipe", recipe = "belt-counter" })
end

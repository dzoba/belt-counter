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
entity.icon = ICON
entity.icon_size = 64
entity.icons = nil
entity.icon_mipmaps = nil

-- Custom in-world sprite, applied to all four directions. Factorio's camera is
-- fixed (top always recedes upward), so a rotated combinator keeps the same
-- silhouette; one clean front render reads correctly from every facing.
-- SCALE/SHIFT are the in-game tweak knobs: SCALE sizes the box on the tile,
-- SHIFT nudges it (negative y = up). graphics/entity.png is a 256x256 square
-- with the object centered (~244px wide).
local ENTITY_SPRITE = "__belt-counter__/graphics/entity.png"
local SCALE = 0.14          -- ~1.07 tiles wide
local SHIFT = { 0, -0.05 }  -- slight upward nudge

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
-- Recipe (available immediately for early testing)
----------------------------------------------------------------------
local recipe = {
  type = "recipe",
  name = "belt-counter",
  enabled = true,
  energy_required = 1,
  ingredients = {
    { type = "item", name = "constant-combinator", amount = 1 },
    { type = "item", name = "electronic-circuit", amount = 5 },
  },
  results = {
    { type = "item", name = "belt-counter", amount = 1 },
  },
}

data:extend({ entity, item, recipe })

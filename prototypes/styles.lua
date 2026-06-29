-- GUI styles for the Belt Counter graph.
-- A set of flat colored bar styles (white-square tinted) — neutral for the
-- "all items" view, and one per quality so a focused item's graph takes on its
-- quality color. Bar width/height are set at runtime to draw the area chart.
local styles = data.raw["gui-style"].default

local function bar(tint)
  return {
    type = "empty_widget_style",
    graphical_set = {
      base = { filename = "__core__/graphics/white-square.png", size = 1, tint = tint },
    },
  }
end

-- highlighted slot for the currently-focused item's icon
styles["belt_counter_sel_slot"] = {
  type = "button_style",
  parent = "slot_button",
  default_graphical_set = { base = { filename = "__core__/graphics/white-square.png", size = 1, tint = { 0.30, 0.55, 0.48, 1 } } },
  hovered_graphical_set = { base = { filename = "__core__/graphics/white-square.png", size = 1, tint = { 0.38, 0.68, 0.58, 1 } } },
  clicked_graphical_set = { base = { filename = "__core__/graphics/white-square.png", size = 1, tint = { 0.30, 0.55, 0.48, 1 } } },
}

styles["belt_counter_bar"]           = bar({ 0.48, 0.80, 0.78, 1 })  -- neutral teal
styles["belt_counter_bar_normal"]    = bar({ 0.85, 0.85, 0.85, 1 })
styles["belt_counter_bar_uncommon"]  = bar({ 0.40, 0.90, 0.40, 1 })
styles["belt_counter_bar_rare"]      = bar({ 0.40, 0.60, 1.00, 1 })
styles["belt_counter_bar_epic"]      = bar({ 0.75, 0.40, 1.00, 1 })
styles["belt_counter_bar_legendary"] = bar({ 1.00, 0.60, 0.20, 1 })

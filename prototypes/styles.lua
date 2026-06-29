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

-- Highlight for the focused item's icon: make the vanilla yellow hover state
-- "stick" by reusing slot_button's own hovered graphical set as the default.
local slot = data.raw["gui-style"].default.slot_button
styles["belt_counter_sel_slot"] = {
  type = "button_style",
  parent = "slot_button",
  default_graphical_set = slot.hovered_graphical_set,
  hovered_graphical_set = slot.hovered_graphical_set,
  clicked_graphical_set = slot.clicked_graphical_set,
}

styles["belt_counter_bar"]           = bar({ 0.48, 0.80, 0.78, 1 })  -- neutral teal
styles["belt_counter_bar_normal"]    = bar({ 0.85, 0.85, 0.85, 1 })
styles["belt_counter_bar_uncommon"]  = bar({ 0.40, 0.90, 0.40, 1 })
styles["belt_counter_bar_rare"]      = bar({ 0.40, 0.60, 1.00, 1 })
styles["belt_counter_bar_epic"]      = bar({ 0.75, 0.40, 1.00, 1 })
styles["belt_counter_bar_legendary"] = bar({ 1.00, 0.60, 0.20, 1 })

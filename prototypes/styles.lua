-- GUI styles for the Belt Counter graph.
-- A single white bar whose height we set at runtime to draw the time-series.
-- (white-square ships in __core__; tinting/coloring per quality is done on
--  labels at runtime where it is well supported.)
local styles = data.raw["gui-style"].default

styles["belt_counter_bar"] = {
  type = "empty_widget_style",
  width = 7,
  graphical_set = {
    base = { filename = "__core__/graphics/white-square.png", size = 1 },
  },
}

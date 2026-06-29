-- Belt Counter runtime.
--
-- Counting model:
--   The player wires a transport belt (set to "read belt contents -> pulse")
--   to a Belt Counter. In pulse mode the belt emits a one-tick signal of count
--   1 per item entering the read position, so summing those pulses over time =
--   throughput. 2.0 circuit signals carry quality, so we bucket per (item,
--   quality).
--
--   Each tick we read the connected red & green networks and add the pulses to
--   SEVERAL independent ring buffers, one per time window (5s/1m/10m/1h/10h),
--   the same way the engine's production statistics keep one series per
--   precision level. "All" is derived from lifetime totals.
--
--   When circuit output is enabled, the counter emits the measured rate as
--   constant-combinator output. That output lands on the same network we read,
--   so we subtract our own last output from each read (feedback cancellation).

local M = require("scripts.model")

local NAME = "belt-counter"

local OUTPUT_EVERY = 15           -- recompute circuit output 4x/second
local GUI_REFRESH  = 15           -- redraw open windows ~4x/second
local GRAPH_MAX_H  = 90           -- px, tallest graph bar
local BAR_W        = 5            -- px, graph bar width (contiguous = area chart)

-- Config / helpers / data model live in the testable model module.
local WINDOWS        = M.WINDOWS
local RING_WINDOWS   = M.RING_WINDOWS
local UNITS          = M.UNITS
local QUALITY_COLOR  = M.QUALITY_COLOR
local round          = M.round
local key_of         = M.key_of
local fmt_unit       = M.fmt_unit
local fresh_counter  = M.fresh_counter

----------------------------------------------------------------------
-- registry
----------------------------------------------------------------------
local function register(entity)
  if not (entity and entity.valid and entity.name == NAME) then return end
  storage.counters[entity.unit_number] = fresh_counter(entity)
end

local function unregister(unit_number)
  if unit_number then storage.counters[unit_number] = nil end
end

local function rescan()
  storage.counters = {}
  for _, surface in pairs(game.surfaces) do
    for _, e in pairs(surface.find_entities_filtered({ name = NAME })) do
      register(e)
    end
  end
end

----------------------------------------------------------------------
-- reading signals
----------------------------------------------------------------------
local function read_network(entity, connector, into, meta)
  local net = entity.get_circuit_network(connector)
  if not (net and net.signals) then return end
  for _, s in pairs(net.signals) do
    local sig = s.signal
    if sig.type == nil or sig.type == "item" then   -- type is nil for items when read
      local quality = sig.quality or "normal"
      local k = key_of(sig.name, quality)
      into[k] = (into[k] or 0) + s.count
      if not meta[k] then meta[k] = { name = sig.name, quality = quality } end
    end
  end
end

----------------------------------------------------------------------
-- rates (wrap the model with the current game tick)
----------------------------------------------------------------------
local function rates_for(c, win_index)
  return M.rates_for(c, win_index, game.tick)
end

----------------------------------------------------------------------
-- circuit output
----------------------------------------------------------------------
local function clear_output(c)
  if not c.entity.valid then return end
  local cb = c.entity.get_or_create_control_behavior()
  local section = cb.get_section(1)
  if section then section.filters = {} end
  c.last_output = {}
end

local function write_output(c)
  if not c.entity.valid then return end
  local emitted = M.compute_output(c, c.sel_win, game.tick)   -- key -> items/min
  local cb = c.entity.get_or_create_control_behavior()
  local section = cb.get_section(1) or cb.add_section()
  if not section then return end
  local filters = {}
  for k, count in pairs(emitted) do
    local meta = c.meta[k]
    if meta then
      filters[#filters + 1] = {
        value = { type = "item", name = meta.name, quality = meta.quality, comparator = "=" },
        min = count,
      }
    end
  end
  section.filters = filters
  c.last_output = emitted
end

----------------------------------------------------------------------
-- per-tick accumulation
----------------------------------------------------------------------
local function tick_counter(c, tick)
  if not c.entity.valid then return false end

  local incoming = {}
  read_network(c.entity, defines.wire_connector_id.circuit_red, incoming, c.meta)
  read_network(c.entity, defines.wire_connector_id.circuit_green, incoming, c.meta)
  if c.output_enabled then M.apply_feedback(incoming, c.last_output) end

  M.accumulate(c, incoming, tick)

  if c.output_enabled and tick % OUTPUT_EVERY == 0 then write_output(c) end
  return true
end

local function on_tick(event)
  if not next(storage.counters) then return end
  local tick = event.tick
  local dead
  for un, c in pairs(storage.counters) do
    if not tick_counter(c, tick) then
      dead = dead or {}
      dead[#dead + 1] = un
    end
  end
  if dead then for _, un in pairs(dead) do unregister(un) end end
end

----------------------------------------------------------------------
-- GUI
----------------------------------------------------------------------
local function close_window(player)
  local w = player.gui.screen.belt_counter_window
  if w then w.destroy() end
  storage.open[player.index] = nil
end

local function build_window(player, c)
  close_window(player)
  local win = player.gui.screen.add({
    type = "frame", name = "belt_counter_window", direction = "vertical",
  })
  win.auto_center = true

  -- titlebar (draggable) ------------------------------------------------
  local title = win.add({ type = "flow", name = "bc_titlebar", direction = "horizontal" })
  title.drag_target = win
  title.add({ type = "sprite", sprite = "item/" .. NAME })
  title.add({ type = "label", caption = { "belt-counter.window-title" }, style = "frame_title" })
  local pusher = title.add({ type = "empty-widget", style = "draggable_space_header" })
  pusher.style.horizontally_stretchable = true
  pusher.style.height = 24
  pusher.drag_target = win
  local unit_dd = title.add({ type = "drop-down", name = "bc_unit", selected_index = c.unit_idx })
  for _, u in ipairs(UNITS) do unit_dd.add_item(u.label) end
  title.add({
    type = "sprite-button", name = "bc_close", style = "frame_action_button",
    sprite = "utility/close", tooltip = { "gui.close" },
  })

  local body = win.add({ type = "frame", name = "bc_body", style = "inside_shallow_frame_with_padding", direction = "vertical" })

  -- setup reminder ------------------------------------------------------
  local help = body.add({ type = "label", caption = { "belt-counter.help-line" } })
  help.tooltip = { "belt-counter.help-tooltip" }
  help.style.font_color = { 0.85, 0.78, 0.55 }
  help.style.bottom_margin = 6

  -- window (timescale) toggle ------------------------------------------
  local winrow = body.add({ type = "flow", name = "bc_winrow", direction = "horizontal" })
  winrow.add({ type = "label", caption = { "belt-counter.window-label" } }).style.right_margin = 6
  for i, def in ipairs(WINDOWS) do
    local b = winrow.add({
      type = "button", name = "bc_win_" .. i, caption = def.label, style = "button",
      tags = { bc_win = i },
    })
    b.style.width = 44
    b.style.height = 26
    b.style.padding = 0
    b.toggled = (i == c.sel_win)
  end

  body.add({ type = "label", name = "bc_summary" }).style.top_margin = 6

  -- graph ---------------------------------------------------------------
  -- axis row: peak value (Y) on the left, time span (X) on the right
  local axis = body.add({ type = "flow", name = "bc_axis", direction = "horizontal" })
  axis.style.top_margin = 4
  local peak = axis.add({ type = "label", name = "bc_peak" })
  peak.style.font_color = { 0.7, 0.7, 0.7 }
  local apush = axis.add({ type = "empty-widget" })
  apush.style.horizontally_stretchable = true
  local span = axis.add({ type = "label", name = "bc_span" })
  span.style.font_color = { 0.7, 0.7, 0.7 }

  local graph_bg = body.add({ type = "frame", name = "bc_graph_bg", style = "inside_deep_frame" })
  graph_bg.style.height = GRAPH_MAX_H + 8
  graph_bg.style.horizontally_stretchable = true
  local graph = graph_bg.add({ type = "flow", name = "bc_graph", direction = "horizontal" })
  graph.style.horizontal_spacing = 0   -- contiguous = area chart
  graph.style.vertical_align = "bottom"
  graph.style.padding = 4

  -- per item+quality table ---------------------------------------------
  local scroll = body.add({ type = "scroll-pane", name = "bc_scroll" })
  scroll.style.maximal_height = 240
  scroll.style.top_margin = 6
  local tbl = scroll.add({ type = "table", name = "bc_table", column_count = 4 })
  tbl.style.horizontal_spacing = 10
  tbl.style.vertical_spacing = 4

  -- footer: circuit output ---------------------------------------------
  body.add({ type = "line" }).style.top_margin = 6
  local foot = body.add({ type = "flow", direction = "horizontal" })
  foot.style.top_margin = 6
  foot.style.vertical_align = "center"
  foot.add({
    type = "checkbox", name = "bc_output", state = c.output_enabled,
    caption = { "belt-counter.output-rates" },
  })

  storage.open[player.index] = c.unit_number
  return win
end

local function refresh_window(player, c)
  local win = player.gui.screen.belt_counter_window
  if not win then return end
  local body = win.bc_body
  local unit = UNITS[c.unit_idx]
  local rates = rates_for(c, c.sel_win)

  -- focus: nil = all items; otherwise restrict the graph + summary to one key
  local fk = c.focus_key
  if fk and not c.meta[fk] then fk = nil; c.focus_key = nil end
  local function sample_value(s) return fk and (s.by_key[fk] or 0) or s.total end

  local total = 0
  for _, r in pairs(rates) do total = total + r end

  -- summary
  if fk then
    local m = c.meta[fk]
    body.bc_summary.caption = {
      "", "[item=" .. m.name .. ",quality=" .. m.quality .. "] ",
      { "item-name." .. m.name }, ":  ", fmt_unit(rates[fk] or 0, unit, m.name),
      "      ", { "belt-counter.clear-focus" },
    }
  else
    body.bc_summary.caption = { "belt-counter.total-line", fmt_unit(total, unit, nil) }
  end

  -- graph: ring windows plot their own samples; "All" uses the coarsest (10h)
  -- ring as a proxy. With a focus set, plot only that item's series and color
  -- the area to that item's quality.
  local gi = (c.sel_win == #WINDOWS) and RING_WINDOWS or c.sel_win
  local gwin = c.windows[gi]
  local gdef = WINDOWS[gi]
  local gname = fk and c.meta[fk].name or nil
  local bar_style = fk and ("belt_counter_bar_" .. (c.meta[fk].quality or "normal")) or "belt_counter_bar"
  local graph = body.bc_graph_bg.bc_graph
  graph.clear()
  local maxv = 1
  for i = 1, gdef.samples do
    local v = sample_value(gwin.samples[i])
    if v > maxv then maxv = v end
  end
  local sample_secs = gwin.interval / 60
  for i = 1, gdef.samples do
    local bi = ((gwin.idx + i - 1) % gdef.samples) + 1   -- oldest -> newest
    local val = sample_value(gwin.samples[bi])
    local hgt = math.max(0, round(val / maxv * GRAPH_MAX_H))
    local col = graph.add({ type = "flow", direction = "vertical" })
    col.style.vertical_spacing = 0
    local filler = col.add({ type = "empty-widget" })
    filler.style.width = BAR_W
    filler.style.height = GRAPH_MAX_H - hgt
    local bar = col.add({ type = "empty-widget", style = bar_style })
    bar.style.width = BAR_W
    bar.style.height = hgt
    bar.tooltip = fmt_unit(val / sample_secs, unit, gname)
  end

  -- axis labels: peak rate (Y) and the time span (X)
  body.bc_axis.bc_peak.caption = { "", "Peak ", fmt_unit(maxv / sample_secs, unit, gname) }
  body.bc_axis.bc_span.caption = (c.sel_win == #WINDOWS) and "all time" or ("last " .. gdef.label)

  -- table: one clickable row per item+quality (click the icon to focus)
  local tbl = body.bc_scroll.bc_table
  tbl.clear()
  for _, hd in ipairs({ "", { "belt-counter.col-item" }, { "belt-counter.col-rate" }, { "belt-counter.col-share" } }) do
    tbl.add({ type = "label", caption = hd, style = "bold_label" })
  end
  local keys = {}
  for k in pairs(c.meta) do keys[#keys + 1] = k end
  table.sort(keys, function(a, b) return (rates[a] or 0) > (rates[b] or 0) end)

  if #keys == 0 then
    tbl.add({ type = "label", caption = { "belt-counter.no-data" } })
  else
    for _, k in ipairs(keys) do
      local m = c.meta[k]
      local r = rates[k] or 0

      -- clickable item icon WITH the quality badge; click focuses the graph
      local btn = tbl.add({
        type = "button", style = "slot_button",
        caption = "[item=" .. m.name .. ",quality=" .. m.quality .. "]",
        tags = { bc_focus = k }, tooltip = { "item-name." .. m.name },
      })
      btn.style.size = 36
      btn.style.font = "default-large"
      btn.toggled = (c.focus_key == k)

      -- plain item name (quality is shown by the badge on the icon)
      local name_lbl = tbl.add({ type = "label", caption = { "item-name." .. m.name } })
      name_lbl.style.font = "default-large-semibold"
      name_lbl.style.font_color = QUALITY_COLOR[m.quality] or { 1, 1, 1 }
      name_lbl.style.left_margin = 8

      tbl.add({ type = "label", caption = fmt_unit(r, unit, m.name) })

      local share = (total > 0) and (r / total) or 0
      local cell = tbl.add({ type = "flow", direction = "horizontal" })
      cell.style.vertical_align = "center"
      cell.add({ type = "progressbar", value = share }).style.width = 70
      cell.add({ type = "label", caption = string.format("%d%%", round(share * 100)) }).style.left_margin = 6
    end
  end
end

----------------------------------------------------------------------
-- GUI events
----------------------------------------------------------------------
local function counter_for_player(player_index)
  local un = storage.open[player_index]
  return un and storage.counters[un]
end

local function on_gui_opened(event)
  local entity = event.entity
  if not (entity and entity.valid and entity.name == NAME) then return end
  local player = game.get_player(event.player_index)
  if not player then return end
  local c = storage.counters[entity.unit_number]
  if not c then register(entity); c = storage.counters[entity.unit_number] end
  local win = build_window(player, c)
  player.opened = win                 -- replaces the vanilla combinator GUI
  refresh_window(player, c)
end

local function on_gui_closed(event)
  local el = event.element
  if el and el.valid and el.name == "belt_counter_window" then
    local player = game.get_player(event.player_index)
    if player then close_window(player) end
  end
end

local function on_gui_click(event)
  local el = event.element
  if not (el and el.valid) then return end
  local player = game.get_player(event.player_index)
  if not player then return end
  if el.name == "bc_close" then
    close_window(player)
    return
  end
  local tags = el.tags
  if tags and tags.bc_win then
    local c = counter_for_player(event.player_index)
    if not c then return end
    c.sel_win = tags.bc_win
    -- update toggled states
    local winrow = el.parent
    for _, child in pairs(winrow.children) do
      if child.tags and child.tags.bc_win then child.toggled = (child.tags.bc_win == c.sel_win) end
    end
    refresh_window(player, c)
  elseif tags and tags.bc_focus then
    local c = counter_for_player(event.player_index)
    if not c then return end
    -- toggle: click the focused item again to clear back to "all"
    c.focus_key = (c.focus_key == tags.bc_focus) and nil or tags.bc_focus
    refresh_window(player, c)
  end
end

local function on_gui_selection(event)
  local el = event.element
  if not (el and el.valid and el.name == "bc_unit") then return end
  local player = game.get_player(event.player_index)
  local c = counter_for_player(event.player_index)
  if player and c then
    c.unit_idx = el.selected_index
    refresh_window(player, c)
  end
end

local function on_gui_checked(event)
  if event.element.name ~= "bc_output" then return end
  local c = counter_for_player(event.player_index)
  if not c then return end
  c.output_enabled = event.element.state
  if not c.output_enabled then clear_output(c) end
end

local function refresh_open_windows()
  for player_index, un in pairs(storage.open) do
    local c = storage.counters[un]
    local player = game.get_player(player_index)
    if player and c and c.entity.valid then
      refresh_window(player, c)
    elseif player then
      close_window(player)
    end
  end
end

----------------------------------------------------------------------
-- build / remove
----------------------------------------------------------------------
local function on_built(event)
  register(event.entity or event.created_entity)
end

local function on_removed(event)
  local e = event.entity
  if e and e.unit_number then unregister(e.unit_number) end
end

local FILTER = { { filter = "name", name = NAME } }

local function register_events()
  script.on_event(defines.events.on_tick, on_tick)
  script.on_nth_tick(GUI_REFRESH, refresh_open_windows)

  for _, ev in pairs({
    defines.events.on_built_entity, defines.events.on_robot_built_entity,
    defines.events.script_raised_built, defines.events.script_raised_revive,
    defines.events.on_space_platform_built_entity,
  }) do
    if ev then script.on_event(ev, on_built, FILTER) end
  end
  for _, ev in pairs({
    defines.events.on_player_mined_entity, defines.events.on_robot_mined_entity,
    defines.events.on_entity_died, defines.events.script_raised_destroy,
    defines.events.on_space_platform_mined_entity,
  }) do
    if ev then script.on_event(ev, on_removed, FILTER) end
  end

  script.on_event(defines.events.on_gui_opened, on_gui_opened)
  script.on_event(defines.events.on_gui_closed, on_gui_closed)
  script.on_event(defines.events.on_gui_click, on_gui_click)
  script.on_event(defines.events.on_gui_selection_state_changed, on_gui_selection)
  script.on_event(defines.events.on_gui_checked_state_changed, on_gui_checked)
end

script.on_init(function()
  storage.counters = {}
  storage.open = {}
  register_events()
end)

script.on_load(register_events)

script.on_configuration_changed(function()
  storage.counters = storage.counters or {}
  storage.open = storage.open or {}
  rescan()
end)

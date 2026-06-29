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
local STRUCT_VERSION = 4          -- bump when the window's element layout changes

-- Line-graph chart: drawn with LuaRendering onto a hidden surface, shown via a
-- camera element. 384x128 px element at zoom 0.5 = 16 px/tile = a 24x8 tile box.
local CHART_SURFACE = "belt-counter-chart"
local CHART_W, CHART_H = 24, 8        -- tiles
local CAM_W, CAM_H = 384, 128         -- camera element pixels
local CAM_ZOOM = CAM_W / (32 * CHART_W)

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
-- chart surface + LuaRendering line graph
----------------------------------------------------------------------
local function ensure_chart_surface()
  local s = game.surfaces[CHART_SURFACE]
  if s then return s end
  s = game.create_surface(CHART_SURFACE, {
    default_enable_all_autoplace_controls = false,
    autoplace_settings = {
      tile       = { settings = { ["out-of-map"] = {} } },
      decorative = { treat_missing_as_default = false, settings = {} },
      entity     = { treat_missing_as_default = false, settings = {} },
    },
    starting_area = "none",
  })
  s.generate_with_lab_tiles = true
  return s
end

-- each player draws into their own region so cameras/lines don't collide
local function chart_region(player_index)
  return (player_index - 1) * (CHART_W + 4), 0
end

local function prepare_region(surf, x0, y0)
  surf.request_to_generate_chunks({ x0 + CHART_W / 2, y0 + CHART_H / 2 }, 2)
  surf.force_generate_chunk_requests()
  local tiles = {}
  for x = x0 - 1, x0 + CHART_W + 1 do
    for y = y0 - 1, y0 + CHART_H + 1 do
      tiles[#tiles + 1] = { name = "lab-dark-1", position = { x, y } }
    end
  end
  surf.set_tiles(tiles, false)
end

local function clear_chart(player_index)
  local ids = storage.chart_ids and storage.chart_ids[player_index]
  if not ids then return end
  for _, id in ipairs(ids) do
    local o = rendering.get_object_by_id(id)
    if o and o.valid then o.destroy() end
  end
  storage.chart_ids[player_index] = nil
end

-- redraw the line + filled area for one player's window
local function draw_chart(player, c, gwin, gdef, maxv, fk)
  local surf = ensure_chart_surface()
  local x0, y0 = chart_region(player.index)
  clear_chart(player.index)
  local pf = { player.index }
  local col = fk and (QUALITY_COLOR[c.meta[fk].quality] or { 1, 1, 1 }) or { 0.48, 0.80, 0.78 }
  local ids = {}

  ids[#ids + 1] = rendering.draw_rectangle({ left_top = { x0, y0 }, right_bottom = { x0 + CHART_W, y0 + CHART_H },
    color = { 0.45, 0.45, 0.45, 0.5 }, width = 1, surface = surf, players = pf }).id
  ids[#ids + 1] = rendering.draw_line({ from = { x0, y0 + CHART_H / 2 }, to = { x0 + CHART_W, y0 + CHART_H / 2 },
    color = { 0.45, 0.45, 0.45, 0.3 }, width = 1, surface = surf, players = pf }).id

  local N = gdef.samples
  local vals = {}
  for i = 1, N do
    local bi = ((gwin.idx + i - 1) % N) + 1   -- oldest -> newest
    vals[i] = fk and (gwin.samples[bi].by_key[fk] or 0) or gwin.samples[bi].total
  end
  local function px(i) return x0 + (i - 1) / (N - 1) * CHART_W end
  local function py(v) return y0 + CHART_H * (1 - v / maxv) end   -- world Y is down

  for i = 1, N - 1 do
    ids[#ids + 1] = rendering.draw_line({ from = { px(i), py(vals[i]) }, to = { px(i + 1), py(vals[i + 1]) },
      color = col, width = 2, surface = surf, players = pf }).id
  end

  storage.chart_ids[player.index] = ids
end

----------------------------------------------------------------------
-- GUI
----------------------------------------------------------------------
local function close_window(player)
  local w = player.gui.screen.belt_counter_window
  if w then w.destroy() end
  clear_chart(player.index)
  storage.open[player.index] = nil
end

local function build_window(player, c)
  close_window(player)
  local win = player.gui.screen.add({
    type = "frame", name = "belt_counter_window", direction = "vertical",
    tags = { struct = STRUCT_VERSION },
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

  -- graph with a Y axis -------------------------------------------------
  local graph_bg = body.add({ type = "frame", name = "bc_graph_bg", style = "inside_deep_frame" })
  graph_bg.style.top_margin = 4
  graph_bg.style.horizontally_stretchable = true
  local grow = graph_bg.add({ type = "flow", name = "bc_graph_row", direction = "horizontal" })
  grow.style.padding = 4
  grow.style.vertical_align = "top"

  -- Y axis: max (top) / mid (center) / 0 (bottom), pushed apart by fillers
  local yax = grow.add({ type = "flow", name = "bc_yaxis", direction = "vertical" })
  yax.style.width = 42
  yax.style.height = CAM_H
  yax.style.horizontal_align = "right"
  for _, n in ipairs({ "bc_ymax", "bc_ymid", "bc_yzero" }) do
    local l = yax.add({ type = "label", name = n })
    l.style.font = "default-small"
    l.style.font_color = { 0.7, 0.7, 0.7 }
    if n ~= "bc_yzero" then
      yax.add({ type = "empty-widget" }).style.vertically_stretchable = true
    end
  end

  local cx, cy = chart_region(player.index)
  local surf
  local ok = pcall(function() surf = ensure_chart_surface(); prepare_region(surf, cx, cy) end)
  local cam
  if ok and surf then
    cam = grow.add({ type = "camera", name = "bc_camera", surface_index = surf.index,
      position = { cx + CHART_W / 2, cy + CHART_H / 2 }, zoom = CAM_ZOOM })
  else
    cam = grow.add({ type = "empty-widget", name = "bc_camera" })   -- graceful fallback
    log("belt-counter: chart surface setup failed")
  end
  cam.style.width = CAM_W
  cam.style.height = CAM_H
  cam.style.left_margin = 4

  -- X axis row: a "Show all" button (only while focused) + the time span
  local xrow = body.add({ type = "flow", name = "bc_xrow", direction = "horizontal" })
  xrow.style.top_margin = 2
  xrow.style.vertical_align = "center"
  local clr = xrow.add({ type = "button", name = "bc_clear", caption = { "belt-counter.show-all" } })
  clr.style.height = 24
  clr.style.font = "default-small"
  clr.visible = false
  xrow.add({ type = "empty-widget" }).style.horizontally_stretchable = true
  local span = xrow.add({ type = "label", name = "bc_span" })
  span.style.font_color = { 0.7, 0.7, 0.7 }

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
  -- discard a window left over from an older mod version (different layout)
  if (win.tags.struct or 0) ~= STRUCT_VERSION then close_window(player); return end
  local body = win.bc_body
  local unit = UNITS[c.unit_idx]
  local rates = rates_for(c, c.sel_win)

  -- focus: nil = all items; otherwise restrict the graph + summary to one key
  local fk = c.focus_key
  if fk and not c.meta[fk] then fk = nil; c.focus_key = nil end
  local function sample_value(s) return fk and (s.by_key[fk] or 0) or s.total end

  local total = 0
  for _, r in pairs(rates) do total = total + r end

  -- summary (plain text — rich-text icons render fuzzy, so we avoid them)
  if fk then
    local m = c.meta[fk]
    body.bc_summary.caption = { "", { "item-name." .. m.name }, ":  ", fmt_unit(rates[fk] or 0, unit, m.name) }
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
  local maxv = 1
  for i = 1, gdef.samples do
    local v = sample_value(gwin.samples[i])
    if v > maxv then maxv = v end
  end
  local sample_secs = gwin.interval / 60
  local dok, derr = pcall(draw_chart, player, c, gwin, gdef, maxv, fk)
  if not dok then log("belt-counter draw_chart error: " .. tostring(derr)) end

  -- Y-axis numbers (max / mid / 0), X-axis span, and show-all visibility
  local peak_rate = maxv / sample_secs
  local yax = body.bc_graph_bg.bc_graph_row.bc_yaxis
  yax.bc_ymax.caption = fmt_unit(peak_rate, unit, gname)
  yax.bc_ymid.caption = fmt_unit(peak_rate / 2, unit, gname)
  yax.bc_yzero.caption = "0"
  body.bc_xrow.bc_span.caption = (c.sel_win == #WINDOWS) and "all time" or ("last " .. gdef.label)
  body.bc_xrow.bc_clear.visible = (fk ~= nil)

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

      -- sharp NATIVE item icon + quality badge. A locked choose-elem-button
      -- won't open the picker but still fires on_gui_click, so it doubles as the
      -- filter button.
      local btn = tbl.add({
        type = "choose-elem-button", elem_type = "item-with-quality",
        tags = { bc_focus = k }, tooltip = { "item-name." .. m.name },
      })
      btn.elem_value = { name = m.name, quality = m.quality }
      btn.locked = true
      -- highlight the focused item's icon background
      if c.focus_key == k then pcall(function() btn.style = "belt_counter_sel_slot" end) end

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
  if el.name == "bc_clear" then
    local c = counter_for_player(event.player_index)
    if c then c.focus_key = nil; refresh_window(player, c) end
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
    if c.focus_key == tags.bc_focus then
      c.focus_key = nil
    else
      c.focus_key = tags.bc_focus
    end
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
  storage.chart_ids = {}
  register_events()
end)

script.on_load(register_events)

script.on_configuration_changed(function()
  storage.counters = storage.counters or {}
  storage.open = storage.open or {}
  storage.chart_ids = {}
  rendering.clear("belt-counter")   -- drop any stale chart render objects
  -- close any windows left open across a mod update; they rebuild on next open
  for _, player in pairs(game.players) do
    local w = player.gui.screen.belt_counter_window
    if w then w.destroy() end
  end
  storage.open = {}
  rescan()
end)

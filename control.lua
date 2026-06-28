-- Belt Counter runtime.
--
-- Counting model:
--   The player wires a transport belt (set to "read belt contents -> pulse")
--   to a Belt Counter. In pulse mode the belt emits a one-tick signal of count
--   1 per item entering the read position, so summing those pulses over time =
--   throughput. 2.0 circuit signals carry quality, so we bucket per (item,
--   quality).
--
--   We read the connected red & green networks every tick and add the pulses to
--   a ring of 1-second buckets (a rolling window) plus lifetime totals.
--
--   When "output rates" is enabled, the counter emits the measured items/min as
--   constant-combinator output. Because that output lands on the same network we
--   read, we subtract our own last output from each read (feedback cancellation).

local NAME = "belt-counter"

local BUCKET_TICKS = 60          -- 1 second per bucket
local NUM_BUCKETS  = 30          -- rolling window length (seconds)
local OUTPUT_EVERY = 15          -- recompute circuit output 4x/second
local GUI_REFRESH  = 15          -- redraw open GUIs 4x/second
local GRAPH_MAX_H  = 80          -- px, tallest graph bar
local BAR_W        = 7           -- px, graph bar width

local QUALITY_COLOR = {
  normal    = {0.85, 0.85, 0.85},
  uncommon  = {0.4,  0.9,  0.4 },
  rare      = {0.4,  0.6,  1.0 },
  epic      = {0.75, 0.4,  1.0 },
  legendary = {1.0,  0.6,  0.2 },
}
local QUALITY_LETTER = {
  normal = "N", uncommon = "U", rare = "R", epic = "E", legendary = "L",
}

----------------------------------------------------------------------
-- helpers
----------------------------------------------------------------------
local function round(x) return math.floor(x + 0.5) end

local function key_of(name, quality) return name .. "/" .. quality end

local function new_bucket() return { total = 0, by_key = {} } end

local function fresh_counter(entity)
  local buckets = {}
  for i = 1, NUM_BUCKETS do buckets[i] = new_bucket() end
  return {
    entity         = entity,
    unit_number    = entity.unit_number,
    buckets        = buckets,
    idx            = 1,          -- current (newest) bucket
    tick_in_bucket = 0,
    warm           = 1,          -- buckets that have collected data (<= NUM_BUCKETS)
    totals         = {},         -- key -> lifetime count
    meta           = {},         -- key -> {name=, quality=}
    output_enabled = false,
    last_output    = {},         -- key -> count we emitted (for feedback cancel)
  }
end

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
-- Accumulate item signals from a network into `into` (key -> count), recording
-- prototype info in `meta`.
local function read_network(entity, connector, into, meta)
  local net = entity.get_circuit_network(connector)
  if not (net and net.signals) then return end
  for _, s in pairs(net.signals) do
    local sig = s.signal
    -- when reading, type is nil for items
    if sig.type == nil or sig.type == "item" then
      local quality = sig.quality or "normal"
      local k = key_of(sig.name, quality)
      into[k] = (into[k] or 0) + s.count
      if not meta[k] then meta[k] = { name = sig.name, quality = quality } end
    end
  end
end

----------------------------------------------------------------------
-- rate computation
----------------------------------------------------------------------
-- Sum each key over the whole window. Returns key->count_in_window and the
-- window length in seconds.
local function window_sums(c)
  local sums = {}
  for i = 1, NUM_BUCKETS do
    for k, v in pairs(c.buckets[i].by_key) do
      sums[k] = (sums[k] or 0) + v
    end
  end
  return sums, c.warm
end

local function rate_per_min(c)
  local sums, seconds = window_sums(c)
  local rates = {}
  for k, v in pairs(sums) do
    rates[k] = v / seconds * 60
  end
  return rates
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
  local rates = rate_per_min(c)
  local cb = c.entity.get_or_create_control_behavior()
  local section = cb.get_section(1) or cb.add_section()
  if not section then return end

  local filters = {}
  local emitted = {}
  for k, meta in pairs(c.meta) do
    local r = round(rates[k] or 0)
    if r ~= 0 then
      filters[#filters + 1] = {
        value = { type = "item", name = meta.name, quality = meta.quality, comparator = "=" },
        min = r,
      }
      emitted[k] = r
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

  -- cancel our own emitted output so only real belt pulses remain
  if c.output_enabled then
    for k, v in pairs(c.last_output) do
      incoming[k] = (incoming[k] or 0) - v
    end
  end

  local bucket = c.buckets[c.idx]
  for k, v in pairs(incoming) do
    if v > 0 then
      bucket.total = bucket.total + v
      bucket.by_key[k] = (bucket.by_key[k] or 0) + v
      c.totals[k] = (c.totals[k] or 0) + v
    end
  end

  -- advance bucket once per second
  c.tick_in_bucket = c.tick_in_bucket + 1
  if c.tick_in_bucket >= BUCKET_TICKS then
    c.tick_in_bucket = 0
    c.idx = (c.idx % NUM_BUCKETS) + 1
    c.buckets[c.idx] = new_bucket()
    if c.warm < NUM_BUCKETS then c.warm = c.warm + 1 end
  end

  if c.output_enabled and tick % OUTPUT_EVERY == 0 then
    write_output(c)
  end
  return true
end

local function on_tick(event)
  if not next(storage.counters) then return end
  local tick = event.tick
  local dead = nil
  for unit_number, c in pairs(storage.counters) do
    if not tick_counter(c, tick) then
      dead = dead or {}
      dead[#dead + 1] = unit_number
    end
  end
  if dead then for _, un in pairs(dead) do unregister(un) end end
end

----------------------------------------------------------------------
-- GUI
----------------------------------------------------------------------
local function build_panel(player)
  local rel = player.gui.relative
  if rel.belt_counter_panel then return rel.belt_counter_panel end

  local frame = rel.add({
    type = "frame",
    name = "belt_counter_panel",
    caption = { "belt-counter.window-title" },
    direction = "vertical",
    anchor = {
      gui = defines.relative_gui_type.constant_combinator_gui,
      position = defines.relative_gui_position.right,
    },
  })
  frame.style.minimal_width = 280

  -- Persistent setup reminder: the wired belt must be in "read contents -> pulse"
  -- mode or counts will be wrong. Hover for the full how-to.
  local help = frame.add({ type = "label", name = "bc_help", caption = { "belt-counter.help-line" } })
  help.tooltip = { "belt-counter.help-tooltip" }
  help.style.font_color = { 0.85, 0.78, 0.55 }
  help.style.single_line = false
  help.style.bottom_margin = 6

  local summary = frame.add({ type = "label", name = "bc_summary" })
  summary.style.bottom_margin = 6

  frame.add({ type = "label", caption = "Throughput (last " .. NUM_BUCKETS .. "s)" })
  local graph_bg = frame.add({ type = "frame", name = "bc_graph_bg", style = "inside_shallow_frame" })
  graph_bg.style.height = GRAPH_MAX_H + 8
  graph_bg.style.horizontally_stretchable = true
  local graph = graph_bg.add({ type = "flow", name = "bc_graph", direction = "horizontal" })
  graph.style.horizontal_spacing = 1
  graph.style.vertical_align = "bottom"
  graph.style.top_padding = 4

  frame.add({ type = "line" })
  local scroll = frame.add({ type = "scroll-pane", name = "bc_scroll" })
  scroll.style.maximal_height = 200
  local tbl = scroll.add({ type = "table", name = "bc_table", column_count = 4 })
  tbl.style.horizontal_spacing = 8

  frame.add({ type = "line" })
  frame.add({
    type = "checkbox",
    name = "bc_output",
    caption = { "belt-counter.output-rates" },
    state = false,
  })

  return frame
end

local function refresh_panel(player, c)
  local frame = player.gui.relative.belt_counter_panel
  if not frame then return end

  local rates = rate_per_min(c)

  -- summary: current total items/min
  local total_rate = 0
  for _, r in pairs(rates) do total_rate = total_rate + r end
  frame.bc_summary.caption = "Total: " .. round(total_rate) .. "/min"

  -- graph: oldest -> newest left to right
  local graph = frame.bc_graph_bg.bc_graph
  graph.clear()
  local max_total = 1
  for i = 1, NUM_BUCKETS do
    if c.buckets[i].total > max_total then max_total = c.buckets[i].total end
  end
  for i = 1, NUM_BUCKETS do
    local bi = ((c.idx + i - 1) % NUM_BUCKETS) + 1   -- start just past newest = oldest
    local val = c.buckets[bi].total
    local h = math.max(0, round(val / max_total * GRAPH_MAX_H))
    local col = graph.add({ type = "flow", direction = "vertical" })
    col.style.vertical_spacing = 0
    local filler = col.add({ type = "empty-widget" })
    filler.style.width = BAR_W
    filler.style.height = GRAPH_MAX_H - h
    local bar = col.add({ type = "empty-widget", style = "belt_counter_bar" })
    bar.style.height = h
    bar.tooltip = tostring(val) .. " items/s"
  end

  -- per (item,quality) table
  local tbl = frame.bc_scroll.bc_table
  tbl.clear()
  for _, h in pairs({ "", "/min", "total", "" }) do
    local lbl = tbl.add({ type = "label", caption = h })
    lbl.style.font = "default-bold"
  end

  local keys = {}
  for k in pairs(c.meta) do keys[#keys + 1] = k end
  table.sort(keys, function(a, b)
    local ma, mb = c.meta[a], c.meta[b]
    if ma.name ~= mb.name then return ma.name < mb.name end
    return ma.quality < mb.quality
  end)

  if #keys == 0 then
    tbl.add({ type = "label", caption = { "belt-counter.no-data" } })
  else
    for _, k in pairs(keys) do
      local m = c.meta[k]
      local icon = tbl.add({ type = "sprite", sprite = "item/" .. m.name })
      icon.style.size = 24
      icon.tooltip = m.name

      local rate_lbl = tbl.add({ type = "label", caption = tostring(round(rates[k] or 0)) })

      tbl.add({ type = "label", caption = tostring(c.totals[k] or 0) })

      local q = tbl.add({ type = "label", caption = (QUALITY_LETTER[m.quality] or "?") })
      q.style.font_color = QUALITY_COLOR[m.quality] or {1, 1, 1}
      q.style.font = "default-bold"
      q.tooltip = m.quality
      rate_lbl.style.font_color = QUALITY_COLOR[m.quality] or {1, 1, 1}
    end
  end
end

local function on_gui_opened(event)
  local entity = event.entity
  local player = game.get_player(event.player_index)
  if not player then return end
  local panel = player.gui.relative.belt_counter_panel
  if entity and entity.valid and entity.name == NAME then
    local c = storage.counters[entity.unit_number]
    if not c then register(entity); c = storage.counters[entity.unit_number] end
    panel = build_panel(player)
    panel.visible = true
    panel.bc_output.state = c.output_enabled
    storage.open[event.player_index] = entity.unit_number
    refresh_panel(player, c)
  elseif panel then
    -- a vanilla constant combinator (or anything else) opened: hide our panel
    panel.visible = false
  end
end

local function on_gui_closed(event)
  local player = game.get_player(event.player_index)
  if player and player.gui.relative.belt_counter_panel then
    player.gui.relative.belt_counter_panel.visible = false
  end
  storage.open[event.player_index] = nil
end

local function on_gui_checked(event)
  if event.element.name ~= "bc_output" then return end
  local un = storage.open[event.player_index]
  local c = un and storage.counters[un]
  if not c then return end
  c.output_enabled = event.element.state
  if not c.output_enabled then clear_output(c) end
end

local function refresh_open_guis()
  for player_index, unit_number in pairs(storage.open) do
    local c = storage.counters[unit_number]
    local player = game.get_player(player_index)
    if player and c and c.entity.valid then
      refresh_panel(player, c)
    end
  end
end

----------------------------------------------------------------------
-- event wiring
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
  script.on_nth_tick(GUI_REFRESH, refresh_open_guis)

  local built = {
    defines.events.on_built_entity,
    defines.events.on_robot_built_entity,
    defines.events.script_raised_built,
    defines.events.script_raised_revive,
    defines.events.on_space_platform_built_entity,
  }
  for _, ev in pairs(built) do
    if ev then script.on_event(ev, on_built, FILTER) end
  end

  local removed = {
    defines.events.on_player_mined_entity,
    defines.events.on_robot_mined_entity,
    defines.events.on_entity_died,
    defines.events.script_raised_destroy,
    defines.events.on_space_platform_mined_entity,
  }
  for _, ev in pairs(removed) do
    if ev then script.on_event(ev, on_removed, FILTER) end
  end

  script.on_event(defines.events.on_gui_opened, on_gui_opened)
  script.on_event(defines.events.on_gui_closed, on_gui_closed)
  script.on_event(defines.events.on_gui_checked_state_changed, on_gui_checked)
end

script.on_init(function()
  storage.counters = {}
  storage.open = {}
  register_events()
end)

script.on_load(function()
  register_events()
end)

script.on_configuration_changed(function()
  storage.counters = storage.counters or {}
  storage.open = storage.open or {}
  rescan()
end)

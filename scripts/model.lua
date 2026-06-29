-- Belt Counter — pure data model (no Factorio I/O, so it runs under plain Lua).
--
-- Holds the time-window ring buffers, lifetime totals, rate math and unit
-- formatting. control.lua feeds it an `incoming` table (key -> count this tick)
-- and reads rates back; everything here is deterministic and unit-testable.
--
-- The only external dependency is the global `prototypes` (for item stack sizes),
-- used solely by stack_size(); tests stub it.

local M = {}

-- Time windows. Each ring advances one sample every `seconds*60/samples` ticks.
-- The last entry ("all") has no ring; it is derived from lifetime totals.
M.WINDOWS = {
  { id = "5s",  label = "5s",  seconds = 5,     samples = 50 },
  { id = "1m",  label = "1m",  seconds = 60,    samples = 60 },
  { id = "10m", label = "10m", seconds = 600,   samples = 60 },
  { id = "1h",  label = "1h",  seconds = 3600,  samples = 60 },
  { id = "10h", label = "10h", seconds = 36000, samples = 60 },
  { id = "all", label = "All", seconds = nil,   samples = 0  },
}
M.RING_WINDOWS = 5
M.DEFAULT_WIN  = 2   -- 1m

M.UNITS = {
  { id = "per_s",    label = "items/s",   factor = 1,    suffix = "/s" },
  { id = "per_m",    label = "items/min", factor = 60,   suffix = "/m" },
  { id = "per_h",    label = "items/h",   factor = 3600, suffix = "/h" },
  { id = "stacks_s", label = "stacks/s",  stacks = true, suffix = " stk/s" },
}
M.DEFAULT_UNIT = 1

M.QUALITY_COLOR = {
  normal    = { 0.85, 0.85, 0.85 },
  uncommon  = { 0.4,  0.9,  0.4 },
  rare      = { 0.4,  0.6,  1.0 },
  epic      = { 0.75, 0.4,  1.0 },
  legendary = { 1.0,  0.6,  0.2 },
}
M.QUALITY_LETTER = {
  normal = "N", uncommon = "U", rare = "R", epic = "E", legendary = "L",
}

local WINDOWS = M.WINDOWS
local RING_WINDOWS = M.RING_WINDOWS

local function round(x) return math.floor(x + 0.5) end
M.round = round

function M.key_of(name, quality) return name .. "/" .. quality end

local function new_sample() return { total = 0, by_key = {} } end
M.new_sample = new_sample

function M.stack_size(name)
  local proto = prototypes.item[name]
  return (proto and proto.stack_size) or 1
end

local function fmt(v)
  if v == 0 then return "0" end
  if v >= 100 then return tostring(round(v)) end
  return string.format("%.1f", v)
end
M.fmt = fmt

-- per-second value -> string in the given unit
function M.fmt_unit(per_sec, unit, item_name)
  if unit.stacks then
    return fmt(per_sec / M.stack_size(item_name)) .. unit.suffix
  end
  return fmt(per_sec * unit.factor) .. unit.suffix
end

function M.fresh_counter(entity)
  local windows = {}
  for w = 1, RING_WINDOWS do
    local def = WINDOWS[w]
    local samples = {}
    for i = 1, def.samples do samples[i] = new_sample() end
    windows[w] = {
      samples  = samples,
      idx      = 1,
      ticks    = 0,
      interval = math.max(1, round(def.seconds * 60 / def.samples)),
      warm     = 1,
    }
  end
  return {
    entity         = entity,
    unit_number    = entity and entity.unit_number,
    windows        = windows,
    totals         = {},
    meta           = {},
    start_tick     = nil,
    output_enabled = false,
    last_output    = {},
    sel_win        = M.DEFAULT_WIN,
    unit_idx       = M.DEFAULT_UNIT,
    focus_key      = nil,         -- nil = graph shows all items; else a single key
  }
end

-- Add this tick's counts (key -> count, may be 0/negative after feedback cancel)
-- to every ring window and lifetime totals, then advance each ring's clock.
function M.accumulate(c, incoming, tick)
  if not c.start_tick then c.start_tick = tick end

  for k, v in pairs(incoming) do
    if v > 0 then
      for w = 1, RING_WINDOWS do
        local s = c.windows[w].samples[c.windows[w].idx]
        s.total = s.total + v
        s.by_key[k] = (s.by_key[k] or 0) + v
      end
      c.totals[k] = (c.totals[k] or 0) + v
    end
  end

  for w = 1, RING_WINDOWS do
    local win = c.windows[w]
    win.ticks = win.ticks + 1
    if win.ticks >= win.interval then
      win.ticks = 0
      win.idx = (win.idx % WINDOWS[w].samples) + 1
      win.samples[win.idx] = new_sample()
      if win.warm < WINDOWS[w].samples then win.warm = win.warm + 1 end
    end
  end
end

-- Subtract our own last-emitted output from a freshly-read network so only real
-- belt pulses remain. The constant combinator emits its output onto the same
-- wire we read, so without this the counter would tally its own output.
function M.apply_feedback(incoming, last_output)
  for k, v in pairs(last_output) do
    incoming[k] = (incoming[k] or 0) - v
  end
end

-- The circuit output to emit for the selected window: key -> items/min (rounded,
-- nonzero only). control.lua maps these keys to item+quality signal filters.
function M.compute_output(c, win_index, now_tick)
  local rates = M.rates_for(c, win_index, now_tick)
  local out = {}
  for k, r in pairs(rates) do
    local per_min = round(r * 60)
    if per_min ~= 0 then out[k] = per_min end
  end
  return out
end

-- per-second rate for every key in the selected window. now_tick is required for
-- the "All" window (lifetime average over uptime).
function M.rates_for(c, win_index, now_tick)
  local rates = {}
  if win_index == #WINDOWS then
    local uptime = math.max(1, (now_tick - (c.start_tick or now_tick)) / 60)
    for k, v in pairs(c.totals) do rates[k] = v / uptime end
    return rates, uptime
  end
  local win = c.windows[win_index]
  local def = WINDOWS[win_index]
  local sums = {}
  for i = 1, def.samples do
    for k, v in pairs(win.samples[i].by_key) do
      sums[k] = (sums[k] or 0) + v
    end
  end
  local elapsed = math.max(0.001, math.min(win.warm, def.samples) * win.interval / 60)
  for k, v in pairs(sums) do rates[k] = v / elapsed end
  return rates, elapsed
end

return M

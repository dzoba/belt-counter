-- Pure-Lua tests for the Belt Counter model. No Factorio needed.
-- Run from the repo root:  lua tests/run.lua
--
-- Mocks the only engine global the model touches (`prototypes`, for stack sizes)
-- then drives M.accumulate over simulated ticks and checks the rate math,
-- ring-buffer behavior, quality separation and unit formatting.

package.path = "./?.lua;" .. package.path

-- minimal mock of the prototypes global
_G.prototypes = {
  item = {
    ["iron-plate"]   = { stack_size = 100 },
    ["copper-plate"] = { stack_size = 50 },
  },
}

local M = require("scripts.model")

----------------------------------------------------------------------
local n, fails = 0, 0
local function ok(cond, msg)
  n = n + 1
  if not cond then fails = fails + 1; print("  FAIL: " .. msg) end
end
local function eq(a, b, msg)
  ok(a == b, (msg or "eq") .. " — expected " .. tostring(b) .. ", got " .. tostring(a))
end
local function near(a, b, tol, msg)
  tol = tol or 0.01
  ok(math.abs(a - b) <= tol, (msg or "near") .. " — expected ~" .. tostring(b) .. ", got " .. tostring(a))
end

local function counter() return M.fresh_counter({ unit_number = 1, valid = true }) end
local function feed(c, incoming, ticks, start)
  start = start or 0
  for t = 1, ticks do M.accumulate(c, incoming, start + t) end
end
local IRON = "iron-plate/normal"

----------------------------------------------------------------------
print("fresh_counter structure")
do
  local c = counter()
  eq(#c.windows, M.RING_WINDOWS, "ring window count")
  eq(c.windows[1].interval, 6,     "5s interval (5*60/50)")
  eq(c.windows[2].interval, 60,    "1m interval")
  eq(c.windows[3].interval, 600,   "10m interval")
  eq(c.windows[4].interval, 3600,  "1h interval")
  eq(c.windows[5].interval, 36000, "10h interval")
  eq(c.sel_win, M.DEFAULT_WIN, "default window")
end

print("single tick accumulation")
do
  local c = counter()
  M.accumulate(c, { [IRON] = 3 }, 1)
  eq(c.start_tick, 1, "start_tick set")
  eq(c.totals[IRON], 3, "lifetime total")
  for w = 1, M.RING_WINDOWS do
    eq(c.windows[w].samples[c.windows[w].idx].total, 3, "window " .. w .. " current sample")
  end
end

print("ignores zero / negative (post-feedback) input")
do
  local c = counter()
  M.accumulate(c, { [IRON] = 0 }, 1)
  M.accumulate(c, { [IRON] = -5 }, 2)
  eq(c.totals[IRON], nil, "no totals from non-positive input")
end

print("steady throughput -> correct rate (1 item/tick = 60/s)")
do
  local c = counter()
  feed(c, { [IRON] = 1 }, 40000)   -- fills 5s, 1m, 10m windows
  local r5  = M.rates_for(c, 1, 40000)[IRON]
  local r1m = M.rates_for(c, 2, 40000)[IRON]
  local r10 = M.rates_for(c, 3, 40000)[IRON]
  near(r5,  60, 2, "5s rate ~60/s")
  near(r1m, 60, 2, "1m rate ~60/s")
  near(r10, 60, 2, "10m rate ~60/s")
  local rAll = M.rates_for(c, #M.WINDOWS, 40000)[IRON]
  near(rAll, 60, 1, "All-time rate ~60/s")
end

print("per-item + per-quality separation and shares")
do
  local c = counter()
  feed(c, { ["iron-plate/normal"] = 2, ["iron-plate/rare"] = 1, ["copper-plate/normal"] = 1 }, 4000)
  local r = M.rates_for(c, 2, 4000)
  near(r["iron-plate/normal"],   120, 3, "iron normal ~120/s")
  near(r["iron-plate/rare"],     60,  2, "iron rare ~60/s (separate from normal)")
  near(r["copper-plate/normal"], 60,  2, "copper ~60/s")
  -- quality variants are distinct keys
  ok(r["iron-plate/normal"] ~= r["iron-plate/rare"], "normal and rare are distinct series")
end

print("unit formatting")
do
  eq(M.fmt(0), "0", "fmt 0")
  eq(M.fmt(5), "5.0", "fmt small -> 1 decimal")
  eq(M.fmt(150), "150", "fmt >=100 -> integer")
  local per_s = M.UNITS[1]
  local per_m = M.UNITS[2]
  local stk   = M.UNITS[4]
  eq(M.fmt_unit(30, per_s), "30.0/s", "items/s")
  eq(M.fmt_unit(30, per_m), "1800/m", "items/min (×60)")
  eq(M.fmt_unit(30, stk, "iron-plate"), "0.3 stk/s", "stacks/s (÷100)")
  eq(M.fmt_unit(30, stk, "copper-plate"), "0.6 stk/s", "stacks/s (÷50)")
end

print("window rings advance independently (1h not full early)")
do
  local c = counter()
  feed(c, { [IRON] = 1 }, 300)   -- 5s fills (300 ticks), 1h barely moved
  ok(c.windows[1].warm >= 50, "5s warmed up")
  ok(c.windows[4].warm < 5,  "1h still warming")
end

print("feedback cancellation: count stays accurate with circuit output ON")
do
  -- Simulate control.lua's real loop: each tick the wire carries the belt's
  -- pulse PLUS whatever the counter is currently emitting. If feedback
  -- cancellation is wrong, the counter tallies its own output and the rate
  -- explodes. Belt = 1 iron/tick = a true 60/s.
  local c = counter()
  c.output_enabled = true
  c.sel_win = 2 -- 1m
  local OUTPUT_EVERY = 15
  local our_output = {} -- what the constant combinator currently puts on the wire
  for tick = 1, 40000 do
    local wire = { [IRON] = 1 }                     -- belt pulse this tick
    for k, v in pairs(our_output) do wire[k] = (wire[k] or 0) + v end  -- + our own output
    M.apply_feedback(wire, c.last_output)           -- real cancellation code
    M.accumulate(c, wire, tick)
    if tick % OUTPUT_EVERY == 0 then
      our_output = M.compute_output(c, c.sel_win, tick)  -- real output code
      c.last_output = our_output
    end
  end
  local r = M.rates_for(c, 2, 40000)[IRON]
  near(r, 60, 2, "1m rate stays ~60/s despite the counter's own output on the wire")
  -- and prove the test is meaningful: the counter WAS emitting a large value
  ok((our_output[IRON] or 0) > 1000, "counter was actually emitting (~3600/min) — feedback had real work to do")
end

----------------------------------------------------------------------
print(string.format("\n%d checks, %d failures", n, fails))
os.exit(fails == 0 and 0 or 1)

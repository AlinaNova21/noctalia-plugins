--!nonstrict
-- series.luau spec: normalize, stats, normalizeGraph, zone, crossing.
-- CLI-runnable with the repo's luau tooling.

local series = require("../series")

local function expect(label, got, want)
  if got ~= want then
    error(string.format("%s: got %q want %q", label, tostring(got), tostring(want)), 0)
  end
end

local function expectNil(label, got)
  if got ~= nil then
    error(string.format("%s: got %q want nil", label, tostring(got)), 0)
  end
end

-- ── normalize ───────────────────────────────────────────────────────────────

local raw = {
  { date = 3000, sgv = 100, direction = "Flat", delta = 1, noise = 1, device = "xDrip-Follower", id = "a" },
  { date = 1000, sgv = 80, direction = "SingleUp", delta = 2, noise = 3 },
  { date = 2000, sgv = 120, direction = "DoubleUp" },
  { date = nil, sgv = 95 },   -- dropped (unparseable date)
  { date = 1500, sgv = "bad" }, -- dropped (non-numeric sgv)
  { sgv = 90 },                 -- dropped (no date)
}
local s = series.normalize(raw)
expect("n.size", #s, 3)
expect("n.sorted1", s[1].date, 1000)
expect("n.sorted2", s[2].date, 2000)
expect("n.sorted3", s[3].date, 3000)
expect("n.meta", s[3].direction, "Flat")
expect("n.metaDelta", s[3].delta, 1)
expect("n.noMeta", s[1].delta, 2)
expect("n.nilMeta", s[2].device, nil)
local hasNilDate = false
for _, p in ipairs(s) do
  if p.date == nil then
    hasNilDate = true
  end
end
expect("n.droppedNilDate", hasNilDate, false)

expect("n.empty", #series.normalize(nil), 0)
expect("n.notTable", #series.normalize("x"), 0)

-- ── stats ────────────────────────────────────────────────────────────────────

local st = series.stats(s)
expect("s.min", st.min, 80)
expect("s.max", st.max, 120)
expect("s.avg", st.avg, 100)
expect("s.current", st.current, 100)
expect("s.direction", st.direction, "Flat")
expect("s.lastDate", st.lastDate, 3000)

expectNil("s.empty", series.stats({}))

-- ── normalizeGraph ──────────────────────────────────────────────────────────

local g = series.normalizeGraph({ { date = 1, sgv = 70 }, { date = 2, sgv = 140 } }, 70, 140)
expect("g.size", #g, 2)
expect("g.lo", g[1], 0)
expect("g.hi", g[2], 1)

-- Tight span with wide data => clamped
local g2 = series.normalizeGraph({ { date = 1, sgv = 70 }, { date = 2, sgv = 90 } }, 70, 80)
expect("g2.lo", g2[1], 0)
expect("g2.clampedHi", g2[2], 1)

-- Uniform series with explicit bounds: maps to its position in the range
local g3 = series.normalizeGraph({ { date = 1, sgv = 99 }, { date = 2, sgv = 99 } }, 70, 140)
expect("g3.inRange", g3[1], 0.4142857142857143)
expect("g3.inRange2", g3[2], 0.4142857142857143)

-- Uniform series with no bounds: derived span is 0, so it middles at 0.5
local g3b = series.normalizeGraph({ { date = 1, sgv = 99 }, { date = 2, sgv = 99 } })
expect("g3b.mid", g3b[1], 0.5)
expect("g3b.mid2", g3b[2], 0.5)

-- No bounds: derive from data
local g4 = series.normalizeGraph({ { date = 1, sgv = 80 }, { date = 2, sgv = 120 } })
expect("g4.lo", g4[1], 0)
expect("g4.hi", g4[2], 1)

expect("g.empty", #series.normalizeGraph({}), 0)

-- ── zone ─────────────────────────────────────────────────────────────────────

-- ── window / delta / timeHhMm ────────────────────────────────────────────────

local wp = { { date = 1000, sgv = 80 }, { date = 2000, sgv = 100 }, { date = 3000, sgv = 120 } }
local w = series.window(wp, 1500)
expect("w.size", #w, 2)
expect("w.first", w[1].date, 2000)
expect("w.last", w[2].date, 3000)
expect("w.noMutate", #wp, 3)
expect("w.empty", #series.window({}, 1), 0)
expect("w.noFrom", #series.window(wp, nil), 0)

expect("d.two", series.delta({ { date = 1, sgv = 100 }, { date = 2, sgv = 107 } }), 7)
expect("d.drop", series.delta({ { date = 1, sgv = 100 }, { date = 2, sgv = 91 } }), -9)
expectNil("d.one", series.delta({ { date = 1, sgv = 100 } }))
expectNil("d.none", series.delta({}))

expect("t.midnight", series.timeHhMm(0), "00:00")
expect("t.noon", series.timeHhMm(12 * 3600000), "12:00")
expect("t.general", series.timeHhMm(9.5 * 3600000 + 42 * 60000), "10:12")
expectNil("t.nil", series.timeHhMm(nil))


-- ── zone ─────────────────────────────────────────────────────────────────────

expect("z.low", series.zone(69, 70, 180), "low")
expect("z.lowEq", series.zone(70, 70, 180), "in_range")
expect("z.inRange", series.zone(100, 70, 180), "in_range")
expect("z.highEq", series.zone(180, 70, 180), "in_range")
expect("z.high", series.zone(181, 70, 180), "high")

-- ── crossing ─────────────────────────────────────────────────────────────────

-- Into high: notify
local c1 = series.crossing(100, 220, 70, 180)
expect("c1.to", c1.to, "high")
expect("c1.from", c1.from, "in_range")
expect("c1.value", c1.value, 220)

-- Into low: notify
local c2 = series.crossing(100, 60, 70, 180)
expect("c2.to", c2.to, "low")

-- Recovery to range: no notify (no spam)
expectNil("c2.recover", series.crossing(220, 100, 70, 180))

-- Persisting same zone: no notify
expectNil("c3.sameHigh", series.crossing(200, 210, 70, 180))
expectNil("c3.sameRange", series.crossing(100, 110, 70, 180))

-- Missing prev/cur: no notify
expectNil("c4.noPrev", series.crossing(nil, 220, 70, 180))
expectNil("c4.noCur", series.crossing(100, nil, 70, 180))


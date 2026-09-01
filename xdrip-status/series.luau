--!nonstrict
-- xDrip glucose series: pure helpers shared by the service, bar, and panel.
-- Normalizes /entries/ API rows, computes window stats, maps values to 0..1
-- for ui.graph, and detects threshold crossings. No noctalia.* deps so it
-- runs standalone under the repo's luau tooling (see tests/series_spec.luau).

local M = {}

-- Normalizes an entries JSON array (from GET /api/v1/entries?type=sgv) into a
-- time-ascending series of point tables. Dropped: non-numeric/no-date rows and
-- rows whose date is nil. Keeps the newest point's metadata (direction, delta,
-- noise, device, id) so stats can surface it.
function M.normalize(raw)
  local out = {}
  if type(raw) ~= "table" then
    return out
  end
  for _, e in ipairs(raw) do
    local d = e and e.date
    local v = e and e.sgv
    if type(d) == "number" and type(v) == "number" then
      out[#out + 1] = {
        date = d,
        sgv = v,
        direction = (type(e.direction) == "string") and e.direction or nil,
        delta = (type(e.delta) == "number") and e.delta or nil,
        noise = (type(e.noise) == "number") and e.noise or nil,
        device = (type(e.device) == "string") and e.device or nil,
        id = (type(e.id) == "string") and e.id or nil,
      }
    end
  end
  table.sort(out, function(a, b)
    return a.date < b.date
  end)
  return out
end

-- Single-pass window stats over a series: min, max, avg (rounded int), and the
-- newest point plus its metadata. Returns nil when the series is empty.
function M.stats(series)
  if type(series) ~= "table" or #series == 0 then
    return nil
  end
  local min, max, sum = math.huge, -math.huge, 0
  for _, p in ipairs(series) do
    if p.sgv < min then
      min = p.sgv
    end
    if p.sgv > max then
      max = p.sgv
    end
    sum = sum + p.sgv
  end
  local cur = series[#series]
  return {
    min = min,
    max = max,
    avg = math.floor(sum / #series + 0.5),
    current = cur.sgv,
    direction = cur.direction,
    delta = cur.delta,
    noise = cur.noise,
    device = cur.device,
    lastDate = cur.date,
  }
end

-- Maps a series' sgv values to 0..1 for ui.graph. When plotLo/plotHi are given
-- (e.g. spanned across the low/high thresholds), values outside that range are
-- clamped so the points stay on the graph. Without bounds, derives them from
-- the data so the line fills the chart. Uniform series -> middled at 0.5 so a
-- flat reading still draws.
function M.normalizeGraph(series, plotLo, plotHi)
  local out = {}
  if type(series) ~= "table" then
    return out
  end
  if plotLo == nil or plotHi == nil then
    local st = M.stats(series)
    if not st then
      return out
    end
    plotLo, plotHi = st.min, st.max
  end
  local span = plotHi - plotLo
  for _, p in ipairs(series) do
    local v
    if span <= 0 then
      v = 0.5
    else
      v = (p.sgv - plotLo) / span
    end
    out[#out + 1] = math.max(0, math.min(1, v))
  end
  return out
end

-- Subset of a time-ascending series whose points fall at/after fromMs.
-- Returns a new array (does not mutate); empty when the series is empty.
function M.window(series, fromMs)
  local out = {}
  if type(series) ~= "table" or fromMs == nil then
    return out
  end
  for _, p in ipairs(series) do
    if p.date >= fromMs then
      out[#out + 1] = p
    end
  end
  return out
end

-- Computed delta: change from the previous reading to the current one.
-- Uses the last two points of the (time-ascending) series, so a window slice
-- passed here gives "change over the shown period".
function M.delta(series)
  if type(series) ~= "table" or #series < 2 then
    return nil
  end
  return series[#series].sgv - series[#series - 1].sgv
end

-- "HH:MM" local time for a ms timestamp, using the shell's timezone via
-- noctalia.formatTime (strftime pattern). Falls back to a UTC-ish manual
-- format if formatTime is unavailable at runtime.
function M.timeHhMm(ms)
  if ms == nil then
    return nil
  end
  if noctalia and noctalia.formatTime then
    local ok, out = pcall(noctalia.formatTime, "%H:%M", math.floor(ms / 1000))
    if ok and type(out) == "string" and out ~= "" then
      return out
    end
  end
  local sec = math.floor(ms / 1000)
  local h = math.floor((sec % 86400) / 3600)
  local m = math.floor((sec % 3600) / 60)
  return string.format("%02d:%02d", h, m)
end

-- Threshold zone for a value: "low" | "in_range" | "high".
function M.zone(v, low, high)
  if v < low then
    return "low"
  end
  if v > high then
    return "high"
  end
  return "in_range"
end

-- Crossing detection for one-shot notifications. Given the previous and current
-- reading plus thresholds, returns { from, to, value } when the reading moved
-- INTO low or high (not when it recovered back to range, so we don't spam
-- recovery alerts). Returns nil when there's no crossing to report.
function M.crossing(prev, cur, low, high)
  if prev == nil or cur == nil then
    return nil
  end
  local pz, cz = M.zone(prev, low, high), M.zone(cur, low, high)
  if cz == pz or cz == "in_range" then
    return nil
  end
  return { from = pz, to = cz, value = cur }
end

return M
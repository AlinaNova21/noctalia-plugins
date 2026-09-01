--!nonstrict
-- xDrip Glucose service: polls the xdrip-sync entries API, normalizes the
-- window to a series + stats + graph values, publishes to noctalia.state, and
-- fires one-shot notifications when a reading crosses a configured threshold.

local series = require("./series.luau")

local STATE_KEY = "xdrip_status.status"
local CMD_KEY = "xdrip_status.cmd"

local lastSgv = nil
local pollInFlight = false

local function cfg(key, default)
  local v = noctalia.getConfig(key)
  if v == nil or v == "" then
    return default
  end
  return v
end

local function baseUrl()
  return tostring(cfg("url", "http://localhost:8080")):gsub("/+$", "")
end

-- Read-endpoint auth. xdrip-sync accepts either an `api-secret` header (sha1 of
-- XD_SECRET) or `Authorization: Bearer <token>`. We use a long-lived Bearer
-- token (`xdrip-sync token create`) since it avoids reimplementing SHA-1.
-- Empty token -> anonymous (works when the server runs XD_OPEN_READS=true).
local function buildRequest(fromMs)
  local req = {
    url = string.format(
      "%s/api/v1/entries?type=sgv&from=%d&limit=1000&order=asc",
      baseUrl(), fromMs
    ),
  }
  local token = cfg("token", "")
  if type(token) == "string" and token ~= "" then
    req.headers = { "Authorization: Bearer " .. token }
  end
  return req
end

local function handlePoll(res, fromMs)
  pollInFlight = false
  if not res or not res.ok or res.status ~= 200 then
    local err = (not res or not res.ok) and "timeout" or string.format("http_%d", res.status)
    noctalia.state.set(STATE_KEY, { error = err })
    return
  end
  local decoded = noctalia.json.decode(res.body)
  if type(decoded) ~= "table" then
    noctalia.state.set(STATE_KEY, { error = "parse" })
    return
  end
  local list = series.normalize(decoded)
  local st = series.stats(list)
  if not st then
    noctalia.state.set(STATE_KEY, { empty = true })
    return
  end

  local low = tonumber(cfg("low", 70)) or 70
  local high = tonumber(cfg("high", 180)) or 180
  local hours = tonumber(cfg("hours", 8)) or 8
  if hours < 1 then
    hours = 1
  end
  local barHours = tonumber(cfg("bar_hours", 1)) or 1
  if barHours < 1 then
    barHours = 1
  end
  if barHours > hours then
    barHours = hours
  end

  -- The panel graph + stats cover the configured window (hours). The bar
  -- sparkline is a short slice (bar_hours) of the same batch, so no second
  -- HTTP round-trip; it auto-scales so a narrow range still shows shape.
  local barFrom = fromMs + (hours - barHours) * 3600000
  local barSeries = series.window(list, barFrom)
  local barGraph = series.normalizeGraph(barSeries)

  -- Plot range spans the thresholds so low/high sit visibly inside the graph
  -- and a reading pushed past a threshold shows as a spike toward the edge.
  local plotLo = math.min(st.min, low)
  local plotHi = math.max(st.max, high)

  if cfg("notify_crossings", true) ~= false then
    local cross = series.crossing(lastSgv, st.current, low, high)
    if cross then
      noctalia.notify(noctalia.tr("title"), noctalia.tr("ipc.cross", {
        zone = noctalia.tr("zone." .. cross.to),
        value = tostring(cross.value),
      }))
    end
  end
  lastSgv = st.current

  noctalia.state.set(STATE_KEY, {
    series = list,
    graph = series.normalizeGraph(list, plotLo, plotHi),
    bar_graph = barGraph,
    stats = st,
    delta = series.delta(list),
    low = low,
    high = high,
    plot_lo = plotLo,
    plot_hi = plotHi,
    window_hours = hours,
    bar_hours = barHours,
    from_ms = (list[1] and list[1].date) or fromMs,
    to_ms = st.lastDate,
    fetched = noctalia.nowMs(),
  })
end

local function poll()
  if pollInFlight then
    return
  end
  pollInFlight = true
  local hours = tonumber(cfg("hours", 8)) or 8
  if hours < 1 then
    hours = 1
  end
  local fromMs = noctalia.nowMs() - hours * 3600000
  noctalia.http(buildRequest(fromMs), function(res)
    handlePoll(res, fromMs)
  end)
end

-- Listen for a manual refresh from the panel.
noctalia.state.watch(CMD_KEY, function(cmd)
  if type(cmd) == "table" and cmd.op == "poll" then
    poll()
  end
  noctalia.state.set(CMD_KEY, nil)
end)

noctalia.setUpdateInterval((tonumber(cfg("poll_seconds", 60)) or 60) * 1000)
function update()
  poll()
end

poll()
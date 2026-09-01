--!nonstrict
-- xDrip Glucose bar widget: current reading + trend + mini sparkline.
-- Hover shows a tooltip; click opens the panel.

local series = require("./series.luau")

local STATE_KEY = "xdrip_status.status"
local data: any = {}

local function trendArrow(direction)
  if type(direction) ~= "string" then
    return "→"
  end
  if direction:match("Up") then
    return "↑"
  end
  if direction:match("Down") then
    return "↓"
  end
  return "→"
end


local function deltaLabel()
  local v = data.delta
  if v == nil then
    v = data.stats and data.stats.delta
  end
  if v == nil then
    return nil
  end
  return string.format("%+d", math.floor(v + 0.5))
end

local function tooltipRows(st)
  local out = {}
  table.insert(out, { key = "Current", value = tostring(st.current) .. " mg/dL" })
  if st.direction then
    table.insert(out, { key = "Trend", value = st.direction })
  end
  local d = deltaLabel()
  if d then
    table.insert(out, { key = "Δ (vs prev)", value = d })
  end
  if st.noise ~= nil then
    table.insert(out, { key = "Noise", value = tostring(st.noise) })
  end
  local last = series.timeHhMm(st.lastDate)
  if last then
    table.insert(out, { key = "Last", value = last })
  end
  return out
end

local function render()
  local container = barWidget.isVertical() and ui.column or ui.row
  local children = {}

  if data.error then
    table.insert(children, ui.label({ text = "–", fontSize = 11, color = "error" }))
    barWidget.render(container({ gap = 5, align = "center" }, children))
    barWidget.setTooltip({ { key = "Error", value = data.error } })
    return
  end

  if not data.stats then
    table.insert(children, ui.label({ text = "–", fontSize = 11 }))
    barWidget.render(container({ gap = 5, align = "center" }, children))
    barWidget.setTooltip({})
    return
  end

  local st = data.stats
  local zone = series.zone(st.current, data.low, data.high)
  local color = (zone == "high") and "error" or ((zone == "low") and "error" or "primary")

  table.insert(children, ui.label({ text = tostring(st.current), fontSize = 12, fontWeight = "bold", color = color }))

  -- 1h sparkline (bar window), auto-scaled; falls back to the panel graph.
  local spark = data.bar_graph
  if not spark or #spark <= 1 then
    spark = data.graph
  end
  if spark and #spark > 1 then
    table.insert(children, ui.graph({
      values = spark,
      width = 34,
      height = 12,
      color = "primary",
      lineWidth = 1.5,
      fillOpacity = 0.1,
    }))
  end

  table.insert(children, ui.label({ text = trendArrow(st.direction), fontSize = 12, color = color }))
  local d = deltaLabel()
  if d then
    table.insert(children, ui.label({ text = d, fontSize = 11 }))
  end

  barWidget.render(container({ gap = 5, align = "center" }, children))
  barWidget.setTooltip(tooltipRows(st))
end

function update()
  noctalia.setUpdateInterval(1000)
  data = noctalia.state.get(STATE_KEY) or {}
  render()
end

function onClick()
  noctalia.togglePanel("alinanova21/xdrip-status:read")
end

noctalia.state.watch(STATE_KEY, function(value)
  data = type(value) == "table" and value or {}
  render()
end)

render()
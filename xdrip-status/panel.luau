--!nonstrict
-- xDrip Glucose panel: current reading card, window stats, threshold chips,
-- and a large history graph. Click the bar to open; refresh in the header.

local series = require("./series.luau")

local STATE_KEY = "xdrip_status.status"
local CMD_KEY = "xdrip_status.cmd"

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

local function fmtTime(ms)
  return series.timeHhMm(ms)
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

-- Current reading card: big value (zone-colored), trend arrow + delta, and a
-- subline with last timestamp. Background tinted by zone.
local function currentCard(st)
  local zone = series.zone(st.current, data.low, data.high)
  local color = (zone == "high") and "error" or ((zone == "low") and "error" or "primary")
  local fill = (zone == "high") and "error/0.14"
    or ((zone == "low") and "error/0.14")
    or "surface_variant/0.5"

  local valueRow = {}
  table.insert(valueRow, ui.label({ text = tostring(st.current), fontSize = 24, fontWeight = "bold", color = color }))
  table.insert(valueRow, ui.label({ text = "mg/dL", fontSize = 12, color = "on_surface_variant" }))
  table.insert(valueRow, ui.label({ text = " " .. trendArrow(st.direction), fontSize = 14, color = color }))
  local d = deltaLabel()
  if d then
    table.insert(valueRow, ui.label({ text = "  " .. d, fontSize = 14 }))
  end

  local sub = {}
  if st.direction then
    table.insert(sub, st.direction)
  end
  if st.noise ~= nil then
    table.insert(sub, "noise " .. tostring(st.noise))
  end
  local last = fmtTime(st.lastDate)
  if last then
    table.insert(sub, "last " .. last)
  end
  local subText = (#sub > 0) and table.concat(sub, " · ") or ""

  local children = {
    ui.label({ text = noctalia.tr("ui.current"), fontSize = 11, color = "on_surface_variant" }),
  }
  table.insert(children, ui.row({ gap = 4, align = "center" }, valueRow))
  if subText ~= "" then
    table.insert(children, ui.label({ text = subText, fontSize = 10, color = "on_surface_variant", maxLines = 1 }))
  end

  return ui.column({
    fill = fill,
    radius = 8,
    gap = 6,
    paddingH = 12,
    paddingV = 8,
    flexGrow = 1,
  }, children)
end

-- Stats card: MIN / MAX / AVG / readings in a small stacked column.
local function statsCard(st, n)
  local rows = {
    { key = "MIN", value = tostring(st.min) },
    { key = "MAX", value = tostring(st.max) },
    { key = "AVG", value = tostring(st.avg) },
    { key = "POINTS", value = tostring(n) },
  }
  local children = {}
  for _, r in ipairs(rows) do
    table.insert(children, ui.row({ gap = 6, align = "center", justify = "space_between" }, {
      ui.label({ text = r.key, fontSize = 10, color = "on_surface_variant", flexGrow = 1 }),
      ui.label({ text = r.value, fontSize = 13, fontWeight = "bold" }),
    }))
  end
  return ui.column({
    fill = "surface_variant/0.5",
    radius = 8,
    gap = 4,
    paddingH = 12,
    paddingV = 8,
    width = 120,
  }, children)
end

local function thresholdRow()
  local chips = {
    { label = string.format("high %s", tostring(data.high)), color = "error" },
    { label = string.format("low %s", tostring(data.low)), color = "error" },
  }
  local children = {}
  for _, c in ipairs(chips) do
    table.insert(children, ui.row({ gap = 4, align = "center", paddingH = 8, paddingV = 2, fill = c.color .. "/0.14", radius = 6 }, {
      ui.label({ text = c.label, fontSize = 10, color = c.color }),
    }))
  end
  return ui.row({ gap = 6, align = "center" }, children)
end

local function render()
  local children = {}
  table.insert(children, ui.row({ align = "center", justify = "space_between" }, {
    ui.label({ text = noctalia.tr("title"), fontSize = 16, fontWeight = "bold", flexGrow = 1 }),
    ui.button({
      glyph = "refresh",
      variant = "ghost",
      tooltip = noctalia.tr("ui.refresh_tooltip"),
      onClick = function()
        noctalia.state.set(CMD_KEY, { op = "poll" })
      end,
    }),
    ui.button({ glyph = "close", onClick = function()
      panel.close()
    end }),
  }))

  if not data.stats and data.error then
    -- Map specific failures ("timeout", "parse", "http_<code>") to a stable label.
    local key = "ui.error_timeout"
    if data.error == "parse" then
      key = "ui.error_parse"
    elseif data.error:match("^http_") then
      key = "ui.error_http"
    end
    table.insert(children, ui.label({ text = noctalia.tr(key), color = "error", fontSize = 13 }))
    panel.render(ui.column({ flexGrow = 1, gap = 8, padding = 8 }, children))
    return
  end

  if not data.stats and data.empty then
    table.insert(children, ui.label({ text = noctalia.tr("ui.empty"), color = "on_surface_variant", fontSize = 13 }))
    panel.render(ui.column({ flexGrow = 1, gap = 8, padding = 8 }, children))
    return
  end

  local st = data.stats
  local n = type(data.series) == "table" and #data.series or 0

  -- Current + stats side by side
  table.insert(children, ui.row({ gap = 6, align = "stretch" }, {
    currentCard(st),
    statsCard(st, n),
  }))

  -- Large history graph with a period caption (what window is shown).
  local fromT = series.timeHhMm(data.from_ms)
  local toT = series.timeHhMm(data.to_ms)
  local periodText = noctalia.tr("ui.window_label") .. " · "
    .. noctalia.tr("ui.period", { h = tostring(data.window_hours or data.bar_hours or 0) })
  if fromT and toT then
    periodText = periodText .. "  (" .. fromT .. " – " .. toT .. ")"
  end
  table.insert(children, ui.label({
    text = periodText,
    fontSize = 10,
    color = "on_surface_variant",
    maxLines = 1,
  }))

  if data.graph and #data.graph > 1 then
    table.insert(children, ui.graph({
      values = data.graph,
      color = "primary",
      lineWidth = 2,
      fillOpacity = 0.12,
      width = 700,
      height = 180,
    }))
  else
    table.insert(children, ui.label({ text = noctalia.tr("ui.no_graph"), color = "on_surface_variant", fontSize = 12 }))
  end

  -- Threshold chips + settings hint
  table.insert(children, ui.row({ gap = 6, align = "center" }, {
    thresholdRow(),
    ui.label({ text = noctalia.tr("ui.settings_hint"), color = "on_surface_variant", fontSize = 10, flexGrow = 1 }),
  }))

  panel.render(ui.column({ flexGrow = 1, gap = 8, padding = 8 }, children))
end

function onOpen(_ctx)
  data = noctalia.state.get(STATE_KEY) or {}
  panel.setWantsSecondTicks(true)
  render()
end

function onClose()
  panel.setWantsSecondTicks(false)
end

noctalia.state.watch(STATE_KEY, function(value)
  data = type(value) == "table" and value or {}
  render()
end)

render()
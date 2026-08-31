--!nonstrict
-- SS14 Status bar widget: SS14 glyph + aggregate count, quick-info tooltip,
-- click opens the panel.

local timeutil = require("./timeutil.luau")

local STATE_KEY = "ss14_status.servers"
local rows = {}

local function countOnline()
  local n = 0
  for _, r in ipairs(rows) do
    if r.online then
      n = n + 1
    end
  end
  return n
end

local function fmtElapsed(startMs)
  if startMs == nil then
    return nil
  end
  return timeutil.formatElapsed(noctalia.nowMs() - startMs, 0)
end

-- quick info tooltip rows (name — players/max, then map/round/preset/time, flags)
local function tooltipRows()
  local out = {}
  local online, offline = {}, {}
  for _, r in ipairs(rows) do
    if r.online then
      online[#online + 1] = r
    else
      offline[#offline + 1] = r
    end
  end
  for _, r in ipairs(online) do
    local head = (r.name or r.host) .. " — " .. tostring(r.players or 0) .. "/" .. tostring(r.soft_max_players or 0)
    table.insert(out, { key = head, value = nil })
    local detail = {}
    if r.map then
      detail[#detail + 1] = r.map
    end
    if r.round_id then
      detail[#detail + 1] = "Round " .. tostring(r.round_id)
    end
    if r.preset then
      detail[#detail + 1] = r.preset
    end
    local el = fmtElapsed(r.round_start_ms)
    if el then
      detail[#detail + 1] = el
    end
    if #detail > 0 then
      table.insert(out, { key = table.concat(detail, " · "), value = nil })
    end
    local flags = {}
    if r.panic_bunker then
      flags[#flags + 1] = "⛨ bunker"
    end
    if r.baby_jail then
      flags[#flags + 1] = "👶 jail"
    end
    if #flags > 0 then
      table.insert(out, { key = table.concat(flags, " · "), value = nil })
    end
  end
  if #offline > 0 then
    local hosts = {}
    for _, r in ipairs(offline) do
      hosts[#hosts + 1] = r.host
    end
    table.insert(out, { key = "Offline:", value = table.concat(hosts, ", ") })
  end
  return out
end

local function render()
  local showCount = noctalia.getConfig("show_count")
  local total = #rows
  local online = countOnline()
  local container = barWidget.isVertical() and ui.column or ui.row
  local children = { ui.image({ path = "logo.png", width = 16, height = 16 }) }
  if showCount ~= false then
    table.insert(children, ui.label({
      text = (total == 0) and "–" or (tostring(online) .. "/" .. tostring(total)),
      fontSize = 11,
    }))
  end
  barWidget.render(container({ gap = 5, align = "center" }, children))
  barWidget.setTooltip(tooltipRows())
end

function update()
  noctalia.setUpdateInterval(1000)
  rows = noctalia.state.get(STATE_KEY) or {}
  render()
end

function onClick()
  noctalia.togglePanel("alinas/ss14-status:list")
end

noctalia.state.watch(STATE_KEY, function(value)
  rows = type(value) == "table" and value or {}
  render()
end)

render()
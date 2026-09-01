--!nonstrict
-- SS14 Status bar widget: SS14 glyph + aggregate count, favorites-only
-- quick-info tooltip, click opens the panel.

local timeutil = require("./timeutil.luau")
local entries = require("./entries.luau")

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

-- Tooltip: only favorited (pinned) servers, in panel order (rows are already
-- sorted pins-first by the service). Head line uses the display name when set.
-- No pins -> empty tooltip (nothing to favorite yet).
local function tooltipRows()
  local out = {}
  for _, r in ipairs(rows) do
    if r.pinned then
      if r.online then
        local head = entries.displayTitle(r) .. " — " .. tostring(r.players or 0) .. "/" .. tostring(r.soft_max_players or 0)
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
      else
        table.insert(out, { key = entries.displayTitle(r) .. " (offline)", value = nil })
      end
    end
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
  noctalia.togglePanel("alinanova21/ss14-status:list")
end

noctalia.state.watch(STATE_KEY, function(value)
  rows = type(value) == "table" and value or {}
  render()
end)

render()
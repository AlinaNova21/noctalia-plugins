--!nonstrict
-- SS14 Status panel: rows with full status, Launch (Steam URI) + Copy,
-- add/remove server list, sync from launcher DB, refresh now.

local timeutil = require("./timeutil.luau")

local STATE_KEY = "ss14_status.servers"
local CMD_KEY = "ss14_status.cmd"

local rows = {}
local draft = ""
local draftKey = 0
local pendingDelete = nil
local syncing = false

-- Forward declaration: render is referenced by callbacks defined above it.
local render

local function playersLabel(row)
  return tostring(row.players or 0) .. "/" .. tostring(row.soft_max_players or 0)
end

-- Preferred: connect_address "udp://host:port" -> "ss14://host:port".
-- Fallback: config uri verbatim.
local function connUri(row)
  if row.connect_address then
    local host, port = row.connect_address:match("^udp:%/%/(.+):(%d+)$")
    if host and port then
      return "ss14://" .. host .. ":" .. port
    end
  end
  return row.uri
end

local function launchServer(row)
  if not row.online then
    return
  end
  local appid = noctalia.getConfig("steam_appid") or "1255460"
  local ss14 = connUri(row)
  local cmd = "steam steam://run/" .. appid .. "//" .. ss14
  if noctalia.commandExists("steam") then
    if not noctalia.runAsync(cmd) then
      noctalia.notifyError(noctalia.tr("title"), noctalia.tr("ipc.launch_failed"))
    end
  else
    noctalia.notifyError(noctalia.tr("title"), noctalia.tr("ipc.no_steam"))
    noctalia.copyToClipboard(ss14, "text/plain")
  end
end

local function copyServer(row)
  noctalia.copyToClipboard(connUri(row), "text/plain")
end

local function serverRow(row)
  local online = row.online
  local title = online and (row.name or row.host) or (row.host .. " (offline)")
  local line2 = {}
  if online then
    if row.map then
      line2[#line2 + 1] = row.map
    end
    if row.round_id then
      line2[#line2 + 1] = "Round " .. tostring(row.round_id)
    end
    if row.preset then
      line2[#line2 + 1] = row.preset
    end
    if row.round_start_ms then
      line2[#line2 + 1] = timeutil.formatElapsed(noctalia.nowMs() - row.round_start_ms, 0)
    end
  end
  local flags = {}
  if row.panic_bunker then
    flags[#flags + 1] = noctalia.tr("flag.bunker")
  end
  if row.baby_jail then
    flags[#flags + 1] = noctalia.tr("flag.jail")
  end

  -- Build actions array first (ui.* nodes don't expose .props for children).
  local actionButtons = {}
  table.insert(actionButtons, ui.button({
    glyph = "player-play",
    variant = "primary",
    enabled = online,
    tooltip = noctalia.tr("ui.launch_tooltip"),
    onClick = function()
      launchServer(row)
    end,
  }))
  table.insert(actionButtons, ui.button({
    glyph = "copy",
    variant = "ghost",
    tooltip = noctalia.tr("ui.copy_tooltip"),
    onClick = function()
      copyServer(row)
    end,
  }))
  if pendingDelete == row.uri then
    table.insert(actionButtons, ui.button({
      glyph = "check",
      variant = "destructive",
      onClick = function()
        noctalia.state.set(CMD_KEY, { op = "remove", uri = row.uri })
        pendingDelete = nil
        render()
      end,
    }))
    table.insert(actionButtons, ui.button({
      glyph = "close",
      variant = "ghost",
      onClick = function()
        pendingDelete = nil
        render()
      end,
    }))
  else
    table.insert(actionButtons, ui.button({
      glyph = "trash",
      variant = "ghost",
      tooltip = noctalia.tr("ui.remove_tooltip"),
      onClick = function()
        pendingDelete = row.uri
        render()
      end,
    }))
  end
  local actions = ui.row({ gap = 4, align = "center" }, actionButtons)

  -- Left column children (built with statements; Luau has no if-expressions).
  local titleRowChildren = {
    ui.label({ text = title, fontWeight = "bold", fontSize = 13, flexGrow = 1 }),
  }
  if online then
    table.insert(titleRowChildren, ui.label({ text = playersLabel(row), fontWeight = "bold", fontSize = 13, color = "primary" }))
  end
  local colChildren = {
    ui.row({ gap = 6, align = "center" }, titleRowChildren),
  }
  if online and #line2 > 0 then
    table.insert(colChildren, ui.label({ text = table.concat(line2, " · "), color = "on_surface_variant", fontSize = 10, maxLines = 2 }))
  elseif not online then
    table.insert(colChildren, ui.label({ text = row.error or "", color = "error", fontSize = 10 }))
  end
  if #flags > 0 then
    table.insert(colChildren, ui.label({ text = table.concat(flags, " · "), color = "warning", fontSize = 10 }))
  end

  return ui.row({
    key = row.uri,
    gap = 6,
    align = "center",
    paddingV = 3,
    paddingH = 6,
    fill = "surface_variant/0.35",
    radius = 6,
  }, {
    ui.column({ flexGrow = 1, gap = 1 }, colChildren),
    actions,
  })
end

render = function()
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
    ui.button({
      glyph = "close",
      onClick = function()
        panel.close()
      end,
    }),
  }))
  table.insert(children, ui.row({ gap = 6, align = "center" }, {
    ui.input({
      key = "add-" .. draftKey,
      value = draft,
      placeholder = noctalia.tr("ui.add_placeholder"),
      flexGrow = 1,
      onChange = function(v)
        draft = v
      end,
      onSubmit = "onAdd",
    }),
    ui.button({
      glyph = "plus",
      variant = "primary",
      onClick = "onAdd",
    }),
    ui.button({
      text = noctalia.tr("ui.sync"),
      variant = "secondary",
      tooltip = noctalia.tr("ui.sync_tooltip"),
      enabled = not syncing,
      onClick = "onSync",
    }),
  }))
  local body = {}
  if #rows == 0 then
    table.insert(body, ui.label({ text = noctalia.tr("ui.empty"), color = "on_surface_variant", fontSize = 13 }))
  else
    for _, row in ipairs(rows) do
      table.insert(body, serverRow(row))
    end
  end
  table.insert(children, ui.scroll({ flexGrow = 1, gap = 4, padding = 4 }, body))
  panel.render(ui.column({ flexGrow = 1, gap = 8, padding = 8 }, children))
end

function onAdd()
  local s = noctalia.string.trim(draft)
  draft = ""
  draftKey += 1
  pendingDelete = nil
  if s ~= "" then
    noctalia.state.set(CMD_KEY, { op = "add", uri = s })
  end
  render()
end

function onSync()
  if syncing then
    return
  end
  syncing = true
  noctalia.state.set(CMD_KEY, { op = "sync" })
  -- reset after a moment so the button re-enables
  syncing = false
  render()
end

function onOpen(_ctx)
  rows = noctalia.state.get(STATE_KEY) or {}
  pendingDelete = nil
  draft = ""
  draftKey += 1
  panel.setWantsSecondTicks(true)
  render()
end

function onClose()
  panel.setWantsSecondTicks(false)
end

noctalia.state.watch(STATE_KEY, function(value)
  rows = type(value) == "table" and value or {}
  pendingDelete = nil
  render()
end)

render()
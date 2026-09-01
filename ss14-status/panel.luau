--!nonstrict
-- SS14 Status panel: rows with full status, launch / pin / rename / copy /
-- remove, add/remove server list, sync from launcher DB, refresh now.

local uri = require("./uri.luau")
local timeutil = require("./timeutil.luau")
local entries = require("./entries.luau")

local STATE_KEY = "ss14_status.servers"
local CMD_KEY = "ss14_status.cmd"

local rows = {}
local draft = ""
local draftKey = 0
local pendingDelete = nil
local syncing = false
local renameUri = nil   -- uri of the row being renamed (nil = none)
local renameDraft = ""  -- current input text while renaming
local renameKey = 0     -- bumped to remount the rename input

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
  -- Normalize the config URI, applying the SS14 default port (1212 for ss14://,
  -- 443 for ss14s://) so the launcher gets an unambiguous address.
  local normalized = uri.connectUri(row.uri)
  if normalized ~= nil then
    return normalized
  end
  return row.uri
end

-- Locates the SS14 launcher binary. Checks, in order:
--   1. explicit setting (expandPath handles ~)
--   2. canonical Steam root ~/.steam/steam (symlinked to real store on most distros)
--   3. ~/.local/share/Steam (legacy / flatpak-ish layout)
-- Returns an absolute path used with runAsync arg-array, or nil.
local function findLauncher()
  local fromSetting = noctalia.getConfig("launcher_path")
  if type(fromSetting) == "string" and fromSetting ~= "" then
    local p = noctalia.expandPath(fromSetting)
    if noctalia.fileExists(p) then
      return p
    end
  end
  local home = noctalia.getenv("HOME") or "~"
  local candidates = {
    home .. "/.steam/steam/steamapps/common/Space Station 14 Playtest/SS14.Launcher",
    home .. "/.local/share/Steam/steamapps/common/Space Station 14 Playtest/SS14.Launcher",
  }
  for _, p in ipairs(candidates) do
    if noctalia.fileExists(p) then
      return p
    end
  end
  return nil
end

local function launchServer(row)
  if not row.online then
    return
  end
  local ss14 = connUri(row)
  -- Prefer the launcher binary directly: it accepts the ss14:// URI as a single
  -- positional argument (SS14.Launcher <uri>). Steam streaming via // is brittle.
  local launcherPath = findLauncher()
  if launcherPath ~= nil then
    if noctalia.runAsync({ launcherPath, ss14 }) then
      return
    end
    noctalia.notifyError(noctalia.tr("title"), noctalia.tr("ipc.launch_failed"))
    return
  end
  -- Fallback: Steam URI (appid is the launcher itself).
  local appid = noctalia.getConfig("steam_appid") or "1482520"
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

local function findRow(uri_)
  for _, r in ipairs(rows) do
    if r.uri == uri_ then
      return r
    end
  end
  return nil
end

local function startRename(row)
  renameUri = row.uri
  renameDraft = row.display_name or row.name or row.host or ""
  renameKey += 1
  render()
end

local function togglePin(row)
  noctalia.state.set(CMD_KEY, { op = "pin", uri = row.uri, pinned = not row.pinned })
end

-- Per-row "⋮" menu: launch / pin·unpin / rename / copy / remove (plugin_api 28).
local function openRowMenu(row)
  local items = {}
  table.insert(items, { id = "launch", label = noctalia.tr("ui.menu.launch"), enabled = row.online })
  if row.pinned then
    table.insert(items, { id = "unpin", label = noctalia.tr("ui.menu.unpin") })
  else
    table.insert(items, { id = "pin", label = noctalia.tr("ui.menu.pin") })
  end
  table.insert(items, { id = "rename", label = noctalia.tr("ui.menu.rename") })
  table.insert(items, { id = "copy", label = noctalia.tr("ui.menu.copy") })
  table.insert(items, { id = "remove", label = noctalia.tr("ui.menu.remove") })
  panel.openContextMenu({
    items = items,
    onActivate = "onRowMenuActivate",
    context = row.uri,
  })
end

local function serverRow(row)
  local online = row.online
  local hasDisplayName = type(row.display_name) == "string" and row.display_name ~= ""
  local title = entries.displayTitle(row) or row.uri
  if not online then
    title = title .. " (offline)"
  end
  local serverNameSub = nil
  if hasDisplayName then
    serverNameSub = row.name or row.host -- the full server name, shown as a subline
  end
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
    glyph = row.pinned and "pin" or "pin-outline",
    variant = row.pinned and "primary" or "ghost",
    tooltip = noctalia.tr(row.pinned and "ui.unpin" or "ui.pin"),
    onClick = function()
      togglePin(row)
    end,
  }))
  table.insert(actionButtons, ui.button({
    glyph = "pencil",
    variant = "ghost",
    tooltip = noctalia.tr("ui.rename"),
    onClick = function()
      startRename(row)
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
  table.insert(actionButtons, ui.button({
    glyph = "dots-vertical",
    variant = "ghost",
    tooltip = noctalia.tr("ui.more_tooltip"),
    onClick = function()
      openRowMenu(row)
    end,
  }))
  local actions = ui.row({ gap = 4, align = "center" }, actionButtons)

  -- Left column children (built with statements; Luau has no if-expressions).
  local titleRowChildren
  if renameUri == row.uri then
    titleRowChildren = {
      ui.input({
        key = "rename-" .. renameKey,
        value = renameDraft,
        placeholder = noctalia.tr("ui.rename_placeholder"),
        flexGrow = 1,
        onChange = function(v)
          renameDraft = v
        end,
        onSubmit = "onRenameSubmit",
      }),
    }
  else
    titleRowChildren = {
      ui.label({ text = title, fontWeight = "bold", fontSize = 13, flexGrow = 1 }),
    }
    if online then
      table.insert(titleRowChildren, ui.label({ text = playersLabel(row), fontWeight = "bold", fontSize = 13, color = "primary" }))
    end
  end
  local colChildren = {
    ui.row({ gap = 6, align = "center" }, titleRowChildren),
  }
  -- Subline: the full server name, only when a display name is set and it
  -- actually differs from the title (avoids a duplicated line).
  if hasDisplayName and serverNameSub ~= nil and serverNameSub ~= title then
    table.insert(colChildren, ui.label({ text = serverNameSub, color = "on_surface_variant", fontSize = 10, maxLines = 1 }))
  end
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

function onRenameSubmit()
  if renameUri ~= nil then
    noctalia.state.set(CMD_KEY, { op = "rename", uri = renameUri, display_name = renameDraft })
    renameUri = nil
    renameDraft = ""
    render()
  end
end

function onRenameCancel()
  renameUri = nil
  renameDraft = ""
  render()
end

function onRowMenuActivate(actionId, context)
  local row = findRow(context or "")
  if row == nil then
    return
  end
  if actionId == "launch" then
    launchServer(row)
  elseif actionId == "pin" then
    noctalia.state.set(CMD_KEY, { op = "pin", uri = row.uri, pinned = true })
  elseif actionId == "unpin" then
    noctalia.state.set(CMD_KEY, { op = "pin", uri = row.uri, pinned = false })
  elseif actionId == "rename" then
    startRename(row)
  elseif actionId == "copy" then
    copyServer(row)
  elseif actionId == "remove" then
    pendingDelete = row.uri
    render()
  end
end

function onOpen(_ctx)
  rows = noctalia.state.get(STATE_KEY) or {}
  pendingDelete = nil
  draft = ""
  draftKey += 1
  renameUri = nil
  renameDraft = ""
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
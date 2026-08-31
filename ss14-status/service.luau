--!nonstrict
-- SS14 Status service: polls every configured server's /status, normalizes to
-- rows, and publishes ss14_status.servers + ss14_status.last to noctalia.state.
-- Also caches /info (connect address, engine version) once per session and
-- converts round_start_time via the bundled timestamp_ms.sh (GNU date).

local uri = require("./uri.luau")

local STATE_KEY = "ss14_status.servers"
local LAST_KEY = "ss14_status.last"
local CMD_KEY = "ss14_status.cmd"

local DEFAULT_SERVERS = {
  "ss14s://quantumblue.gay",
  "ss14://denstation.net:1212",
}

local servers = {}  -- ordered array of uri strings
local infoCache = {} -- host -> { connect_address=, engine_version= }
local roundStartCache = {} -- raw RFC3339 -> epoch ms (from timestamp_ms.sh)
local pollGen = 0    -- bumped each HTTP response; stale responses discarded
local offlineNotified = {} -- host -> true (rate-limit flip notifications)

-- Forward declaration: pollNow is referenced by callbacks (fetchInfo,
-- buildRoundStartMs) defined earlier lexically, so it must exist before them.
local pollNow

local function dataPath()
  local dir = noctalia.pluginDataDir()
  return dir and (dir .. "/servers.json") or nil
end

local function saveServers()
  local path = dataPath()
  if path == nil then
    return
  end
  local enc = noctalia.json.encode({ servers = servers })
  if enc ~= nil then
    noctalia.writeFile(path, enc)
  end
end

local function indexOf(s)
  for i, v in ipairs(servers) do
    if v == s then
      return i
    end
  end
  return nil
end

local function loadServers()
  servers = {}
  local path = dataPath()
  if path ~= nil then
    local raw = noctalia.readFile(path)
    if raw ~= nil then
      local decoded = noctalia.json.decode(raw)
      if type(decoded) == "table" and type(decoded.servers) == "table" then
        for _, s in ipairs(decoded.servers) do
          if type(s) == "string" and uri.parseUri(s) ~= nil then
            servers[#servers + 1] = s
          end
        end
      end
    end
  end
  if #servers == 0 then
    for _, s in ipairs(DEFAULT_SERVERS) do
      servers[#servers + 1] = s
    end
    saveServers()
  end
end

local function publish(rows)
  noctalia.state.set(STATE_KEY, rows)
  noctalia.state.set(LAST_KEY, noctalia.nowMs())
end

local function bumpGen()
  return pollGen + 1
end

-- Sorts rows so they appear in config order regardless of HTTP completion order.
local function sortByConfigOrder(rows)
  table.sort(rows, function(a, b)
    local ai, bi = nil, nil
    for i, s in ipairs(servers) do
      if a.uri == s then
        ai = i
      end
      if b.uri == s then
        bi = i
      end
    end
    if ai == nil then
      ai = math.huge
    end
    if bi == nil then
      bi = math.huge
    end
    if ai ~= bi then
      return ai < bi
    end
    return a.uri < b.uri
  end)
end

-- Accumulates rows for the current poll generation; published once every
-- configured server has a row (or immediately when nothing was requested).
local rows_in_flight = {}

local function buildRow(serverUri, res)
  local p = uri.parseUri(serverUri)
  local row = { uri = serverUri, host = (p and p.host) or serverUri, online = false }
  if not res or not res.ok or res.status ~= 200 then
    row.error = (not (res and res.ok)) and "timeout" or ("http_" .. tostring(res.status))
    return row
  end
  local decoded = noctalia.json.decode(res.body)
  if type(decoded) ~= "table" then
    row.error = "parse"
    return row
  end
  row.online = true
  row.name = type(decoded.name) == "string" and decoded.name or nil
  row.players = decoded.players
  row.soft_max_players = decoded.soft_max_players
  row.map = type(decoded.map) == "string" and decoded.map or nil
  row.round_id = decoded.round_id
  row.preset = type(decoded.preset) == "string" and decoded.preset or nil
  row.panic_bunker = decoded.panic_bunker == true
  row.baby_jail = decoded.baby_jail == true
  row.tags = type(decoded.tags) == "table" and decoded.tags or {}
  row.round_start_raw = type(decoded.round_start_time) == "string" and decoded.round_start_time or nil
  row.round_start_ms = row.round_start_raw and roundStartCache[row.round_start_raw] or nil
  local info = infoCache[row.host]
  if info then
    row.connect_address = info.connect_address
    row.engine_version = info.engine_version
  end
  return row
end

local function fetchInfo(serverUri, p)
  if infoCache[p.host] then
    return
  end
  local scheme = p.scheme == "ss14s" and "https" or "http"
  local auth = p.host
  if p.port ~= nil then
    auth = auth .. ":" .. p.port
  end
  local url = scheme .. "://" .. auth .. "/info"
  local gen = bumpGen()
  noctalia.http({ url = url }, function(res)
    if gen ~= pollGen then
      return -- stale
    end
    infoCache[p.host] = {}
    if res and res.ok and res.status == 200 then
      local d = noctalia.json.decode(res.body)
      if type(d) == "table" then
        if type(d.connect_address) == "string" then
          infoCache[p.host].connect_address = d.connect_address
        end
        if type(d.build) == "table" and type(d.build.engine_version) == "string" then
          infoCache[p.host].engine_version = d.build.engine_version
        end
      end
    end
    pollNow() -- re-publish with enriched rows after info lands
  end)
end

-- Converts a raw round_start_time RFC3339 string to epoch ms via the bundled
-- timestamp_ms.sh (GNU date). Caches by unique string; re-publishes when a
-- previously-uncached value lands so rows gain round time.
local function buildRoundStartMs(raw)
  if type(raw) ~= "string" or raw == "" then
    return
  end
  if roundStartCache[raw] ~= nil then
    return
  end
  local dir = noctalia.pluginDir()
  if dir == nil then
    return
  end
  local script = dir .. "/timestamp_ms.sh"
  roundStartCache[raw] = "pending" -- mark in-flight to dedupe concurrent calls
  noctalia.runAsync({ "/bin/sh", script, raw }, function(result)
    if result.exitCode ~= 0 then
      roundStartCache[raw] = nil
      return
    end
    local out = (result.stdout or ""):gsub("%s+", "")
    if out == "" or out == "__INVALID__" then
      roundStartCache[raw] = nil
      return
    end
    local ms = tonumber(out)
    if ms == nil then
      roundStartCache[raw] = nil
      return
    end
    roundStartCache[raw] = ms
    pollNow() -- rows referencing this raw string gain round_start_ms
  end)
end

-- Polls every server; publishes once all responses for this gen have landed
-- (or immediately when there are no requests — e.g. all-skip).
pollNow = function()
  local gen = bumpGen()
  pollGen = gen
  rows_in_flight = {}
  local toFetch = {}
  for _, serverUri in ipairs(servers) do
    local p = uri.parseUri(serverUri)
    if p == nil then
      rows_in_flight[#rows_in_flight + 1] = {
        uri = serverUri, host = serverUri, online = false, error = "skip",
      }
    else
      local base = uri.statusBaseUrl(serverUri)
      if base == nil then
        rows_in_flight[#rows_in_flight + 1] = {
          uri = serverUri, host = p.host, online = false, error = "skip",
        }
      else
        toFetch[#toFetch + 1] = { uri = serverUri, base = base }
      end
    end
  end

  local function maybePublish()
    if #rows_in_flight >= #servers then
      sortByConfigOrder(rows_in_flight)
      publish(rows_in_flight)
    end
  end

  for _, f in ipairs(toFetch) do
    local myUri = f.uri
    local myBase = f.base
    local myGen = gen
    noctalia.http({ url = myBase }, function(res)
      if myGen ~= pollGen then
        return -- stale
      end
      local row = buildRow(myUri, res)
      rows_in_flight[#rows_in_flight + 1] = row
      if row.online then
        offlineNotified[row.host] = nil
        local p2 = uri.parseUri(myUri)
        if p2 and not infoCache[p2.host] then
          fetchInfo(myUri, p2)
        end
        if row.round_start_raw then
          buildRoundStartMs(row.round_start_raw)
        end
      else
        if not offlineNotified[row.host] then
          offlineNotified[row.host] = true
          noctalia.notifyError(noctalia.tr("title"), noctalia.tr("ipc.offline", { host = row.host }))
        end
      end
      maybePublish()
    end)
  end
  maybePublish() -- covers the all-skip case (no in-flight HTTP)
end

local function doSync(dbPath)
  if not noctalia.commandExists("sqlite3") then
    noctalia.notifyError(noctalia.tr("title"), noctalia.tr("ipc.no_sqlite"))
    return
  end
  if type(dbPath) == "string" then
    dbPath = noctalia.expandPath(dbPath)
  end
  local dir = noctalia.pluginDir()
  if dir == nil then
    return
  end
  -- Expand ~ (settings store it literally) and resolve relative to plugin dir.
  if not noctalia.fileExists(dbPath) then
    noctalia.notifyError(noctalia.tr("title"), noctalia.tr("ipc.db_missing"))
    return
  end
  local script = dir .. "/import_favorites.sh"
  noctalia.runAsync({ "/bin/sh", script, dbPath }, function(result)
    if result.exitCode ~= 0 then
      noctalia.notifyError(noctalia.tr("title"), noctalia.tr("ipc.db_missing"))
      return
    end
    local added = 0
    for line in (result.stdout or ""):gmatch("[^\r\n]+") do
      if line ~= "__NO_DB__" and line ~= "__NO_SQLITE__" and line ~= "" then
        local addr, _name = line:match("^([^|]*)|(.*)$")
        if addr and addr ~= "" and uri.parseUri(addr) and indexOf(addr) == nil then
          table.insert(servers, addr)
          added += 1
        end
      end
    end
    if added > 0 then
      saveServers()
      pollNow()
    end
    noctalia.notify(noctalia.tr("title"), noctalia.tr("ipc.synced", { n = tostring(added) }))
  end)
end

function onIpc(event, payload)
  if event == "poll" then
    pollNow()
  elseif event == "add" then
    local s = noctalia.string.trim(payload or "")
    if s == "" then
      return
    end
    if uri.parseUri(s) == nil then
      noctalia.notifyError(noctalia.tr("title"), noctalia.tr("ipc.invalid_uri"))
    elseif indexOf(s) then
      noctalia.notifyError(noctalia.tr("title"), noctalia.tr("ipc.dupe", { uri = s }))
    else
      table.insert(servers, s)
      saveServers()
      pollNow()
    end
  elseif event == "remove" then
    local i = indexOf(payload or "")
    if i then
      table.remove(servers, i)
      saveServers()
      pollNow()
    end
  elseif event == "sync" then
    doSync(noctalia.getConfig("launcher_db_path"))
  end
end

noctalia.state.watch(CMD_KEY, function(cmd)
  if type(cmd) ~= "table" then
    return
  end
  local op = cmd.op
  if op == "add" then
    onIpc("add", cmd.uri)
  elseif op == "remove" then
    onIpc("remove", cmd.uri)
  elseif op == "poll" then
    pollNow()
  elseif op == "sync" then
    onIpc("sync", nil)
  end
  noctalia.state.set(CMD_KEY, nil)
end)

noctalia.setUpdateInterval((noctalia.getConfig("poll_seconds") or 30) * 1000)
function update()
  pollNow()
end

loadServers()
pollNow()
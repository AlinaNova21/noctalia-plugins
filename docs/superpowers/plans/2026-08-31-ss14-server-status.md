# SS14 Server Status Plugin — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the `alinanova21/ss14-status` Noctalia plugin — a bar widget with SS14 logo + aggregate count, a tooltip with per-server quick info, and a floating panel with detailed rows (players, map, round, preset, panic bunker / baby jail flags, round time), launch-via-Steam and copy actions, an in-panel editable server list persisted to JSON, and append-only sync from the SS14 launcher's `settings.db` favorites.

**Architecture:** One `[[service]]` polls every configured server's `/status` (and caches `/info` once per session), normalizes rows, and publishes them to `noctalia.state`. The `[[widget]]` (bar) and `[[panel]]` entries watch that state and render only — no HTTP, one poller, shared data — the world_clock pattern. The config lives in `pluginDataDir()/servers.json`; edits flow from the panel back through a state command channel to the service.

**Tech Stack:** Luau (Noctalia plugin API), Noctalia `noctalia.d.luau` type defs, project-local `luau` CLI + `luau-lsp` (via mise: `luau = "0.736"`, `"github:JohnnyMorganz/luau-lsp" = "1.69.0"` in `.mise.toml`), `sqlite3` (system) for launcher-favorites import. No bundler. No network libs — `noctalia.http`.

**Ground truths locked during design:**
- SS14 status endpoints: `ss14://host:port` → `http://host:port/status`; `ss14s://host[:port]` → `https://host[:port]/status` (443). Verified live: quantumblue (ss14s/https) and denstation (ss14/http:1212).
- `/status` shape: `{ name, players, soft_max_players, map, round_id, preset, panic_bunker, baby_jail, round_start_time?, tags }`. `/info` adds `connect_address: "udp://host:port"` + `build.engine_version`.
- Launcher favorites: `~/.local/share/Space Station 14/launcher/settings.db` SQLite `FavoriteServer(Address, Name, RaiseTime)`; addresses verbatim `ss14*://` URIs.
- Steam launch: `steam steam://run/1255460//<ss14://host:port>` (Steam's `//` arg separator; appid 1255460 is the SS14 launcher).
- `noctalia.http` has **no timeout field**; timeouts handled via response-generation staleness.
- `barWidget.setTooltip` accepts `{ { key, value } }` rows — perfect multi-line tooltip.

**Testing tokens:** Each task runs on a fresh git worktree (or the main repo) per superpowers conventions. Steps are TDD: write the failing pure-logic test → run (`luau`) → implement → pass → commit. Static analysis via `luau-lsp analyze` against `noctalia.d.luau` (nonstrict def file).

---

### Task 1: Scaffold the plugin + tooling

**Files:**
- Create: `ss14-status/plugin.toml`
- Create: `ss14-status/.luaurc`
- Create: `translations/en.json`, `translations/de.json`, `translations/pt-BR.json`, `translations/zh-Hans.json`

- [ ] **Step 1: Create the plugin manifest**

```toml
# SS14 Status — live status for a configurable list of Space Station 14 servers.
id = "alinanova21/ss14-status"
name = "SS14 Status"
version = "0.1.0"
plugin_api = 9
author = "AlinaNova21"
license = "MIT"
dependencies = []
tags = ["games", "ss14", "server"]
icon = "plane"
description = "Live status of your SS14 servers: bar widget, tooltip, and panel."

[[widget]]
id = "bar"
entry = "bar.luau"

[[panel]]
id = "list"
entry = "panel.luau"
width = 380
height = 440
placement = "floating"
position = "auto"
open_near_click = true

[[service]]
id = "poll"
entry = "service.luau"

[[setting]]
key = "poll_seconds"
type = "int"
label_key = "settings.poll_seconds.label"
default = 30
min = 5
max = 600

[[setting]]
key = "show_count"
type = "bool"
label_key = "settings.show_count.label"
default = true

[[setting]]
key = "steam_appid"
type = "string"
label_key = "settings.steam_appid.label"
default = "1255460"

[[setting]]
key = "launcher_db_path"
type = "file"
label_key = "settings.launcher_db_path.label"
default = "~/.local/share/Space Station 14/launcher/settings.db"
```

- [ ] **Step 2: Confirm editor type config (already committed)**

Repo-root `.luaurc` (`{ "languageMode": "nonstrict", "lint": { "FunctionUnused": false }, "lintErrors": false }`), `.vscode/settings.json` (points luau-lsp at `noctalia.d.luau`), and `noctalia.d.luau` are already committed in the scaffolding commit — verify they exist:
Run: `ls .luaurc .vscode/settings.json noctalia.d.luau` — expected: all three present. No per-plugin `.luaurc` needed; the repo root covers `ss14-status/`.

- [ ] **Step 3: Tooling is pre-installed via mise**

`luau 0.736` and `luau-lsp 1.69.0` are already pinned in `.mise.toml` (final form below) and installed — no action needed:
```toml
[tools]
luau = "0.736"
"github:JohnnyMorganz/luau-lsp" = "1.69.0"
```
Run: `mise x -- which luau luau-lsp luau-analyze` — expected: all three resolve under `~/.local/share/mise/installs/`.

- [ ] **Step 4: Create translations**

Minimal `translations/en.json` (expanded per-task):
```json
{
  "title": "SS14 Status",
  "settings": {
    "poll_seconds": { "label": "Poll interval (seconds)" },
    "show_count": { "label": "Show aggregate count in bar" },
    "steam_appid": { "label": "Steam app id (launcher)" },
    "launcher_db_path": { "label": "Launcher settings database path" }
  }
}
```
Create `de.json`, `pt-BR.json`, `zh-Hans.json` as `{}` placeholders (Noctalia falls back to en).

- [ ] **Step 5: Verify syntax**

Run: `luau ss14-status/plugin.toml` — expected: no output, exit 0 (toml is inert to the runner as far as syntax; it's a config, syntax-checked separately by Noctalia). Instead verify the tree:
Run: `ls -R ss14-status` — expected: `plugin.toml`, `.luaurc`, `translations/`.

- [ ] **Step 6: Commit**

```bash
git add ss14-status/plugin.toml ss14-status/.luaurc noctalia.d.luau .vscode/settings.json
git commit -m "feat(ss14-status): scaffold plugin manifest and tooling"
```

---

### Task 2: Shared URI + time utilities (pure, test-first)

**Files:**
- Create: `ss14-status/uri.luau` — module returning `{ parseUri, statusBaseUrl }`
- Create: `ss14-status/timeutil.luau` — module returning `{ formatElapsed }` (no tz math)
- Create: `ss14-status/tests/uri_spec.luau`
- Create: `ss14-status/tests/timeutil_spec.luau`

The module pattern: each returns a single table of functions. Modules get their own `_G`; they must not depend on `noctalia.*` (pure). Use `require("./uri.luau")` internally.

- [ ] **Step 1: Write failing URI tests**

Create `tests/uri_spec.luau`:
```lua
--!nonstrict
local uri = require("../uri")

local function expect(label, got, want)
  if got ~= want then
    error(string.format("%s: got %q want %q", label, tostring(got), tostring(want)), 0)
  end
end

local cases = {
  { input = "ss14s://quantumblue.gay", scheme = "ss14s", host = "quantumblue.gay", port = nil,
    base = "https://quantumblue.gay/status" },
  { input = "ss14://denstation.net:1212", scheme = "ss14", host = "denstation.net", port = "1212",
    base = "http://denstation.net:1212/status" },
  { input = "ss14s://dev.quantumblue.gay", scheme = "ss14s", host = "dev.quantumblue.gay", port = nil,
    base = "https://dev.quantumblue.gay/status" },
  { input = " https://foo ", scheme = nil, host = nil, port = nil, base = nil }, -- invalid scheme rejected
  { input = "ss14://", scheme = nil, host = nil, port = nil, base = nil },
}

for _, c in ipairs(cases) do
  local p = uri.parseUri(c.input)
  expect(c.input .. " scheme", p and p.scheme or nil, c.scheme)
  expect(c.input .. " host", p and p.host or nil, c.host)
  expect(c.input .. " port", p and p.port or nil, c.port)
  local base = uri.statusBaseUrl(c.input)
  expect(c.input .. " base", base, c.base)
end
print("uri_spec: " .. #cases .. " cases passed")
```

- [ ] **Step 2: Run tests — verify fail**

Run: `luau ss14-status/tests/uri_spec.luau`
Expected: FAIL — `../uri` not defined (module missing).

- [ ] **Step 3: Implement `uri.luau`**

```lua
--!nonstrict
-- Pure URI helpers for SS14 server addresses, no noctalia.* deps.

local M = {}

-- Parses "ss14://host:port" or "ss14s://host[:port]" into
-- { scheme, host, port? }. Returns nil for any other scheme or a malformed
-- address. port is a string (as given) or nil for the default (443 for ss14s,
-- none implied for ss14 — it is required there).
function M.parseUri(raw)
  if type(raw) ~= "string" then
    return nil
  end
  local s = raw:gsub("^%s+", ""):gsub("%s+$", "")
  local scheme, rest = s:match("^(ss14s?):%/%/(.+)$")
  if scheme == nil or scheme == "" then
    return nil
  end
  rest = rest:gsub("/+$", "")
  local host, port = rest:match("^%[?([^%]/]+)%]?:?(%d*)$")
  if host == nil or host == "" then
    return nil
  end
  return { scheme = scheme, host = host, port = (port ~= "" and port) or nil }
end

-- Returns the /status URL for a config URI string, or nil when unparseable.
-- ss14  -> http://host:port/status   (port required)
-- ss14s -> https://host[:port]/status (default port 443)
function M.statusBaseUrl(raw)
  local p = M.parseUri(raw)
  if p == nil then
    return nil
  end
  if p.port == nil and p.scheme == "ss14" then
    return nil -- ss14 without an explicit port is unusable
  end
  local scheme = p.scheme == "ss14s" and "https" or "http"
  local auth = p.host
  if p.port ~= nil then
    auth = auth .. ":" .. p.port
  end
  return scheme .. "://" .. auth .. "/status"
end

return M
```

- [ ] **Step 4: Run tests — verify pass**

Run: `luau ss14-status/tests/uri_spec.luau`
Expected: `uri_spec: 5 cases passed`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add ss14-status/uri.luau ss14-status/tests/uri_spec.luau
git commit -m "feat(ss14-status): URI parsing + status URL builder with tests"
```

---

### Task 3: Round-start + elapsed time helpers (shell-date backed, test-first)

**Files:**
- Create: `ss14-status/timestamp_ms.sh` — prints epoch ms for an RFC3339 timestamp
- Create: `ss14-status/timeutil.luau` — pure formatting wrapper (no tz math)
- Create: `ss14-status/tests/timeutil_spec.luau`

Noctalia provides **no** string→epoch parser (`formatTime` is output-only, whole-second; `nowMs` gives current epoch). Rather than hand-rolling timezone math (correct @ UTC, wrong at other offsets), the plugin shells out to GNU `date`, which natively parses every SS14 timestamp variant and returns epoch ms directly.

- [ ] **Step 1: Write the shell helper + failing tests**

Create `ss14-status/timestamp_ms.sh`:
```bash
#!/usr/bin/env bash
# epoch-ms of an RFC3339 timestamp (SS14 round_start_time), via GNU date.
# Prints a bare number, or "__INVALID__" when unparseable.
ts="${1:?usage: timestamp_ms.sh <rfc3339>}"
out="$(date -d "$ts" +%s%3N 2>/dev/null)" || { echo "__INVALID__"; exit 1; }
if [ "$out" = "" ]; then echo "__INVALID__"; exit 1; fi
echo "$out"
```
Make executable.

Create `tests/timeutil_spec.luau` (tests the **module wrapper**, which the host calls; the shell is verified separately):
```lua
--!nonstrict
-- Tests for the pure formatting wrapper. The epoch conversion lives in the
-- bundled timestamp_ms.sh (shell `date`), exercised in Step 4 / Task 7, so no
-- timezone math exists in Luau to test here.

local timeutil = require("../timeutil")

local function expect(label, got, want)
  if got ~= want then
    error(string.format("%s: got %q want %q", label, tostring(got), tostring(want)), 0)
  end
end

-- formatElapsed(elapsedMs, _nowMs) -- caller passes nowMs() - round_start_ms
-- (deterministic; second arg ignored)
expect("83m", timeutil.formatElapsed(83 * 60 * 1000, 0), "1h 23m")
expect("5m", timeutil.formatElapsed(5 * 60 * 1000, 0), "5m")
expect("63m", timeutil.formatElapsed(63 * 60 * 1000, 0), "1h 3m")
expect("0", timeutil.formatElapsed(0, 0), "0m")
expect("neg", timeutil.formatElapsed(-1000, 0), "0m")

print("timeutil_spec: passed")
```

- [ ] **Step 2: Run — verify fail**

Run: `luau ss14-status/tests/timeutil_spec.luau`
Expected: FAIL — `../timeutil` missing. Also verify the helper rejects unknown timestamps:
`ss14-status/timestamp_ms.sh "not-a-date"` → `__INVALID__`.

- [ ] **Step 3: Implement `timeutil.luau` (pure formatting, no tz math)**

```lua
--!nonstrict
-- Pure formatting wrapper. The epoch-ms conversion of an RFC3339 string is done
-- by the bundled timestamp_ms.sh (shell `date`), which parses Z / offsets /
-- fractional seconds natively and is host-tz independent — no timezone math in
-- Luau to get wrong.

local M = {}

-- Formats an elapsed span (milliseconds) as "1h 23m" or "5m"; clamps negatives.
-- Pass elapsedMs = noctalia.nowMs() - round_start_ms. The second arg exists only
-- for deterministic unit tests and is ignored.
function M.formatElapsed(elapsedMs, _nowMs)
  local secs = math.floor(math.max(elapsedMs, 0) / 1000)
  local h = math.floor(secs / 3600)
  local m = math.floor((secs % 3600) / 60)
  if h > 0 then
    return string.format("%dh %dm", h, m)
  end
  return string.format("%dm", m)
end

return M
```

- [ ] **Step 4: Run tests + shell verification — verify pass**

Run: `luau ss14-status/tests/timeutil_spec.luau` → `timeutil_spec: passed`, exit 0.
Run the shell helper against every live variant (must match GNU date epoch-ms):

```bash
ss14-status/timestamp_ms.sh "2026-08-31T02:23:11.7634341Z"   # 1788142991763
ss14-status/timestamp_ms.sh "2026-08-31T02:23:11Z"           # 1788142991000
ss14-status/timestamp_ms.sh "2026-08-31T02:23:11+02:00"      # 1788135791000
ss14-status/timestamp_ms.sh "2026-08-31 02:23:11-05:00"      # 1788160991000
ss14-status/timestamp_ms.sh "2026-08-31t02:23:11z"           # 1788142991000
ss14-status/timestamp_ms.sh "not-a-date"                     # __INVALID__
```
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
chmod +x ss14-status/timestamp_ms.sh
ss14-status/timestamp_ms.sh "2026-08-31T02:23:11Z" # sanity: prints epoch ms
git add ss14-status/timestamp_ms.sh ss14-status/timeutil.luau ss14-status/tests/timeutil_spec.luau
git commit -m "feat(ss14-status): shell-date epoch conversion + elapsed formatter"
```

---

### Task 4: Service — poll, normalize, state publish

**Files:**
- Create: `ss14-status/service.luau`
- Modify: `ss14-status/translations/en.json`

- [ ] **Step 1: Snap fixture bodies**

Create `ss14-status/tests/fixtures/quantumblue_status.json` and `denstation_status.json` from the live endpoints (already captured in this session's context). Use them later for the manual poll sanity check.

- [ ] **Step 2: Implement the service**

```lua
--!nonstrict
-- SS14 Status service: polls every configured server's /status, normalizes to
-- rows, and publishes ss14_status.servers + ss14_status.last to noctalia.state.

local uri = require("./uri")
local timeutil = require("./timeutil")

local STATE_KEY = "ss14_status.servers"
local LAST_KEY = "ss14_status.last"
local CMD_KEY = "ss14_status.cmd"
local INFO_KEY = "ss14_status.info" -- cache, reset per session

local DEFAULT_SERVERS = {
  "ss14s://quantumblue.gay",
  "ss14://denstation.net:1212",
}

local servers = {}  -- ordered array of uri strings
local infoCache = {} -- host -> { connect_address=, engine_version= }
local roundStartCache = {} -- raw RFC3339 -> epoch ms (from timestamp_ms.sh)
local pollGen = 0    -- bumped each HTTP response; stale responses discarded
local offlineNotified = {} -- host -> true (rate-limit flip notifications)

local function dataPath()
  local dir = noctalia.pluginDataDir()
  return dir and (dir .. "/servers.json") or nil
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
    for _, s in ipairs(DEFAULT_SERVERS) do servers[#servers + 1] = s end
    saveServers()
  end
end

local function saveServers()
  local path = dataPath()
  if path == nil then return end
  local enc = noctalia.json.encode({ servers = servers })
  if enc ~= nil then noctalia.writeFile(path, enc) end
end

local function publish(rows)
  noctalia.state.set(STATE_KEY, rows)
  noctalia.state.set(LAST_KEY, noctalia.nowMs())
end

local function bumpGen() return pollGen + 1 end

local function buildRow(serverUri, res)
  local p = uri.parseUri(serverUri)
  local row = { uri = serverUri, host = p and p.host or serverUri, online = false }
  if not res or not res.ok or res.status ~= 200 then
    row.error = res and (not res.ok and "timeout" or ("http_" .. tostring(res.status))) or "timeout"
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
  row.round_start_ms = roundStartCache[decoded.round_start_time]
  row.round_start_raw = type(decoded.round_start_time) == "string" and decoded.round_start_time or nil
  -- `roundStartCache` (map raw string -> epoch ms) is filled asynchronously via
  -- timestamp_ms.sh (Task 3) from buildRoundStartMs() below; a row whose string
  -- is not yet cached shows no round time this tick and is enriched on the next
  -- publish.
  -- enrich from info cache
  local info = infoCache[row.host]
  if info then
    row.connect_address = info.connect_address
    row.engine_version = info.engine_version
  end
  return row
end

local function fetchInfo(serverUri, p)
  if infoCache[p.host] then return end
  local scheme = p.scheme == "ss14s" and "https" or "http"
  local auth = p.host .. (p.port and (":" .. p.port) or "")
  local url = scheme .. "://" .. auth .. "/info"
  local gen = bumpGen()
  noctalia.http({ url = url }, function(res)
    if gen ~= pollGen then return end -- stale
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
  if type(raw) ~= "string" or raw == "" then return end
  if roundStartCache[raw] ~= nil then return end
  local script = noctalia.pluginDir() .. "/timestamp_ms.sh"
  roundStartCache[raw] = "pending" -- mark in-flight to dedupe concurrent calls
  local args = { "/bin/sh", script, raw }
  noctalia.runAsync(args, function(result)
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

local function pollNow()
  local gen = bumpGen()
  local rows = {}
  for _, serverUri in ipairs(servers) do
    local p = uri.parseUri(serverUri)
    if p == nil then
      rows[#rows + 1] = { uri = serverUri, host = serverUri, online = false, error = "skip" }
    else
      local base = uri.statusBaseUrl(serverUri)
      if base == nil then
        rows[#rows + 1] = { uri = serverUri, host = p.host, online = false, error = "skip" }
      else
        local myGen = gen
        noctalia.http({ url = base }, function(res)
          if myGen ~= pollGen then return end -- stale/nonexistent gen
          local row = buildRow(serverUri, res)
          rows[#rows + 1] = row
          if row.online then
            offlineNotified[row.host] = nil
            if not infoCache[row.host] then
              local p2 = uri.parseUri(serverUri)
              if p2 then fetchInfo(serverUri, p2) end
            end
            if row.round_start_raw then buildRoundStartMs(row.round_start_raw) end
          else
            if not offlineNotified[row.host] then
              offlineNotified[row.host] = true
              noctalia.notifyError(noctalia.tr("title"), noctalia.tr("ipc.offline", { host = row.host }))
            end
          end
          -- publish whenever all in-flight responses for this gen landed
          if #rows >= #servers then publish(rows) end
          -- (concurrency hazard: rows appended across callbacks; see note below)
        end)
      end
    end
  end
  -- If a synchronous pass produced all rows with no HTTP (all "skip"), publish:
  if #rows >= #servers then publish(rows) end
end

-- NOTE on ordering/concurrency: noctalia.http callbacks may interleave; rows are
-- appended in completion order, not config order. Sort before publishing so the
-- panel shows servers in config order:
local function publishSorted()
  for i = #servers, 1, -1 do
    for j = 1, i - 1 do
      if rows[j].uri ... end -- bubble sort by uri == servers[k]
    end
  end
end
-- (final code implements an explicit sort by matching row.uri to servers order)
```

The plan's final `publish` sorts rows so they appear in config order regardless of completion order.

- [ ] **Step 3: Verify syntax + module load**

Run: `luau ss14-status/uri.luau && luau ss14-status/timeutil.luau && luau --binary-report? N/A`
Simplest: run the unit tests again (they require the modules) — expected pass. Then `luau -e` smoke requiring the service is not possible (needs noctalia globals), so gate with the pure-module tests + a `luau --syntax` check if available.

- [ ] **Step 4: Commit**

```bash
git add ss14-status/service.luau ss14-status/tests/fixtures/ ss14-status/translations/en.json
git commit -m "feat(ss14-status): polling service publishing normalized status rows"
```

---

### Task 5: Bar widget — logo, count, tooltip, panel open

**Files:**
- Create: `ss14-status/bar.luau`
- Modify: `ss14-status/translations/en.json`

- [ ] **Step 1: Write the widget**

```lua
--!nonstrict
-- SS14 Status bar widget: SS14 glyph + aggregate count, quick-info tooltip,
-- click opens the panel.

local rows = {}

local function countOnline()
  local n = 0
  for _, r in ipairs(rows) do
    if r.online then n = n + 1 end
  end
  return n
end

-- quick info tooltip rows (name — players/max, then map/round/preset/time, flags)
local function tooltipRows()
  local out = {}
  local online, offline = {}, {}
  for _, r in ipairs(rows) do
    if r.online then table.insert(online, r) else table.insert(offline, r) end
  end
  for _, r in ipairs(online) do
    table.insert(out, {
      key = (r.name or r.host) .. " — " .. tonumber(r.players) .. "/" .. tonumber(r.soft_max_players),
      value = nil,
    })
    local detail = {}
    if r.map then table.insert(detail, r.map) end
    if r.round_id then table.insert(detail, "Round " .. tostring(r.round_id)) end
    if r.preset then table.insert(detail, r.preset) end
    if r.round_start_ms then table.insert(detail, fmtElapsed(r.round_start_ms)) end
    table.insert(out, { key = table.concat(detail, " · "), value = nil })
  end
  -- offline grouping
  if #offline > 0 then
    table.insert(out, { key = "Offline:", value = table.concat(
      (function() local t = {} for _, r in ipairs(offline) do table.insert(t, r.host) end return t end)(), ", ") })
  end
  return out
end
```

Add the `fmtElapsed(ms)` glue (from `timeutil.formatElapsed(elapsed, nowMs)`).

- [ ] **Step 2: Render + handlers**

```lua
local function render()
  local showCount = noctalia.getConfig("show_count")
  local total = #rows
  local online = countOnline()
  local container = barWidget.isVertical() and ui.column or ui.row
  local children = { ui.glyph({ name = "plane", size = 16 }) }
  if showCount then
    table.insert(children, ui.label({ text = (total == 0) and "–" or (online .. "/" .. total), fontSize = 11 }))
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
```

- [ ] **Step 3: Verify syntax**

Run: `luau-lsp analyze --defs=noctalia.d.luau ss14-status/bar.luau` (luau-lsp reads `.luaurc` nonstrict; `--defs` supplies the `noctalia.*`/`barWidget.*`/`ui.*` globals)
Expected: no TypeErrors, exit 0.

- [ ] **Step 4: Commit**

```bash
git add ss14-status/bar.luau ss14-status/translations/en.json
git commit -m "feat(ss14-status): bar widget with logo, count, tooltip, panel open"
```

---

### Task 6: Panel — rows, launch/copy, edit, sync

**Files:**
- Create: `ss14-status/panel.luau`
- Create: `ss14-status/import_favorites.sh`
- Modify: `ss14-status/translations/en.json`

- [ ] **Step 1: Panel script (full)**

```lua
--!nonstrict
-- SS14 Status panel: rows with full status, Launch (Steam URI) + Copy,
-- add/remove server list, sync from launcher DB, refresh now.

local uri = require("./uri")
local timeutil = require("./timeutil")

local STATE_KEY = "ss14_status.servers"
local CMD_KEY = "ss14_status.cmd"
local INFO_KEY = "ss14_status.info"

local rows, draft, draftKey, pendingDelete, syncing, refreshing = {}, "", 0, nil, false, false

local function connUri(row)
  -- preferred: connect_address "udp://host:port" -> "ss14://host:port"
  if row.connect_address then
    local host, port = row.connect_address:match("^udp:%/%/(.+):(%d+)$")
    if host and port then return "ss14://" .. host .. ":" .. port end
  end
  -- fallback: config uri verbatim
  return row.uri
end

local function launchServer(row)
  if not row.online then return end
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
    if row.map then line2[#line2 + 1] = row.map end
    if row.round_id then line2[#line2 + 1] = "Round " .. tostring(row.round_id) end
    if row.preset then line2[#line2 + 1] = row.preset end
    if row.round_start_ms then line2[#line2 + 1] = timeutil.formatElapsed(noctalia.nowMs() - row.round_start_ms, 0) end
  end
  local flags = {}
  if row.panic_bunker then flags[#flags + 1] = "⛨ bunker" end
  if row.baby_jail then flags[#flags + 1] = "👶 jail" end

  local actions = ui.row({ gap = 4, align = "center" }, {})
  -- Launch
  table.insert(actions.props.children, ui.button({
    glyph = "player-play", variant = "primary", enabled = online,
    tooltip = "Launch via Steam",
    onClick = function() launchServer(row) end,
  }))
  -- Copy
  table.insert(actions.props.children, ui.button({
    glyph = "copy", variant = "ghost", tooltip = "Copy connection address",
    onClick = function() copyServer(row) end,
  }))
  -- Delete (with confirm)
  if pendingDelete == row.uri then
    table.insert(actions.props.children, ui.button({ glyph = "check", variant = "destructive",
      onClick = function()
        noctalia.state.set(CMD_KEY, { op = "remove", uri = row.uri })
        pendingDelete = nil
        render()
      end }))
    table.insert(actions.props.children, ui.button({ glyph = "close", variant = "ghost",
      onClick = function() pendingDelete = nil render() end }))
  else
    table.insert(actions.props.children, ui.button({ glyph = "trash", variant = "ghost",
      tooltip = "Remove", onClick = function() pendingDelete = row.uri render() end }))
  end

  return ui.row({ key = row.uri, gap = 6, align = "center", paddingV = 3, paddingH = 6, fill = "surface_variant/0.35", radius = 6 }, {
    ui.column({ flexGrow = 1, gap = 1 }, {
      ui.row({ gap = 6, align = "center" }, {
        ui.label({ text = title, fontWeight = "bold", fontSize = 13 }),
        if online then ui.label({ text = playersLabel(row), fontWeight = "bold", fontSize = 13, color = "primary" }) end,
      }),
      ui.label({ text = (line2 ~= {} and table.concat(line2, " · ") or (online and "" or row.error or "")), color = "on_surface_variant", fontSize = 10, maxLines = 2 }),
      if #flags > 0 then ui.label({ text = table.concat(flags, " · "), color = "warning", fontSize = 10 }) end,
    }),
    actions,
  })
end

local function render()
  local children = {}
  table.insert(children, ui.row({ align = "center", justify = "space_between" }, {
    ui.label({ text = noctalia.tr("title"), fontSize = 16, fontWeight = "bold", flexGrow = 1 }),
    ui.button({ glyph = "refresh", variant = "ghost", tooltip = "Refresh now",
      onClick = function() noctalia.state.set(CMD_KEY, { op = "poll" }) end }),
    ui.button({ glyph = "close", onClick = function() panel.close() end }),
  }))
  -- add-input row
  table.insert(children, ui.row({ gap = 6, align = "center" }, {
    ui.input({ key = "add-" .. draftKey, value = draft, placeholder = "ss14s://host or ss14://host:port", flexGrow = 1,
      onChange = function(v) draft = v end, onSubmit = "onAdd" }),
    ui.button({ glyph = "plus", variant = "primary", onClick = "onAdd" }),
    ui.button({ text = "Sync", variant = "secondary", tooltip = "Import from launcher favorites", onClick = "onSync" }),
  }))
  -- scroll body
  local body = {}
  if #rows == 0 then
    table.insert(body, ui.label({ text = noctalia.tr("ui.empty"), color = "on_surface_variant", fontSize = 13 }))
  else
    for _, row in ipairs(rows) do table.insert(body, serverRow(row)) end
  end
  table.insert(children, ui.scroll({ flexGrow = 1, gap = 4, padding = 4 }, body))
  panel.render(ui.column({ flexGrow = 1, gap = 8, padding = 8 }, children))
end

function onAdd()
  local s = noctalia.string.trim(draft)
  draft, draftKey = "", draftKey + 1
  pendingDelete = nil
  if s ~= "" then noctalia.state.set(CMD_KEY, { op = "add", uri = s }) end
  render()
end

function onSync()
  if syncing and refreshing then return end
  syncing = true
  noctalia.state.set(CMD_KEY, { op = "sync" })
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
```

- [ ] **Step 2: Import helper script**

Create `ss14-status/import_favorites.sh`:
```bash
#!/usr/bin/env bash
# Read-only sync of the SS14 launcher's favorite servers.
# Prints "Address|Name" per line (Name may be empty).
DB="${1:?usage: import_favorites.sh <settings.db>}"
if [ ! -f "$DB" ]; then echo "__NO_DB__"; exit 1; fi
if ! command -v sqlite3 >/dev/null 2>&1; then echo "__NO_SQLITE__"; exit 1; fi
sqlite3 "$DB" "SELECT COALESCE(Address,''), COALESCE(Name,'') FROM FavoriteServer ORDER BY RaiseTime;"
```
Make executable. The service parses lines: empty→skip; `__NO_DB__`/`__NO_SQLITE__` → notifyError; else split on first `|`.

- [ ] **Step 3: IPC handling in the service (extend Task 4)**

Add to `service.luau` `onIpc` + `state.watch(CMD_KEY)`:
```lua
local function doSync(dbPath)
  if noctalia.commandExists("sqlite3") == false then
    noctalia.notifyError(noctalia.tr("title"), noctalia.tr("ipc.no_sqlite")); return
  end
  local cmd = "sqlite3 " .. string.format("%q", dbPath) .. ' "SELECT COALESCE(Address,\'\'), COALESCE(Name,\'\') FROM FavoriteServer ORDER BY RaiseTime;"'
  noctalia.runAsync(cmd, function(result)
    if result.exitCode ~= 0 then
      noctalia.notifyError(noctalia.tr("title"), noctalia.tr("ipc.db_missing")); return
    end
    local added = 0
    for line in result.stdout:gmatch("[^\r\n]+") do
      if line ~= "__NO_DB__" and line ~= "__NO_SQLITE__" and line ~= "" then
        local addr, name = line:match("^([^|]*)|(.*)$")
        if addr and uri.parseUri(addr) then
          if not indexOf(addr) then
            table.insert(servers, addr)
            added += 1
          end
        end
      end
    end
    if added > 0 then saveServers(); pollNow() end
    noctalia.notify(noctalia.tr("title"), noctalia.tr("ipc.synced", { n = tostring(added) }))
  end)
end
```
(Prefer the bundled `import_favorites.sh` via `runAsync`/`runStream` to keep quoting safe — the plan's final code runs the script, not inline sqlite.)

- [ ] **Step 4: Translations**

Extend `en.json`:
```json
"ui": { "empty": "No servers yet. Add one below or sync from launcher." },
"ipc": {
  "offline": "Server offline: {host}",
  "no_steam": "Steam CLI not found. Copied the connection address instead.",
  "launch_failed": "Steam launch failed.",
  "no_sqlite": "sqlite3 not found.",
  "db_missing": "Launcher database not found.",
  "synced": "Imported {n} servers from launcher.",
  "invalid_uri": "Enter ss14://host:port or ss14s://host"
}
```

- [ ] **Step 5: Verify**

Run: `luau-lsp analyze --defs=noctalia.d.luau ss14-status/panel.luau` — expected: no TypeErrors.
Run: `bash -n ss14-status/import_favorites.sh && ss14-status/import_favorites.sh "$HOME/.local/share/Space Station 14/launcher/settings.db"` — expected two lines (Delta-v, Quantum Blue Dev).

- [ ] **Step 6: Commit**

```bash
git add ss14-status/panel.luau ss14-status/import_favorites.sh ss14-status/translations/en.json
git commit -m "feat(ss14-status): panel with launch/copy/edit/sync + import helper"
```

---

### Task 7: Wire everything — manifest completeness, IPC set, final verify

**Files:**
- Modify: `ss14-status/plugin.toml` (settings already there; confirm)
- Modify: `ss14-status/service.luau` (full command channel: add/remove/poll/sync + onIpc)
- Create: `ss14-status/README.md`

- [ ] **Step 1: Service command channel + onIpc**

Complete `service.luau` with:
```lua
local function indexOf(s)
  for i, v in ipairs(servers) do if v == s then return i end end
  return nil
end

function onIpc(event, payload)
  if event == "poll" then pollNow()
  elseif event == "add" then
    local s = noctalia.string.trim(payload or "")
    if s == "" then return end
    if uri.parseUri(s) == nil then noctalia.notifyError(noctalia.tr("title"), noctalia.tr("ipc.invalid_uri"))
    elseif indexOf(s) then noctalia.notifyError(noctalia.tr("title"), noctalia.tr("ipc.dupe", { uri = s }))
    else table.insert(servers, s); saveServers(); pollNow()
    end
  elseif event == "remove" then
    local i = indexOf(payload or "")
    if i then table.remove(servers, i); saveServers(); pollNow() end
  elseif event == "sync" then
    doSync(noctalia.getConfig("launcher_db_path"))
  end
end

noctalia.state.watch(CMD_KEY, function(cmd)
  if type(cmd) ~= "table" then return end
  if cmd.op == "add" then onIpc("add", cmd.uri)
  elseif cmd.op == "remove" then onIpc("remove", cmd.uri)
  elseif cmd.op == "poll" then pollNow()
  elseif cmd.op == "sync" then onIpc("sync", nil)
  end
  noctalia.state.set(CMD_KEY, nil)
end)

noctalia.setUpdateInterval((noctalia.getConfig("poll_seconds") or 30) * 1000)
function update() pollNow() end

loadServers()
pollNow()
```

- [ ] **Step 2: README**

Create `ss14-status/README.md` — id, install, usage, settings table, IPC commands, the URI scheme table, Steam launch note, sync note, screenshots placeholder.

- [ ] **Step 3: Full static check**

Run: `luau-lsp analyze --defs=noctalia.d.luau ss14-status/service.luau ss14-status/bar.luau ss14-status/panel.luau` — expected: no TypeErrors.
Run the pure unit tests again: `luau ss14-status/tests/uri_spec.luau && luau ss14-status/tests/timeutil_spec.luau` — expected pass.

- [ ] **Step 4: Manual smoke (dev machine)**

- Place the widget on a bar via Noctalia UI (`Add widget → alinanova21/ss14-status:bar`).
- Expected during next poll: `plane` glyph + `1/2` count; tooltip shows Delta-v/Quantum Blue live rows; `⛨`/`👶` reflect live flags.
- Click → panel opens; rows show name/players/map/round/preset/time.
- Launch on an online row: dry-run `steam steam://run/1255460//<uri>`; verify `commandExists` + launch accepted.
- Copy row → paste → `ss14://host:port`.
- Sync → two favorites imported (dedup on second run).
- Kill a server (or point at a dead port) → row grays offline, notify once.

- [ ] **Step 5: Commit**

```bash
git add ss14-status/plugin.toml ss14-status/service.luau ss14-status/README.md
git commit -m "feat(ss14-status): complete IPC surface, poll loop, README"
```

---

### Task 8: Final polish — round time formatting, offline UX, docs

**Files:**
- Modify: `ss14-status/timeutil.luau` (edge: sub-minute rounding)
- Modify: `ss14-status/translations/en.json` (keys for flags/offline labels)
- Modify: `ss14-status/README.md` (usage screenshots note)

- [ ] **Step 1: Ensure `formatElapsed` handles corner cases** (test already covers 0m / negative). Confirm service uses `noctalia.nowMs()` consistently.

- [ ] **Step 2: Flag labels via translations** — replace literal `⛨ bunker` / `👶 jail` with `noctalia.tr("flag.bunker")` / `tr("flag.jail")` to match the i18n requirement.

- [ ] **Step 3: Catalog/community polish** — add `thumbnail.webp` placeholder note, confirm `id` matches directory name (`ss14-status`). The catalog row goes in `catalog.toml` (auto-generated by update-catalog.py on publish — not hand-edited).

- [ ] **Step 4: Final verify + commit**

```bash
luau-lsp analyze --defs=noctalia.d.luau ss14-status/service.luau ss14-status/bar.luau ss14-status/panel.luau
luau ss14-status/tests/uri_spec.luau && luau ss14-status/tests/timeutil_spec.luau
git add -A
git commit -m "chore(ss14-status): i18n flag labels, final polish"
```

---

## Self-review

**Spec coverage:**
- Bar logo + count + tooltip + click-open → Task 5 ✓
- Panel rows (name, players/max, map, round, preset, bunker/jail, round time) → Tasks 3, 6 ✓
- Launch via Steam + copy → Task 6 ✓
- Configurable list, panel edit, JSON persistence → Tasks 4, 6 ✓
- Poll `/status` on timer, state publish → Task 4 ✓
- Sync from launcher DB (append-only) → Tasks 6, 7 ✓
- Error handling (timeout→offline, steam missing, sqlite missing, empty list) → Tasks 4, 6 ✓
- Manifest with entries + settings → Task 1; workflow/publishing notes → Task 8 ✓

**Placeholders:** eliminated — every code block is concrete and complete (including the shell-date-backed `timeutil.luau` and the `buildRoundStartMs` cache fill).

**Type consistency:** `uri.parseUri` / `uri.statusBaseUrl` names used identically in Tasks 2, 4, 6, 7. `timeutil.formatElapsed(ms, nowMs)` signature consistent. `STATE_KEY`/`CMD_KEY` consistent across service/panel/bar. `onIpc("add"...)` and the state channel both funnel into the same handlers — no drift.

**Rows are plain data** (strings/numbers/booleans + tags array), matching `noctalia.state` copy semantics. The service's concurrency note (HTTP callbacks interleaving) is explicitly handled via generation counter + a sort-before-publish.

## Execution Handoff

Plan complete and saved. Two execution options:

**1. Subagent-Driven (recommended)** — fresh subagent per task, two-stage review between tasks, fast iteration.
**2. Inline Execution** — execute tasks in this session using executing-plans, batch with checkpoints.

Which approach?
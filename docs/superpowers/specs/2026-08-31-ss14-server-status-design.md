# SS14 Server Status — Design

**Date:** 2026-08-31
**Status:** Approved (design conversation)
**Author:** alina

## Summary

A Noctalia plugin (`alinas/ss14-status`) that shows live status for a configurable list
of Space Station 14 servers: an SS14 logo widget in the bar with quick-info tooltip,
and a panel with detailed rows — players, map, round, preset, panic bunker / baby
jail flags — plus launch-via-Steam and copy-address actions. Optionally syncs
favorites from the SS14 launcher's SQLite database.

## Goals

- Bar widget: SS14 logo glyph, compact aggregate player count, tooltip with
  per-server quick info, click opens the panel.
- Panel: one row per server with name, players/max, map, round id, preset,
  panic-bunker and baby-jail flags, round start time; launch + copy actions.
- Configurable server list, editable inside the panel, persisted to JSON.
- Poll `/status` (HTTP) on a timer, publish via `noctalia.state` to all entries.
- Optional import of the launcher's favorite servers from
  `~/.local/share/Space Station 14/launcher/settings.db` (SQLite).

## Non-goals

- No launcher writes (we never modify the launcher DB).
- No OS-level `ss14://` URI handler registration; launch is via Steam URI.
- No per-ASCII-map or ping/anti-cheat stats beyond what `/status` exposes.

## Architecture

**Approach: service + widget + panel** (world_clock pattern).

```
[[service]] poll  ── polls each server's /status → noctalia.state.servers
      │  noctalia.state.watch
      ├── [[widget]] bar   (SS14 glyph + count + tooltip)
      └── [[panel]] list   (rows, edit, launch, copy, sync)
```

Entries are isolated VMs, so the service is the single poller; the widget and panel
only render from state. The service also fetches each server's `/info` once per
session to cache `connect_address` (launch/copy/tooltip) and engine version.

## Data model

**Stored** in `pluginDataDir()/servers.json` (ordered array):

```json
{ "servers": [ "ss14s://quantumblue.gay", "ss14://denstation.net:1212" ] }
```

URI forms (scheme → status URL), stored verbatim from user/launcher:

| URI | Status endpoint | Default port | Example |
|---|---|---|---|
| `ss14://host:port` | `http://host:port/status` | (port required) | `ss14://denstation.net:1212` |
| `ss14s://host[:port]` | `https://host[:port]/status` | 443 | `ss14s://quantumblue.gay` |

**Published state** — `ss14_status.servers`: array of row tables:

```lua
{
  uri = "ss14s://quantumblue.gay",      -- config key, verbatim
  host = "quantumblue.gay",
  online = true,
  name = "Quantum Blue",                -- nil when offline
  players = 0, soft_max_players = 60,   -- numbers
  map = "...", round_id = 307,          -- nil when absent
  preset = "Secret",
  panic_bunker = false, baby_jail = false,
  round_start_ms = 1756530934110,       -- parsed from round_start_time (UTC RFC3339), nil if absent
  tags = { ... },                       -- string array
  connect_address = "udp://quantumblue.gay:1213",  -- cached from /info, else nil
  engine_version = "270.1.0",           -- cached from /info, else nil
  error = nil,                          -- "timeout" | "http_<code>" | "parse" | "skipped"
}
```

`ss14_status.last` — epoch-ms timestamp of the last completed poll (for "stale"
indicators). State is process-lifetime; the JSON file is the durable list.

## Components

### `[[service]] poll` — `service.luau`

- Load `servers.json` (default when empty: `ss14s://quantumblue.gay`,
  `ss14://denstation.net:1212`; written back on first run only, never
  overwrites an existing non-empty list).
- `noctalia.setUpdateInterval(poll_ms)` (default `30000` from a setting).
- Per poll: for each URI, build status URL, `noctalia.http({ url = s, timeout_ms =
  5000 })`, normalize row (parse `round_start_time`), publish all rows.
- Offline rules: timeout → `error="timeout"`; non-200 → `error="http_<code>"`;
  decode failure → `error="parse"`. Row stays in list, `online=false`.
- `/info` fetched once per server (session cache keyed by host): stores
  `connect_address`, `engine_version`.
- Rate-limited (once per server per session) `notifyError` when a server flips to
  offline; notify again only after it recovers and re-fails.
- Config ops via `noctalia.state` command channel + `onIpc`:
  - `add` (uri) — validate scheme, trim, reject duplicates/empty.
  - `remove` (uri) — remove from list, save.
  - `sync` — import from launcher DB (below).
  - `poll` — force an immediate poll tick (also triggered from the panel).
- `onExit` — no special cleanup (HTTP callbacks are host-owned).

### `[[widget]] bar` — `bar.luau`

- Renders via `barWidget.render`:
  - Horizontal: `ui.row({gap, align="center"})` → SS14 glyph (tabler `plane`; a
    themed logo glyph if one resolves) + aggregate count label `3/5` (matches on a
    vertical bar → `ui.column`).
  - Count = online servers / total; `--` when none online.
- `barWidget.setTooltip(...)`: per-server two-line quick info, online last:
  ```
  Quantum Blue — 3/60
  IceBox · Round 307 · Secret · 1h 23m
  ⛨ bunker · 👶 jail
  ```
  Offline servers rendered red with their error.
- Widget-level `onClick` → `noctalia.togglePanel("alinas/ss14-status:list")`.

### `[[panel]] list` — `panel.luau`

- Width ~380, height ~440, `placement = "floating"`, `open_near_click = true`.
- Renders from `ss14_status.servers`; rows:
  - Line 1: name (or host) + `players/max`; badges `⛨` (bunker) / `👶` (jail) when
    on. Offline → `Offline` + error.
  - Line 2 (online): `map · Round #id · preset · <round time>` (`1h 23m`, from
    `round_start_ms`).
  - Row actions: **Launch** (Steam URI) + **Copy** (connection address).
- **Launch**: `noctalia.commandExists("steam")`; then
  `noctalia.runAsync("steam steam://run/<appid>//<ss14://host:port>")` (string
  form; appid from `steam_appid` setting, default `1255460`). Construct the
  `ss14://` URI from `connect_address` if present (`udp://h:p` → `ss14://h:p`),
  else from config host:port. On missing steam → notifyError + still offer copy.
- **Copy**: `noctalia.copyToClipboard(ss14_uri, "text/plain")`.
- Footer: add-server `ui.input` + Add button; **Sync** button (launcher import);
  **Refresh now** button.
- Empty list → "No servers — add one below" placeholder.

### Sync-from-launcher (`sync`)

- Source: `~/.local/share/Space Station 14/launcher/settings.db` (SQLite).
- Helper: bundled `import_favorites.sh` in the plugin dir, shells `/usr/bin/sqlite3`
  (checked via `commandExists`): `sqlite3 "<db>" "SELECT Address, Name FROM
  FavoriteServer;"` → one `Address|Name` per line. Only **reads** the DB.
- Service (or panel via IPC) runs the helper with `noctalia.runStream`/`runAsync`
  capture, parses lines, **appends** URIs not already present (keeps the launcher
  `Name` as an optional label). Never removes/overwrites.
- Errors → notifyError("Launcher DB not found / sqlite3 missing"), list unchanged.

### Manifest (`plugin.toml`)

- `id = "alinas/ss14-status"`, `name = "SS14 Status"`, `icon = "plane"`,
  `tags = ["games","ss14","server"]`, `plugin_api` per feature needs (module
  `require` needs 22 if used — keep scripts single-file where possible to stay at
  a lower level; target `plugin_api = 19` for `timeFormat` if used, else 3-9).
- Settings: `poll_seconds` (int, default 30), `show_count` (bool, default true),
  `steam_appid` (string/int, default `1255460`), `launcher_db_path` (file, default
  `~/.../launcher/settings.db`).
- Entries: `[[widget]] bar`, `[[panel]] list`, `[[service]] poll`.

## Error handling

- Request timeout (5s) → offline row, no notify spam (rate-limited per server).
- Non-200 / parse failure → offline row with reason in tooltip.
- Offline servers stay in the list, grayed, with a **Refresh now** affordance.
- Steam missing → notifyError, fall back to copy.
- `sqlite3` missing / DB absent → notifyError, import no-ops.
- Empty server list → bar hides count (`–`), panel shows placeholder.
- Widget placement on a vertical bar → column layout via `barWidget.isVertical()`.

## Round time

`round_start_time` is an ISO-8601 UTC string (`2026-08-31T02:23:11.7634341Z`). The
service converts it to epoch-ms with a Luau helper (parse components + UTC offset
via `os.time` / `os.date("*t", ...)`); `round time = nowMs() - start`, formatted
`1h 23m`. Unparseable / absent → hidden (no crash).

## Testing

- **Fixtures**: capture real `/status` + `/info` bodies for quantumblue (ss14s,
  https) and denstation (ss14, http:1212) as test data; verify parse against both,
  including `character`/`baby_jail`/`round_start_time` variants.
- **Round time**: validate the UTC→epoch helper against denstation's live value.
- **Sync**: snapshot a synthetic `FavoriteServer` table; run the helper against a
  copy of `settings.db`; assert import adds, dedups, and never removes.
- **Static**: `luau-lsp` type-check all entries against the repo's `noctalia.d.luau`
  (nonstrict).
- **Manual**: `noctalia msg` IPC (`alinas/ss14-status poll`, `add`, `remove`,
  `sync`); place the bar widget on a test bar; verify tooltip, panel open, Steam
  launch (dry-run: `commandExists("steam")` + notify), copy-to-clipboard.

## Risks / open items

- **Steam URI launch** (`steam://run/<appid>//<uri>`): the `//` argument separator
  is the documented Steam pattern, but the launcher's exact argument handling is
  unverified locally. Mitigation: setting for appid; fall back to copying the
  address; manual dry-run step in testing.
- **SQLite CLI dependency**: `sqlite3` must be on `PATH` (present by default on
  XDG desktops; checked via `commandExists`, notify otherwise). Bundled shim keeps
  it a one-command read and avoids parsing the binary format in Luau.
- **`round_start_time`** is optional on some servers → round time simply hidden.
- **Launcher DB path** is the default local path; exposed as a file setting so a
  non-default layout keeps working.
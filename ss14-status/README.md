# SS14 Status

Live status for a configurable list of [Space Station 14](https://spacestation14.io/) servers,
right in your Noctalia bar.

- **Bar widget** — an SS14 logo glyph with a compact aggregate count (`online/total`). Hover for a
  quick-info tooltip (players, map, round, preset, round time, panic bunker / baby jail flags).
  Click to open the panel.
- **Panel** — one row per server: name, players/max, map, round id, preset, round start time, and
  ⛨/👶 flags. **Launch** a server via Steam (`steam://run/<appid>//ss14://host:port`) or **copy**
  its connection address.
- **Editable list** — add/remove servers inside the panel; persisted to the plugin data dir.
- **Sync from launcher** — import your favorite servers straight from the SS14 launcher's
  `settings.db` (append-only; never touches the launcher DB).

## Install

1. Add this repository as a plugin source:
   `noctalia msg plugins source add <name> git <url>`
2. Enable `alinas/ss14-status`, then add the **bar** widget from the Add-widget picker.

## Configuration

| Setting | Default | Notes |
|---|---|---|
| `poll_seconds` | `30` | How often each server's `/status` is fetched (5–600). |
| `show_count` | `true` | Show the `online/total` count next to the logo in the bar. |
| `steam_appid` | `1255460` | Steam app id of the SS14 launcher used for Launch. |
| `launcher_db_path` | `~/.local/share/Space Station 14/launcher/settings.db` | SQLite DB the Sync button reads. |

## Server URIs

Entries use the SS14 server-browser scheme:

| URI | Status URL | Default port |
|---|---|---|
| `ss14://host:port` | `http://host:port/status` | (port required) |
| `ss14s://host[:port]` | `https://host[:port]/status` | 443 |

Defaults: `ss14s://quantumblue.gay`, `ss14://denstation.net:1212`.

## IPC

```
noctalia msg alinas/ss14-status poll         # force a poll now
noctalia msg alinas/ss14-status add ss14s://host
noctalia msg alinas/ss14-status remove ss14s://host
noctalia msg alinas/ss14-status sync         # import launcher favorites
```

## Notes

- **Launch** requires the `steam` CLI on `PATH`. If it's missing, the connection address is copied
  to the clipboard instead.
- **Sync** requires `sqlite3` on `PATH` (standard on XDG desktops). It only ever reads the launcher DB.
- Offline servers stay in the list, grayed, with the failure reason in the row/tooltip.
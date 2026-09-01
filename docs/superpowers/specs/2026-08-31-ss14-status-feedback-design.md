# SS14 Status v0.2.0 — Display Names, Pinned Favorites, Tooltip, Sync Names

**Date:** 2026-08-31
**Status:** Approved (design conversation)
**Author:** AlinaNova21

## Summary

Feedback round on the shipped SS14 Status plugin (v0.1.0): users want a custom
**display name** per server entry, **pinned favorites** that float to the top, a
**hover tooltip** that lists only favorites (using display names), and **sync to
carry over the launcher's favorite-server name** into the display name. The 5s
query-timeout request is recorded as a follow-up, out of scope this iteration.

## Goals

1. Per-entry **display name**, editable in the panel, shown as the row title when set.
2. Per-entry **pin**; pinned entries sort to the top of the panel (stable within
   groups, no manual drag order). Pins → the bar tooltip shows **only** favorited
   entries, head line using the display name when set. No pins → empty tooltip.
3. **Sync** imports the launcher favorite **Name** as the entry's display name,
   overwriting (your pick c), guarded so an *empty* launcher name never blanks an
   existing name.
4. Lossless **migration** of the persisted server list from the v0.1.0
   string-array format to the new entry-object format, transparently, for users
   upgrading from the old version.
5. *(Deferred)* 5s per-query HTTP timeout via a fast service tick during
   in-flight polls.

## Non-Goals

- Manual drag reordering  (pins get an order, not arbitrary position).
- The 5s timeout this iteration — see Outstanding.
- Config-driven display name (there is no `setConfig` in the plugin API).
- Any change to launch/copy, offline rows, or the /status normalization.

## Data Model

### Entry

```luau
-- entry = {
--   uri = "ss14s://host",        -- canonical id (unchanged)
--   display_name = "My rig"?    -- when set, shown as the row title
--   pinned = true?              -- when true, sorts to the top
-- }
```

`servers.json` (in the plugin data dir) becomes an **array of entry objects**:

```json
{ "servers": [ { "uri": "ss14s://a", "display_name": "A", "pinned": true } ] }
```

The URI remains the identity key everywhere (remove/add/sync dedupe, `pendingDelete`, IPC ops).

### Migration (lossless)

On load, the service normalizes whatever it finds:

- Plain strings (v0.1.0 format) → `{ uri = s }` (validated with `uri.parseUri`).
- Tables → sanitized: `uri` must parse; `display_name` kept only when a
  non-empty string (whitespace-trimmed); `pinned` kept only when exactly `true`.
- Junk/hostile shapes are dropped.

The migrated list is saved back immediately, so users on old versions move to the
new format on their first launch — nothing is lost, because the old strings
round-trip into new entries.

### Sort

Pinned first, then unpinned; **stable** within each group (insertion/config order
preserved — no manual drag order). Sorting lives **in the service at publish
time**, so panel, tooltip, and bar all consume the same ordered rows (no
per-consumer re-sorting).

## Architecture / Components

### `entries.luau` (new, pure)

Tiny dependency-free module (mirrors `uri.luau` / `timeutil.luau` style):

- `normalize(rawList) -> { entries }` — the migration above; drop-in for the
  old string-only load path.
- `sanitizeDisplayName(s) -> string?` — trims; empty/whitespace → nil.
- `sortPinnedFirst(entries) -> entries` — stable sort; pinned group first.
- `displayName(entry, row)` — returns the entry `display_name` when set, else
  the server's live `row.name`/`row.host`. Single source of "what is the title".

### `service.luau` (entry format drives everything)

- `loadServers()` → `entries.normalize` over the saved array; save the
  normalized form.
- `servers` becomes an array of **entries**; `indexOf`/remove/poll loops keep
  working off `entry.uri`.
- `sortByConfigOrder` → `entries.sortPinnedFirst` after the config-order sort
  (pins win, otherwise config order).
- `doSync` — currently discards the launcher `Name`; now writes it to the
  entry's `display_name`. **Overwrite** (pick c) when the launcher name is a
  non-empty string; an empty launcher name leaves the existing display name
  untouched (can't meaningfully "overwrite with nothing").
- Rows published to `ss14_status.servers` gain the entry fields so consumers
  need no re-merge: each row = status data + `display_name`, `pinned`
  (from its entry).

### `panel.luau`

Row title logic: bold title = `entries.displayName(entry, row)`; when a display
name is set, **line 2** (small, `on_surface_variant`) shows the actual server
name — skipped when it equals the title, so no duplicated line; existing details
line (`map · round · preset · time` / offline error) follows. No display name →
today's layout exactly.

Rename — a per-row **pencil button** plus a **`⋮` more menu** (pick c), both to
an inline input:

- Pencil / menu "Rename" swaps the title row into an inline
  `ui.input({ value = currentTitle, placeholder = <server name> })`; Enter/✓
  commits, Esc/✗ cancels. Empty input clears the display name.
- Row actions become: **launch · pin · rename · trash · ⋮**; **Copy** moves into
  the menu (fed by the same `panel.openContextMenu` — plugin_api 28 already
  declared). Pin button toggles `pinned` (ghost ↔ primary variant).
- Menu (per-row `⋮`): Launch · Pin/Unpin · Rename · Copy · Remove (two-step
  confirm as today).

### `bar.luau` (tooltip)

`tooltipRows()` shows **only pinned entries**, in panel order (pins first);
head line = `entries.displayName` when set, else live name. Offline pins stay
listed with the offline annotation. **No pins → empty tooltip set.**
Detail lines (`map · round · preset · time`, ⛨/👶 flags) unchanged.

### `plugin.toml`

- `version = "0.2.0"`
- `plugin_api` stays `28` (context menu already reserved/declared there).

## Translations

New keys added to all four locales (`translations/en.json`, `de.json`,
`pt-BR.json`, `zh-Hans.json`):

- `ui.rename`, `ui.pin`, `ui.unpin`, `ui.rename_placeholder`, `ui.more_tooltip`
- `ui.menu.launch`, `ui.menu.pin`, `ui.menu.unpin`, `ui.menu.rename`,
  `ui.menu.copy`, `ui.menu.remove`

Existing keys (`ui.launch_tooltip` etc.) unchanged; **Copy** keeps its
`ui.copy_tooltip` text in the menu. Priority: `en.json` authoritative, other
locales best-effort (match the existing translation style).

## Testing

- New **`tests/entries_spec.luau`** (CLI-runnable via the repo's `luau` tooling):
  - Migration: old string array → entries; mixed array; junk entries dropped;
    display-name/pinned field sanitization.
  - `sortPinnedFirst`: pins first, stable within groups, tail order preserved.
  - `sanitizeDisplayName`: trims, blanks → nil.
- Existing specs (`uri_spec.luau`, `timeutil_spec.luau`, `normalize_spec.luau`)
  keep passing.
- Manual shell pass: upgrade an old-format `servers.json`, pin/rename each row,
  open the bar tooltip (pinned-only, display names), sync to confirm launcher
  names land as display names without blanking existing ones.

## Documentation

- `README.md`: rename/pin/more-menu behavior, tooltip = favorites-only,
  sync-imports-names (overwrite) semantics, entry-object storage note.

## Outstanding

- **5s query timeout** — skipped at user request. Follow-up: fast (1s) service
  tick while a poll is in flight, per-URI deadline slots filled once (late HTTP
  responses can't overwrite a timeout row), restore the slow `poll_seconds`
  interval when the poll settles.
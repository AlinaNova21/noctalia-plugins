# xDrip Glucose

A Noctalia plugin that shows your current glucose reading, trend, and history
chart from a self-hosted [xdrip-sync](https://xdrip-sync) server.

- **Bar widget** — current reading (color-coded by zone), trend arrow + delta,
  and a mini sparkline. Hover shows a tooltip; click opens the panel.
- **Panel** — current reading card, 24h MIN / MAX / AVG / point-count stats,
  high/low threshold chips, and a large history graph.
- **Threshold notifications (optional)** — fires a one-shot notification when a
  reading crosses the high or low threshold.

## Requirements

- A running xdrip-sync server (see the xdrip-sync repo) reachable over HTTP.
- Read access: either `XD_OPEN_READS=true` on the server (anonymous reads), or a
  long-lived bearer token created with `xdrip-sync token create` and pasted into
  the plugin's **Read token** setting.

## Setup

1. Enable the plugin and set **xDrip sync URL** to your server's base URL
   (e.g. `http://host:8080`).
2. If reads require auth, create a token:

   ```console
   $ xdrip-sync token create
   ```

   and paste it into **Read token**.

3. Adjust **History window (hours)**, **Low/High threshold (mg/dL)**, **Poll
   interval (seconds)**, and **Notify when a reading crosses a threshold** to
   taste.

## Notes

- Query endpoints are read-only; the plugin never writes to xdrip-sync.
- Thresholds and notifications are configured in **plugin settings** (there is
  no `setConfig` in the plugin API, so the panel shows them read-only).
- The state key is `xdrip_status.status`; the panel triggers a manual refresh
  via `xdrip_status.cmd` (`{ op = "poll" }`).

## Layout

- `service.luau` — poll + normalize + publish + threshold notification
- `bar.luau` — bar widget
- `panel.luau` — panel
- `series.luau` — pure helpers (normalize, stats, graph mapping, crossing)
- `tests/series_spec.luau` — CLI-runnable spec for `series.luau`
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
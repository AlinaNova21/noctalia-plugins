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
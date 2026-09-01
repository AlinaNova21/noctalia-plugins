--!nonstrict
-- entries.luau spec: entry-object normalization/migration, display name
-- sanitization, stable pinned-first sort, title resolution (display_name –
-- live name – host fallback). CLI-runnable with the repo's luau tooling.

local entries = require("../entries")

local function expect(label, got, want)
  if got ~= want then
    error(string.format("%s: got %q want %q", label, tostring(got), tostring(want)), 0)
  end
end

local function expectNil(label, got)
  if got ~= nil then
    error(string.format("%s: got %q want nil", label, tostring(got)), 0)
  end
end

-- ── normalize: legacy string-array migration ────────────────────────────────

local plain = entries.normalize({ "ss14s://a", "ss14://b:1212" })
expect("n1.size", #plain, 2)
expect("n1.uri", plain[1].uri, "ss14s://a")
expect("n1.noName", plain[1].display_name, nil)
expect("n1.noPin", plain[1].pinned, nil)
expect("n2.uri", plain[2].uri, "ss14://b:1212")

-- Mixed array: strings and entry tables both survive; entry metadata kept.
local mixed = entries.normalize({
  "ss14s://a",
  { uri = "ss14s://b", display_name = "B", pinned = true },
})
expect("mx.size", #mixed, 2)
expect("mx.a.uri", mixed[1].uri, "ss14s://a")
expect("mx.b.uri", mixed[2].uri, "ss14s://b")
expect("mx.b.name", mixed[2].display_name, "B")
expect("mx.b.pinned", mixed[2].pinned, true)

-- Junk / hostile shapes are dropped, not fatal.
local junk = entries.normalize({
  42,
  "not-a-uri",
  { uri = "ss14s://ok", garbage = "x" },
  "ss14s://good",
  nil,
})
expect("jk.size", #junk, 2)
expect("jk.ok.uri", junk[1].uri, "ss14s://ok")
expect("jk.good.uri", junk[2].uri, "ss14s://good")

-- display_name sanitized: whitespace-trimmed; blank -> nil.
local blankName = entries.normalize({ { uri = "ss14s://a", display_name = "   " } })
expectNil("bn.name", blankName[1].display_name)
local trimName = entries.normalize({ { uri = "ss14s://a", display_name = "  My Rig  " } })
expect("tn.name", trimName[1].display_name, "My Rig")
local nonStringName = entries.normalize({ { uri = "ss14s://a", display_name = 7 } })
expectNil("ns.name", nonStringName[1].display_name)

-- pinned only when exactly true.
local pinTruthy = entries.normalize({ { uri = "ss14s://a", pinned = 1 } })
expectNil("pt.pinned", pinTruthy[1].pinned)
local pinFalse = entries.normalize({ { uri = "ss14s://a", pinned = false } })
expectNil("pf.pinned", pinFalse[1].pinned)
local pinTrue = entries.normalize({ { uri = "ss14s://a", pinned = true } })
expect("pn.pinned", pinTrue[1].pinned, true)

-- Non-list input -> empty list, no crash.
expect("nl.size", #entries.normalize(nil), 0)
expect("nl2.size", #entries.normalize("x"), 0)
expect("nl3.size", #entries.normalize({ servers = { "ss14s://a" } }), 0) -- envelope not a bare list

-- Input is not mutated.
local raw = { "ss14s://a" }
entries.normalize(raw)
expect("noMutate", raw[1], "ss14s://a")

-- ── sortPinnedFirst: pinned group first, stable within groups ───────────────

local s = entries.sortPinnedFirst({
  { uri = "d", pinned = false },
  { uri = "a", pinned = true },
  { uri = "b" },
  { uri = "c", pinned = true },
})
expect("s.size", #s, 4)
expect("s.1", s[1].uri, "a")
expect("s.2", s[2].uri, "c")
expect("s.3", s[3].uri, "d")
expect("s.4", s[4].uri, "b")

-- No pins -> original order untouched (stability).
local noPins = entries.sortPinnedFirst({ { uri = "x" }, { uri = "y" }, { uri = "z" } })
expect("np.1", noPins[1].uri, "x")
expect("np.2", noPins[2].uri, "y")
expect("np.3", noPins[3].uri, "z")

-- ── sanitizeDisplayName ─────────────────────────────────────────────────────

expect("sd.trim", entries.sanitizeDisplayName("  Rig  "), "Rig")
expect("sd.inner", entries.sanitizeDisplayName(" My Rig "), "My Rig")
expectNil("sd.blank", entries.sanitizeDisplayName(""))
expectNil("sd.ws", entries.sanitizeDisplayName("   "))
expectNil("sd.nil", entries.sanitizeDisplayName(nil))
expectNil("sd.num", entries.sanitizeDisplayName(42))

-- ── displayTitle: display_name -> live name -> host fallback ──────────────

-- The row's title: its display name when set, else the live server name, else
-- the host. Rows published by the service already carry display_name/pinned
-- flattened from their entry, so a single-arg helper is all consumers need.
expect("dt.override", entries.displayTitle({ display_name = "Rig", name = "Actual", host = "h" }), "Rig")
expect("dt.liveName", entries.displayTitle({ name = "Actual", host = "h" }), "Actual")
expect("dt.host", entries.displayTitle({ host = "h" }), "h")
expectNil("dt.none", entries.displayTitle({}))

print("entries_spec: passed")
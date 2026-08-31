--!nonstrict
-- Normalization test: parses real SS14 /status bodies (captured live) using the
-- same row-building logic as the service (uri + timeutil modules). Guards against
-- field-shape drift in the two endpoint variants we support (https/ss14s and
-- http/ss14://host:port).

local uri = require("../uri")
local timeutil = require("../timeutil")

local function expect(label, got, want)
  if got ~= want then
    error(string.format("%s: got %q want %q", label, tostring(got), tostring(want)), 0)
  end
end

-- Live captures:
--   quantumblue (ss14s/https): players 0, soft_max 60, map null, round 307, panic_bunker false
--   denstation (ss14/http:1212): players >=0, soft_max 100, map Glacier, round 5665,
--     preset "Even More Antags", panic_bunker false, baby_jail false, round_start_time set
local QB_BODY = '{"name":"Quantum Blue","players":0,"tags":[],"map":null,"round_id":307,"soft_max_players":60,"panic_bunker":false,"run_level":0,"preset":"Secret"}'
local DEN_BODY = '{"name":"[18+][EN][MRP] The Den: Salvation | Roleplay Focus","players":46,"tags":["18+","rp:med"],"map":"Glacier","round_id":5665,"soft_max_players":100,"panic_bunker":false,"baby_jail":false,"run_level":1,"preset":"Even More Antags","round_start_time":"2026-08-31T02:23:11.7634341Z"}'

-- Minimal field extractors for the flat /status shape (the luau CLI has no
-- code-eval/io, so we pattern-match the specific keys instead of full JSON).
local function field(body, key)
  return body:match('"' .. key .. '"%s*:%s*([^,}]+)')
end

local function strField(body, key)
  local v = field(body, key)
  if v == nil or v == "null" then
    return nil
  end
  return (v:gsub('^"(.*)"$', "%1"))
end

local function numField(body, key)
  local v = field(body, key)
  if v == nil or v == "null" then
    return nil
  end
  return tonumber(v)
end

local function boolField(body, key)
  return field(body, key) == "true"
end

-- Mirror of service buildRow's online path (flat-field JSON only).
local function buildRow(serverUri, body)
  local p = uri.parseUri(serverUri)
  local row = { uri = serverUri, host = p.host, online = true }
  row.name = strField(body, "name")
  row.players = numField(body, "players")
  row.soft_max_players = numField(body, "soft_max_players")
  row.map = strField(body, "map")
  row.round_id = numField(body, "round_id")
  row.preset = strField(body, "preset")
  row.panic_bunker = boolField(body, "panic_bunker")
  row.baby_jail = boolField(body, "baby_jail")
  row.round_start_raw = strField(body, "round_start_time")
  -- round_start_ms is filled by the service via timestamp_ms.sh (not here); the
  -- raw string is asserted below instead.
  return row
end

-- Quantum Blue (ss14s/https)
local qb = buildRow("ss14s://quantumblue.gay", QB_BODY)
expect("qb.name", qb.name, "Quantum Blue")
expect("qb.players", qb.players, 0)
expect("qb.soft_max", qb.soft_max_players, 60)
expect("qb.map", qb.map, nil) -- null map stays nil
expect("qb.round", qb.round_id, 307)
expect("qb.preset", qb.preset, "Secret")
expect("qb.bunker", qb.panic_bunker, false)
expect("qb.jail", qb.baby_jail, false)

-- The Den (ss14/http:1212)
local dn = buildRow("ss14://denstation.net:1212", DEN_BODY)
expect("dn.name", dn.name, "[18+][EN][MRP] The Den: Salvation | Roleplay Focus")
expect("dn.players>=0", dn.players >= 0, true)
expect("dn.soft_max", dn.soft_max_players, 100)
expect("dn.map", dn.map, "Glacier")
expect("dn.round", dn.round_id, 5665)
expect("dn.preset", dn.preset, "Even More Antags")
expect("dn.bunker", dn.panic_bunker, false)
expect("dn.jail", dn.baby_jail, false)
expect("dn.round_start_raw", dn.round_start_raw, "2026-08-31T02:23:11.7634341Z")

-- round start -> elapsed via timeutil (1h later)
expect("elapsed 1h", timeutil.formatElapsed(3600000, 0), "1h 0m")
expect("elapsed 83m", timeutil.formatElapsed(83 * 60 * 1000, 0), "1h 23m")

print("normalize_spec: passed")
--!nonstrict
-- Pure entry-model helpers for SS14 Status: normalizes the persisted server
-- list (legacy string-array -> entry objects), handles display names and
-- pinned markers, stable pinned-first sorting, and title resolution.
-- No noctalia.* deps (mirrors uri.luau / timeutil.luau).

-- Resolve uri under both environments: the CLI luau require is extensionless,
-- while the Noctalia runtime requires the .luau suffix.
local uriOk, uri = pcall(require, "./uri")
if not uriOk then
  uri = require("./uri.luau")
end

local M = {}

-- Trims whitespace; returns nil for empty/whitespace-only or non-strings.
function M.sanitizeDisplayName(s)
  if type(s) ~= "string" then
    return nil
  end
  local t = s:gsub("^%s+", ""):gsub("%s+$", "")
  if t == "" then
    return nil
  end
  return t
end

-- Returns a sanitized entry table for a raw item, or nil when the item is
-- unusable (unparseable uri, wrong type, ...).
local function sanitizeEntry(raw)
  if type(raw) == "string" then
    if uri.parseUri(raw) == nil then
      return nil
    end
    return { uri = raw }
  end
  if type(raw) ~= "table" then
    return nil
  end
  local entryUri = raw.uri
  if type(entryUri) ~= "string" or uri.parseUri(entryUri) == nil then
    return nil
  end
  local out = { uri = entryUri }
  local dn = M.sanitizeDisplayName(raw.display_name)
  if dn ~= nil then
    out.display_name = dn
  end
  if raw.pinned == true then
    out.pinned = true
  end
  return out
end

-- Normalizes a persisted server list into entry objects. Accepts the legacy
-- v0.1.0 string-array format and the new entry-object format (mixed is fine);
-- drops unusable items. Returns a fresh list; does not mutate the input.
function M.normalize(rawList)
  local out = {}
  if type(rawList) ~= "table" then
    return out
  end
  -- Bare array of entries/strings; an { servers = [...] } envelope is not a
  -- list and is ignored (callers decode the envelope themselves).
  for i = 1, #rawList do
    local e = sanitizeEntry(rawList[i])
    if e ~= nil then
      out[#out + 1] = e
    end
  end
  return out
end

-- Stable sort: pinned entries first, original order preserved within each
-- group (config/insertion order; no manual drag ordering).
function M.sortPinnedFirst(rawEntries)
  local decorated = {}
  for i, e in ipairs(rawEntries) do
    decorated[#decorated + 1] = { e = e, i = i, pinned = (e.pinned == true) }
  end
  table.sort(decorated, function(a, b)
    if a.pinned ~= b.pinned then
      return a.pinned
    end
    return a.i < b.i
  end)
  local out = {}
  for _, d in ipairs(decorated) do
    out[#out + 1] = d.e
  end
  return out
end

-- Title resolution: the row's display name when set, else the live server
-- name, else the host. Rows published by the service already carry
-- display_name/pinned flattened from their entry, so a single-arg helper is
-- all consumers need.
function M.displayTitle(row)
  if row and type(row.display_name) == "string" and row.display_name ~= "" then
    return row.display_name
  end
  if row and type(row.name) == "string" then
    return row.name
  end
  if row and type(row.host) == "string" then
    return row.host
  end
  return nil
end

return M
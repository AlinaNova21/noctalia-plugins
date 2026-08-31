--!nonstrict
-- Pure URI helpers for SS14 server addresses, no noctalia.* deps.

local M = {}

-- Parses "ss14://host:port" or "ss14s://host[:port]" into
-- { scheme, host, port? }. Returns nil for any other scheme or a malformed
-- address. port is a string (as given) or nil for the default.
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
  -- host may be bare or have a :port suffix (port optional -> nil when absent).
  local host, port = rest:match("^([^:/]+):?(%d*)$")
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
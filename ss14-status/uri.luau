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
-- ss14  -> http://host:port/status   (default port 1212, SS14 standard)
-- ss14s -> https://host[:port]/status (default port 443)
function M.statusBaseUrl(raw)
  local p = M.parseUri(raw)
  if p == nil then
    return nil
  end
  local scheme = p.scheme == "ss14s" and "https" or "http"
  local defaultPort = p.scheme == "ss14s" and "443" or "1212"
  local auth = p.host
  if p.port ~= nil and p.port ~= "" then
    auth = auth .. ":" .. p.port
  elseif scheme == "http" then
    -- ss14:// without an explicit port means the standard status port 1212.
    auth = auth .. ":" .. defaultPort
  end
  return scheme .. "://" .. auth .. "/status"
end

-- Full connection URI for launching/copying: ss14://host[:port]. Applies the
-- SS14 default port (ss14: 1212, ss14s: 443) when the config entry omits one,
-- so the launcher always gets an unambiguous address.
function M.connectUri(raw)
  local p = M.parseUri(raw)
  if p == nil then
    return nil
  end
  local port = p.port
  if port == nil or port == "" then
    port = p.scheme == "ss14s" and "443" or "1212"
  end
  return p.scheme .. "://" .. p.host .. ":" .. port
end

return M
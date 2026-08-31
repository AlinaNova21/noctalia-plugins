--!nonstrict
local uri = require("../uri")

local function expect(label, got, want)
  if got ~= want then
    error(string.format("%s: got %q want %q", label, tostring(got), tostring(want)), 0)
  end
end

local cases = {
  { input = "ss14s://quantumblue.gay", scheme = "ss14s", host = "quantumblue.gay", port = nil,
    base = "https://quantumblue.gay/status" },
  { input = "ss14://denstation.net:1212", scheme = "ss14", host = "denstation.net", port = "1212",
    base = "http://denstation.net:1212/status" },
  { input = "ss14s://dev.quantumblue.gay", scheme = "ss14s", host = "dev.quantumblue.gay", port = nil,
    base = "https://dev.quantumblue.gay/status" },
  { input = " https://foo ", scheme = nil, host = nil, port = nil, base = nil }, -- invalid scheme rejected
  { input = "ss14://", scheme = nil, host = nil, port = nil, base = nil }, -- no host
  { input = "ss14://host", scheme = "ss14", host = "host", port = nil,
    base = "http://host:1212/status", connect = "ss14://host:1212" }, -- ss14 defaults to 1212
  { input = "ss14://euphoria.game-server.cc", scheme = "ss14", host = "euphoria.game-server.cc", port = nil,
    base = "http://euphoria.game-server.cc:1212/status", connect = "ss14://euphoria.game-server.cc:1212" },
  { input = "ss14s://quantumblue.gay", scheme = "ss14s", host = "quantumblue.gay", port = nil,
    base = "https://quantumblue.gay/status", connect = "ss14s://quantumblue.gay:443" },
}

for _, c in ipairs(cases) do
  local p = uri.parseUri(c.input)
  expect(c.input .. " scheme", p and p.scheme or nil, c.scheme)
  expect(c.input .. " host", p and p.host or nil, c.host)
  expect(c.input .. " port", p and p.port or nil, c.port)
  local base = uri.statusBaseUrl(c.input)
  expect(c.input .. " base", base, c.base)
  if c.connect ~= nil then
    local conn = uri.connectUri(c.input)
    expect(c.input .. " connect", conn, c.connect)
  end
end
print("uri_spec: " .. #cases .. " cases passed")
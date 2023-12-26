local function replaceNamePattern(url)
  local replacedUrl = url:gsub("{(.-)}", "(?<%1>[^/]+)")
  return replacedUrl
end

local function convert_githubapi()
  local file = io.open("github-api.txt", "rb")
  if not file then return nil end

  local lines = {}
  for line in io.lines("github-api.txt") do
    local i = string.find(line, "{", nil, true)
    if i then
      line = "~" .. replaceNamePattern(line)
    end
    table.insert(lines, line)
  end
  file:close()

  local file2 = io.open("github-api-regex.txt", "w")
  file2:write(table.concat(lines, "\n"))
  file2:close()
end



local service1 = {
  name = "example-service",
  host = "mockbin.org",
  port = 80,
  protocol = "http",
  routes = {},
  plugins = {
    {
      name = "pre-function",
      config = {
        access = {
          "kong.response.exit(200, { params = kong.request.get_uri_captures()})"
        }
      }
    }
  }
}
local config = {
  _format_version = "3.0",
  services = { service1 }
}

local function gen_simple_variable(n)
  local lyaml = require "lyaml"

  -- default
  service1.routes = {}
  for i = 1, n do
    local route = {
      name = "route" .. i,
      paths = { string.format("~/user%d/(?<name>[^/]+)$", i) }
    }
    service1.routes[i] = route
  end
  local content = lyaml.dump({ config })
  local file = io.open("kong-default-variable-" .. n  .. ".yaml", "w")
  file:write(content)
  file:close()

  -- radix
  service1.routes = {}
  for i = 1, n do
    local route = {
      name = "route" .. i,
      paths = { string.format("/user%d/{name}", i) }
    }
    service1.routes[i] = route
  end
  local content = lyaml.dump({ config })
  local file = io.open("kong-radix-variable-" .. n .. ".yaml", "w")
  file:write(content)
  file:close()
end

convert_githubapi()
--gen_simple_variable(1000)
--gen_simple_variable(10000)
--gen_simple_variable(20000)
--gen_simple_variable(30000)
--gen_simple_variable(100000)

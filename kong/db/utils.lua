local insert = table.insert
local clustering_tls = require("kong.clustering.tls")
local utils = require "kong.admin_gui.utils"
local get_cluster_cert = clustering_tls.get_cluster_cert
local get_cluster_cert_key = clustering_tls.get_cluster_cert_key
local select_listener = utils.select_listener
local fmt       = string.format
local cjson    = require "cjson.safe"
local http      = require "resty.http"

local _M = {}

function _M.fetch_from_cp(resource)
  local kong_conf = kong.configuration
  local c = http.new()

  local api_ssl_listen = select_listener(kong_conf.admin_listeners, {ssl = true})
  local cert = assert(get_cluster_cert(kong_conf))
  local cert_key = assert(get_cluster_cert_key(kong_conf))

  -- Enable mutual TLS
  c:set_timeout(5000) -- 2 sec
  local ok, err = c:connect({
    scheme = "https",
    host = api_ssl_listen.ip,
    port = api_ssl_listen.port,
    -- FIXME: verify cert when shipping
    ssl_verify = false,
    ssl_client_cert = cert.cdata,
    ssl_client_priv_key = cert_key,
  })

  if not ok then
    return nil, "ssl handshake failed: " .. err
  end

  print(fmt("XXX: FETCHING %s FROM CP", resource))
  local response, err = c:request({
    path = resource,
    method = "GET",
    headers = {
      ["Content-Type"] = "application/json",
    },
  })
  if err then
    return nil, err
  end


  local res, err = response:read_body()
  local cred = cjson.decode(res)

  if cred.message == "Not found" then
    return nil, nil -- -1
  end

  return cred, nil
end

local function visit(current, neighbors_map, visited, marked, sorted)
  if visited[current] then
    return true
  end

  if marked[current] then
    return nil, "Cycle detected, cannot sort topologically"
  end

  marked[current] = true

  local schemas_pointing_to_current = neighbors_map[current]
  if schemas_pointing_to_current then
    local neighbor, ok, err
    for i = 1, #schemas_pointing_to_current do
      neighbor = schemas_pointing_to_current[i]
      ok, err = visit(neighbor, neighbors_map, visited, marked, sorted)
      if not ok then
        return nil, err
      end
    end
  end

  marked[current] = false

  visited[current] = true

  insert(sorted, 1, current)

  return true
end




function _M.topological_sort(items, get_neighbors)
  local neighbors_map = {}
  local source, destination
  local neighbors
  for i = 1, #items do
    source = items[i] -- services
    neighbors = get_neighbors(source)
    for j = 1, #neighbors do
      destination = neighbors[j] --routes
      neighbors_map[destination] = neighbors_map[destination] or {}
      insert(neighbors_map[destination], source)
    end
  end

  local sorted = {}
  local visited = {}
  local marked = {}

  local current, ok, err
  for i = 1, #items do
    current = items[i]
    if not visited[current] and not marked[current] then
      ok, err = visit(current, neighbors_map, visited, marked, sorted)
      if not ok then
        return nil, err
      end
    end
  end

  return sorted
end


return _M

local insert = table.insert
local clustering_tls = require("kong.clustering.tls")
local utils = require "kong.admin_gui.utils"
local get_cluster_cert = clustering_tls.get_cluster_cert
local get_cluster_cert_key = clustering_tls.get_cluster_cert_key
local fmt       = string.format
local cjson    = require "cjson.safe"
local http      = require "resty.http"

local _M = {}

function _M.fetch_from_cp(resource)
  local kong_conf = kong.configuration
  if not kong_conf then
    return nil, "could not load kong configuration"
  end
  local c = http.new()

  local control_plane_adr = kong_conf.cluster_control_plane
  print("control_plane_adr = " .. require("inspect")(control_plane_adr))
  local host, port = control_plane_adr:match("([^:]+):([^:]+)")
  local cert = assert(get_cluster_cert(kong_conf))
  if not cert then
    return nil, "could not load cluster cert"
  end
  print("cert = " .. require("inspect")(cert))
  local cert_key = assert(get_cluster_cert_key(kong_conf))
  if not cert_key then
    return nil, "could not load cluster cert key"
  end
  print("cert_key = " .. require("inspect")(cert_key))

  -- Enable TLS
  c:set_timeout(5000) -- 2 sec
  local ok, err = c:connect({
    scheme = "https",
    host = host,
    port = port,
    -- FIXME: verify cert when shipping, we use self-signed certs for anyway
    -- should this be configurable?
    ssl_verify = false,
    ssl_client_cert = cert.cdata,
    ssl_client_priv_key = cert_key,
  })

  if not ok then
    return nil, "ssl handshake failed: " .. err, -1
  end

  print(fmt("XXX: FETCHING %s FROM CP", resource))
  local response, err = c:request({
    path = "/v1/api" .. resource,
    method = "GET",
    headers = {
      ["Content-Type"] = "application/json",
    },
  })
  print("err = " .. require("inspect")(err))
  if err then
    -- FIXME: return a proper TTL after development is done
    return nil, err, -1
  end
  print("response = " .. require("inspect")(response))

  local res, err = response:read_body()
  if not res then
    -- FIXME: return a proper TTL after development is done
    return nil, err, -1
  end
  print("res = " .. require("inspect")(res))

  local cred = cjson.decode(res)

  if not cred then
    return nil, "could not decode", -1
  end

  if cred.message == "Not found" then
    -- FIXME: return a proper TTL after development is done
    return nil, nil, -1
  end

  -- FIXME: return a proper TTL after development is done
  return cred, nil, -1
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

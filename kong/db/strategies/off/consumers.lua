local kong      = kong
local fmt       = string.format
local http      = require "resty.http"
local cjson    = require "cjson.safe"

local dp = require("kong.clustering.data_plane")

local Consumers = {}


function Consumers:select(id)
  -- Retrieve a consumer by id from the admin api :8001/consumers/:id

  local correlation_id, err = dp.get_consumer({id = id})
  if err then
    return nil, err
  end

  -- ensure that this isn't blocking
  local results = dp.wait_for_results(correlation_id)
  print("results = " .. require("inspect")(results))

  return results

end

-- function Consumers:select(id)
--   -- Retrieve a consumer by id from the admin api :8001/consumers/:id
--   local c = http.new()

--   id = id.id or id
--   if not id then
--     return nil, "id is required"
--   end

--   local url = "http://localhost:8001/consumers/" .. id

--   local response, err = c:request_uri(url, {
--     method = "GET",
--     headers = {
--       ["Content-Type"] = "application/json",
--     },
--   })
--   if err then
--     return nil, err
--   end

--   local res = cjson.decode(response.body)
--   print("XXX: FETCHING CONSUMER FROM CP")
--   print("res = " .. require("inspect")(res))

--   return res
-- end

return Consumers

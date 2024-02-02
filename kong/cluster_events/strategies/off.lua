local http      = require "resty.http"
local cjson = require("cjson.safe")
local yield = require("kong.tools.yield").yield

local off = {}


local OffStrategy = {}
OffStrategy.__index = OffStrategy


function OffStrategy.should_use_polling()
  -- TODO: this polls now.
  return true
end


function OffStrategy:insert(node_id, channel, at, data, delay)
  -- We don't insert on the DP
  return true
end


function OffStrategy:select_interval(channels, min_at, max_at)
  -- FIXME: have this support min_at and max_at and specific channel query.
  -- For now, just return all events and filter them here. It's inefficient but okay with the POC
  -- If we support `indexing|filtering` in the future, we can use that to filter the events.
  local c = http.new()

  -- TODO: properly implement pageing
  local url = "http://localhost:8001/clustering/events"

  print("pinging events endpoint")
  local response, err = c:request_uri(url, {
    method = "GET",
    headers = {
      ["Content-Type"] = "application/json",
    },
  })
  if err then
    return nil, err
  end
  local res = cjson.decode(response.body)

  yield(true)

  for i, event in ipairs(res.data) do
    event.now = self:server_time()
    event.data = cjson.decode(event.data)
  end
  -- print("res = " .. require("inspect")(res))
  return function()
    return res.data, nil, nil
  end
end


function OffStrategy:truncate_events()
  return true
end


function OffStrategy:server_time()
  return ngx.now()
end


function off.new(db, page_size, event_ttl)
  print("XXX: creating a new OFF strategy")
  return setmetatable({}, OffStrategy)
end


return off

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

  local page = 0
  local last_page
  return function()

    if last_page then
      return nil
    end

    local response, err = c:request_uri(url, {
      method = "GET",
      headers = {
        ["Content-Type"] = "application/json",
      },
      keepalive = true,
      keepalive_timeout = 10,
      keepalive_pool = 10
    })
    if err then
      return nil, err
    end
    local res = cjson.decode(response.body)
    for i, event in ipairs(res.data) do
      -- print("fetching server_time")
      event.now = self:server_time()
      -- print("decoding")
      event.data = cjson.decode(event.data)
      -- print("decoding done")
    end

    local len = #res.data
    print("XXX: len = " .. require("inspect")(len))
    if len == 0 then
      return nil
    end

    page = page + 1

    -- FIXME: trick the iterator function to think that
    -- this is the only and last page
    last_page = true

    return res.data, nil, page
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
  return setmetatable({
    db = db,
    page_size = page_size,
    event_ttl = event_ttl,
  }, OffStrategy)
end


return off

local fetch_from_cp = require "kong.db.utils".fetch_from_cp
local fmt = string.format

local lazy_loader = {}


local LazyLoader = {}
LazyLoader.__index = LazyLoader


function LazyLoader.should_use_polling()
  -- TODO: this polls now.
  return true
end


function LazyLoader:insert(node_id, channel, at, data, delay)
  -- We don't insert on the DP
  return true
end


function LazyLoader:select_interval(channels, min_at, max_at)
  -- FIXME: have this support min_at and max_at and specific channel query.
  -- For now, just return all events and filter them here. It's inefficient but okay with the POC
  -- If we support `indexing|filtering` in the future, we can use that to filter the events.

  local page = 0
  local last_page

  return function()

    if last_page then
      return nil
    end


    local response, err, _ = fetch_from_cp(fmt("/events?min_at=%s&max_at=", min_at, max_at))
    if err then
      return nil, err
    end

    local len = #response.data
    if len == 0 then
      return nil
    end

    page = page + 1

    -- FIXME: trick the iterator function to think that
    -- this is the only and last page
    last_page = true

    return response.data, nil, page
  end
end


function LazyLoader:truncate_events()
  return true
end


function LazyLoader:server_time()
  return ngx.now()
end


function lazy_loader.new(db, page_size, event_ttl)
  print("XXX: creating a new OFF strategy")
  return setmetatable({
    db = db,
    connector = db.connector,
    page_size = page_size,
    event_ttl = event_ttl,
  }, LazyLoader)
end


return lazy_loader

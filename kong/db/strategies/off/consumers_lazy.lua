local kong      = kong
local fetch_from_cp = require "kong.db.utils".fetch_from_cp


local Consumers = {}

function Consumers:select(id)
  -- Retrieve a consumer by id from the admin api :8001/consumers/:id
  id = id.id or id
  if not id then
    return nil, "id is required"
  end
  return fetch_from_cp("/consumers/" .. id)
end

function Consumers:select_by_username(username)
  -- Retrieve a consumer by username from the admin api :8001/consumers/:username
  return fetch_from_cp("/consumers/" .. username)
end

return Consumers

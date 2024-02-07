local kong      = kong
local fetch_from_cp = require "kong.db.utils".fetch_from_cp

local BasicauthCredentials = {}

function BasicauthCredentials:select_by_username(username)
  local cred, err = fetch_from_cp("/basic-auths/" .. username)

  if not cred then
    return nil, err
  end

  return cred, nil, cred.ttl
end

return BasicauthCredentials

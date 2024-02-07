local kong      = kong
local fetch_from_cp = require "kong.db.utils".fetch_from_cp

local KeyauthCredentials = {}

function KeyauthCredentials:select_by_key(key)
  local cred, err = fetch_from_cp("/key-auths/" .. key)

  print("cred = " .. require("inspect")(cred))
  if not cred then
    return nil, err
  end

  if cred.ttl == 0 then
    kong.log.debug("key expired")

    return nil
  end
  return cred, nil, cred.ttl
end

return KeyauthCredentials

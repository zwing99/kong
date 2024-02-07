local kong      = kong
local fmt       = string.format
local http      = require "resty.http"
local cjson    = require "cjson.safe"

local KeyauthCredentials = {}

function KeyauthCredentials:select_by_key(key)

  local c = http.new()

  local url = "http://localhost:8001/key-auths/" .. key

  local response, err = c:request_uri(url, {
    method = "GET",
    headers = {
      ["Content-Type"] = "application/json",
    },
  })
  if err then
    return nil, err
  end

  local cred = cjson.decode(response.body)

  if cred.ttl == 0 then
    kong.log.debug("key expired")

    return nil
  end
  print("XXX: FETCHING KEYAUTH CREDENTIAL FROM CP")
  if cred.message == "Not found" then
    return nil, nil -- -1
  end

  return cred, nil, cred.ttl
end

return KeyauthCredentials

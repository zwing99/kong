local kong      = kong
local http      = require "resty.http"
local cjson    = require "cjson.safe"

local BasicauthCredentials = {}

function BasicauthCredentials:select_by_username(username)

  local c = http.new()

  local url = "http://localhost:8001/basic-auths/" .. username

  print("XXX: FETCHING BASIC AUTH CREDENTIAL FROM CP")
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

  if cred.message == "Not found" then
    return nil, nil -- -1
  end

  print("cred = " .. require("inspect")(cred))
  return cred, nil, cred.ttl
end

return BasicauthCredentials

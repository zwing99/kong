-- Copyright (C) Kong Inc.
local access = require "kong.plugins.hmac-auth.access"

local HMACAuthHandler = {
  VERSION = require "kong.constants".VERSION,
  PRIORITY = 1030,
}


function HMACAuthHandler:access(conf)
  access.execute(conf)
end


return HMACAuthHandler

-- Copyright (C) Kong Inc.
local access = require "kong.plugins.basic-auth.access"
local BasicAuthHandler = {
  VERSION = require "kong.constants".VERSION,
  PRIORITY = 1100,
}


function BasicAuthHandler:access(conf)
  access.execute(conf)
end

return BasicAuthHandler

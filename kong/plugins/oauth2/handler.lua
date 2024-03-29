local access = require "kong.plugins.oauth2.access"

local OAuthHandler = {
  VERSION = require "kong.constants".VERSION,
  PRIORITY = 1400,
}


function OAuthHandler:access(conf)
  access.execute(conf)
end


return OAuthHandler

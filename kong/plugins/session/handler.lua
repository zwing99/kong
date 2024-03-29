local access = require "kong.plugins.session.access"
local header_filter = require "kong.plugins.session.header_filter"

local KongSessionHandler = {
  PRIORITY = 1900,
  VERSION = require "kong.constants".VERSION,
}


function KongSessionHandler:header_filter(conf)
  header_filter.execute(conf)
end


function KongSessionHandler:access(conf)
  access.execute(conf)
end


return KongSessionHandler

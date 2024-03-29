local access = require "kong.plugins.request-transformer.access"

local RequestTransformerHandler = {
  VERSION = require "kong.constants".VERSION,
  PRIORITY = 801,
}


function RequestTransformerHandler:access(conf)
  access.execute(conf)
end


return RequestTransformerHandler

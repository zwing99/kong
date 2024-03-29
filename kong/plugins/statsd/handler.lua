local log = require "kong.plugins.statsd.log"

local StatsdHandler = {
  PRIORITY = 11,
  VERSION = require "kong.constants".VERSION,
}


function StatsdHandler:log(conf)
  log.execute(conf)
end


return StatsdHandler

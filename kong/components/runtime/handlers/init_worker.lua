local Runtime = require "kong.components.runtime"


local function init_worker_handler()
  -- special math.randomseed from kong.globalpatches not taking any argument.
  -- Must only be called in the init or init_worker phases, to avoid
  -- duplicated seeds.
  math.randomseed()

  -- setup timerng to _G.kong
  Runtime.register_globals("timer", _G.timerng)
  _G.timerng = nil

  kong.timer:set_debug(kong.configuration.log_level == "debug")
  kong.timer:start()

  return true
end

return init_worker_handler
local Runtime = require "kong.components.runtime"


local function register()
  Runtime.register_phase_handler("runtime", "init", require "kong.components.runtime.handlers.init")
  Runtime.register_phase_handler("runtime", "init_worker", require "kong.components.runtime.handlers.init_worker")
end

return register
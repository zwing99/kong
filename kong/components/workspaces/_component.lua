local Runtime = require "kong.components.runtime"

local function init_enter()
  local default_ws = kong.db.workspaces:select_by_name("default")
  Runtime.register_globals("default_workspace", default_ws and default_ws.id)

  return true
end

local function register()
  Runtime.register_phase_handler("workspaces", "init", init_enter, nil, {
    "datastore",
  })
end

return register
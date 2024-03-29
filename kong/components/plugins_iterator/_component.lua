local Runtime = require "kong.components.runtime"
local update_plugins_iterator = require "kong.components.plugins_iterator.build".update_plugins_iterator
local build_plugins_iterator = require "kong.components.plugins_iterator.build".build_plugins_iterator

local function init_enter()
  -- Load plugins as late as possible so that everything is set up
  assert(kong.db.plugins:load_plugin_schemas(kong.configuration.loaded_plugins))

  local ok, err = build_plugins_iterator("init")
  if not ok then
    error("error building initial plugins: " .. tostring(err))
  end
end

local function init_worker_enter()
  return update_plugins_iterator()
end

local function register()
  Runtime.register_phase_handler("plugins_iterator", "init", init_enter, nil, {
    "datastore", "workspaces",
  })
  Runtime.register_phase_handler("plugins_iterator", "init_worker", init_worker_enter, nil, {
    "datastore", "cache", "events", "workspaces",
  })
end

return register
local Runtime = require "kong.components.runtime"
local update_plugins_iterator = require "kong.components.plugins_iterator.build".update_plugins_iterator
local build_plugins_iterator = require "kong.components.plugins_iterator.build".build_plugins_iterator
local get_plugins_iterator = require "kong.components.plugins_iterator.build".get_plugins_iterator

local function init_enter()
  -- Load plugins as late as possible so that everything is set up
  assert(kong.db.plugins:load_plugin_schemas(kong.configuration.loaded_plugins))

  local ok, err = build_plugins_iterator("init")
  if not ok then
    error("error building initial plugins: " .. tostring(err))
  end
end


local set_namespaced_log, reset_log
do
  local log_facilities = setmetatable({}, { __index = "k" })


  set_namespaced_log = function(self, namespace, ctx)
    if not self then
      error("arg #1 cannot be nil", 2)
    end

    if type(namespace) ~= "string" then
      error("namespace (arg #2) must be a string", 2)
    end

    local log = log_facilities[namespace]
    if not log then
      log = self._log.new(namespace) -- use default namespaced format
      log_facilities[namespace] = log
    end

    (ctx or ngx.ctx).KONG_LOG = log
  end


  reset_log = function(self, ctx)
    if not self then
      error("arg #1 cannot be nil", 2)
    end

    (ctx or ngx.ctx).KONG_LOG = self._log
  end
end

local function execute_init_worker_plugins_iterator(plugins_iterator, ctx)
  local iterator, plugins = plugins_iterator:get_init_worker_iterator()
  if not iterator then
    return
  end

  local errors

  for _, plugin in iterator, plugins, 0 do
    set_namespaced_log(kong, plugin.name, ctx)

    -- guard against failed handler in "init_worker" phase only because it will
    -- cause Kong to not correctly initialize and can not be recovered automatically.
    local ok, err = pcall(plugin.handler.init_worker, plugin.handler)
    if not ok then
      errors = errors or {}
      errors[#errors + 1] = {
        plugin = plugin.name,
        err = err,
      }
    end

    reset_log(kong, ctx)
  end

  return errors
end

local function init_worker_enter()
  local ok, err = update_plugins_iterator()
  if not ok then
    return false, "failed to build the plugins iterator: " .. err
  end

  local plugins_iterator = get_plugins_iterator()
  local errros = execute_init_worker_plugins_iterator(plugins_iterator, ngx.ctx)

  if errors then
    for i=1, #errors do
      local e = errors[i]
      errors[i] = 'failed to execute the "init_worker" ' ..
                  'handler for plugin "' .. e.plugin ..'": ' .. e.err
    end

    return table.concat(errors, ", ")
  end

  plugins_iterator:configure(ctx)

  return true
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
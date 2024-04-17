pcall(require, "luarocks.loader")


assert(package.loaded["resty.core"], "lua-resty-core must be loaded; make " ..
                                     "sure 'lua_load_resty_core' is not "..
                                     "disabled.")


local globals = require "kong.internal.globals"

local constants = require "kong.constants"
local PHASES = require "kong.pdk.private.phases".phases

local Runtime = {
  phase_handlers = {},
}

local function load_components(enabled_components)
  local loaded_components = {}

  for k, _ in pairs(enabled_components) do
    local pok, perr
    pok, perr = pcall(require, "kong.components." .. k .. "._component")
    if not pok then
      error("Component '" .. k .. "' failed to resolve: " .. perr, 2)
    end

    local fn = perr

    pok, perr = pcall(fn)
    if not pok then
      error("Component '" .. k .. "' failed in registration: " .. perr, 2)
    end

    loaded_components[k] = true
  end

  return loaded_components
end

local function sorted_with_dependency(handlers, dependencies, reversed)
  -- topological sort handlers_def.dependencies and output a sorted list
  -- of handlers to be executed in the phase
  -- note: didn't implement loop check
  local sorted_handlers = {}
  local visited = {}

  local function visit(name, handler)
    if visited[name] then
      return
    end

    visited[name] = true

    for _, dep in ipairs(dependencies[name] or {}) do
      visit(dep)
    end

    table.insert(sorted_handlers, reversed and 1 or #sorted_handlers + 1, handlers[name])
  end

  for name, handler in pairs(handlers) do
    visit(name)
  end

  return sorted_handlers
end

function Runtime.resolve_dag()
  local REVERSED = true
  for _, handlers_def in pairs(Runtime.phase_handlers) do
    handlers_def.enter_sorted = sorted_with_dependency(handlers_def.enter, handlers_def.dependencies, not REVERSED)
    handlers_def.exit_sorted = sorted_with_dependency(handlers_def.exit, handlers_def.dependencies, REVERSED)
  end
end

function Runtime.load_deployment(name)
  local components = require ("kong.deployment." .. name .. ".components")

  -- add myself as a component too
  Runtime.enabled_components = { runtime = true }
  for _, c in ipairs(components) do
    Runtime.enabled_components[c] = true
  end

  Runtime.loaded_components = load_components(Runtime.enabled_components)
end


function Runtime.register_phase_handler(name, phase, fn_enter, fn_exit, deps, opt_deps)
  local handlers = Runtime.phase_handlers[phase] or {
    enter = {},
    exit = {},
    dependencies = {},
  }

  Runtime.phase_handlers[phase] = handlers

  handlers.enter[name] = fn_enter
  handlers.exit[name] = fn_exit

  local component_dep = name ~= "runtime" and { "runtime" } or {}
  if deps then
    for _, k in ipairs(deps) do
      if not Runtime.enabled_components[k] then
        error("Component '" .. name .. "' depends on '" .. k .. "', which is not loaded", 2)
      else
        table.insert(component_dep, k)
      end
    end
  end
  
  if opt_deps then
    for _, k in ipairs(opt_deps) do
      if Runtime.enabled_components[k] then
        table.insert(component_dep, k)
      end
    end
  end

  handlers.dependencies[name] = component_dep

  return true                       
end


function Runtime.inspects_output(component, key)
  return true
end

function Runtime.register_globals(key, value)
  _G.kong[key] = value

  return value
end

function Runtime.execute_phase(phase)
  local handlers = Runtime.phase_handlers[phase]
  if not handlers then
    ngx.log(ngx.WARN, "no handlers registered for phase: " .. phase)
    return true
  end

  if phase ~= "init" and phase ~= "admin_content" and phase ~= "admin_header_filter" then
    local ctx = ngx.ctx
    ctx.KONG_PHASE = PHASES[phase]
  end

  local ok, err

  for _, handler in ipairs(handlers.enter_sorted) do
    ok, err = handler()
    if err then
      return false, err
    end
  end

  for _, handler in ipairs(handlers.exit_sorted) do
    ok, err = handler()
    if err then
      return false, err
    end
  end

  return true
end


--- transitional handlers

function Runtime.init()
  globals.init()

  Runtime.load_deployment("community_edition")
  Runtime.resolve_dag()

  assert(Runtime.execute_phase("init"))
  -- return require("kong").init()
end

function Runtime.init_worker()
  local ok, err = Runtime.execute_phase("init_worker")
  if err then
    return ngx.log(ngx.CRIT, "worker initialization error: ", err,
                             "; this node must be restarted")
  end
end

function Runtime.balancer()
  assert(Runtime.execute_phase("balancer"))
end

function Runtime.ssl_certificate()
  assert(Runtime.execute_phase("ssl_certificate"))
end

function Runtime.rewrite()
  assert(Runtime.execute_phase("rewrite"))
end

function Runtime.access()
  assert(Runtime.execute_phase("access"))
end

function Runtime.header_filter()
  assert(Runtime.execute_phase("header_filter"))
end

function Runtime.body_filter()
  assert(Runtime.execute_phase("body_filter"))
end

function Runtime.log()
  assert(Runtime.execute_phase("log"))
end

function Runtime.handle_error()
  --
end

function Runtime.admin_content()
  assert(Runtime.execute_phase("admin_content"))
end

function Runtime.admin_header_filter()
  assert(Runtime.execute_phase("admin_header_filter"))
end 

function Runtime.status_content()
  --return require("kong").status_content()
end

function Runtime.status_header_filter()
  --return require("kong").status_header_filter()
end

function Runtime.serve_cluster_listener()
  --return require("kong").serve_cluster_listener()
end

return Runtime
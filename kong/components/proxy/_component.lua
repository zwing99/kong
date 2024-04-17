local Runtime = require "kong.components.runtime"
local router = require "kong.components.proxy.router"
local encode = require("string.buffer").encode

local core_cache_shm = ngx.shared.kong_core_db_cache

local function set_init_versions_in_cache()
  -- because of worker events, kong.cache can not be initialized in `init` phase
  -- therefore, we need to use the shdict API directly to set the initial value
  assert(kong.configuration.role ~= "control_plane")
  assert(ngx.get_phase() == "init")
  local core_cache_shm = ngx.shared["kong_core_db_cache"]

  -- ttl = forever is okay as "*:versions" keys are always manually invalidated
  local marshalled_value = encode("init")

  -- see kong.cache.safe_set function
  local ok, err = core_cache_shm:safe_set("kong_core_db_cacherouter:version", marshalled_value)
  if not ok then
    return nil, "failed to set initial router version in cache: " .. tostring(err)
  end

  ok, err = core_cache_shm:safe_set("kong_core_db_cacheplugins_iterator:version", marshalled_value)
  if not ok then
    return nil, "failed to set initial plugins iterator version in cache: " .. tostring(err)
  end

  ok, err = core_cache_shm:safe_set("kong_core_db_cachefilter_chains:version", marshalled_value)
  if not ok then
    return nil, "failed to set initial wasm filter chains version in cache: " .. tostring(err)
  end


  return true
end

local function init_enter()
  if kong.configuration.role ~= "control_plane" then
    assert(router.build_router("init"))

    local ok, err = set_init_versions_in_cache()
    if not ok then
      error("error setting initial versions for router and plugins iterator in cache: " ..
            tostring(err))
    end
  end
end

local function init_worker_enter()
  local ok, err

  if kong.configuration.role ~= "control_plane" then
    ok, err = router.update_router()
    if not ok then
      return ok, "failed to build the router: " .. err
    end
  end

  router.init_worker.enter()

  return true
end

local function access_enter()
  router.access.enter(ngx.ctx)

  return true
end

local function access_exit()
  router.access.exit(ngx.ctx)

  return true
end

local function balancer_enter()
  router.balancer.enter(ngx.ctx)

  return true
end

local function register()
  Runtime.register_phase_handler("proxy", "init", init_enter, nil, { "datastore" })
  Runtime.register_phase_handler("proxy", "init_worker", init_worker_enter, nil, { "datastore", "cache", "events" })
  Runtime.register_phase_handler("proxy", "access", access_enter, access_exit, { "datastore", "cache", "events", "workspaces" })
  Runtime.register_phase_handler("proxy", "balancer", balancer_enter, nil, { "datastore", "cache", "events", })
end

return register
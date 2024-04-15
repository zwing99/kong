local utils        = require "kong.tools.utils"
local Router       = require "kong.internal.router"
local lrucache     = require "resty.lrucache"
local constants    = require "kong.constants"
local concurrency  = require "kong.concurrency"


local kong              = kong
local max               = math.max
local min               = math.min
local ceil              = math.ceil
local ngx               = ngx
local log               = ngx.log
local subsystem         = ngx.config.subsystem

local DEFAULT_MATCH_LRUCACHE_SIZE = Router.DEFAULT_MATCH_LRUCACHE_SIZE


local kong_shm          = ngx.shared.kong
local ROUTERS_REBUILD_COUNTER_KEY =
                                constants.ROUTERS_REBUILD_COUNTER_KEY


local ROUTER_CACHE_SIZE = DEFAULT_MATCH_LRUCACHE_SIZE
local ROUTER_CACHE = lrucache.new(ROUTER_CACHE_SIZE)
local ROUTER_CACHE_NEG = lrucache.new(ROUTER_CACHE_SIZE)


local ERR   = ngx.ERR
local WARN  = ngx.WARN


local SUBSYSTEMS = constants.PROTOCOLS_WITH_SUBSYSTEM
local TTL_ZERO = { ttl = 0 }


local ROUTER
local ROUTER_VERSION
local ROUTER_SYNC_OPTS


local GLOBAL_QUERY_OPTS = { workspace = ngx.null, show_ws_id = true }


-- @param name "router" or "plugins_iterator"
-- @param callback A function that will update the router or plugins_iterator
-- @param version target version
-- @param opts concurrency options, including lock name and timeout.
-- @returns true if callback was either successfully executed synchronously,
-- enqueued via async timer, or not needed (because current_version == target).
-- nil otherwise (callback was neither called successfully nor enqueued,
-- or an error happened).
-- @returns error message as a second return value in case of failure/error
local function rebuild(name, callback, version, opts)
  local current_version, err = kong.core_cache:get(name .. ":version", TTL_ZERO, utils.uuid)
  if err then
    return nil, "failed to retrieve " .. name .. " version: " .. err
  end

  if current_version == version then
    return true
  end

  return concurrency.with_coroutine_mutex(opts, callback)
end


-- Given a protocol, return the subsystem that handles it
local function should_process_route(route)
  for _, protocol in ipairs(route.protocols) do
    if SUBSYSTEMS[protocol] == subsystem then
      return true
    end
  end

  return false
end


local function load_service_from_db(service_pk)
  local service, err = kong.db.services:select(service_pk, GLOBAL_QUERY_OPTS)
  if service == nil then
    -- the third value means "do not cache"
    return nil, err, -1
  end
  return service
end


local function build_services_init_cache(db)
  local services_init_cache = {}
  local services = db.services
  local page_size
  if services.pagination then
    page_size = services.pagination.max_page_size
  end

  for service, err in services:each(page_size, GLOBAL_QUERY_OPTS) do
    if err then
      return nil, err
    end

    services_init_cache[service.id] = service
  end

  return services_init_cache
end


local function get_service_for_route(db, route, services_init_cache)
  local service_pk = route.service
  if not service_pk then
    return nil
  end

  local id = service_pk.id
  local service = services_init_cache[id]
  if service then
    return service
  end

  local err

  -- kong.core_cache is available, not in init phase
  if kong.core_cache and db.strategy ~= "off" then
    local cache_key = db.services:cache_key(service_pk.id, nil, nil, nil, nil,
                                            route.ws_id)
    service, err = kong.core_cache:get(cache_key, TTL_ZERO,
                                       load_service_from_db, service_pk)

  else -- dbless or init phase, kong.core_cache not needed/available

    -- A new service/route has been inserted while the initial route
    -- was being created, on init (perhaps by a different Kong node).
    -- Load the service individually and update services_init_cache with it
    service, err = load_service_from_db(service_pk)
    services_init_cache[id] = service
  end

  if err then
    return nil, "error raised while finding service for route (" .. route.id .. "): " ..
                err

  elseif not service then
    return nil, "could not find service for route (" .. route.id .. ")"
  end


  -- TODO: this should not be needed as the schema should check it already
  if SUBSYSTEMS[service.protocol] ~= subsystem then
    log(WARN, "service with protocol '", service.protocol,
              "' cannot be used with '", subsystem, "' subsystem")

    return nil
  end

  return service
end


local function get_router_version()
  return kong.core_cache:get("router:version", TTL_ZERO, utils.uuid)
end


local function new_router(version)
  local db = kong.db
  local routes, i = {}, 0

  local err
  -- The router is initially created on init phase, where kong.core_cache is
  -- still not ready. For those cases, use a plain Lua table as a cache
  -- instead
  local services_init_cache = {}
  if not kong.core_cache and db.strategy ~= "off" then
    services_init_cache, err = build_services_init_cache(db)
    if err then
      services_init_cache = {}
      log(WARN, "could not build services init cache: ", err)
    end
  end

  local detect_changes = db.strategy ~= "off" and kong.core_cache
  local counter = 0
  local page_size = db.routes.pagination.max_page_size
  for route, err in db.routes:each(page_size, GLOBAL_QUERY_OPTS) do
    if err then
      return nil, "could not load routes: " .. err
    end

    if detect_changes then
      if counter > 0 and counter % page_size == 0 then
        local new_version, err = get_router_version()
        if err then
          return nil, "failed to retrieve router version: " .. err
        end

        if new_version ~= version then
          return nil, "router was changed while rebuilding it"
        end
      end
      counter = counter + 1
    end

    if should_process_route(route) then
      local service, err = get_service_for_route(db, route, services_init_cache)
      if err then
        return nil, err
      end

      -- routes with no services are added to router
      -- but routes where the services.enabled == false are not put in router
      if service == nil or service.enabled ~= false then
        local r = {
          route   = route,
          service = service,
        }

        i = i + 1
        routes[i] = r
      end
    end
  end

  local n = DEFAULT_MATCH_LRUCACHE_SIZE
  local cache_size = min(ceil(max(i / n, 1)) * n, n * 20)

  if cache_size ~= ROUTER_CACHE_SIZE then
    ROUTER_CACHE = lrucache.new(cache_size)
    ROUTER_CACHE_SIZE = cache_size
  end

  local new_router, err = Router.new(routes, ROUTER_CACHE, ROUTER_CACHE_NEG, ROUTER)
  if not new_router then
    return nil, "could not create router: " .. err
  end

  local _, err = kong_shm:incr(ROUTERS_REBUILD_COUNTER_KEY, 1, 0)
  if err then
    log(ERR, "failed to increase router rebuild counter: ", err)
  end

  return new_router
end


local function build_router(version)
  local router, err = new_router(version)
  if not router then
    return nil, err
  end

  ROUTER = router

  if version then
    ROUTER_VERSION = version
  end

  ROUTER_CACHE:flush_all()
  ROUTER_CACHE_NEG:flush_all()

  return true
end


local function update_router()
  -- we might not need to rebuild the router (if we were not
  -- the first request in this process to enter this code path)
  -- check again and rebuild only if necessary
  local version, err = get_router_version()
  if err then
    return nil, "failed to retrieve router version: " .. err
  end

  if version == ROUTER_VERSION then
    return true
  end

  local ok, err = build_router(version)
  if not ok then
    return nil, --[[ 'err' fully formatted ]] err
  end

  return true
end


local function rebuild_router(opts)
  return rebuild("router", update_router, ROUTER_VERSION, opts)
end


local function get_updated_router()
  if kong.db.strategy ~= "off" and kong.configuration.worker_consistency == "strict" then
    local ok, err = rebuild_router(ROUTER_SYNC_OPTS)
    if not ok then
      -- If an error happens while updating, log it and return non-updated
      -- version.
      log(ERR, "could not rebuild router: ", err, " (stale router will be used)")
    end
  end
  return ROUTER
end


-- for tests only
local function _set_update_router(f)
  update_router = f
end

local function _set_build_router(f)
  build_router = f
end

local function _set_router(r)
  ROUTER = r
end

local function _set_router_version(v)
  ROUTER_VERSION = v
end

return {
  build_router = build_router,
  update_router = update_router,

  -- exposed only for tests
  _set_router = _set_router,
  _set_update_router = _set_update_router,
  _set_build_router = _set_build_router,
  _set_router_version = _set_router_version,
  _get_updated_router = get_updated_router,

  init_worker = {
    enter = function ()
      -- TODO: PR #9337 may affect the following line
      local prefix = kong.configuration.prefix or ngx.config.prefix()

      STREAM_TLS_TERMINATE_SOCK = fmt("unix:%s/stream_tls_terminate.sock", prefix)
      STREAM_TLS_PASSTHROUGH_SOCK = fmt("unix:%s/stream_tls_passthrough.sock", prefix)

      log_level.init_worker()

      if kong.configuration.host_ports then
        HOST_PORTS = kong.configuration.host_ports
      end

      if kong.configuration.anonymous_reports then
        reports.init(kong.configuration)
        reports.add_ping_value("database_version", kong.db.infos.db_ver)
        reports.init_worker(kong.configuration)
      end

      update_lua_mem(true)

      if kong.configuration.role == "control_plane" then
        return
      end

      events.register_events(reconfigure_handler)

      -- initialize balancers for active healthchecks
      timer_at(0, function()
        balancer.init()
      end)

      local strategy = kong.db.strategy

      do
        local rebuild_timeout = 60

        if strategy == "postgres" then
          rebuild_timeout = kong.configuration.pg_timeout / 1000
        end

        if strategy == "off" then
          RECONFIGURE_OPTS = {
            name = "reconfigure",
            timeout = rebuild_timeout,
          }

        elseif kong.configuration.worker_consistency == "strict" then
          ROUTER_SYNC_OPTS = {
            name = "router",
            timeout = rebuild_timeout,
            on_timeout = "run_unlocked",
          }

          PLUGINS_ITERATOR_SYNC_OPTS = {
            name = "plugins_iterator",
            timeout = rebuild_timeout,
            on_timeout = "run_unlocked",
          }

          WASM_STATE_SYNC_OPTS = {
            name = "wasm",
            timeout = rebuild_timeout,
            on_timeout = "run_unlocked",
          }
        end
      end

      if strategy ~= "off" then
        local worker_state_update_frequency = kong.configuration.worker_state_update_frequency or 1

        local function rebuild_timer(premature)
          if premature then
            return
          end

          local router_update_status, err = rebuild_router({
            name = "router",
            timeout = 0,
            on_timeout = "return_true",
          })
          if not router_update_status then
            log(ERR, "could not rebuild router via timer: ", err)
          end

          local plugins_iterator_update_status, err = rebuild_plugins_iterator({
            name = "plugins_iterator",
            timeout = 0,
            on_timeout = "return_true",
          })
          if not plugins_iterator_update_status then
            log(ERR, "could not rebuild plugins iterator via timer: ", err)
          end

          if wasm.enabled() then
            local wasm_update_status, err = rebuild_wasm_state({
              name = "wasm",
              timeout = 0,
              on_timeout = "return_true",
            })
            if not wasm_update_status then
              log(ERR, "could not rebuild wasm filter chains via timer: ", err)
            end
          end
        end

        local _, err = kong.timer:named_every("rebuild",
                                         worker_state_update_frequency,
                                         rebuild_timer)
        if err then
          log(ERR, "could not schedule timer to rebuild: ", err)
        end
      end
    end,
  }
}
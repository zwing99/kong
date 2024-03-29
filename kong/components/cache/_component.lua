local Runtime = require "kong.components.runtime"
local process = require "ngx.process"
local kong_cache = require "kong.internal.cache"
local constants = require "kong.constants"

local function get_lru_size(kong_config)
  if (process.type() == "privileged agent")
  or (kong_config.role == "control_plane")
  or (kong_config.role == "traditional" and #kong_config.proxy_listeners  == 0
                                        and #kong_config.stream_listeners == 0)
  then
    return 1000
  end
end


local function init_cache(name, invalidation_channel)
  assert(name, "name must be given", 2)

  local db_cache_ttl = kong.configuration.db_cache_ttl
  local db_cache_neg_ttl = kong.configuration.db_cache_neg_ttl
  local page = 1
  local cache_pages = 1

  if kong.configuration.database == "off" then
    db_cache_ttl = 0
    db_cache_neg_ttl = 0
   end

  return kong_cache.new({
    shm_name             = name,
    cluster_events       = kong.cluster_events,
    worker_events        = kong.worker_events,
    ttl                  = db_cache_ttl,
    neg_ttl              = db_cache_neg_ttl or db_cache_ttl,
    resurrect_ttl        = kong.configuration.resurrect_ttl,
    page                 = page,
    cache_pages          = cache_pages,
    resty_lock_opts      = LOCK_OPTS,
    lru_size             = get_lru_size(kong.configuration),
    invalidation_channel = invalidation_channel,
  })
end


local function init_core_cache()
  local db_cache_ttl = kong.configuration.db_cache_ttl
  local db_cache_neg_ttl = kong.configuration.db_cache_neg_ttl
  local page = 1
  local cache_pages = 1

  if kong.configuration.database == "off" then
    db_cache_ttl = 0
    db_cache_neg_ttl = 0
  end

  return kong_cache.new({
    shm_name        = "kong_core_db_cache",
    cluster_events  = kong.cluster_events,
    worker_events   = kong.worker_events,
    ttl             = db_cache_ttl,
    neg_ttl         = db_cache_neg_ttl or db_cache_ttl,
    resurrect_ttl   = kong.configuration.resurrect_ttl,
    page            = page,
    cache_pages     = cache_pages,
    resty_lock_opts = LOCK_OPTS,
    lru_size        = get_lru_size(kong.configuration),
  })
end


local function init_worker_enter()
  local cache, err = init_cache("kong_db_cache", "invalidations")
  if err then
    return nil, "failed to instantiate 'kong.cache' module: " .. err
  end

  Runtime.register_globals("cache", cache)

  local core_cache, err = init_cache("kong_core_db_cache")

  if err then
    return nil, "failed to instantiate 'kong.core_cache' module: " .. err
  end

  Runtime.register_globals("core_cache", cache)

  if kong.configuration.admin_gui_listeners then
    kong.cache:invalidate_local(constants.ADMIN_GUI_KCONFIG_CACHE_KEY)
  end

  return true
end

local function register()
  Runtime.register_phase_handler("cache", "init_worker", init_worker_enter, nil, { "datastore", "events" })
end

return register
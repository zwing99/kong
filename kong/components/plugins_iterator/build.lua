local utils        = require "kong.tools.utils"
local constants    = require "kong.constants"
local concurrency  = require "kong.concurrency"

local PluginsIterator = require "kong.components.plugins_iterator"

local kong              = kong
local ngx               = ngx
local log               = ngx.log
local get_phase         = ngx.get_phase

local ERR   = ngx.ERR
local TTL_ZERO = { ttl = 0 }


local kong_shm          = ngx.shared.kong
local PLUGINS_REBUILD_COUNTER_KEY =
                                constants.PLUGINS_REBUILD_COUNTER_KEY


local PLUGINS_ITERATOR
local PLUGINS_ITERATOR_SYNC_OPTS


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


local new_plugins_iterator
do
  local PluginsIterator_new = PluginsIterator.new
  new_plugins_iterator = function(version)
    local plugin_iterator, err = PluginsIterator_new(version)
    if not plugin_iterator then
      return nil, err
    end

    local _, err = kong_shm:incr(PLUGINS_REBUILD_COUNTER_KEY, 1, 0)
    if err then
      log(ERR, "failed to increase plugins rebuild counter: ", err)
    end

    return plugin_iterator
  end
end


local function build_plugins_iterator(version)
  local plugins_iterator, err = new_plugins_iterator(version)
  if not plugins_iterator then
    return nil, err
  end

  local phase = get_phase()
  -- skip calling plugins_iterator:configure on init/init_worker
  -- as it is explicitly called on init_worker
  if phase ~= "init" and phase ~= "init_worker" then
    plugins_iterator:configure()
  end

  PLUGINS_ITERATOR = plugins_iterator
  return true
end


local function update_plugins_iterator()
  local version, err = kong.core_cache:get("plugins_iterator:version", TTL_ZERO, utils.uuid)
  if err then
    return nil, "failed to retrieve plugins iterator version: " .. err
  end

  if PLUGINS_ITERATOR and PLUGINS_ITERATOR.version == version then
    return true
  end

  local ok, err = build_plugins_iterator(version)
  if not ok then
    return nil, --[[ 'err' fully formatted ]] err
  end

  return true
end


local function rebuild_plugins_iterator(opts)
  local plugins_iterator_version = PLUGINS_ITERATOR and PLUGINS_ITERATOR.version
  return rebuild("plugins_iterator", update_plugins_iterator, plugins_iterator_version, opts)
end


local function get_updated_plugins_iterator()
  if kong.db.strategy ~= "off" and kong.configuration.worker_consistency == "strict" then
    local ok, err = rebuild_plugins_iterator(PLUGINS_ITERATOR_SYNC_OPTS)
    if not ok then
      -- If an error happens while updating, log it and return non-updated
      -- version
      log(ERR, "could not rebuild plugins iterator: ", err,
               " (stale plugins iterator will be used)")
    end
  end
  return PLUGINS_ITERATOR
end


local function get_plugins_iterator()
  return PLUGINS_ITERATOR
end


-- for tests only
local function _set_update_plugins_iterator(f)
  update_plugins_iterator = f
end


return {
  build_plugins_iterator = build_plugins_iterator,
  update_plugins_iterator = update_plugins_iterator,
  get_plugins_iterator = get_plugins_iterator,
  get_updated_plugins_iterator = get_updated_plugins_iterator,

  -- exposed only for tests
  _set_update_plugins_iterator = _set_update_plugins_iterator,
}
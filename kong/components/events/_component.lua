local Runtime = require "kong.components.runtime"
local kong_cluster_events = require "kong.internal.cluster_events"

local function init_worker_events()
  local worker_events
  local opts

  local configuration = kong.configuration

  -- `kong.configuration.prefix` is already normalized to an absolute path,
  -- but `ngx.config.prefix()` is not
  local prefix = configuration and
                 configuration.prefix or
                 require("pl.path").abspath(ngx.config.prefix())

  local sock = ngx.config.subsystem == "stream" and
               "stream_worker_events.sock" or
               "worker_events.sock"

  local listening = "unix:" .. prefix .. "/" .. sock

  local max_payload_len = configuration and
                          configuration.worker_events_max_payload

  if max_payload_len and max_payload_len > 65535 then   -- default is 64KB
    ngx.log(ngx.WARN,
            "Increasing 'worker_events_max_payload' value has potential " ..
            "negative impact on Kong's response latency and memory usage")
  end

  opts = {
    unique_timeout = 5,     -- life time of unique event data in lrucache
    broker_id = 0,          -- broker server runs in nginx worker #0
    listening = listening,  -- unix socket for broker listening
    max_queue_len = 1024 * 50,  -- max queue len for events buffering
    max_payload_len = max_payload_len,  -- max payload size in bytes
  }

  worker_events = require "resty.events.compat"

  local ok, err = worker_events.configure(opts)
  if not ok then
    return nil, err
  end

  return worker_events
end

function init_cluster_events()
  return kong_cluster_events.new({
    db            = kong.db,
    poll_interval = kong.configuration.db_update_frequency,
    poll_offset   = kong.configuration.db_update_propagation,
    poll_delay    = kong.configuration.db_update_propagation,
  })
end

local function init_worker_enter()
  local worker_events, err = init_worker_events()
  if err then
    return nil, "failed to instantiate 'kong.worker_events' module: " .. err
  end

  Runtime.register_globals("worker_events", worker_events)

  kong.db:set_events_handler(worker_events)

  local cluster_events, err = init_cluster_events()
  if err then
    return nil, "failed to instantiate 'kong.cluster_events' module: " .. err
  end

  Runtime.register_globals("cluster_events", cluster_events)

  return true
end

local function register()
  Runtime.register_phase_handler("events", "init_worker", init_worker_enter, nil, { "datastore" })
end

return register
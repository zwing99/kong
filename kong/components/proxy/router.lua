local utils        = require "kong.tools.utils"
local Router       = require "kong.internal.router"
local Balancer     = require "kong.internal.balancer"
local lrucache     = require "resty.lrucache"
local constants    = require "kong.constants"
local concurrency  = require "kong.concurrency"

local ngx_balancer = require "ngx.balancer"

local csv            = require "kong.components.proxy.tools".csv
local update_lua_mem = require "kong.components.proxy.tools".update_lua_mem


local kong              = kong
local max               = math.max
local min               = math.min
local ceil              = math.ceil
local ngx               = ngx
local log               = ngx.log
local var               = ngx.var
local header            = ngx.header
local subsystem         = ngx.config.subsystem
local clear_header      = ngx.req.clear_header
local sub               = string.sub
local ERR               = ngx.ERR
local WARN              = ngx.WARN
local DEBUG             = ngx.DEBUG
local uri_escape        = require("kong.tools.uri").escape
local QUESTION_MARK     = string.byte("?")

local get_last_failure = ngx_balancer.get_last_failure
local set_current_peer = ngx_balancer.set_current_peer
local set_timeouts     = ngx_balancer.set_timeouts
local set_more_tries   = ngx_balancer.set_more_tries
local enable_keepalive = ngx_balancer.enable_keepalive

local time_ns           = utils.time_ns
local get_now_ms        = utils.get_now_ms
local get_updated_now_ms = utils.get_updated_now_ms

local DEFAULT_MATCH_LRUCACHE_SIZE = Router.DEFAULT_MATCH_LRUCACHE_SIZE

local PHASES = require "kong.pdk.private.phases".phases


local kong_shm          = ngx.shared.kong
local ROUTERS_REBUILD_COUNTER_KEY =
                                constants.ROUTERS_REBUILD_COUNTER_KEY


local ROUTER_CACHE_SIZE = DEFAULT_MATCH_LRUCACHE_SIZE
local ROUTER_CACHE = lrucache.new(ROUTER_CACHE_SIZE)
local ROUTER_CACHE_NEG = lrucache.new(ROUTER_CACHE_SIZE)

local SUBSYSTEMS = constants.PROTOCOLS_WITH_SUBSYSTEM
local ARRAY_MT = require("cjson.safe").array_mt
local GLOBAL_QUERY_OPTS = { workspace = ngx.null, show_ws_id = true }
local TTL_ZERO = { ttl = 0 }
local HOST_PORTS = {}

local NOOP = function() end


local ROUTER
local ROUTER_VERSION
local ROUTER_SYNC_OPTS

local RECONFIGURE_OPTS

local STREAM_TLS_TERMINATE_SOCK
local STREAM_TLS_PASSTHROUGH_SOCK

local SERVER_HEADER = constants.SERVER_TOKENS

local get_header
local set_authority
local is_stream_module
local is_http_module

if subsystem == "http" then
  is_http_module = true
  get_header = require("kong.tools.http").get_header
  set_authority = require("resty.kong.grpc").set_authority
end

local disable_proxy_ssl
if subsystem == "stream" then
  is_stream_module = true
  disable_proxy_ssl = nil -- ktls.disable_proxy_ssl
end



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
  -- TODO: this is not true anymore, more to use kong.core_cache instead?
  local services_init_cache = {}
  if db.strategy ~= "off" then
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

local balancer_prepare
do
  local function sleep_once_for_balancer_init()
    ngx.sleep(0)
    sleep_once_for_balancer_init = NOOP
  end

  function balancer_prepare(ctx, scheme, host_type, host, port,
                            service, route)

    sleep_once_for_balancer_init()

    local retries
    local connect_timeout
    local send_timeout
    local read_timeout

    if service then
      retries         = service.retries
      connect_timeout = service.connect_timeout
      send_timeout    = service.write_timeout
      read_timeout    = service.read_timeout
    end

    local balancer_data = {
      scheme             = scheme,    -- scheme for balancer: http, https
      type               = host_type, -- type of 'host': ipv4, ipv6, name
      host               = host,      -- target host per `service` entity
      port               = port,      -- final target port
      try_count          = 0,         -- retry counter

      retries            = retries         or 5,
      connect_timeout    = connect_timeout or 60000,
      send_timeout       = send_timeout    or 60000,
      read_timeout       = read_timeout    or 60000,

      -- stores info per try, metatable is needed for basic log serializer
      -- see #6390
      tries              = setmetatable({}, ARRAY_MT),
      -- ip              = nil,       -- final target IP address
      -- balancer        = nil,       -- the balancer object, if any
      -- hostname        = nil,       -- hostname of the final target IP
      -- hash_cookie     = nil,       -- if Upstream sets hash_on_cookie
      -- balancer_handle = nil,       -- balancer handle for the current connection
    }

    ctx.service          = service
    ctx.route            = route
    ctx.balancer_data    = balancer_data

    -- TODO: upstream_ssl
    -- set_service_ssl(ctx)

    if disable_proxy_ssl and scheme == "tcp" then
      local res, err = disable_proxy_ssl()
      if not res then
        log(ERR, "unable to disable upstream TLS handshake: ", err)
      end
    end
  end
end


local function balancer_execute(ctx)
  local balancer_data = ctx.balancer_data
  local ok, err, errcode = Balancer.execute(balancer_data, ctx)
  if not ok and errcode == 500 then
    err = "failed the initial dns/balancer resolve for '" ..
          balancer_data.host .. "' with: " .. tostring(err)
  end
  return ok, err, errcode
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

      STREAM_TLS_TERMINATE_SOCK = string.format("unix:%s/stream_tls_terminate.sock", prefix)
      STREAM_TLS_PASSTHROUGH_SOCK = string.format("unix:%s/stream_tls_passthrough.sock", prefix)

      -- log_level.init_worker()

      if kong.configuration.host_ports then
        HOST_PORTS = kong.configuration.host_ports
      end

      -- if kong.configuration.anonymous_reports then
      --   reports.init(kong.configuration)
      --   reports.add_ping_value("database_version", kong.db.infos.db_ver)
      --   reports.init_worker(kong.configuration)
      -- end

      update_lua_mem(true)

      if kong.configuration.role == "control_plane" then
        return
      end

      -- events.register_events(reconfigure_handler)

      -- initialize balancers for active healthchecks
      ngx.timer.at(0, function()
        Balancer.init()
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

          -- PLUGINS_ITERATOR_SYNC_OPTS = {
          --   name = "plugins_iterator",
          --   timeout = rebuild_timeout,
          --   on_timeout = "run_unlocked",
          -- }

          -- WASM_STATE_SYNC_OPTS = {
          --   name = "wasm",
          --   timeout = rebuild_timeout,
          --   on_timeout = "run_unlocked",
          -- }
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

          -- local plugins_iterator_update_status, err = rebuild_plugins_iterator({
          --   name = "plugins_iterator",
          --   timeout = 0,
          --   on_timeout = "return_true",
          -- })
          -- if not plugins_iterator_update_status then
          --   log(ERR, "could not rebuild plugins iterator via timer: ", err)
          -- end

          -- if wasm.enabled() then
          --   local wasm_update_status, err = rebuild_wasm_state({
          --     name = "wasm",
          --     timeout = 0,
          --     on_timeout = "return_true",
          --   })
          --   if not wasm_update_status then
          --     log(ERR, "could not rebuild wasm filter chains via timer: ", err)
          --   end
          -- end
        end

        local _, err = kong.timer:named_every("rebuild",
                                         worker_state_update_frequency,
                                         rebuild_timer)
        if err then
          log(ERR, "could not schedule timer to rebuild: ", err)
        end
      end
    end,
  },
  access = {
    enter = function(ctx)
      -- if there is a gRPC service in the context, don't re-execute the pre-access
      -- phase handler - it has been executed before the internal redirect
      if ctx.service and (ctx.service.protocol == "grpc" or
                          ctx.service.protocol == "grpcs")
      then
        return
      end

      ctx.scheme = var.scheme
      ctx.request_uri = var.request_uri

      -- routing request
      local router = get_updated_router()
      local match_t = router:exec(ctx)

      if not match_t then
        return kong.response.error(404, "no Route matched with those values")
      end

      ctx.workspace = match_t.route and match_t.route.ws_id

      local host           = var.host
      local port           = ctx.host_port or tonumber(var.server_port, 10)

      local route          = match_t.route
      local service        = match_t.service
      local upstream_url_t = match_t.upstream_url_t

      local realip_remote_addr = var.realip_remote_addr
      local forwarded_proto
      local forwarded_host
      local forwarded_port
      local forwarded_path
      local forwarded_prefix

      -- X-Forwarded-* Headers Parsing
      --
      -- We could use $proxy_add_x_forwarded_for, but it does not work properly
      -- with the realip module. The realip module overrides $remote_addr and it
      -- is okay for us to use it in case no X-Forwarded-For header was present.
      -- But in case it was given, we will append the $realip_remote_addr that
      -- contains the IP that was originally in $remote_addr before realip
      -- module overrode that (aka the client that connected us).

      local trusted_ip = kong.ip.is_trusted(realip_remote_addr)
      if trusted_ip then
        forwarded_proto  = get_header("x_forwarded_proto", ctx)  or ctx.scheme
        forwarded_host   = get_header("x_forwarded_host", ctx)   or host
        forwarded_port   = get_header("x_forwarded_port", ctx)   or port
        forwarded_path   = get_header("x_forwarded_path", ctx)
        forwarded_prefix = get_header("x_forwarded_prefix", ctx)

      else
        forwarded_proto  = ctx.scheme
        forwarded_host   = host
        forwarded_port   = port
      end

      if not forwarded_path then
        forwarded_path = ctx.request_uri
        local p = string.find(forwarded_path, "?", 2, true)
        if p then
          forwarded_path = sub(forwarded_path, 1, p - 1)
        end
      end

      if not forwarded_prefix and match_t.prefix ~= "/" then
        forwarded_prefix = match_t.prefix
      end

      local protocols = route.protocols
      if (protocols and protocols.https and not protocols.http and
          forwarded_proto ~= "https")
      then
        local redirect_status_code = route.https_redirect_status_code or 426

        if redirect_status_code == 426 then
          return kong.response.error(426, "Please use HTTPS protocol", {
            ["Connection"] = "Upgrade",
            ["Upgrade"]    = "TLS/1.2, HTTP/1.1",
          })
        end

        if redirect_status_code == 301
        or redirect_status_code == 302
        or redirect_status_code == 307
        or redirect_status_code == 308
        then
          header["Location"] = "https://" .. forwarded_host .. ctx.request_uri
          return kong.response.exit(redirect_status_code)
        end
      end

      local protocol_version = ngx.req.http_version()
      if protocols.grpc or protocols.grpcs then
        -- perf: branch usually not taken, don't cache var outside
        local content_type = var.content_type

        if content_type and sub(content_type, 1, #"application/grpc") == "application/grpc" then
          if protocol_version ~= 2 then
            -- mismatch: non-http/2 request matched grpc route
            return kong.response.error(426, "Please use HTTP2 protocol", {
              ["connection"] = "Upgrade",
              ["upgrade"]    = "HTTP/2",
            })
          end

        else
          -- mismatch: non-grpc request matched grpc route
          return kong.response.error(415, "Non-gRPC request matched gRPC route")
        end

        if not protocols.grpc and forwarded_proto ~= "https" then
          -- mismatch: grpc request matched grpcs route
          return kong.response.exit(200, nil, {
            ["content-type"] = "application/grpc",
            ["grpc-status"] = 1,
            ["grpc-message"] = "gRPC request matched gRPCs route",
          })
        end
      end

      balancer_prepare(ctx, match_t.upstream_scheme,
                      upstream_url_t.type,
                      upstream_url_t.host,
                      upstream_url_t.port,
                      service, route)

      ctx.router_matches = match_t.matches

      -- `uri` is the URI with which to call upstream, as returned by the
      --       router, which might have truncated it (`strip_uri`).
      -- `host` is the original header to be preserved if set.
      var.upstream_scheme = match_t.upstream_scheme -- COMPAT: pdk
      var.upstream_uri    = uri_escape(match_t.upstream_uri)
      if match_t.upstream_host then
        var.upstream_host = match_t.upstream_host
      end

      -- Keep-Alive and WebSocket Protocol Upgrade Headers
      local upgrade = get_header("upgrade", ctx)
      if upgrade and string.lower(upgrade) == "websocket" then
        var.upstream_connection = "keep-alive, Upgrade"
        var.upstream_upgrade    = "websocket"

      else
        var.upstream_connection = "keep-alive"
      end

      -- X-Forwarded-* Headers
      local http_x_forwarded_for = get_header("x_forwarded_for", ctx)
      if http_x_forwarded_for then
        var.upstream_x_forwarded_for = http_x_forwarded_for .. ", " ..
                                      realip_remote_addr

      else
        var.upstream_x_forwarded_for = var.remote_addr
      end

      var.upstream_x_forwarded_proto  = forwarded_proto
      var.upstream_x_forwarded_host   = forwarded_host
      var.upstream_x_forwarded_port   = forwarded_port
      var.upstream_x_forwarded_path   = forwarded_path
      var.upstream_x_forwarded_prefix = forwarded_prefix

      -- At this point, the router and `balancer_setup_stage1` have been
      -- executed; detect requests that need to be redirected from `proxy_pass`
      -- to `grpc_pass`. After redirection, this function will return early
      if service and var.kong_proxy_mode == "http" then
        if service.protocol == "grpc" or service.protocol == "grpcs" then
          return ngx.exec("@grpc")
        end

        if route.request_buffering == false then
          if route.response_buffering == false then
            return ngx.exec("@unbuffered")
          end

          return ngx.exec("@unbuffered_request")
        end

        if route.response_buffering == false then
          return ngx.exec("@unbuffered_response")
        end
      end
    end,
    -- Only executed if the `router` module found a route and allows nginx to proxy it.
    exit = function(ctx)
      -- Nginx's behavior when proxying a request with an empty querystring
      -- `/foo?` is to keep `$is_args` an empty string, hence effectively
      -- stripping the empty querystring.
      -- We overcome this behavior with our own logic, to preserve user
      -- desired semantics.
      -- perf: branch usually not taken, don't cache var outside
      if string.byte(ctx.request_uri or var.request_uri, -1) == QUESTION_MARK or var.is_args == "?" then
        var.upstream_uri = var.upstream_uri .. "?" .. (var.args or "")
      end

      local upstream_scheme = var.upstream_scheme

      local balancer_data = ctx.balancer_data
      balancer_data.scheme = upstream_scheme -- COMPAT: pdk

      -- The content of var.upstream_host is only set by the router if
      -- preserve_host is true
      --
      -- We can't rely on var.upstream_host for balancer retries inside
      -- `set_host_header` because it would never be empty after the first -- balancer try
      local upstream_host = var.upstream_host
      if upstream_host ~= nil and upstream_host ~= "" then
        balancer_data.preserve_host = true

        -- the nginx grpc module does not offer a way to override the
        -- :authority pseudo-header; use our internal API to do so
        -- this call applies to routes with preserve_host=true; for
        -- preserve_host=false, the header is set in `set_host_header`,
        -- so that it also applies to balancer retries
        if upstream_scheme == "grpc" or upstream_scheme == "grpcs" then
          local ok, err = set_authority(upstream_host)
          if not ok then
            log(ERR, "failed to set :authority header: ", err)
          end
        end
      end

      local ok, err, errcode = balancer_execute(ctx)
      if not ok then
        return kong.response.error(errcode, err)
      end

      local ok, err = Balancer.set_host_header(balancer_data, upstream_scheme, upstream_host)
      if not ok then
        log(ERR, "failed to set balancer Host header: ", err)
        return ngx.exit(500)
      end

      -- clear hop-by-hop request headers:
      local http_connection = get_header("connection", ctx)
      if http_connection ~= "keep-alive" and
        http_connection ~= "close"      and
        http_connection ~= "upgrade"
      then
        for _, header_name in csv(http_connection) do
          -- some of these are already handled by the proxy module,
          -- upgrade being an exception that is handled below with
          -- special semantics.
          if header_name == "upgrade" then
            if var.upstream_connection == "keep-alive" then
              clear_header(header_name)
            end

          else
            clear_header(header_name)
          end
        end
      end

      -- add te header only when client requests trailers (proxy removes it)
      local http_te = get_header("te", ctx)
      if http_te then
        if http_te == "trailers" then
          var.upstream_te = "trailers"

        else
          for _, header_name in csv(http_te) do
            if header_name == "trailers" then
              var.upstream_te = "trailers"
              break
            end
          end
        end
      end

      if var.http_proxy then
        clear_header("Proxy")
      end

      if var.http_proxy_connection then
        clear_header("Proxy-Connection")
      end
    end,
  },
  balancer = {
    enter = function(ctx)
      -- local has_timing = ctx.has_timing
    
      -- if has_timing then
      --   req_dyn_hook_run_hooks("timing", "before:balancer")
      -- end
    
      -- This may be called multiple times, and no yielding here!
      local now_ms = get_now_ms()
      local now_ns = time_ns()
    
      if not ctx.KONG_BALANCER_START then
        ctx.KONG_BALANCER_START = now_ms
    
        if is_stream_module then
          if ctx.KONG_PREREAD_START and not ctx.KONG_PREREAD_ENDED_AT then
            ctx.KONG_PREREAD_ENDED_AT = ctx.KONG_BALANCER_START
            ctx.KONG_PREREAD_TIME = ctx.KONG_PREREAD_ENDED_AT -
                                    ctx.KONG_PREREAD_START
          end
    
        else
          if ctx.KONG_REWRITE_START and not ctx.KONG_REWRITE_ENDED_AT then
            ctx.KONG_REWRITE_ENDED_AT = ctx.KONG_ACCESS_START or
                                        ctx.KONG_BALANCER_START
            ctx.KONG_REWRITE_TIME = ctx.KONG_REWRITE_ENDED_AT -
                                    ctx.KONG_REWRITE_START
          end
    
          if ctx.KONG_ACCESS_START and not ctx.KONG_ACCESS_ENDED_AT then
            ctx.KONG_ACCESS_ENDED_AT = ctx.KONG_BALANCER_START
            ctx.KONG_ACCESS_TIME = ctx.KONG_ACCESS_ENDED_AT -
                                   ctx.KONG_ACCESS_START
          end
        end
      end

    
      local balancer_data = ctx.balancer_data
      local tries = balancer_data.tries
      local try_count = balancer_data.try_count
      local current_try = table.new(0, 4)

    
      try_count = try_count + 1
      balancer_data.try_count = try_count
      tries[try_count] = current_try
    
      current_try.balancer_start = now_ms
      current_try.balancer_start_ns = now_ns
    
      if try_count > 1 then
        -- only call balancer on retry, first one is done in `runloop.access.after`
        -- which runs in the ACCESS context and hence has less limitations than
        -- this BALANCER context where the retries are executed
    
        -- record failure data
        local previous_try = tries[try_count - 1]
        previous_try.state, previous_try.code = get_last_failure()
    
        -- Report HTTP status for health checks
        local balancer_instance = balancer_data.balancer
        if balancer_instance then
          if previous_try.state == "failed" then
            if previous_try.code == 504 then
              balancer_instance.report_timeout(balancer_data.balancer_handle)
            else
              balancer_instance.report_tcp_failure(balancer_data.balancer_handle)
            end
    
          else
            balancer_instance.report_http_status(balancer_data.balancer_handle,
                                                 previous_try.code)
          end
        end
    
        local ok, err, errcode = Balancer.execute(balancer_data, ctx)
        if not ok then
          log(ERR, "failed to retry the dns/balancer resolver for ",
                  tostring(balancer_data.host), "' with: ", tostring(err))
    
          ctx.KONG_BALANCER_ENDED_AT = get_updated_now_ms()
          ctx.KONG_BALANCER_TIME = ctx.KONG_BALANCER_ENDED_AT - ctx.KONG_BALANCER_START
          ctx.KONG_PROXY_LATENCY = ctx.KONG_BALANCER_ENDED_AT - ctx.KONG_PROCESSING_START
    
          -- if has_timing then
          --   req_dyn_hook_run_hooks("timing", "after:balancer")
          -- end
    
          return ngx.exit(errcode)
        end
    
        if is_http_module then
          ok, err = Balancer.set_host_header(balancer_data, var.upstream_scheme, var.upstream_host, true)
          if not ok then
            log(ERR, "failed to set balancer Host header: ", err)
    
            -- if has_timing then
            --   req_dyn_hook_run_hooks("timing", "after:balancer")
            -- end
    
            return ngx.exit(500)
          end
        end
    
      else
        -- first try, so set the max number of retries
        local retries = balancer_data.retries
        if retries > 0 then
          set_more_tries(retries)
        end
      end
    
      local pool_opts
      local kong_conf = kong.configuration
      local balancer_data_ip = balancer_data.ip
      local balancer_data_port = balancer_data.port
    
      if kong_conf.upstream_keepalive_pool_size > 0 and is_http_module then
        local pool = balancer_data_ip .. "|" .. balancer_data_port
    
        if balancer_data.scheme == "https" then
          -- upstream_host is SNI
          pool = pool .. "|" .. var.upstream_host
    
          if ctx.service and ctx.service.client_certificate then
            pool = pool .. "|" .. ctx.service.client_certificate.id
          end
        end
    
        pool_opts = {
          pool = pool,
          pool_size = kong_conf.upstream_keepalive_pool_size,
        }
      end
    
      current_try.ip   = balancer_data_ip
      current_try.port = balancer_data_port
    
      -- set the targets as resolved
      log(DEBUG, "setting address (try ", try_count, "): ",
                         balancer_data_ip, ":", balancer_data_port)
      local ok, err = set_current_peer(balancer_data_ip, balancer_data_port, pool_opts)
      if not ok then
        log(ERR, "failed to set the current peer (address: ",
                tostring(balancer_data_ip), " port: ", tostring(balancer_data_port),
                "): ", tostring(err))
    
        ctx.KONG_BALANCER_ENDED_AT = get_updated_now_ms()
        ctx.KONG_BALANCER_TIME = ctx.KONG_BALANCER_ENDED_AT - ctx.KONG_BALANCER_START
        ctx.KONG_PROXY_LATENCY = ctx.KONG_BALANCER_ENDED_AT - ctx.KONG_PROCESSING_START
    
        -- if has_timing then
        --   req_dyn_hook_run_hooks("timing", "after:balancer")
        -- end
    
        return ngx.exit(500)
      end
    
      ok, err = set_timeouts(balancer_data.connect_timeout / 1000,
                             balancer_data.send_timeout / 1000,
                             balancer_data.read_timeout / 1000)
      if not ok then
        log(ERR, "could not set upstream timeouts: ", err)
      end
    
      -- if pool_opts then
      --   ok, err = enable_keepalive(kong_conf.upstream_keepalive_idle_timeout,
      --                              kong_conf.upstream_keepalive_max_requests)
      --   if not ok then
      --     log(ERR, "could not enable connection keepalive: ", err)
      --   end
    
      --   log(DEBUG, "enabled connection keepalive (pool=", pool_opts.pool,
      --                      ", pool_size=", pool_opts.pool_size,
      --                      ", idle_timeout=", kong_conf.upstream_keepalive_idle_timeout,
      --                      ", max_requests=", kong_conf.upstream_keepalive_max_requests, ")")
      -- end
    
      -- record overall latency
      ctx.KONG_BALANCER_ENDED_AT = get_updated_now_ms()
      ctx.KONG_BALANCER_TIME = ctx.KONG_BALANCER_ENDED_AT - ctx.KONG_BALANCER_START
    
      -- record try-latency
      local try_latency = ctx.KONG_BALANCER_ENDED_AT - current_try.balancer_start
      current_try.balancer_latency = try_latency
      current_try.balancer_latency_ns = time_ns() - current_try.balancer_start_ns
    
      -- time spent in Kong before sending the request to upstream
      -- start_time() is kept in seconds with millisecond resolution.
      --ctx.KONG_PROXY_LATENCY = ctx.KONG_BALANCER_ENDED_AT - ctx.KONG_PROCESSING_START
    
      -- if has_timing then
      --   req_dyn_hook_run_hooks("timing", "after:balancer")
      -- end
    end,
  }
}
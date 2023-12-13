
local client -- forward declaration
local dns_utils = require "kong.resty.dns.utils"
local helpers = require "spec.helpers.dns"
local dnsSRV = function(...) return helpers.dnsSRV(client, ...) end
local dnsA = function(...) return helpers.dnsA(client, ...) end
local dnsExpire = helpers.dnsExpire
local ffi = require("ffi")

ffi.cdef([[
char *inet_ntoa(uint32_t in);
]])

local mocker = require "spec.fixtures.mocker"
local utils = require "kong.tools.utils"

local ws_id = utils.uuid()

local hc_defaults = {
  active = {
    timeout = 1,
    concurrency = 10,
    http_path = "/",
    healthy = {
      interval = 0,  -- 0 = probing disabled by default
      http_statuses = { 200, 302 },
      successes = 0, -- 0 = disabled by default
    },
    unhealthy = {
      interval = 0, -- 0 = probing disabled by default
      http_statuses = { 429, 404,
                        500, 501, 502, 503, 504, 505 },
      tcp_failures = 0,  -- 0 = disabled by default
      timeouts = 0,      -- 0 = disabled by default
      http_failures = 0, -- 0 = disabled by default
    },
  },
  passive = {
    healthy = {
      http_statuses = { 200, 201, 202, 203, 204, 205, 206, 207, 208, 226,
                        300, 301, 302, 303, 304, 305, 306, 307, 308 },
      successes = 0,
    },
    unhealthy = {
      http_statuses = { 429, 500, 503 },
      tcp_failures = 0,  -- 0 = circuit-breaker disabled by default
      timeouts = 0,      -- 0 = circuit-breaker disabled by default
      http_failures = 0, -- 0 = circuit-breaker disabled by default
    },
  },
}

local unset_register = {}
local function setup_block()
  local function mock_cache(cache_table, limit)
    return {
      safe_set = function(self, k, v)
        if limit then
          local n = 0
          for _, _ in pairs(cache_table) do
            n = n + 1
          end
          if n >= limit then
            return nil, "no memory"
          end
        end
        cache_table[k] = v
        return true
      end,
      get = function(self, k, _, fn, arg)
        if cache_table[k] == nil then
          cache_table[k] = fn(arg)
        end
        return cache_table[k]
      end,
    }
  end

  local cache_table = {}
  local function register_unsettter(f)
    table.insert(unset_register, f)
  end

  mocker.setup(register_unsettter, {
    kong = {
      configuration = {
        --worker_consistency = consistency,
        worker_state_update_frequency = 0.1,
      },
      core_cache = mock_cache(cache_table),
    },
    ngx = {
      ctx = {
        workspace = ws_id,
      }
    }
  })
end

local function unsetup_block()
  for _, f in ipairs(unset_register) do
    f()
  end
end


local balancers, targets

local upstream_index = 0

local function add_target(b, name, port, weight)
  if type(name) == "table" then
    local entry = name
    name = entry.name or entry[1]
    port = entry.port or entry[2]
    weight = entry.weight or entry[3]
  end

  local target = {
    upstream = b.upstream_id,
    balancer = b,
    name = name,
    nameType = dns_utils.hostnameType(name),
    addresses = {},
    port = port or 80,
    weight = weight or 100,
    totalWeight = 0,
    unavailableWeight = 0,
  }
  table.insert(b.targets, target)
  targets.resolve_targets(b.targets)

  return target

end


local function new_balancer(algorithm, hosts, count)
  upstream_index = upstream_index + 1
  local upname="upstream_" .. upstream_index
  local my_upstream = { id=upname, name=upname, ws_id=ws_id, slots=65500, healthchecks=hc_defaults, algorithm=algorithm }
  local b = (balancers.create_balancer(my_upstream, true))

  for i = 1, count do
    add_target(b, hosts[i])
  end

  return b
end

local hosts = {}
for i = 3232235521, 3232235521 + 100000 do
  table.insert(hosts, { name = ffi.string(ffi.C.inet_ntoa(i)), port = 8000, weight = 100})
end

for _, algorithm in ipairs{ "consistent-hashing", "least-connections", "round-robin" } do

  describe("[" .. algorithm .. "]", function()

    local snapshot

    setup(function()
      _G.package.loaded["kong.resty.dns.client"] = nil -- make sure module is reloaded
      _G.package.loaded["kong.runloop.balancer.targets"] = nil -- make sure module is reloaded

      local kong = {}

      _G.kong = kong

      kong.db = {}

      client = require "kong.resty.dns.client"
      targets = require "kong.runloop.balancer.targets"
      balancers = require "kong.runloop.balancer.balancers"
      local healthcheckers = require "kong.runloop.balancer.healthcheckers"
      healthcheckers.init()
      balancers.init()

      local function empty_each()
        return function() end
      end

      kong.db = {
        targets = {
          each = empty_each,
          select_by_upstream_raw = function()
            return {}
          end
        },
        upstreams = {
          each = empty_each,
          select = function() end,
        },
      }

      kong.core_cache = {
        _cache = {},
        get = function(self, key, _, loader, arg)
          local v = self._cache[key]
          if v == nil then
            v = loader(arg)
            self._cache[key] = v
          end
          return v
        end,
        invalidate_local = function(self, key)
          self._cache[key] = nil
        end
      }

    end)


    before_each(function()
      setup_block()
      assert(client.init {
        hosts = {},
        -- don't supply resolvConf and fallback to default resolver
        -- so that CI and docker can have reliable results
        -- but remove `search` and `domain`
        search = {},
      })
      snapshot = assert:snapshot()
      assert:set_parameter("TableFormatLevel", 10)
    end)


    after_each(function()
      snapshot:revert()  -- undo any spying/stubbing etc.
      unsetup_block()
      collectgarbage()
      collectgarbage()
    end)


    describe("bench", function()
      for i = 100, 100000, 100 do
          if algorithm ~= "consistent-hashing" or i <= 400 then
              it(i .. " targets", function()
                local before = collectgarbage("count")
                local b = new_balancer(algorithm, hosts, i)
                assert.is_true(b:getStatus().healthy)
                print("after creating balancer: ", collectgarbage("count") - before, " KB increase")
                print("done")
              end)
          end
      end
    end)
  end)
end

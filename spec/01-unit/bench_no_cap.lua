local Router
local atc_compat = require "kong.router.compat"
local path_handling_tests = require "spec.fixtures.router_path_handling_tests"
local tostring = tostring

local random = math.random
local function uuid()
    local template ='xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'
    return string.gsub(template, '[xy]', function (c)
        local v = (c == 'x') and random(0, 0xf) or random(8, 0xb)
        return string.format('%x', v)
    end)
end

local function reload_router(flavor, subsystem)
  _G.kong = {
    configuration = {
      router_flavor = flavor,
    },
  }

  ngx.config.subsystem = subsystem or "http" -- luacheck: ignore

  package.loaded["kong.router.atc"] = nil
  package.loaded["kong.router.compat"] = nil
  package.loaded["kong.router.expressions"] = nil
  package.loaded["kong.router"] = nil

  Router = require "kong.router"
end

local function new_router(cases, old_router)
  -- add fields expression/priority only for flavor expressions
  if kong.configuration.router_flavor == "expressions" then
    for _, v in ipairs(cases) do
      local r = v.route

      r.expression = r.expression or atc_compat.get_expression(r)
      r.priority = r.priority or atc_compat._get_priority(r)
    end
  end

  return Router.new(cases, nil, nil, old_router)
end

local service = {
  name = "service-invalid",
  protocol = "http",
}

local headers_mt = {
  __index = function(t, k)
    local u = rawget(t, string.upper(k))
    if u then
      return u
    end

    return rawget(t, string.lower(k))
  end
}


local re_match_n = 0
local re_find_n = 0


local function mock_ngx(method, request_uri, headers, queries)
  local find = ngx.re.find
  local match = ngx.re.match

  local _ngx
  _ngx = {
    log = ngx.log,
    re = {
      find = function(subject, regex, options, ctx, nth)
        re_find_n = re_find_n + 1
        return find(subject, regex, options, ctx, nth)
      end,
      match = function(subject, regex, options, ctx, res_table)
        re_match_n = re_match_n + 1
        return match(subject, regex, options, ctx, res_table)
      end,
    },
    var = setmetatable({
      request_uri = request_uri,
      http_kong_debug = headers.kong_debug
    }, {
      __index = function(_, key)
        if key == "http_host" then
          return headers.host
        end
      end
    }),
    req = {
      get_method = function()
        return method
      end,
      get_headers = function()
        return setmetatable(headers, headers_mt)
      end,
      get_uri_args = function()
        return queries
      end,
    }
  }

  return _ngx
end


function generate_scenarios(routes)
    local s = {}

    local s_len = 0

    local s0 = {
      name     = "service-0",
      host     = "upstream-service",
      protocol = "http"
    }

    s_len = s_len + 1
    s[s_len] = {
        service    = s0,
        route      = {
          id = uuid(),
          paths    = { "~/service-0/api/v1/mockroute-0/[a-zA-Z0-9]+/mockpath/?$" },
          hosts = { "service.a.api.v1.mockroute.a.mockpath",
                    "dataplane.kong.benchmark.svc.cluster.local",
                    "dataplane.kong.benchmark.svc",
                  },
          regex_priority = 100,
        },
    }

    s_len  = s_len + 1
    s[s_len] = {
        service    = s0,
        route      = {
          id = uuid(),
          paths    = { "~/service-0/api/v1/mockroute-1/[a-zA-Z0-9]+/mockpath/?$" },
          hosts = { "service.a.api.v1.mockroute.a.mockpath",
                    "dataplane.kong.benchmark.svc.cluster.local",
                    "dataplane.kong.benchmark.svc",
                  },
          regex_priority = 100,
        },
    }

    for i = 1, routes * 0.05 / 10 - 1 do
        local ser = {
          name     = "service-" .. i,
          host     = "upstream-service",
          protocol = "http"
        }

        s_len  = s_len + 1
        s[s_len] = {
            service    = ser,
            route      = {
              id = uuid(),
              paths    = { "~/service-" .. i .. "/api/v1/mockroute-0/[a-zA-Z0-9]+/mockpath/?$" },
              hosts = { "service.a.api.v1.mockroute.a.mockpath",
                        "dataplane.kong.benchmark.svc.cluster.local",
                        "dataplane.kong.benchmark.svc",
                      },
              regex_priority = 90,
            },
        }

        for j = 1, 4 do
            s_len  = s_len + 1
            s[s_len] = {
                service    = ser,
                route      = {
                  id = uuid(),
                  paths    = { "~/service-" .. i .. "/api/v1/mockroute-" .. j .. "/[a-zA-Z0-9]+/mockpath/?$" },
                  hosts = { "service.a.api.v1.mockroute.a.mockpath",
                            "dataplane.kong.benchmark.svc.cluster.local",
                            "dataplane.kong.benchmark.svc",
                          },
                  regex_priority = 90,
                },
            }
        end

        for j = 5, 10 do
            s_len  = s_len + 1
            s[s_len] = {
                service    = ser,
                route      = {
                  id = uuid(),
                  paths    = { "~/service-" .. i .. "/api/v1/mockroute-" .. j .. "/mockpath/?$" },
                  hosts = { "service.a.api.v1.mockroute.a.mockpath",
                            "dataplane.kong.benchmark.svc.cluster.local",
                            "dataplane.kong.benchmark.svc",
                          },
                  regex_priority = 90,
                },
            }
        end
    end

    for i = routes * 0.05 / 10, routes * 0.50 / 10 - 1 do
        local ser = {
          name     = "service-" .. i,
          host     = "upstream-service",
          protocol = "http"
        }

        s_len  = s_len + 1
        s[s_len] = {
            service    = ser,
            route      = {
              id = uuid(),
              paths    = { "~/service-" .. i .. "/api/v1/mockroute-0/[a-zA-Z0-9]+/mockpath/?$", },
              hosts = { "service.a.api.v1.mockroute.a.mockpath",
                        "dataplane.kong.benchmark.svc.cluster.local",
                        "dataplane.kong.benchmark.svc",
                      },
              regex_priority = 80,
            },
        }

        for j = 1, 4 do
            s_len  = s_len + 1
            s[s_len] = {
                service    = ser,
                route      = {
                  id = uuid(),
                  paths    = { "~/service-" .. i .. "/api/v1/mockroute-" .. j .. "/[a-zA-Z0-9]+/mockpath/?$" },
                  hosts = { "service.a.api.v1.mockroute.a.mockpath",
                            "dataplane.kong.benchmark.svc.cluster.local",
                            "dataplane.kong.benchmark.svc",
                          },
                  regex_priority = 80,
                },
            }
        end

        for j = 5, 10 do
            s_len  = s_len + 1
            s[s_len] = {
                service    = ser,
                route      = {
                  id = uuid(),
                  paths    = { "~/service-" .. i .. "/api/v1/mockroute-" .. j .. "/mockpath/?$" },
                  hosts = { "service.a.api.v1.mockroute.a.mockpath",
                            "dataplane.kong.benchmark.svc.cluster.local",
                            "dataplane.kong.benchmark.svc",
                          },
                  regex_priority = 80,
                },
            }
        end
    end

    for i = routes * 0.50 / 10, routes / 10 - 1 do
        local ser = {
          name     = "service-" .. i,
          host     = "upstream-service",
          protocol = "http"
        }

        s_len  = s_len + 1
        s[s_len] = {
            service    = ser,
            route      = {
              id = uuid(),
              paths    = { "~/service-" .. i .. "/api/v1/mockroute-0/[a-zA-Z0-9]+/mockpath/?$", },
              hosts = { "service.a.api.v1.mockroute.a.mockpath",
                        "dataplane.kong.benchmark.svc.cluster.local",
                        "dataplane.kong.benchmark.svc",
                      },
              regex_priority = 70,
            },
        }

        for j = 1, 4 do
            s_len  = s_len + 1
            s[s_len] = {
                service    = ser,
                route      = {
                  id = uuid(),
                  paths    = { "~/service-" .. i .. "/api/v1/mockroute-" .. j .. "/[a-zA-Z0-9]+/mockpath/?$" },
                  hosts = { "service.a.api.v1.mockroute.a.mockpath",
                            "dataplane.kong.benchmark.svc.cluster.local",
                            "dataplane.kong.benchmark.svc",
                          },
                  regex_priority = 70,
                },
            }
        end

        for j = 5, 10 do
            s_len  = s_len + 1
            s[s_len] = {
                service    = ser,
                route      = {
                  id = uuid(),
                  paths    = { "~/service-" .. i .. "/api/v1/mockroute-" .. j .. "/mockpath/?$" },
                  hosts = { "service.a.api.v1.mockroute.a.mockpath",
                            "dataplane.kong.benchmark.svc.cluster.local",
                            "dataplane.kong.benchmark.svc",
                          },
                  regex_priority = 70,
                },
            }
        end
    end

    return s
end

local HOSTS = {
  'service.a.api.v1.mockroute.a.mockpath',
  'dataplane.kong.benchmark.svc.cluster.local',
  'dataplane.kong.benchmark.svc'
}


local function get_host()
  return HOSTS[random(3)]
end


local function get_cached_host()
  return HOSTS[1]
end


local function get_cached_url()
  local service_id = random(1000, 1001);
  local route_id = random(0, 9);

  if route_id <= 4 then
    return "/service-" .. service_id .. "/api/v1/mockroute-" .. route_id .."/fixed/mockpath", true
  end

  return "/service-" .. service_id .. "/api/v1/mockroute-" .. route_id .. "/mockpath", true
end


local function gen_random_string()
  local st = tostring(math.random()):sub(3)
  return string.format("%.14f", math.random()):sub(3)
end


local function get_top_traffic()
  local service_id = 0
  local route_id = random(0, 1);
  local segment = gen_random_string() .. gen_random_string()

  return "/service-" .. service_id .. "/api/v1/mockroute-" .. route_id .. "/" .. segment .. "/mockpath", false
end


local function get_second_traffic()
  local service_id = random(1, 99)
  local route_id = random(0, 9);
  local segment = gen_random_string() .. gen_random_string()

  if route_id <= 4 then
    return "/service-" .. service_id .. "/api/v1/mockroute-" .. route_id .. "/" .. segment .. "/mockpath", false
  end

  return "/service-" .. service_id .. "/api/v1/mockroute-" .. route_id .. "/mockpath", false
end


local function get_third_traffic()
  local service_id = random(100, 999)
  local route_id = random(0, 9);
  local segment = gen_random_string() .. gen_random_string()

  if route_id <= 4 then
    return "/service-" .. service_id .. "/api/v1/mockroute-" .. route_id .. "/" .. segment .. "/mockpath", false
  end

  return "/service-" .. service_id .. "/api/v1/mockroute-" .. route_id .. "/mockpath", false
end


local function get_remaining_traffic()
  local service_id = random(1000, 1999)
  local route_id = random(0, 9);
  local segment = gen_random_string() .. gen_random_string()

  if route_id <= 4 then
    return "/service-" .. service_id .. "/api/v1/mockroute-" .. route_id .. "/" .. segment .. "/mockpath", false
  end

  return "/service-" .. service_id .. "/api/v1/mockroute-" .. route_id .. "/mockpath", false
end


local counter = 0
local target_counters = {}

for i = 1, 100 do
  target_counters[i] = false
end

-- 20% of the traffic is cached
for i = 1, 20 do
  target_counters[math.floor(random() * 100)] = true
end

local function get_url()
  counter = (counter + 1) % 100

  if target_counters[counter] then
    return get_cached_url()
  end

  local rand = random(1, 10000)

  if (rand < 6000) then
    return get_top_traffic()
  end

  if (rand < 8000) then
    return get_second_traffic()
  end

  if (rand < 9500) then
    return get_third_traffic()
  end

  return get_remaining_traffic()
end


for _, flavor in ipairs({ "traditional", "traditional_compatible" }) do
  describe("Router (flavor = " .. flavor .. ")", function()
    reload_router(flavor)
    math.randomseed(12345) -- ensure predictability in UUID

    local use_case_routes = generate_scenarios(20000)
    local router = assert(new_router(use_case_routes))

    local f = io.open("regexes.txt", "w")
    for _, item in ipairs(use_case_routes) do
        assert(#item.route.paths == 1)
        f:write(item.route.paths[1]:sub(2) .. "\n")
    end
    f:close()

    describe("exec()", function()
      it("20000 routes", function()
        local headers = { host = "dataplane.kong.benchmark.svc.cluster.local" }
        local _ngx = mock_ngx("GET", "/service-2000/api/v1/mockroute-5/foo/mockpath", headers)
        router._set_ngx(_ngx)

        for i = 1, 10000 do
          local url, cached = get_url()
          local host = cached and get_cached_host() or get_host()

          _ngx.var.request_uri = url
          headers.host = host

          local match_t = router:exec()
          assert(match_t, url .. " did not match")
          if i == 1 then
              print(require('inspect')(match_t))
          end
        end

        print("re_match_n", re_match_n, "\n")
        print("re_find_n", re_find_n, "\n")
      end)
    end)
  end)
end   -- local flavor = "expressions"

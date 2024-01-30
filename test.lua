#!/usr/bin/env resty

setmetatable(_G, nil)

local Router = require "kong.router"
local atc_compat = require "kong.router.compat"

local function reload_router(flavor, subsystem)
  _G.kong = {
    configuration = {
      router_flavor = flavor,
    },
  }

  ngx.config.subsystem = subsystem or "http" -- luacheck: ignore

  package.loaded["kong.router.fields"] = nil
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

local function mock_ngx(method, request_uri, headers, queries)
  local _ngx
  _ngx = {
    log = ngx.log,
    re = ngx.re,
    var = setmetatable({
      request_uri = request_uri,
      http_kong_debug = headers.kong_debug
    }, {
      __index = function(_, key)
        if key == "http_host" then
          --spy_stub.nop()
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

--------

local flavor = "traditional_compatible"
reload_router(flavor)

local service = {
  name = "service-invalid",
  protocol = "http",
}

local use_case = {
  {
    service = service,
    route   = {
      id = "e8fb37f1-102d-461e-9c51-6608a6bb8101",
      paths = {
        "/foo",
      },
      headers = {
        test1 = { "Quote" },
      },
    },
  },
}

local router = assert(new_router(use_case))

local ctx = {}
local _ngx = mock_ngx("GET", "/foo/bar", { test1 = "QUOTE", })
router._set_ngx(_ngx)

ngx.update_time()
local t = ngx.now()

for i =1, 100*1000 do
  local match_t = router:exec(ctx)
  assert(match_t)
  --assert.truthy(match_t)
end

ngx.update_time()
print("time = ", ngx.now() - t)

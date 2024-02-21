local helpers = require "spec.helpers"
local cjson = require "cjson"
local utils = require "kong.tools.utils"
local tablex = require "pl.tablex"
local fetch_from_cp = require "kong.db.utils".fetch_from_cp

local strategy = "postgres"

local DP_PREFIX = "dp-test"
local CP_PREFIX = "cp-test"


describe("CP/DP communication #" .. strategy, function()

  lazy_setup(function()
    helpers.get_db_utils(strategy) -- runs migrations

    assert(helpers.start_kong({
      lazy_loaded_consumers = "on",
      role = "control_plane",
      cluster_cert = "spec/fixtures/kong_clustering.crt",
      cluster_cert_key = "spec/fixtures/kong_clustering.key",
      database = strategy,
      prefix = CP_PREFIX,
      db_update_frequency = 0.1,
      cluster_listen = "127.0.0.1:9005",
      nginx_conf = "spec/fixtures/custom_nginx.template",
    }))

    assert(helpers.start_kong({
      lazy_loaded_consumers = "on",
      role = "data_plane",
      database = "off",
      prefix = DP_PREFIX,
      cluster_cert = "spec/fixtures/kong_clustering.crt",
      cluster_cert_key = "spec/fixtures/kong_clustering.key",
      cluster_control_plane = "127.0.0.1:9005",
      proxy_listen = "0.0.0.0:9002",
      nginx_conf = "spec/fixtures/custom_nginx.template",
    }))
  end)

  lazy_teardown(function()
    helpers.stop_kong(DP_PREFIX)
    helpers.stop_kong(CP_PREFIX)
  end)

  it("enables protected endpoints", function()
    local result, err = fetch_from_cp("/events")
    print("result = " .. require("inspect")(result))

  end)
end)

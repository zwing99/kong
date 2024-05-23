local helpers = require "spec.helpers"

for _, strategy in helpers.each_strategy({"postgres"}) do
  describe("Plugin: acme (handler.access) worked with [#" .. strategy .. "]", function()
    local domain = "mydomain.test"
    local dp_prefix = "servroot2"
    local dp_logfile, bp, db

    lazy_setup(function()
      bp, db = helpers.get_db_utils(strategy, {
        "services",
        "routes",
        "plugins",
      }, { "acme", })

      assert(bp.routes:insert {
        paths = { "/" },
      })

      assert(helpers.start_kong({
        role = "control_plane",
        database = strategy,
        cluster_cert = "spec/fixtures/kong_clustering.crt",
        cluster_cert_key = "spec/fixtures/kong_clustering.key",
        lua_ssl_trusted_certificate = "spec/fixtures/kong_clustering.crt",
        cluster_listen = "127.0.0.1:9005",
        cluster_telemetry_listen = "127.0.0.1:9006",
        nginx_conf = "spec/fixtures/custom_nginx.template",
        admin_listen = "0.0.0.0:9001",
        proxy_listen = "off",
      }))

      assert(helpers.start_kong({
        role = "data_plane",
        database = "off",
        prefix = dp_prefix,
        cluster_cert = "spec/fixtures/kong_clustering.crt",
        cluster_cert_key = "spec/fixtures/kong_clustering.key",
        lua_ssl_trusted_certificate = "spec/fixtures/kong_clustering.crt",
        cluster_control_plane = "127.0.0.1:9005",
        cluster_telemetry_endpoint = "127.0.0.1:9006",
        admin_listen = "off",
        proxy_listen = "0.0.0.0:9002",
      }))
      dp_logfile = helpers.get_running_conf(dp_prefix).nginx_err_logs
    end)

    lazy_teardown(function()
      helpers.stop_kong("servroot2")
      helpers.stop_kong()
    end)

    describe("\"kong\" storage mode in Hybrid mode", function()
      lazy_setup(function ()
        local admin_client = helpers.admin_client(nil, 9001)
        local res = assert(admin_client:send {
          method  = "POST",
          path    = "/plugins",
          body    = {
            name = "acme",
            config = {
              account_email = "test@test.com",
              api_uri = "https://api.acme.org",
              domains = { domain },
              storage = "kong",
              storage_config = {
                kong = {},
              },
            },
          },
          headers = {
            ["Content-Type"] = "application/json",
          }
        })
        assert.res_status(201, res)
        admin_client:close()
      end)

      lazy_teardown(function ()
        db:truncate("plugins")
      end)

      it("sanity test", function()
        local proxy_client = helpers.http_client("127.0.0.1", 9002)
        helpers.wait_until(function()
          local res = assert(proxy_client:send {
            method  = "GET",
            path    = "/.well-known/acme-challenge/x",
            headers =  { host = domain }
          })

          if res.status ~= 404 then
            return false
          end

          local body = res:read_body()
          return body == "Not found\n"
        end, 10)
        proxy_client:close()
      end)
    end)

    describe("\"redis\" storage mode in Hybrid mode", function()
      lazy_setup(function ()
        local admin_client = helpers.admin_client(nil, 9001)
        local res = assert(admin_client:send {
          method  = "POST",
          path    = "/plugins",
          body    = {
            name = "acme",
            config = {
              account_email = "test@test.com",
              api_uri = "https://api.acme.org",
              domains = { domain },
              storage = "kong",
              storage_config = {
                redis = {
                  host = helpers.redis_host,
                  port = helpers.redis_port,
                },
              },
            },
          },
          headers = {
            ["Content-Type"] = "application/json",
          }
        })
        assert.res_status(201, res)
        admin_client:close()
      end)

      lazy_teardown(function ()
        db:truncate("plugins")
      end)

      before_each(function()
        helpers.clean_logfile(dp_logfile)
      end)

      it("sanity test", function()
        local proxy_client = helpers.http_client("127.0.0.1", 9002)
        helpers.wait_until(function()
          local res = assert(proxy_client:send {
            method  = "GET",
            path    = "/.well-known/acme-challenge/x",
            headers =  { host = domain }
          })

          if res.status ~= 404 then
            return false
          end

          local body = res:read_body()
          return body == "Not found\n"
        end, 10)
        assert.logfile(dp_logfile).has.no.line(
          "config%.storage_config%.redis%.(namespace|scan_count) is deprecated",
          false,
          10
        )
        proxy_client:close()
      end)
    end)
  end)
end

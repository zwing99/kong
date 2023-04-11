local helpers = require "spec.helpers"
local encode = require "cjson".encode

for _, strategy in helpers.each_strategy() do
  describe("Plugin: response-transformer (filter) [#" .. strategy .. "]", function()
    local proxy_client

    lazy_setup(function()
      require("kong.runloop.wasm").init({
        wasm = true,
        wasm_modules_parsed = {
          { name = "response_transformer" },
        },
      })

      local bp, db = helpers.get_db_utils(strategy, {
        "routes",
        "services",
        "plugins",
        "filter_chains",
      })

      require("kong.runloop.wasm").enable({
        { name = "response_transformer" },
      })

      -- lua plugin setup
      do
        local route1 = bp.routes:insert({
          hosts = { "lua-1.test" },
        })

        local route2 = bp.routes:insert({
          hosts = { "lua-2.test" },
        })

        local route3 = bp.routes:insert({
          hosts = { "lua-3.test" },
        })

        bp.plugins:insert {
          route = { id = route1.id },
          name     = "response-transformer",
          config   = {
            remove    = {
              headers = {"Access-Control-Allow-Origin"},
              json    = {"url"}
            }
          }
        }

        bp.plugins:insert {
          route = { id = route2.id },
          name     = "response-transformer",
          config   = {
            replace = {
              json  = {
                "headers:/hello/world",
                "uri_args:this is a / test",
                "url:\"wot\""
              }
            }
          }
        }

        bp.plugins:insert {
          route = { id = route3.id },
          name     = "response-transformer",
          config   = {
            remove = {
              json  = {"ip"}
            }
          }
        }

        bp.plugins:insert {
          route = { id = route3.id },
          name     = "basic-auth",
        }
      end

      -- wasm filter setup
      do
        local route1 = bp.routes:insert({
          hosts = { "wasm-1.test" },
        })

        local route2 = bp.routes:insert({
          hosts = { "wasm-2.test" },
        })

        local route3 = bp.routes:insert({
          hosts = { "wasm-3.test" },
        })

        bp.filter_chains:insert {
          route = { id = route1.id },
          filters = {
            { name = "response_transformer",
              config = encode {
                remove    = {
                  headers = {"Access-Control-Allow-Origin"},
                  json    = {"url"}
                }
              }
            }
          }
        }

        bp.filter_chains:insert {
          route = { id = route2.id },
          filters = {
            { name = "response_transformer",
              config  = encode {
                replace = {
                  json  = {
                    "headers:/hello/world",
                    "uri_args:this is a / test",
                    "url:\"wot\""
                  }
                }
              }
            }
          }
        }

        bp.filter_chains:insert {
          route = { id = route3.id },
          filters = {
            { name = "response_transformer",
              config  = encode {
                remove = {
                  json  = {"ip"}
                }
              }
            }
          }
        }

        bp.plugins:insert {
          route = { id = route3.id },
          name     = "basic-auth",
        }
      end

      assert(helpers.start_kong({
        database   = strategy,
        nginx_conf = "spec/fixtures/custom_nginx.template",
        wasm       = true,
      }))
    end)

    lazy_teardown(function()
      helpers.stop_kong()
    end)

    before_each(function()
      proxy_client = helpers.proxy_client()
    end)

    after_each(function()
      if proxy_client then
        proxy_client:close()
      end
    end)

    for _, mode in ipairs({ "lua", "wasm" }) do
      describe(mode, function()
        describe("parameters", function()
          it("remove a parameter", function()
            local res = assert(proxy_client:send {
              method  = "GET",
              path    = "/get",
              headers = {
                host  = mode .. "-1.test"
              }
            })
            assert.response(res).has.status(200)
            local json = assert.response(res).has.jsonbody()
            assert.is_nil(json.url)
          end)
          it("remove a header", function()
            local res = assert(proxy_client:send {
              method  = "GET",
              path    = "/response-headers",
              headers = {
                host  = mode .. "-1.test"
              }
            })
            assert.response(res).has.status(200)
            assert.response(res).has.jsonbody()
            assert.response(res).has.no.header("access-control-allow-origin")
          end)
          it("replace a body parameter on GET", function()
            local res = assert(proxy_client:send {
              method  = "GET",
              path    = "/get",
              headers = {
                host  = mode .. "-2.test"
              }
            })
            assert.response(res).status(200)
            local json = assert.response(res).has.jsonbody()
            helpers.intercept(json)
            assert.equals([[/hello/world]], json.headers)
            assert.equals([["wot"]], json.url)
            assert.equals([[this is a / test]], json.uri_args)
          end)
        end)

        describe("regressions", function()
          it("does not throw an error when request was short-circuited in access phase", function()
            -- basic-auth and response-transformer applied to route makes request
            -- without credentials short-circuit before the response-transformer
            -- access handler gets a chance to be executed.
            --
            -- Regression for https://github.com/Kong/kong/issues/3521
            local res = assert(proxy_client:send {
              method  = "GET",
              path    = "/get",
              headers = {
                host  = mode .. "-3.test"
              }
            })

            assert.response(res).status(401)
          end)
        end)
      end)
    end
  end)
end

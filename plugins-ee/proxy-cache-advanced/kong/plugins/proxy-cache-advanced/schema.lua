-- This software is copyright Kong Inc. and its licensors.
-- Use of the software is subject to the agreement between your organization
-- and Kong Inc. If there is no such agreement, use is governed by and
-- subject to the terms of the Kong Master Software License Agreement found
-- at https://konghq.com/enterprisesoftwarelicense/.
-- [ END OF LICENSE 0867164ffc95e54f04670b5169c09574bdbd9bba ]

local strategies = require "kong.plugins.proxy-cache-advanced.strategies"
local redis      = require "kong.enterprise_edition.redis"
local typedefs   = require "kong.db.schema.typedefs"



local ngx = ngx


local function check_shdict(name)
  if not ngx.shared[name] then
    return false, "missing shared dict '" .. name .. "'"
  end

  return true
end


return {
  name = "proxy-cache-advanced",
  fields = {
    { protocols = typedefs.protocols_http },
    { config = {
        type = "record",
        fields = {
          { response_code = {
            type = "array",
            default = { 200, 301, 404 },
            elements = { type = "integer", between = {100, 900} },
            len_min = 1,
            required = true,
          }},
          { request_method = {
            type = "array",
            default = { "GET", "HEAD" },
            elements = {
              type = "string",
              one_of = { "HEAD", "GET", "POST", "PATCH", "PUT" },
            },
            required = true
          }},
          { content_type = {
            type = "array",
            default = { "text/plain","application/json" },
            elements = { type = "string" },
            required = true,
          }},
          { cache_ttl = {
            type = "integer",
            default = 300,
            gt = 0,
          }},
          { strategy = {
            type = "string",
            one_of = strategies.STRATEGY_TYPES,
            required = true,
          }},
          { cache_control = {
            type = "boolean",
            default = false,
            required = true,
          }},
          { ignore_uri_case = {
            type = "boolean",
            default = false,
            required = false,
          }},
          { storage_ttl = {
            type = "integer",
          }},
          { memory = {
            type = "record",
            fields = {
              { dictionary_name = {
                type = "string",
                required = true,
                default = "kong_db_cache",
              }},
            },
          }},
          { vary_query_params = {
            type = "array",
            elements = { type = "string" },
          }},
          { vary_headers = {
            type = "array",
            elements = { type = "string" },
          }},
          { redis = redis.config_schema }, -- redis schema is provided by
                                           -- Kong Enterprise, since it's useful
                                           -- for other plugins (e.g., rate-limiting)
          { bypass_on_err = {
            type = "boolean",
            default = false,
          }},
        },
      }
    },
  },

  entity_checks = {
    { custom_entity_check = {
      field_sources = { "config" },
      fn = function(entity)
        local config = entity.config

        if config.strategy == "memory" then
          local ok, err = check_shdict(config.memory.dictionary_name)
          if not ok then
            return nil, err
          end

        elseif entity.config.strategy == "redis" then
          if config.redis.host == ngx.null
             and config.redis.sentinel_addresses == ngx.null
             and config.redis.cluster_addresses == ngx.null then
            return nil, "No redis config provided"
          end
        end

        return true
      end
    }},
  },
}
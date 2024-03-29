local kong_global = require "kong.global"
local PDK = require "kong.pdk"
local constants = require "kong.constants"
local Runtime = require "kong.components.runtime"


local DECLARATIVE_LOAD_KEY = constants.DECLARATIVE_LOAD_KEY

local reset_kong_shm
do
  local preserve_keys = {
    "kong:node_id",
    constants.DYN_LOG_LEVEL_KEY,
    constants.DYN_LOG_LEVEL_TIMEOUT_AT_KEY,
    "events:requests",
    "events:requests:http",
    "events:requests:https",
    "events:requests:h2c",
    "events:requests:h2",
    "events:requests:grpc",
    "events:requests:grpcs",
    "events:requests:ws",
    "events:requests:wss",
    "events:requests:go_plugins",
    "events:km:visit",
    "events:streams",
    "events:streams:tcp",
    "events:streams:tls",
  }

  reset_kong_shm = function(config)
    local kong_shm = ngx.shared.kong

    local preserved = {}

    if config.database == "off" then
      if not (config.declarative_config or config.declarative_config_string) then
        preserved[DECLARATIVE_LOAD_KEY] = kong_shm:get(DECLARATIVE_LOAD_KEY)
      end
    end

    for _, key in ipairs(preserve_keys) do
      preserved[key] = kong_shm:get(key) -- ignore errors
    end

    kong_shm:flush_all()
    for key, value in pairs(preserved) do
      kong_shm:set(key, value)
    end
    kong_shm:flush_expired(0)
  end
end


local function init_handler()
  local pl_path = require "pl.path"
  local conf_loader = require "kong.internal.conf_loader"

  -- check if kong global is the correct one
  if not kong.version then
    error("configuration error: make sure your template is not setting a " ..
          "global named 'kong' (please use 'Kong' instead)")
  end

  -- special math.randomseed from kong.globalpatches not taking any argument.
  -- Must only be called in the init or init_worker phases, to avoid
  -- duplicated seeds.
  math.randomseed()

  -- retrieve kong_config
  local conf_path = pl_path.join(ngx.config.prefix(), ".kong_env")
  local config = assert(conf_loader(conf_path, nil, { from_kong_env = true }))

  reset_kong_shm(config)

  Runtime.register_globals("configuration", setmetatable({
      remove_sensitive = function()
        local conf_loader = require "kong.internal.conf_loader"
        return conf_loader.remove_sensitive(config)
      end,
    }, {
      __index = function(_, v)
        return config[v]
      end,

      __newindex = function()
        error("cannot write to configuration", 2)
      end,
    })
  )

  PDK.new(_G.kong)

  return true
end

return init_handler
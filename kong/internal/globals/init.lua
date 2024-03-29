local constants = require "kong.constants"
local VERSION = require "kong.config".VERSION

local globals = {}


function globals.apply_patches()
  require("kong.internal.globals.patches")()
end

function globals.create_G_kong()
  -- no versioned PDK for plugins for now
  _G.kong = {
    -- unified version string for CE and EE
    version = tostring(VERSION),
    version_num = tonumber(string.format("%d%.2d%.2d",
                            VERSION.major * 100,
                            VERSION.minor * 10,
                            VERSION.patch)),

    configuration = nil,
  }
end

function globals.sanity_check()
  -- let's ensure the required shared dictionaries are
  -- declared via lua_shared_dict in the Nginx conf

  for _, dict in ipairs(constants.DICTS) do
    if not ngx.shared[dict] then
      return error("missing shared dict '" .. dict .. "' in Nginx "          ..
                    "configuration, are you using a custom template? "        ..
                    "Make sure the 'lua_shared_dict " .. dict .. " [SIZE];' " ..
                    "directive is defined.")
    end
  end

  -- if we're running `nginx -t` then don't initialize
  if os.getenv("KONG_NGINX_CONF_CHECK") then
    return {
      init = function() end,
    }
  end
end

function globals.init()
  globals.sanity_check()
  globals.apply_patches()
  globals.create_G_kong()
end

return globals
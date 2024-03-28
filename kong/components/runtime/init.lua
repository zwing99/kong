local Runtime = {}

local components = {}

require "kong.components.runtime.preup"

local function resolve_dependency(components)
  for name, mod in pairs(components) do
    print(name, tostring(mod))
  end
end

function Runtime.load_deployment(name)
  local deployment_def = require ("kong.deployment." .. name .. ".components")

  for _, k in ipairs(deployment_def) do
    local pok, perr = pcall(require, "kong.components." .. k)
    if not pok then
      error("Component " .. k .. " not found: " .. perr, 2)
    end
    components[k] = perr
  end

  return resolve_dependency(components)
end

function Runtime.init()
  return require("kong").init()
end

function Runtime.init_worker()
  return require("kong").init_worker()
end

function Runtime.balancer()
  return require("kong").balancer()
end

function Runtime.ssl_certificate()
  return require("kong").ssl_certificate()
end

function Runtime.rewrite()
  return require("kong").rewrite()
end

function Runtime.access()
  return require("kong").access()
end

function Runtime.header_filter()
  return require("kong").header_filter()
end

function Runtime.body_filter()
  return require("kong").body_filter()
end

function Runtime.log()
  return require("kong").log()
end

function Runtime.handle_error()
  return require("kong").handle_error()
end

function Runtime.admin_content()
  return require("kong").admin_content()
end

function Runtime.admin_header_filter()
  return require("kong").admin_header_filter()
end 

function Runtime.status_content()
  return require("kong").status_content()
end

function Runtime.status_header_filter()
  return require("kong").status_header_filter()
end

function Runtime.serve_cluster_listener()
  return require("kong").serve_cluster_listener()
end

return Runtime
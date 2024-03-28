local endpoints = require "kong.components.restful.endpoints"


return {
  -- deactivate endpoint (use /certificates/sni instead)
  ["/snis/:snis/certificate"] = endpoints.disable,
}

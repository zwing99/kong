local endpoints = require "kong.components.restful.endpoints"


return {
  -- deactivate endpoints (use /upstream/{upstream}/targets instead)
  ["/targets"] = endpoints.disable,
  ["/targets/:targets"] = endpoints.disable,
  ["/targets/:targets/upstream"] = endpoints.disable,
}

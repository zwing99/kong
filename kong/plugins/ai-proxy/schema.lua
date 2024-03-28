local typedefs = require("kong.components.datastore.schema.typedefs")
local llm = require("kong.internal.llm")

return {
  name = "ai-proxy",
  fields = {
    { protocols = typedefs.protocols_http },
    { consumer = typedefs.no_consumer },
    { service = typedefs.no_service },
    { config = llm.config_schema },
  },
}

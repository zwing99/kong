local typedefs = require "kong.components.datastore.schema.typedefs"

return {
  name = "random",
  fields = {
    {
      config = {
        type = "record",
        fields = {
          { prefix = { type = "string" } },
          { suffix = { type = "string" } },
          { ttl           = typedefs.ttl },
          { neg_ttl       = typedefs.ttl },
          { resurrect_ttl = typedefs.ttl },
        },
      },
    },
  },
}

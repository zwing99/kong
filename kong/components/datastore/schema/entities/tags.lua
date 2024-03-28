local typedefs = require "kong.components.datastore.schema.typedefs"

return {
  name         = "tags",
  primary_key  = { "tag" },
  endpoint_key = "tag",
  dao          = "kong.internal.dao.tags",
  db_export = false,

  fields = {
    { tag          = typedefs.tag, },
    { entity_name  = { description = "The name of the Kong Gateway entity being tagged.", type = "string", required = true }, },
    { entity_id    = typedefs.uuid { required = true }, },
  }
}

local typedefs = require "kong.components.datastore.schema.typedefs"

return {
  {
    dao = "kong.plugins.acl.acls",
    name = "acls",
    primary_key = { "id" },
    cache_key = { "consumer", "group" },
    workspaceable = true,
    fields = {
      { id = typedefs.uuid },
      { created_at = typedefs.auto_timestamp_s },
      { consumer = { type = "foreign", reference = "consumers", required = true, on_delete = "cascade" }, },
      { group = { type = "string", required = true } },
      { tags  = typedefs.tags },
    },
  },
}

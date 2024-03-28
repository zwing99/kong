local typedefs = require "kong.components.datastore.schema.typedefs"


return {
  {
    dao = "kong.plugins.plugin-with-custom-dao.custom_dao",
    name = "custom_dao",
    primary_key = { "id" },
    fields = {
      { id = typedefs.uuid },
    },
  },
}

local typedefs = require "kong.db.schema.typedefs"
local jq = require "resty.jq"

return {
  protocols = {
    protocols = typedefs.protocols_http
  },
  jq_program = {
    required = false,
    type = "string",
    custom_validator = function(jq_program)
      local jqp = jq.new()
      return jqp:compile(jq_program)
    end,
  },
  jq_options = {
    required = false,
    type = "record",
    default = {},
    fields = {
      {
        compact_output = {
          required = true,
          type = "boolean",
          default = true,
        },
      },
      {
        raw_output = {
          required = true,
          type = "boolean",
          default = false,
        },
      },
      {
        join_output = {
          required = true,
          type = "boolean",
          default = false,
        },
      },
      {
        ascii_output = {
          required = true,
          type = "boolean",
          default = false,
        },
      },
      {
        sort_keys = {
          required = true,
          type = "boolean",
          default = false,
        },
      },
    },
  },
  if_media_type = {
    required = false,
    type = "array",
    elements = {
      type = "string",
    },
    default = { "application/json" },
  },
  if_status_code = {
    required = false,
    type = "array",
    elements = {
      type = "integer",
      between = {
        100,
        599
      },
    },
    default = { 200 },
  },
}


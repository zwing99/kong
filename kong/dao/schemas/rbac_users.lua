local Errors = require "kong.dao.errors"
local rbac = require "kong.rbac"

local LOG_ROUNDS = 9

return {
  table = "rbac_users",
  workspaceable = true,
  primary_key = { "id" },
  cache_key = { "name" },
  fields = {
    id = {
      type = "id",
      dao_insert_value = true,
      required = true,
    },
    name = {
      type = "string",
      required = true,
      unique = true,
    },
    user_token = {
      type = "string",
      required = true,
      unique = true,
    },
    user_token_ident = {
      type = "string",
    },
    comment = {
      type = "string",
    },
    enabled = {
      type = "boolean",
      required = true,
      default = true,
    },
    created_at = {
      type = "timestamp",
      immutable = true,
      dao_insert_value = true,
      required = true,
    },
  },
  self_check = function(schema, user, dao, is_updating)
    local ident = rbac.get_token_ident(user.user_token)

    -- first make sure it's not a duplicate
    local token_users, err = rbac.retrieve_token_users(ident, "user_token_ident")
    if err then
      return nil, err
    end

    if rbac.validate_rbac_token(token_users, user.user_token) then
      return false, Errors.schema("duplicate user token")
    end

    -- if it doesnt look like a bcrypt digest, Do The Thing
    if user.user_token and not string.find(user.user_token, "^%$2b%$") then
      user.user_token_ident = ident

      local bcrypt = require "bcrypt"

      local digest = bcrypt.digest(user.user_token, LOG_ROUNDS)
      user.user_token = digest
    end
  end
}

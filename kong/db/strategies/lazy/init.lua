local declarative_config = require "kong.db.schema.others.declarative_config"
local workspaces = require "kong.workspaces"
local lmdb = require("resty.lmdb")
local marshaller = require("kong.db.declarative.marshaller")
local yield = require("kong.tools.yield").yield
local unique_field_key = require("kong.db.declarative").unique_field_key
local fetch_from_cp = require "kong.db.utils".fetch_from_cp

local kong = kong
local fmt = string.format
local type = type
local next = next
local sort = table.sort
local pairs = pairs
local match = string.match
local assert = assert
local tostring = tostring
local tonumber = tonumber
local encode_base64 = ngx.encode_base64
local decode_base64 = ngx.decode_base64
local null = ngx.null
local unmarshall = marshaller.unmarshall
local lmdb_get = lmdb.get
local get_workspace_id = workspaces.get_workspace_id


local lazy = {}


local _mt = {}
_mt.__index = _mt


local function ws(schema, options)
  if not schema.workspaceable then
    return ""
  end

  if options then
    if options.workspace == null then
      return "*"
    end
    if options.workspace then
      return options.workspace
    end
  end

  return get_workspace_id()
end


local function process_ttl_field(entity)
  if entity and entity.ttl and entity.ttl ~= null then
    local ttl_value = entity.ttl - ngx.time()
    if ttl_value > 0 then
      entity.ttl = ttl_value
    else
      entity = nil  -- do not return the expired entity
    end
  end
  return entity
end

local function select_by_key(schema, key)
  print("selecting by key: " .. key)
  local entity, err = fetch_from_cp(key)
  if not entity then
    return nil, err
  end

  if schema.ttl then
    entity = process_ttl_field(entity)
    if not entity then
      return nil
    end
  end

  return entity
end


local function select(self, pk, options)
  local schema = self.schema
  local ws_id = ws(schema, options)
  local id = declarative_config.pk_string(schema, pk)
  -- TODO: respect ws_id
  local key = "/" .. schema.name .. "/" .. id
  return select_by_key(schema, key)
end


local function select_by_field(self, field, value, options)
  if type(value) == "table" then
    local _
    _, value = next(value)
  end

  local schema = self.schema
  local ws_id = ws(schema, options)

  local key
  if field ~= "cache_key" then
    local unique_across_ws = schema.fields[field].unique_across_ws
    -- only accept global query by field if field is unique across workspaces
    assert(not options or options.workspace ~= null or unique_across_ws)

    -- key = unique_field_key(schema.name, ws_id, field, value, unique_across_ws)
    print("schema.name = " .. require("inspect")(schema.name))
    print("ws_id = " .. require("inspect")(ws_id))
    print("field = " .. require("inspect")(field))
    print("value = " .. require("inspect")(value))
    local endpoint_name = schema.name
    if schema.name == "keyauth_credentials" then
      endpoint_name = "key-auths"
    end
    if schema.name == "basicauth_credentials" then
      endpoint_name = "basic-auths"
    end
    key = fmt("/%s/%s", endpoint_name, value)
  else
    -- if select_by_cache_key, use the provided cache_key as key directly
    key = value
  end

  return select_by_key(schema, key)
end


do
  local unsupported = function(operation)
    return function(self)
      local err = fmt("cannot %s '%s' entities when not using a database",
                      operation, self.schema.name)
      return nil, self.errors:operation_unsupported(err)
    end
  end

  local unsupported_by = function(operation)
    return function(self, field_name)
      local err = fmt("cannot %s '%s' entities by '%s' when not using a database",
                      operation, self.schema.name, '%s')
      return nil, self.errors:operation_unsupported(fmt(err, field_name))
    end
  end

  _mt.select = select
  _mt.page = unsupported("page")
  _mt.select_by_field = select_by_field
  _mt.insert = unsupported("create")
  _mt.update = unsupported("update")
  _mt.upsert = unsupported("create or update")
  _mt.delete = unsupported("remove")
  _mt.update_by_field = unsupported_by("update")
  _mt.upsert_by_field = unsupported_by("create or update")
  _mt.delete_by_field = unsupported_by("remove")
  _mt.truncate = function() return true end
  -- off-strategy specific methods:
  _mt.page_for_key = unsupported("page by key")
end


function lazy.new(connector, schema, errors)
  local self = {
    connector = nil, -- instance of kong.db.strategies.off.connector
    schema = schema,
    errors = errors,
  }

  print("Spawning lazy strategy for schema: " .. schema.name)

  if not kong.default_workspace then
    -- This is not the id for the default workspace in DB-less.
    -- This is a sentinel value for the init() phase before
    -- the declarative config is actually loaded.
    kong.default_workspace = "00000000-0000-0000-0000-000000000000"
  end

  return setmetatable(self, _mt)
end


return lazy

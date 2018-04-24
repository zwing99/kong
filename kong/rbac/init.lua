local _M = {}

local singletons = require "kong.singletons"
local bit        = require "bit"
local workspaces = require "kong.workspaces"
local responses  = require "kong.tools.responses"
local cjson      = require "cjson"

local band   = bit.band
local bxor   = bit.bxor
local bor    = bit.bor
local fmt    = string.format
local lshift = bit.lshift
local rshift = bit.rshift


local function log(lvl, ...)
  ngx.log(lvl, "[rbac] ", ...)
end


local actions_bitfields = {
  read   = 0x01,
  create = 0x02,
  update = 0x04,
  delete = 0x08,
}
_M.actions_bitfields = actions_bitfields
local actions_bitfield_size = 4


local bitfield_action = {
  [0x01] = "read",
  [0x02] = "create",
  [0x04] = "update",
  [0x08] = "delete",
}


local figure_action
local readable_action
do
  local action_lookup = setmetatable(
    {
      GET    = actions_bitfields.read,
      HEAD   = actions_bitfields.read,
      POST   = actions_bitfields.create,
      PATCH  = actions_bitfields.update,
      PUT    = actions_bitfields.update,
      DELETE = actions_bitfields.delete,
    },
    {
      __index = function(t, k)
        error("Invalid method")
      end,
      __newindex = function(t, k, v)
        error("Cannot write to method lookup table")
      end,
    }
  )

  figure_action = function(method)
    return action_lookup[method]
  end

  readable_action = function(action)
    return bitfield_action[action]
  end

  _M.figure_action = figure_action
  _M.readable_action = readable_action
end


-- fetch the id pair mapping of related objects from the database
local function retrieve_relationship_ids(entity_id, entity_name, factory_key)
  local relationship_ids, err = singletons.dao[factory_key]:find_all({
    [entity_name .. "_id"] = entity_id,
  })
  if err then
    log(ngx.ERR, "err retrieving relationship via id ", entity_id, ": ", err)
    return nil, err
  end

  return relationship_ids
end


-- fetch the foreign object associated with a mapping id pair
local function retrieve_relationship_entity(foreign_factory_key, foreign_id)
  local relationship, err = singletons.dao[foreign_factory_key]:find_all({
    id = foreign_id,
  })
  if err then
    log(ngx.ERR, "err retrieving relationship via id ", foreign_id, ": ", err)
    return nil, err
  end

  return relationship[1]
end


-- fetch the foreign entities associated with a given entity
-- practically, this is used to return the role objects associated with a
-- user, or the permission object associated with a role
-- the kong.cache mechanism is used to cache both the id mapping pairs, as
-- well as the foreign entities themselves
local function entity_relationships(dao_factory, entity, entity_name, foreign)
  local cache = singletons.cache

  -- get the relationship identities for this identity
  local factory_key = fmt("rbac_%s_%ss", entity_name, foreign)
  local relationship_cache_key = dao_factory[factory_key]:cache_key(entity.id)
  local relationship_ids, err = cache:get(relationship_cache_key, nil,
                                          retrieve_relationship_ids,
                                          entity.id, entity_name, factory_key)
  if err then
    log(ngx.ERR, "err retrieving relationship ids for ", entity_name, ": ", err)
    return nil, err
  end

  -- now get the relationship objects for each relationship id
  local relationship_objs = {}
  local foreign_factory_key = fmt("rbac_%ss", foreign)

  for i = 1, #relationship_ids do
    local foreign_factory_cache_key = dao_factory[foreign_factory_key]:cache_key(
      relationship_ids[i][foreign .. "_id"])

    local relationship, err = cache:get(foreign_factory_cache_key, nil,
                                        retrieve_relationship_entity,
                                        foreign_factory_key,
                                        relationship_ids[i][foreign .. "_id"])
    if err then
      log(ngx.ERR, "err in retrieving relationship: ", err)
      return nil, err
    end

    relationship_objs[#relationship_objs + 1] = relationship
  end

  return relationship_objs
end
_M.entity_relationships = entity_relationships


local function retrieve_user(user_token)
  local user, err = singletons.dao.rbac_users:find_all({
    user_token = user_token,
    enabled    = true,
  })
  if err then
    log(ngx.ERR, "error in retrieving user from token: ", err)
    return nil, err
  end

  return user[1]
end


local function get_user(user_token)
  local cache_key = singletons.dao.rbac_users:cache_key(user_token)
  local user, err = singletons.cache:get(cache_key, nil,
                                         retrieve_user, user_token)

  if err then
    return nil, err
  end

  return user
end


local function bitfield_check(map, key, bit)
  return map[key] and band(map[key], bit) == bit or false
end


local function arr_hash_add(t, e)
  if not t[e] then
    t[e] = true
    t[#t + 1] = e
  end
end


-- given a list of workspace IDs, return a list/hash
-- of entities belonging to the workspaces, handling
-- circular references
function _M.resolve_workspace_entities(workspaces)
  -- entities = {
  --    [1] = "foo",
  --    foo = 1,
  --
  --    [2] = "bar",
  --    bar = 2
  -- }
  local entities = {}


  local seen_workspaces = {}


  local function resolve(workspace)
    local workspace_entities, err =
      retrieve_relationship_ids(workspace, "workspace", "workspace_entities")
    if err then
      error(err)
    end

    local iter_entities = {}

    for _, ws_entity in ipairs(workspace_entities) do
      local ws_id  = ws_entity.workspace_id
      local e_id   = ws_entity.entity_id
      local e_type = ws_entity.entity_type

      if e_type == "workspaces" then
        assert(seen_workspaces[ws_id] == nil, "already seen workspace " ..
                                              ws_id)
        seen_workspaces[ws_id] = true

        local recursed_entities = resolve(e_id)

        for _, e in ipairs(recursed_entities) do
          arr_hash_add(iter_entities, e)
        end

      else
        arr_hash_add(iter_entities, e_id)
      end
    end

    return iter_entities
  end


  for _, workspace in ipairs(workspaces) do
    local es = resolve(workspace)
    for _, e in ipairs(es) do
      arr_hash_add(entities, e)
    end
  end


  return entities
end


local function resolve_role_entity_permissions(roles)
  local pmap = {}


  local function positive_mask(p, id)
    pmap[id] = bor(p, pmap[id] or 0x0)
  end
  local function negative_mask(p, id)
    pmap[id] = band(pmap[id] or 0x0, bxor(p, pmap[id] or 0x0))
  end


  local function iter(role_entities, mask)
    for _, role_entity in ipairs(role_entities) do
      if role_entity.entity_type == "workspace" then
        -- list/hash
        local es = _M.resolve_workspace_entities({ role_entity.entity_id })

        for _, child_id in ipairs(es) do
          mask(role_entity.actions, child_id)
        end
      else
        mask(role_entity.actions, role_entity.entity_id)
      end
    end
  end


  -- assign all the positive bits first such that we dont have a case
  -- of an explicit positive overriding an explicit negative based on
  -- the order of iteration
  for _, role in ipairs(roles) do
    local role_entities, err = singletons.dao.rbac_role_entities:find_all({
      role_id  = role.id,
      negative = false,
    })
    if err then
      error(err)
    end
    iter(role_entities, positive_mask)
  end

  for _, role in ipairs(roles) do
    local role_entities, err = singletons.dao.rbac_role_entities:find_all({
      role_id  = role.id,
      negative = true,
    })
    if err then
      error(err)
    end
    iter(role_entities, negative_mask)
  end


  return pmap
end
_M.resolve_role_entity_permissions = resolve_role_entity_permissions


local function get_rbac_user_info()
  local ok, res = pcall(function() return ngx.ctx.rbac end)
  return ok and res or { roles = {}, user = "guest", entities_perms = {} }
end


local function is_system_table(t)
  local reserved_tables = { "rbac_.*", "workspace*", ".*_.*s" }
  for i, v in ipairs(reserved_tables) do
    if string.find(t, v) then
      return true
    end
  end
  return false
end


function _M.narrow_readable_entities(db_table_name, entities)
  local filtered_rows = {}
  if not is_system_table(db_table_name) then
    for i, v in ipairs(entities) do
      local valid = _M.validate_entity_operation(v)
      if valid then
        filtered_rows[#filtered_rows+1] = v
      end
    end
    return filtered_rows
  else
    return entities
  end
end


function _M.validate_entity_operation(entity)
  if not singletons.configuration.rbac.entity then
    return true
  end

  local rbac_ctx = get_rbac_user_info()
  if rbac_ctx.user == "guest" then
    return true
  end

  local permissions_map = rbac_ctx.entities_perms
  local action = rbac_ctx.action
  return _M.authorize_request_entity(permissions_map, entity, action)
end


function _M.readable_entities_permissions(roles)
  local map = resolve_role_entity_permissions(roles)

  for k, v in pairs(map) do
    local actions_t = setmetatable({}, cjson.empty_array_mt)
    local actions_t_idx = 0

    for action, n in pairs(actions_bitfields) do
      if band(n, v) == n then
        actions_t_idx = actions_t_idx + 1
        actions_t[actions_t_idx] = action
      end
    end

    map[k] = actions_t
  end

  return map
end


local function authorize_request_entity(map, id, action)
  return bitfield_check(map, id, action)
end
_M.authorize_request_entity = authorize_request_entity


local function resolve_role_endpoint_permissions(roles)
  local pmap = {}


  for _, role in ipairs(roles) do
    local roles_endpoints, err = singletons.dao.rbac_role_endpoints:find_all({
      role_id = role.id,
    })
    if err then
      error(err)
    end

    -- because we hold a two-dimensional mapping and prioritize explicit
    -- mapping matches over endpoint globs, we need to hold both the negative
    -- and positive bit sets independantly, instead of having a negative bit
    -- unset a positive bit, because in doing so it would be impossible to
    -- determine implicit vs. explicit authorization denial (the former leading
    -- to a fall-through in the 2-d array, the latter leading to an immediate
    -- denial)
    for _, role_endpoint in ipairs(roles_endpoints) do
      if not pmap[role_endpoint.workspace] then
        pmap[role_endpoint.workspace] = {}
      end

      -- store explicit negative bits adjacent to the positive bits in the mask
      local p = role_endpoint.actions
      if role_endpoint.negative then
        p = bor(p, lshift(p, 4))
      end

      local ws_prefix = ""
      if role_endpoint.endpoint ~= "*" then
        ws_prefix = "/" .. role_endpoint.workspace
      end

      pmap[role_endpoint.workspace][ws_prefix .. role_endpoint.endpoint] =
        bor(p, pmap[role_endpoint.workspace][role_endpoint.endpoint] or 0x0)
    end
  end


  return pmap
end
_M.resolve_role_endpoint_permissions = resolve_role_endpoint_permissions


function _M.readable_endpoints_permissions(roles)
  local map = resolve_role_endpoint_permissions(roles)

  for workspace in pairs(map) do
    for endpoint, actions in pairs(map[workspace]) do
      local actions_t = setmetatable({}, cjson.empty_array_mt)
      local actions_t_idx = 0

      for action, n in pairs(actions_bitfields) do
        if band(n, actions) == n then
          actions_t_idx = actions_t_idx + 1
          actions_t[actions_t_idx] = action
        end
      end

      map[workspace][endpoint] = actions_t
    end
  end

  return map
end


-- normalized route_name: replace lapis named parameters with *, so that
-- any named parameters match wildcard endpoints
local function normalize_route_name(route_name)
  route_name = ngx.re.gsub(route_name, "^workspace_", "")
  route_name = ngx.re.gsub(route_name, ":[^/]*", "*")
  route_name = ngx.re.gsub(route_name, "/$", "")
  return route_name
end


-- return a list of endpoints; if the incoming request endpoint
-- matches either one of them, we get a positive or negative match
local function get_endpoints(workspace, endpoint, route_name)
  local endpoint_with_workspace = "/" .. workspace .. endpoint
  local normalized_route_name = normalize_route_name(route_name)
  local normalized_route_name_with_workspace = "/" .. workspace .. normalized_route_name

  -- order is important:
  --  - first, try to match exact endpoint name
  --    * without workspace name prepended - e.g., /apis/test
  --    * with workspace name prepended - e.g., /foo/apis/test
  --  - normalized route name
  --    * without workspace name prepended - e.g., /apis/*
  --    * with workspace name prepended - e.g., /foo/apis/*
  return {
    endpoint,
    endpoint_with_workspace,
    normalized_route_name,
    normalized_route_name_with_workspace,
    "*",
  }
end


function _M.authorize_request_endpoint(map, workspace, endpoint, route_name, action)
  -- look for
  -- 1. explicit allow (and _no_ explicit) deny in the specific ws/endpoint
  -- 2. "" in the ws/*
  -- 3. "" in the */endpoint
  -- 4. "" in the */*
  --
  -- explit allow means a match on the lower bit set
  -- and no match on the upper bits. if theres no match on the lower set,
  -- no need to check the upper bit set
  for _, workspace in ipairs{workspace, "*"} do
    if map[workspace] then
      for _, endpoint in ipairs(get_endpoints(workspace, endpoint, route_name)) do
        local perm = map[workspace][endpoint]
        if perm then
          if band(perm, action) == action then
            if band(rshift(perm, actions_bitfield_size), action) == action then
              return false
            else
              return true
            end
          end
        end
      end
    end
  end

  return false
end


function _M.load_rbac_ctx(dao_factory)
  local rbac_auth_header = singletons.configuration.rbac_auth_header
  local rbac_token = ngx.req.get_headers()[rbac_auth_header]
  local http_method = ngx.req.get_method()

  if not rbac_token then
    return false
  end

  local user, err = get_user(rbac_token)
  if err then
    return nil, err
  end
  if not user then
    return false
  end

  local roles, err = entity_relationships(dao_factory, user, "user", "role")
  if err then
    return nil, err
  end

  local action, err = figure_action(http_method)
  if err then
    return nil, err
  end

  local entities_perms, err = resolve_role_entity_permissions(roles)
  if err then
    return nil, err
  end

  local endpoints_perms, err = _M.resolve_role_endpoint_permissions(roles)
  if err then
    return nil, err
  end

  return {
    user = user,
    roles = roles,
    action = action,
    entities_perms = entities_perms,
    endpoints_perms = endpoints_perms,
  }
end


function _M.validate_endpoint(route_name, route)
  if route_name == "default_route" then
    return
  end

  if not singletons.configuration.rbac.endpoint then
    return
  end

  local rbac_ctx, err = _M.load_rbac_ctx(singletons.dao)
  if err then
    ngx.log(ngx.ERR, "[rbac] ", err)
    return responses.send_HTTP_INTERNAL_SERVER_ERROR()
  end
  if not rbac_ctx then
    return responses.send_HTTP_UNAUTHORIZED("Invalid RBAC credentials")
  end

  local  ok = _M.authorize_request_endpoint(rbac_ctx.endpoints_perms,
                                            workspaces.get_workspaces()[1].name,
                                            route, route_name, rbac_ctx.action)
  if not ok then
    local err = fmt("%s, you do not have permissions to %s this resource",
                    rbac_ctx.user.name, readable_action(rbac_ctx.action))
    return responses.send_HTTP_FORBIDDEN(err)
  end
  ngx.ctx.rbac = rbac_ctx
end


-- checks whether the given action can be cleanly performed in a
-- set of entities
function _M.check_cascade(entities)
  if singletons.configuration.rbac.off then
    return true
  end

  local perms_map = ngx.ctx.rbac.entities_perms
  local action    = ngx.ctx.rbac.action

  --
  -- entities = {
  --  [table name] = {
  --    entities = {
  --      ...
  --    },
  --    schema = {
  --      ...
  --    }
  --  }
  -- }
  for table_name, table_info in pairs(entities) do
    for entity in ipairs(table_info.entities) do
      if not authorize_request_entity(perms_map, entity.id, action) then
        return false
      end
    end
  end

  return true
end


do
  local reports = require "kong.core.reports"
  local rbac_users_count = function()
    local c, err = singletons.dao.rbac_users:count()
    if not c then
      log(ngx.WARN, "failed to get count of RBAC users: ", err)
      return nil
    end

    return c
  end

  reports.add_ping_value("rbac_users", rbac_users_count)
end


return _M

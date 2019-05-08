local utils = require "kong.tools.utils"
local cjson = require "cjson"

local tostring     = tostring
local type         = type

local SERVICE_IDS = {
  portal = "00000000-0000-0000-0000-000000000000",
  admin =  "00000000-0000-0000-0000-000000000001",
}

local loaded_plugins_map = {}
local admin_plugin_models = {}
local PHASES, set_phase, set_named_ctx

local function apply_plugin(plugin, phase, opts)
  set_phase(kong, PHASES[phase])
  set_named_ctx(kong, "plugin", plugin.config)

  local err = coroutine.wrap(plugin.handler[phase])(plugin.handler, plugin.config)
  if err then
    return nil, err
  end

  set_phase(kong, PHASES.admin_api)

  return true
end

local function prepare_plugin(opts)
  local model, err

  local plugin = loaded_plugins_map[opts.name]
  if not plugin then
    return nil, "plugin: " .. opts.name .. " not found."
  end

  local fields = {
    name = opts.name,
    service = { id = SERVICE_IDS[opts.api_type], },
    config = utils.deep_copy(opts.config or {}),
  }

  if opts.api_type == "admin" then
    model = admin_plugin_models[opts.name]
  end

  if not model then
    -- convert plugin configuration over to model to obtain defaults
    local plugins_entity = opts.db.plugins
    model, err = plugins_entity.schema:process_auto_fields(fields, "insert")
    if not model then
      local err_t = plugins_entity.errors:schema_violation(err)
      return nil, tostring(err_t), err_t
    end

    if type(model.config) == "string" then
      model.config = cjson.decode(model.config)
    end

     -- only cache valid models
    local ok, errors = plugins_entity.schema:validate_insert(model)
    if not ok then
      -- this config is invalid -- return errors until the user fixes
      local err_t = plugins_entity.errors:schema_violation(errors)
      return nil, tostring(err_t), err_t
    end

    -- convert <userdata> to nil
    for k, v in pairs(model.config) do
      if type(v) == "userdata" then
        model.config[k] = nil
      end
    end

    -- strip out default ports from cors origins
    if opts.name == 'cors' and model.config and model.config.origins then
      local origins = model.config.origins
      for k, v in ipairs(origins) do
        model.config.origins[k] = ngx.re.gsub(origins[k], ":443$", "")
        model.config.origins[k] = ngx.re.gsub(origins[k], ":80$", "")
      end
    end

    if opts.api_type == "admin" then
      admin_plugin_models[opts.name] = model
    end
  end

  return {
    handler = plugin.handler,
    config = model.config,
  }
end


local function validate(opts)
  local plugin = loaded_plugins_map[opts.name]

  if not plugin then
    return nil, "plugin: " .. opts.name .. " not found."
  end

  local fields = {
    name = opts.name,
    service = { id = SERVICE_IDS[opts.api_type], },
    config = utils.deep_copy(opts.config or {}),
  }

  -- convert plugin configuration over to model to obtain defaults
  local plugins_entity = opts.db.plugins
  local model, err = plugins_entity.schema:process_auto_fields(fields, "insert")
  if not model then
    return nil, err
  end

    -- only cache valid models
  local ok, err = plugins_entity.schema:validate_insert(model)
  if not ok then
    -- this config is invalid -- return errors until the user fixes
    return nil, err
  end

  return true
end


local function prepare_and_invoke(opts)
  if opts.validate_only then
    return validate(opts)
  end

  local prepared_plugin, err = prepare_plugin(opts)
  if not prepared_plugin then
    return nil, err
  end

  local ok, err
  for _, phase in ipairs(opts.phases) do
    ok, err = apply_plugin(prepared_plugin, phase, opts)
    if not ok then
      return nil, err
    end
  end

  return true
end

return {
  new = function(opts)
    for _, plugin in ipairs(opts.loaded_plugins) do
      loaded_plugins_map[plugin.name] = plugin
    end

    local kong_global = opts.kong_global

    PHASES = kong_global.phases
    set_phase = kong_global.set_phase
    set_named_ctx = kong_global.set_named_ctx

    return setmetatable({
      prepare_plugin = prepare_plugin,
    }, {
      __call = function(_, ...)
        return prepare_and_invoke(...)
      end,
    })
  end
}

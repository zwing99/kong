local Runtime = require "kong.components.runtime"
local DB = require "kong.components.datastore"

local function init_enter()
  local db = assert(DB.new(kong.configuration))
  assert(db:init_connector())

  assert(db:connect())

  Runtime.register_globals("db", db)
end

local function init_exit()
  kong.db:close()
  
  return true
end

local function init_worker_enter()
  return kong.db:init_worker()
end

local function register()
  Runtime.register_phase_handler("datastore", "init", init_enter, init_exit)
  Runtime.register_phase_handler("datastore", "init_worker", init_worker_enter)
end

return register
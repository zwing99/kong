local meta = require "kong.meta"


local LazyLoaderConnector   = {}
LazyLoaderConnector.__index = LazyLoaderConnector


local function ignore()
  return true
end

function LazyLoaderConnector.init()
  return true
end

function LazyLoaderConnector:connect_migrations(opts)
  return {}
end

function LazyLoaderConnector:schema_migrations(subsystems)
  return {}
end


function LazyLoaderConnector.new(kong_config)
  local self = {
    database = "lazy",
    timeout = 1,
    close = ignore,
    connect = ignore,
    truncate_table = ignore,
    truncate = ignore,
    insert_lock = ignore,
    remove_lock = ignore,
    schema_reset = ignore,
  }

  return setmetatable(self, LazyLoaderConnector)
end


function LazyLoaderConnector:infos()
  return {
    strategy = "lazy",
    db_name = "from cp",
    db_desc = "from cp",
    db_ver = meta._VERSION,
  }
end


function LazyLoaderConnector:query()
  return "querrying"

end

function LazyLoaderConnector:connect(opts)
  return "connecting.."
end


return LazyLoaderConnector

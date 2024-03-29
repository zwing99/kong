local access = require "kong.plugins.ldap-auth.access"

local LdapAuthHandler = {
  VERSION = require "kong.constants".VERSION,
  PRIORITY = 1200,
}


function LdapAuthHandler:access(conf)
  access.execute(conf)
end


return LdapAuthHandler

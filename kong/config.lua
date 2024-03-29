local version = setmetatable({
  major = 3,
  minor = 7,
  patch = 0,
  --suffix = "-alpha.13"
}, {
  -- our Makefile during certain releases adjusts this line. Any changes to
  -- the format need to be reflected in both places
  __tostring = function(t)
    return string.format("%d.%d.%d%s", t.major, t.minor, t.patch,
                         t.suffix or "")
  end
})


return {
  VERSION = version,

  -- third-party dependencies' required version, as they would be specified
  -- to lua-version's `set()` in the form {from, to}
  DEPENDENCIES = {
    nginx = { "1.25.3.1" },
  },
}

local resp_phase = {}


resp_phase.PRIORITY = 950
resp_phase.VERSION = require "kong.constants".VERSION


function resp_phase:access()
end

function resp_phase:response()
end

return resp_phase

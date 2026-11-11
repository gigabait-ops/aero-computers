-- require("autocrafter"): the turtle worker (startup.lua of PC139-149).
local Worker = require("autocrafter.worker")

local Autocrafter = {}

function Autocrafter.new(options)
    return Worker.new(options)
end

return Autocrafter

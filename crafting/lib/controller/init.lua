local Controller = require("controller.controller")

local AutocrafterController = {
    Controller = Controller,
}

function AutocrafterController.new(options)
    return Controller.new(options)
end

return AutocrafterController

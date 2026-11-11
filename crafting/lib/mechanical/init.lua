local Station = require("mechanical.station")

return {
    Station = Station,
    new = function(options) return Station.new(options) end,
}

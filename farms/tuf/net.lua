-- Rednet on every modem of the computer (wireless and wired): PC11 sends
-- its storage report to PC124 over it.
local N = {}

function N.open()
    local opened = {}
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.hasType(name, "modem") then
            if not rednet.isOpen(name) then pcall(rednet.open, name) end
            if rednet.isOpen(name) then opened[#opened + 1] = name end
        end
    end
    table.sort(opened)
    return opened
end

function N.clock()
    return os.epoch("utc") / 1000
end

return N

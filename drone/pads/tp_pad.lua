local channel = "gigabait.tp" -- Текстовий протокол Rednet
local name = "home"          -- Назва цього телепорту
local side = "back"          -- Сторона редстоун-виходу
local delay = 2              -- Тривалість сигналу

-- Teleport pad (firmware 2): fires on its name and tells the pocket
-- computer it did; answers the pocket's ping with its name.

redstone.setOutput(side, false)

local modem = peripheral.find("modem", function(_, m)
    return m.isWireless()
end)

if not modem then
    error("Wireless modem not found", 0)
end

rednet.open(peripheral.getName(modem))

local function tp(sender)
    redstone.setOutput(side, true)
    rednet.send(sender, {type = "tp_done", name = name}, channel)

    local ok, err = pcall(sleep, delay)

    redstone.setOutput(side, false)

    if not ok then
        error(err, 0)
    end
end

print("Teleport: " .. name)
print("Protocol: " .. channel)
print("Waiting...")

while true do
    local sender, msg = rednet.receive(channel)

    if msg == name then
        print("Activated: " .. name)
        tp(sender)
    elseif type(msg) == "table" and msg.type == "tp_ping" then
        rednet.send(sender, {type = "tp_pong", name = name}, channel)
    end
end

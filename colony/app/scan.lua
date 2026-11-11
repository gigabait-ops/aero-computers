-- Colony Supply check: what this computer can see and use. Run: scan
local function row(...) print(table.concat({...}, " ")) end

row("== peripherals")
for _, name in ipairs(peripheral.getNames()) do
    local ptype = peripheral.getType(name)
    local extra = ""
    if ptype == "modem" then
        local ok, wireless = pcall(peripheral.call, name, "isWireless")
        extra = ok and (wireless and " wireless" or " wired") or ""
    elseif ptype == "Create_Frogport" or ptype == "Create_Postbox" or ptype == "Create_Packager" then
        local ok, addr = pcall(peripheral.call, name, "getAddress")
        extra = ok and (" address='" .. tostring(addr) .. "'") or ""
    elseif peripheral.hasType(name, "inventory") then
        local okSize, size = pcall(peripheral.call, name, "size")
        local okList, list = pcall(peripheral.call, name, "list")
        local used = 0
        if okList and type(list) == "table" then for _ in pairs(list) do used = used + 1 end end
        extra = string.format(" inventory %s slots, %d used", tostring(okSize and size), used)
    end
    row(" ", name, "(" .. ptype .. ")" .. extra)
end

row("== colony integrator")
local integrator = peripheral.find("colony_integrator")
if not integrator then
    row("  not found")
else
    local okIn, inColony = pcall(integrator.isInColony)
    row("  isInColony:", tostring(okIn and inColony))
    local okName, name = pcall(integrator.getColonyName)
    if okName then
        local _, id = pcall(integrator.getColonyID)
        local _, c = pcall(integrator.getCitizenCount)
        local _, l = pcall(integrator.getCitizenLimit)
        row("  colony:", tostring(name), "id", tostring(id), "citizens", tostring(c) .. "/" .. tostring(l))
        local okReq, requests = pcall(integrator.getRequests)
        if okReq and type(requests) == "table" then
            row("  open requests:", tostring(#requests))
            for i, r in ipairs(requests) do
                if i > 10 then row("  ...") break end
                local first = r.items and r.items[1] and r.items[1].name or "?"
                row(string.format("   #%s %s x%s [%s] for %s (%s)", tostring(r.id), tostring(r.displayName),
                    tostring(r.count), tostring(r.state), tostring(r.target), tostring(first)))
            end
        else
            row("  getRequests failed:", tostring(requests))
        end
        local okWo, orders = pcall(integrator.getWorkOrders)
        if okWo and type(orders) == "table" then
            row("  work orders:", tostring(#orders))
            for i, o in ipairs(orders) do
                if i > 6 then row("  ...") break end
                row(string.format("   #%s %s %s lvl %s->%s %s", tostring(o.id), tostring(o.displayName),
                    tostring(o.type), tostring(o.level), tostring(o.targetLevel), o.isClaimed and "claimed" or "unclaimed"))
                if o.isClaimed then
                    local okRes, res = pcall(integrator.getWorkOrderResources, o.id)
                    if okRes and type(res) == "table" then
                        local short = 0
                        for _, r in ipairs(res) do
                            if r.status == "DONT_HAVE" or r.status == "NEED_MORE" then short = short + 1 end
                        end
                        row("     resources:", #res, "short:", short)
                    else
                        row("     resources failed:", tostring(res))
                    end
                end
            end
        end
    else
        row("  getColonyName failed:", tostring(name))
    end
end

row("== stock tickers (Create storage = the big one; a colony ticker sees the colony)")
local found = 0
for _, tname in ipairs(peripheral.getNames()) do
    if peripheral.hasType(tname, "Create_StockTicker") then
        found = found + 1
        local ok, list = pcall(peripheral.call, tname, "stock")
        local kinds, total = 0, 0
        if ok and type(list) == "table" then
            for _, e in pairs(list) do kinds = kinds + 1 total = total + (tonumber(e.count) or 0) end
        end
        row("  " .. tname, "network stock:", kinds, "item kinds,", total, "items")
    end
end
if found == 0 then row("  not found") end

if not fs.exists("/app/craft.lua") then return end   -- no craft module
row("== craft controller (rednet)")
local opened = 0
for _, name in ipairs(peripheral.getNames()) do
    if peripheral.hasType(name, "modem") then pcall(rednet.open, name) opened = opened + 1 end
end
if opened == 0 then
    row("  no modem")
else
    for _, host in ipairs({"craft-controller", "autocrafter-controller"}) do
        local ok, id = pcall(rednet.lookup, "gigabait.craft.request.v1", host)
        row("  " .. host .. ":", ok and tostring(id) or ("error " .. tostring(id)))
    end
end

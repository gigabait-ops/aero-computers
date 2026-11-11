-- Colony Supply. Restarts itself after an unexpected error, so a
-- single bad scan never leaves the colony without supplies.
-- At the top level only what you set up: config.lua and rules/. The program
-- is in app/, with its own memory (app/memory) and logs (app/logs).
package.path = "/?.lua;/?/init.lua;/?/?.lua;" .. package.path
-- `install` and `scan` work as commands after Ctrl+T
if shell and not shell.path():find(":/app", 1, true) then shell.setPath(shell.path() .. ":/app") end

-- An older version (program files at the top level) finishes its update:
-- the new installer moves everything into place.
local installer = fs.exists("/app/install.lua") and "/app/install.lua" or "/install.lua"
if (not fs.exists("/app/settings.lua") or fs.exists("/scan.lua") or fs.exists("/lang"))
    and fs.exists(installer) then
    print("Finishing the update...")
    shell.run(installer, "auto")
end

-- The program's own files from before 2026-10-30 (data/, logs/) move into
-- app/, so the top level holds only what the player sets up.
local MOVES = {{"/data/orders.lua", "/app/memory/orders.lua"}, {"/data/send_hold.lua", "/app/memory/send_hold.lua"},
    {"/data/addresses.lua", "/app/memory/last_addresses.lua"}, {"/data/logs", "/app/logs"}, {"/logs", "/app/logs"}}
for _, m in ipairs(MOVES) do
    if fs.exists(m[1]) and not fs.exists(m[2]) then
        pcall(function()
            if not fs.exists(fs.getDir(m[2])) then fs.makeDir(fs.getDir(m[2])) end
            fs.move(m[1], m[2])
        end)
    end
end
-- the old folders go once nothing of the player's is left in them
for _, old in ipairs({"/data", "/logs"}) do
    if fs.isDir(old) then
        for _, name in ipairs(fs.list(old)) do
            if name == "snapshot.lua" or name:find("%.tmp$") then pcall(fs.delete, fs.combine(old, name)) end
        end
        if #fs.list(old) == 0 then pcall(fs.delete, old) end
    end
end

while true do
    local ok, result = pcall(function() return require("app.main").run() end)
    -- load the program files fresh on the next start
    for name in pairs(package.loaded) do
        if tostring(name):find("^app%.") then package.loaded[name] = nil end
    end
    if ok and result == "restart" then
        -- config.lua was fixed: start again right away
    elseif ok or tostring(result):find("Terminated", 1, true) then
        break                                              -- normal exit or Ctrl+T
    else
        term.redirect(term.native())
        term.setBackgroundColor(colors.black)
        term.setTextColor(colors.red)
        term.clear()
        term.setCursorPos(1, 1)
        print("Colony Supply stopped: " .. tostring(result))
        print("Restarting in 10 s (Ctrl+T to stop)")
        -- a short crash log; a full disk must not stop the restarts
        pcall(function()
            local path = "/app/logs/crash.log"
            if not fs.exists("/app/logs") then fs.makeDir("/app/logs") end
            if fs.exists(path) and fs.getSize(path) > 8192 then fs.delete(path) end
            local f = fs.open(path, "a")
            if f then f.writeLine(os.date("%Y-%m-%d %H:%M:%S") .. " " .. tostring(result)) f.close() end
        end)
        -- a program file is missing (an update stopped half way): fetch it again
        if tostring(result):find("module 'app%.") and fs.exists(installer) then
            print("A program file is missing: running the installer...")
            pcall(shell.run, installer, "auto")
        end
        sleep(10)
    end
end

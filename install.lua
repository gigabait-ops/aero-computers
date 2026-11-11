-- Aero computers installer (CC:Tweaked).
--   wget run https://raw.githubusercontent.com/gigabait-ops/aero-computers/main/install.lua <role>
--   wget run https://raw.githubusercontent.com/gigabait-ops/aero-computers/main/install.lua      (lists the roles)
-- Later on the same computer:
--   update            downloads the newest files of every role installed here
-- Your settings files are written once and never overwritten by an update;
-- files the role no longer has are removed.
local BASE = "https://raw.githubusercontent.com/gigabait-ops/aero-computers/main/"

local function say(color, text)
    if term.isColor() then term.setTextColor(color) end
    print(text)
    term.setTextColor(colors.white)
end

local function fail(text)
    say(colors.red, text)
    error("", 0)
end

local function get(path)
    local response, err = http.get(BASE .. path .. "?t=" .. os.epoch("utc"), nil, true)
    if not response then return nil, err end
    local body = response.readAll()
    response.close()
    return body
end

local function readFile(path)
    if not fs.exists(path) then return nil end
    local f = fs.open(path, "r")
    local text = f.readAll()
    f.close()
    return text
end

local function writeFile(path, text)
    local dir = fs.getDir(path)
    if dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
    local f = fs.open(path, "wb")
    f.write(text)
    f.close()
end

if not http then fail("HTTP is disabled on this server: ask an admin to enable it.") end

local text, err = get("manifest.lua")
if not text then fail("Cannot download the role list: " .. tostring(err)) end
local ok, manifest = pcall(load(text, "manifest", "t", {}))
if not ok or type(manifest) ~= "table" then fail("The role list is broken: " .. tostring(manifest)) end

-- roles installed on this computer (several may share one, e.g. a pocket
-- with drone-pocket and mining-tab): /.aero/roles, one name a line
local function lines(text)
    local out = {}
    for line in (text or ""):gmatch("[^\n]+") do out[#out + 1] = line end
    return out
end
local installed = lines(readFile("/.aero/roles"))
local args = {...}
local names = {}
if args[1] then
    names = {args[1]}
else
    names = installed
end
for _, n in ipairs(names) do
    if not manifest[n] then
        say(colors.red, "Unknown role: " .. n)
        names = {}
        break
    end
end
if #names == 0 then
    print("Roles:")
    local all = {}
    for n in pairs(manifest) do all[#all + 1] = n end
    table.sort(all)
    for _, n in ipairs(all) do
        say(colors.yellow, "  " .. n)
        print("    " .. manifest[n].description)
    end
    print("Usage: install <role>")
    return
end

local written, kept, fresh = 0, {}, {}
for _, name in ipairs(names) do
    local role = manifest[name]
    -- files this role put here before, so an update removes dropped ones
    local before = {}
    for _, path in ipairs(lines(readFile("/.aero/" .. name .. ".files"))) do before[path] = true end
    say(colors.cyan, "Installing " .. name .. " (" .. #role.files .. " files)")
    local list = {}
    for _, file in ipairs(role.files) do
        local repoPath, target = file[1], file[2]
        list[#list + 1] = target
        before[target] = nil
        if file.keep and fs.exists(target) then
            kept[#kept + 1] = target
        else
            if file.keep and not target:find("/requests/", 1, true) then fresh[#fresh + 1] = target end
            local body, e = get(repoPath)
            if not body then fail("Download failed for " .. repoPath .. ": " .. tostring(e)) end
            writeFile(target, body)
            written = written + 1
            write(".")
        end
    end
    print()
    for path in pairs(before) do
        if fs.exists(path) and not fs.isDir(path) then
            fs.delete(path)
            print("removed " .. path)
        end
    end
    writeFile("/.aero/" .. name .. ".files", table.concat(list, "\n") .. "\n")
    local known = false
    for _, n in ipairs(installed) do known = known or n == name end
    if not known then installed[#installed + 1] = name end
end
writeFile("/.aero/roles", table.concat(installed, "\n") .. "\n")
writeFile("/update.lua", 'shell.run("wget", "run", "' .. BASE .. 'install.lua")\n')

say(colors.lime, "Done: " .. written .. " files written.")
if #kept > 0 then print("Your settings stay as they are: " .. table.concat(kept, ", ")) end
if #fresh > 0 then
    say(colors.yellow, "Set it up in " .. table.concat(fresh, ", ") .. " (edit <file>), then reboot.")
else
    print("Rebooting...")
    sleep(1)
    os.reboot()
end

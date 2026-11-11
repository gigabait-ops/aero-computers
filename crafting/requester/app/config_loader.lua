local JobValidator = require("app.job_validator")
local Sections = require("app.sections")

local ConfigLoader = {}
ConfigLoader.__index = ConfigLoader

local function loadTable(path)
    local chunk, err = loadfile(path)

    if not chunk then
        return nil, err
    end

    local ok, result = pcall(chunk)

    if not ok then
        return nil, result
    end

    if type(result) ~= "table" then
        return nil, tostring(path) .. " did not return a table"
    end

    return result
end

local function readFile(path)
    local handle = io.open(path, "r")

    if not handle then
        return nil
    end

    local text = handle:read("*a")
    handle:close()
    return text
end

local function sourceFingerprint(paths)
    local parts = {}

    for _, path in ipairs(paths) do
        local contents = readFile(path)

        if contents == nil then
            return nil, "unable to read " .. tostring(path)
        end

        table.insert(parts, tostring(path))
        table.insert(parts, contents)
    end

    return table.concat(parts, "\0")
end

function ConfigLoader.defaultConfigPath()
    return fs and "/config.lua" or "46/config.lua"
end

-- A rule file of requests/ (app.sections), on the computer or in the repo.
function ConfigLoader.defaultPath(file)
    return fs and ("/requests/" .. file) or ("46/requests/" .. file)
end

function ConfigLoader:new(paths)
    return setmetatable({
        paths = paths or {},
        lastHash = nil,
        lastRaw = nil
    }, self)
end

function ConfigLoader:sectionPath(def)
    return self.paths[def.raw] or ConfigLoader.defaultPath(def.file)
end

function ConfigLoader:loadRaw()
    local raw, rootErr = loadTable(self.paths.config or ConfigLoader.defaultConfigPath())

    if not raw then
        return nil, rootErr
    end

    for _, def in ipairs(Sections) do
        local path = self:sectionPath(def)
        local rules, err = {}, nil

        -- An optional file that is absent means no such rules.
        if not def.optional or readFile(path) then
            rules, err = loadTable(path)
            if not rules then
                return nil, err
            end
        end

        raw[def.raw] = rules
    end

    local valid, validationErr = JobValidator.validateRaw(raw)

    if not valid then
        return nil, validationErr
    end

    return raw
end

function ConfigLoader:refreshLocal()
    local paths = {self.paths.config or ConfigLoader.defaultConfigPath()}
    for _, def in ipairs(Sections) do
        local path = self:sectionPath(def)
        if not def.optional or readFile(path) then
            table.insert(paths, path)
        end
    end
    local hash, hashErr = sourceFingerprint(paths)

    if not hash then
        return {
            ok = false,
            changed = false,
            raw = self.lastRaw,
            error = hashErr
        }
    end

    if self.lastRaw and hash == self.lastHash then
        return {
            ok = true,
            changed = false,
            raw = self.lastRaw
        }
    end

    local raw, err = self:loadRaw()

    if not raw then
        return {
            ok = false,
            changed = false,
            raw = self.lastRaw,
            error = tostring(err or "config load failed")
        }
    end

    local changed = hash ~= self.lastHash

    self.lastHash = hash
    self.lastRaw = raw

    return {
        ok = true,
        changed = changed,
        raw = raw
    }
end

return ConfigLoader

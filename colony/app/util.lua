-- Colony Supply: small helpers shared by the app (clock, file store, logger, loaders).
local U = {}

-- Seconds that survive a reboot (os.clock restarts at 0 on every boot).
function U.now()
    if os.epoch then return os.epoch("utc") / 1000 end
    return os.clock()
end

-- {load, save} for one serialized table at `path`, written atomically.
function U.fileStore(path)
    return {
        load = function()
            if not fs.exists(path) then return nil end
            local f = fs.open(path, "r")
            if not f then return nil end
            local text = f.readAll() f.close()
            local ok, value = pcall(textutils.unserialize, text)
            return ok and value or nil
        end,
        save = function(state)
            local dir = fs.getDir(path)
            if dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
            local f = fs.open(path .. ".tmp", "w")
            if not f then return end
            f.write(textutils.serialize(state)) f.close()
            if fs.exists(path) then fs.delete(path) end
            fs.move(path .. ".tmp", path)
        end,
    }
end

-- Logger with plain functions (info/warn/error/debug); wraps the ROM logger
-- when it exists, otherwise appends to cfg.file itself.
function U.makeLog(cfg)
    cfg = cfg or {}
    local ok, logger = pcall(require, "logger")
    if ok and type(logger) == "table" and type(logger.create) == "function" then
        local inner = logger.create("colony", cfg)
        -- a full disk must not stop the colony's supplies: a log line may be lost
        return {
            info = function(...) pcall(inner.info, inner, ...) end,
            warn = function(...) pcall(inner.warn, inner, ...) end,
            error = function(...) pcall(inner.error, inner, ...) end,
            debug = function(...) pcall(inner.debug, inner, ...) end,
        }
    end
    local function line(level, ...)
        local parts = {}
        for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
        pcall(function()
            local f = fs.open(cfg.file or "/app/logs/colony.log", "a")
            if f then f.writeLine(os.date("%H:%M:%S") .. " " .. level .. " " .. table.concat(parts, " ")) f.close() end
        end)
    end
    return {info = function(...) line("INFO", ...) end, warn = function(...) line("WARN", ...) end,
        error = function(...) line("ERROR", ...) end, debug = function() end}
end

-- Lua table file (config, rules). Returns table or nil, error.
function U.loadTable(path)
    if not fs.exists(path) then return nil, "missing " .. path end
    local ok, value = pcall(dofile, path)
    if not ok then return nil, tostring(value) end
    if type(value) ~= "table" then return nil, path .. " must return a table" end
    return value
end

-- Loader for a rules file that re-reads it only when its modification time
-- changes (fs.attributes is a cheap metadata lookup). `translate` (app/words)
-- turns the Ukrainian keys into the program's own.
function U.watchTable(path, translate)
    local stamp, cached, cachedErr
    return function()
        local ok, attr = pcall(fs.attributes, path)
        local modified = ok and type(attr) == "table" and attr.modified or nil
        if modified == nil or modified ~= stamp then
            stamp = modified
            cached, cachedErr = U.loadTable(path)
            if cached and translate then cached = translate(cached) end
        end
        return cached, cachedErr
    end
end

-- Whole text of a file, or nil.
function U.readText(path)
    if not fs.exists(path) then return nil end
    local f = fs.open(path, "r")
    if not f then return nil end
    local text = f.readAll()
    f.close()
    return text
end

-- Written beside it first, then moved in: a full disk never leaves the
-- player's file half written.
function U.writeText(path, text)
    local dir = fs.getDir(path)
    if dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
    local f = fs.open(path .. ".tmp", "w")
    if not f then error("cannot write " .. path, 0) end
    local ok, err = pcall(function() f.write(text) end)
    f.close()
    if not ok then fs.delete(path .. ".tmp") error(err, 0) end
    if fs.exists(path) then fs.delete(path) end
    fs.move(path .. ".tmp", path)
end

-- Inventory proxy whose list() is reused for `ttl` seconds, so the modules
-- that read the same chest in one scan share a single peripheral call.
-- Moving items (pushItems) always goes to the real peripheral.
function U.cachedInventory(inv, ttl, clock)
    if inv == nil then return nil end
    ttl = ttl or 5
    clock = clock or U.now
    local at, result
    local proxy = {}
    for k, v in pairs(inv) do proxy[k] = v end
    proxy.list = function()
        local now = clock()
        if at == nil or now - at >= ttl then
            result = inv.list()
            at = now
        end
        return result
    end
    proxy.invalidate = function() at = nil end
    return proxy
end


return U

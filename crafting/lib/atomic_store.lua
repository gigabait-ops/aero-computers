local AtomicStore = {}

local function serialize(value, seen)
    local kind = type(value)

    if kind == "nil" then
        return "nil"
    end
    if kind == "boolean" or kind == "number" then
        return tostring(value)
    end
    if kind == "string" then
        return string.format("%q", value)
    end
    if kind ~= "table" then
        error("cannot serialize " .. kind, 2)
    end

    seen = seen or {}
    if seen[value] then
        error("cannot serialize recursive table", 2)
    end
    seen[value] = true

    local keys = {}
    for key in pairs(value) do
        keys[#keys + 1] = key
    end
    table.sort(keys, function(left, right)
        if type(left) == type(right) then
            return tostring(left) < tostring(right)
        end
        return type(left) < type(right)
    end)

    local parts = {"{"}
    for _, key in ipairs(keys) do
        parts[#parts + 1] = "[" .. serialize(key, seen) .. "]=" .. serialize(value[key], seen) .. ","
    end
    parts[#parts + 1] = "}"
    seen[value] = nil
    return table.concat(parts)
end

local function readFile(path, fsApi)
    if fsApi and type(fsApi.exists) == "function" and not fsApi.exists(path) then
        return nil, "not found"
    end

    if fsApi and type(fsApi.open) == "function" then
        local handle, err = fsApi.open(path, "r")
        if not handle then
            return nil, err or "open failed"
        end
        local content = handle.readAll()
        handle.close()
        return content
    end

    local handle, err = io.open(path, "r")
    if not handle then
        return nil, "not found"
    end
    local content = handle:read("*a")
    handle:close()
    return content
end

local function decode(content, path)
    if not content:match("^%s*return[%s{]") then
        content = "return " .. content
    end
    local chunk, err = load(content, "@" .. tostring(path), "t", {})
    if not chunk then
        return nil, err
    end

    local ok, value = pcall(chunk)
    if not ok then
        return nil, value
    end
    if type(value) ~= "table" then
        return nil, "state file did not return a table"
    end
    return value
end

local function writeFile(path, content, fsApi)
    if fsApi and type(fsApi.open) == "function" then
        local handle, err = fsApi.open(path, "w")
        if not handle then
            return false, err or "open failed"
        end
        local ok, writeError = pcall(function()
            assert(handle.write(content) ~= false, "write returned false")
            assert(handle.close() ~= false, "close returned false")
        end)
        if not ok then pcall(handle.close) end
        return ok, not ok and tostring(writeError) or nil
    end

    local handle, err = io.open(path, "w")
    if not handle then
        return false, err
    end
    handle:write(content)
    handle:flush()
    handle:close()
    return true
end

local function exists(path, fsApi)
    if fsApi and type(fsApi.exists) == "function" then
        return fsApi.exists(path)
    end
    local handle = io.open(path, "r")
    if handle then
        handle:close()
        return true
    end
    return false
end

local function remove(path, fsApi)
    if not exists(path, fsApi) then
        return true
    end
    if fsApi and type(fsApi.delete) == "function" then
        local ok, err = pcall(fsApi.delete, path)
        return ok and err ~= false, ok and (err == false and "delete returned false" or nil) or err
    end
    local ok, err = os.remove(path)
    return ok ~= nil, err
end

local function move(source, target, fsApi)
    if fsApi and type(fsApi.move) == "function" then
        local ok, err = pcall(fsApi.move, source, target)
        return ok and err ~= false, ok and (err == false and "move returned false" or nil) or err
    end
    local ok, err = os.rename(source, target)
    return ok ~= nil, err
end

function AtomicStore.encode(value)
    return "return " .. serialize(value) .. "\n"
end

function AtomicStore.decode(content, path)
    return decode(content, path or "state")
end

function AtomicStore.load(path, fsApi)
    local errors = {}
    for _, candidate in ipairs({path, path .. ".bak", path .. ".tmp"}) do
        local content, readErr = readFile(candidate, fsApi)
        if content then
            local value, decodeErr = decode(content, candidate)
            if value then
                return value, candidate ~= path and candidate or nil
            end
            errors[#errors + 1] = tostring(candidate) .. ": " .. tostring(decodeErr)
        elseif readErr and readErr ~= "not found" then
            errors[#errors + 1] = tostring(candidate) .. ": " .. tostring(readErr)
        end
    end

    if #errors > 0 then
        return nil, table.concat(errors, "; ")
    end
    return nil, nil
end

local function save(path, value, fsApi)
    local content = AtomicStore.encode(value)
    local temp = path .. ".tmp"
    local backup = path .. ".bak"

    local removed, removeError = remove(temp, fsApi)
    if not removed then return false, removeError end
    if exists(path, fsApi) then
        local freed, freeError = remove(backup, fsApi)
        if not freed then return false, freeError end
    end
    local wrote, writeErr = writeFile(temp, content, fsApi)
    if not wrote then
        return false, writeErr
    end

    local verifyContent, verifyReadErr = readFile(temp, fsApi)
    local verified, verifyErr
    if verifyContent then
        verified, verifyErr = decode(verifyContent, temp)
    else
        verifyErr = verifyReadErr
    end
    if not verified then
        remove(temp, fsApi)
        return false, verifyErr or "temporary state verification failed"
    end

    local hadCurrent = exists(path, fsApi)
    if hadCurrent then
        local backedUp, backupErr = move(path, backup, fsApi)
        if not backedUp then
            remove(temp, fsApi)
            return false, backupErr or "state backup failed"
        end
    end

    local installed, installErr = move(temp, path, fsApi)
    if not installed then
        if hadCurrent and exists(backup, fsApi) then
            move(backup, path, fsApi)
        end
        return false, installErr or "state install failed"
    end

    return true
end

function AtomicStore.save(path, value, fsApi)
    local ok, saved, err = pcall(save, path, value, fsApi)
    if not ok then return false, tostring(saved) end
    return saved, err
end

return AtomicStore

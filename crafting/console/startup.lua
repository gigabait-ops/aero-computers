package.path = "/?.lua;/?/init.lua;/?/?.lua;./?.lua;./?/init.lua;./?/?.lua;" .. package.path

local function showCrash(message)
    if not term then
        return
    end

    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.red)
    term.clear()
    term.setCursorPos(1, 1)
    print("MANUAL CRAFT CONSOLE ERROR")
    term.setTextColor(colors.white)
    print(tostring(message))
end

local ok, App = pcall(require, "app.app")
if not ok then
    showCrash(App)
    return
end

local created, app = pcall(App.new, App)
if not created then
    showCrash(app)
    return
end

local running, failure = xpcall(function()
    app:run()
end, debug.traceback)

if not running then
    pcall(function()
        app:crash(failure)
    end)
    showCrash(failure)
end

package.path = "/?.lua;/?/init.lua;/?/?.lua;./?.lua;./?/init.lua;./?/?.lua;" .. package.path

local App = require("app.app")

App:new():run()

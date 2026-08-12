-- tests/mock_koreader_load.lua
-- 极简 KOReader mock: 把 main.lua 真正 load 起来, 找出加载/初始化阶段的错误

package.path = "./?.lua;./webdav.koplugin/?.lua;./tests/?.lua;" .. package.path

-- mock 所有 KOReader SDK 模块
local M = {}
M["ui/bidi"] = { filepath = function(p) return p end }
M["datastorage"] = { getFullDataDir = function() return "/tmp/koreader-data" end }
M["device"] = {
    isKindle = function() return false end,
    retrieveNetworkInfo = function() return "127.0.0.1 (mock)" end,
}
M["dispatcher"] = {
    registerAction = function(name, opts)
        print(string.format("  [mock dispatcher] registerAction: %s (event=%s)", name, opts.event))
    end,
}
M["ui/widget/infomessage"] = setmetatable({}, { __call = function(_, opts) return { _opts = opts } end })
M["ui/widget/inputdialog"] = setmetatable({}, { __call = function(_, opts) return setmetatable({_opts=opts}, {__index={onShowKeyboard=function() end, getInputText=function() return "3568" end}}) end })
M["ui/uimanager"] = {
    show = function() end,
    close = function() end,
}
-- 极简 WidgetContainer 模拟
M["ui/widget/container/widgetcontainer"] = {
    extend = function(_, props)
        local class = {}
        for k, v in pairs(props or {}) do class[k] = v end
        class.__index = class
        function class.new(c, args)
            args = args or {}
            local inst = setmetatable({}, { __index = c })
            for k, v in pairs(args) do inst[k] = v end
            if inst.init then inst:init() end
            return inst
        end
        return class
    end,
}
M["ffi/util"] = {
    template = function(s, ...)
        local args = {...}
        return (s:gsub("%%1", tostring(args[1] or "")):gsub("%%2", tostring(args[2] or "")))
    end,
    sleep = function() end,
}
M["logger"] = {
    dbg = function(...) print("[dbg]", ...) end,
    warn = function(...) print("[warn]", ...) end,
    err = function(...) print("[err]", ...) end,
}
M["util"] = {
    pathExists = function(p)
        print(string.format("  [mock util.pathExists] %s", p))
        if p == "webdav" then return true end
        return false
    end,
}
M["gettext"] = function(s) return s end

-- 拦截 require
local orig_require = require
function require(name)
    if M[name] then return M[name] end
    return orig_require(name)
end

-- 模拟 G_reader_settings 全局
_G.G_reader_settings = {
    readSetting = function(self, key)
        local defaults = {
            webdav_port = "3568",
            webdav_directory = "/mnt/us",
            webdav_username = "admin",
            webdav_password = "webdav12345",
        }
        return defaults[key]
    end,
    isTrue = function(self, key) return false end,
    saveSetting = function(self, key, value)
        print(string.format("  [mock saveSetting] %s = %s", key, tostring(value)))
    end,
    flipNilOrFalse = function(self, key) end,
}

-- 模拟菜单 UI
local mock_menu = {
    registerToMainMenu = function(self, plugin)
        print(string.format("  [mock menu] registerToMainMenu: %s", plugin.name))
        if plugin.addToMainMenu then
            local items = {}
            plugin:addToMainMenu(items)
            local count = 0; for _ in pairs(items) do count = count + 1 end
            print(string.format("  [mock menu] addToMainMenu returned %d top-level item(s)", count))
            if items.webdav then
                print(string.format("    text=%s sorting_hint=%s sub_items=%d",
                    items.webdav.text, items.webdav.sorting_hint,
                    items.webdav.sub_item_table and #items.webdav.sub_item_table or 0))
            end
        else
            print("  [mock menu] plugin has NO addToMainMenu method!")
        end
    end,
}

print("=== 第 1 步: dofile('webdav.koplugin/main.lua') ===")
local ok, WebDAV_or_err = pcall(function() return dofile("webdav.koplugin/main.lua") end)
if not ok then
    print("LOAD 阶段崩溃: " .. tostring(WebDAV_or_err))
    return
end
print("dofile 返回: type=" .. type(WebDAV_or_err))
if type(WebDAV_or_err) == "table" and WebDAV_or_err.disabled then
    print("插件返回 { disabled = true }, 不会被加载")
    return
end

print("\n=== 第 2 步: WebDAV:new{ui=...}  (会触发 init) ===")
local ok2, inst = pcall(function()
    return WebDAV_or_err:new{ ui = { menu = mock_menu } }
end)
if not ok2 then
    print("INIT 阶段崩溃: " .. tostring(inst))
    return
end
print("实例化成功")
print("实例字段: " .. table.concat((function()
    local t = {}; for k in pairs(inst) do t[#t+1] = k end; return t
end)(), ", "))

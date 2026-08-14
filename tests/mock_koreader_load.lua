-- tests/mock_koreader_load.lua
-- 极简 KOReader mock: 把 main.lua 真正 load 起来, 找出加载/初始化阶段的错误。
--
-- 2026 修订: 之前这里硬编码 pathExists("webdav") = true, 恰好掩盖了插件在真机上
-- 加载失败的真实原因(相对路径检查 + 目录假设)。现在:
--   * datastorage.getFullDataDir 返回本仓库根目录(绝对路径)
--   * util.pathExists 用 io.open 做真实存在性检查
-- 这样 main.lua 里的绝对路径依赖检查(BIN_PATH)在 PC 上就能如实复现设备行为:
--   二进制在仓库里存在 → 加载成功; 临时移走 → 返回 disabled。

-- 推导仓库根: 兼容绝对/相对路径与 / 或 \ 分隔符
local _src = (debug.getinfo(1, "S").source or ""):gsub("^@", "")
local _dir = _src:match("^(.*)[/\\][^/\\]+$") or "."
local REPO_ROOT = _dir:match("^(.*)[/\\]tests$") or (_dir == "tests" and "." or _dir)

package.path = "./?.lua;./webdav.koplugin/?.lua;./tests/?.lua;" .. package.path

-- mock 所有 KOReader SDK 模块
local M = {}
M["ui/bidi"] = { filepath = function(p) return p end }
-- 注意: 与真实 KOReader 一致, getFullDataDir() **不带尾斜杠**
-- (datastorage.lua: "e.g., /mnt/onboard/.adds/koreader")。
-- 之前 mock 返回带 "/" 的路径, 掩盖了 main.lua 拼接路径缺斜杠的 bug。
M["datastorage"] = { getFullDataDir = function() return REPO_ROOT end }
M["device"] = {
    isKindle = function() return false end,
    retrieveNetworkInfo = function() return "127.0.0.1 (mock)" end,
}
M["dispatcher"] = {
    registerAction = function(self, name, opts)
        print(string.format("  [mock dispatcher] registerAction: %s (event=%s)", name, opts.event))
    end,
}
-- 极简 widget 桩: 同时支持 KOReader 标准用法 Widget:new{...}(冒号) 和直接调用
local function mock_infomessage(opts)
    return { _opts = opts }
end
local function mock_inputdialog(opts)
    return setmetatable({ _opts = opts }, {
        __index = {
            onShowKeyboard = function() end,
            getInputText = function() return "3568" end,
        },
    })
end
M["ui/widget/infomessage"] = setmetatable(
    { new = mock_infomessage },
    { __call = function(_, opts) return mock_infomessage(opts) end }
)
M["ui/widget/inputdialog"] = setmetatable(
    { new = mock_inputdialog },
    { __call = function(_, opts) return mock_inputdialog(opts) end }
)
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
-- 真实存在性检查(io.open 读文件; 目录以尾斜杠形式调用时也能识别)
-- 回归防护: 记录被检查的路径, 加载完成后断言它符合绝对路径拼接规则
-- (getFullDataDir() 无尾斜杠, 插件必须自己补 "/")
local checked_bin_path = nil
M["util"] = {
    pathExists = function(p)
        if not checked_bin_path and p:find("webdav%.koplugin/webdav$") then
            checked_bin_path = p
        end
        local ok = false
        local f = io.open(p, "rb")
        if f then
            ok = true
            f:close()
        end
        print(string.format("  [mock util.pathExists] %s -> %s", p, tostring(ok)))
        return ok
    end,
}
M["gettext"] = function(s) return s end
-- 文件夹选择器桩(与 KOReader 的 filemanagerutil.showChooseDialog 签名一致)
M["apps/filemanager/filemanagerutil"] = {
    showChooseDialog = function(title, caller_callback, current_path, default_path, file_filter, reset_button)
        print(string.format("  [mock showChooseDialog] title=%q current=%q default=%q",
            tostring(title), tostring(current_path), tostring(default_path)))
        -- 模拟用户选中 /mnt/us/documents
        caller_callback("/mnt/us/documents")
    end,
}

-- 拦截 require
local orig_require = require
function require(name)
    if M[name] then return M[name] end
    return orig_require(name)
end

-- 包装 os.execute: PC 上没有 nohup/test/iptables, 只记录并假装成功,
-- 让 toggle/start 交互路径能在 mock 里安全演练
local orig_os_execute = os.execute
os.execute = function(cmd)
    print(string.format("  [mock os.execute] %s", tostring(cmd)))
    return 0
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
    delSetting = function(self, key)
        print(string.format("  [mock delSetting] %s", key))
    end,
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
    os.exit(1)
end
print("dofile 返回: type=" .. type(WebDAV_or_err))
if type(WebDAV_or_err) == "table" and WebDAV_or_err.disabled then
    print("插件返回 { disabled = true }, 不会被加载(检查二进制是否存在)")
    os.exit(1)
end

print("\n=== 第 2 步: WebDAV:new{ui=...}  (会触发 init) ===")
local ok2, inst = pcall(function()
    return WebDAV_or_err:new{ ui = { menu = mock_menu } }
end)
if not ok2 then
    print("INIT 阶段崩溃: " .. tostring(inst))
    os.exit(1)
end
print("实例化成功")
print("实例字段: " .. table.concat((function()
    local t = {}; for k in pairs(inst) do t[#t+1] = k end
    table.sort(t)
    return t
end)(), ", "))

-- 回归断言: 依赖检查用的路径必须等于 <data_dir>/webdav.koplugin/webdav
-- (mock 的 getFullDataDir 返回无尾斜杠的 REPO_ROOT, 与真实 API 一致)。
-- 如果 main.lua 拼接时漏了 "/", 这里会得到 REPO_ROOT .. "webdav.koplugin/..." 并 FAIL。
local expected_bin_path = REPO_ROOT .. "/webdav.koplugin/webdav"
if checked_bin_path ~= expected_bin_path then
    print("FAIL: 依赖检查路径不符合预期: " .. tostring(checked_bin_path))
    print("     期望: " .. expected_bin_path)
    os.exit(1)
end

print("\n=== 第 3 步: 交互路径演练(数据目录选择器 + toggle) ===")
-- 3a. 点击"数据目录" → showChooseDialog → 回调更新设置
local mock_touchmenu = { updateItems = function() print("  [mock touchmenu] updateItems") end }
local ok3a = pcall(function()
    inst:show_directory_dialog(mock_touchmenu)
end)
if not ok3a then
    print("FAIL: show_directory_dialog 崩溃: " .. tostring(inst))
    os.exit(1)
end
print("  目录选择后 webdav_directory = " .. inst.webdav_directory)
if inst.webdav_directory ~= "/mnt/us/documents" then
    print("FAIL: 目录选择回调未生效")
    os.exit(1)
end

-- 3b. toggle(未运行 → start) → 不应抛异常
local ok3b = pcall(function()
    inst:onToggleWebDAVServer()
end)
if not ok3b then
    print("FAIL: onToggleWebDAVServer 崩溃")
    os.exit(1)
end
print("  toggle(start) 无异常")

-- 3c. 再次 toggle(此时 PID 文件不存在, 仍走 start 分支) 不应抛异常
local ok3c = pcall(function()
    inst:onToggleWebDAVServer()
end)
if not ok3c then
    print("FAIL: 二次 toggle 崩溃")
    os.exit(1)
end
print("  toggle(再次) 无异常")

print("\n=== 模拟加载成功(与真机路径语义一致) ===")
print("依赖检查路径: " .. checked_bin_path)
os.exit(0)

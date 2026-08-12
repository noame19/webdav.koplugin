-- webdav.koplugin/main.lua
-- KOReader 插件主逻辑:
-- 1. 仿官方 SSH.koplugin 的 toggle/菜单/进程管理模式
-- 2. 集成 hacdias/webdav (Go 单文件二进制,详见 webdav_config.lua)
-- 3. Kindle 设备: 启停时维护 iptables INPUT/OUTPUT 规则(v3 幂等性)
-- 4. 用户配置: 端口/数据目录/文件模式/用户名/密码/自启,持久化到 G_reader_settings
--
-- 设计依据:
--   docs/superpowers/specs/2026-08-11-koreader-webdav-plugin-design.md (v3.2)
--   计划文档:
--   docs/superpowers/plans/2026-08-11-koreader-webdav-koplugin.md

-- 第三方 KOReader SDK
local BD = require("ui/bidi")
local DataStorage = require("datastorage")
local Device = require("device")
local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ffiutil = require("ffi/util")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")
local T = ffiutil.template

-- 插件内部模块(YAML 配置生成)
local webdav_config = require("webdav_config")

-- 依赖检查: 二进制必须和 main.lua 在同一目录
-- (仿 SSH.koplugin main.lua:21-23 模式)
local path = DataStorage:getFullDataDir()
if not util.pathExists("webdav") then
    return { disabled = true }
end

-- 插件类
local WebDAV = WidgetContainer:extend{
    name = "WebDAV",
    is_doc_only = false,
}

-- 初始化: 读取持久化设置,根据 autostart 决定是否启动,注册菜单与 dispatcher
function WebDAV:init()
    self.webdav_port = G_reader_settings:readSetting("webdav_port") or "3568"
    self.webdav_directory = G_reader_settings:readSetting("webdav_directory") or "/mnt/us"
    self.webdav_readonly = G_reader_settings:isTrue("webdav_readonly")
    self.webdav_username = G_reader_settings:readSetting("webdav_username") or "admin"
    self.webdav_password = G_reader_settings:readSetting("webdav_password") or "webdav12345"
    self.autostart = G_reader_settings:isTrue("webdav_autostart")

    if self.autostart then
        self:start()
    end

    self.ui.menu:registerToMainMenu(self)
    self:onDispatcherRegisterActions()
end

-- 启动 webdav 进程(占位,Task 7 完善)
function WebDAV:start()
    logger.dbg("[Network] WebDAV:start placeholder")
end

-- 判断 webdav 进程是否在跑(用 PID 文件存在性,仿 SSH)
function WebDAV:isRunning()
    return util.pathExists("/tmp/webdav_koreader.pid")
end

-- 停止 webdav 进程(占位,Task 8 完善)
function WebDAV:stop()
    logger.dbg("[Network] WebDAV:stop placeholder")
end

-- 主菜单 toggle 行为
function WebDAV:onToggleWebDAVServer()
    if self:isRunning() then
        self:stop()
    else
        self:start()
    end
end

-- 注册 dispatcher action,允许绑定到 gestures 等插件
function WebDAV:onDispatcherRegisterActions()
    Dispatcher:registerAction("toggle_webdav_server",
        { category = "none", event = "ToggleWebDAVServer",
          title = _("Toggle with KOReader"), general = true })
end

return WebDAV

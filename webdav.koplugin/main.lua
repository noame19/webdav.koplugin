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

-- 启动 webdav 进程
-- 1. mkdir settings 目录
-- 2. 写 YAML 配置
-- 3. Kindle 防火墙放行(v3 幂等性: iptables -C 检查规则是否已存在)
-- 4. 启动后台进程,写 PID 文件
-- 5. 弹 InfoMessage 反馈
function WebDAV:start()
    if self:isRunning() then
        logger.dbg("[Network] Not starting WebDAV server, already running.")
        return
    end

    -- 1. mkdir settings 目录(仿 SSH main.lua:99-101)
    local settings_dir = path .. "/settings/webdav"
    if not util.pathExists(settings_dir) then
        os.execute("mkdir -p " .. settings_dir)
    end

    -- 2. 生成 YAML 配置
    self.config_path = settings_dir .. "/config.yml"
    local yaml = webdav_config.writeConfigYAML(
        self.webdav_port,
        self.webdav_directory,
        self.webdav_readonly,
        self.webdav_username,
        self.webdav_password)
    local f = io.open(self.config_path, "w")
    if f then
        f:write(yaml)
        f:close()
    else
        logger.warn("[Network] WebDAV: cannot open config file for writing:", self.config_path)
    end

    -- 3. Kindle 防火墙放行(v3 幂等性保护)
    if Device:isKindle() then
        -- 3a. INPUT 规则: 先 check 已存在就跳过 -A
        local input_check = string.format(
            "iptables -C INPUT -p tcp --dport %s -m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT 2>/dev/null",
            self.webdav_port)
        if os.execute(input_check) ~= 0 then
            os.execute(string.format("%s %s %s",
                "iptables -A INPUT -p tcp --dport", self.webdav_port,
                "-m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT"))
        end
        -- 3b. OUTPUT 规则同理
        local output_check = string.format(
            "iptables -C OUTPUT -p tcp --sport %s -m conntrack --ctstate ESTABLISHED -j ACCEPT 2>/dev/null",
            self.webdav_port)
        if os.execute(output_check) ~= 0 then
            os.execute(string.format("%s %s %s",
                "iptables -A OUTPUT -p tcp --sport", self.webdav_port,
                "-m conntrack --ctstate ESTABLISHED -j ACCEPT"))
        end
    end

    -- 4. 启动并保存 PID(webdav 无 -P 选项,用 shell & echo $!)
    local cmd = string.format(
        "./webdav -c %s & echo $! > /tmp/webdav_koreader.pid",
        self.config_path)
    logger.dbg("[Network] Launching WebDAV server: ", cmd)
    if os.execute(cmd) == 0 then
        UIManager:show(InfoMessage:new{
            timeout = 10,
            text = T(_("WebDAV server started.\n\nWebDAV port: %1\n%2"),
                self.webdav_port,
                Device.retrieveNetworkInfo and Device:retrieveNetworkInfo()
                    or _("Could not retrieve network info.")),
        })
    else
        UIManager:show(InfoMessage:new{
            icon = "notice-warning",
            text = _("Failed to start WebDAV server."),
        })
    end
end

-- 判断 webdav 进程是否在跑(用 PID 文件存在性,仿 SSH)
function WebDAV:isRunning()
    return util.pathExists("/tmp/webdav_koreader.pid")
end

-- 内部: 实际停进程逻辑
---@param force boolean 若优雅停不掉是否强杀(目前 v3.2 不暴露 force 选项,保留以便将来扩展)
---@return boolean ok, string|nil err
function WebDAV:stopPlugin(force)
    if not self:isRunning() then
        return true
    end

    local pid_path = "/tmp/webdav_koreader.pid"
    local pid
    local function readPID()
        local f = io.open(pid_path, "r")
        if not f then return nil end
        local s = f:read("*l")
        f:close()
        return s and tonumber(s) or nil
    end
    pid = readPID()

    local function isProcAlive(p)
        return p and util.pathExists("/proc/" .. p)
    end

    local function send(sig, p)
        return os.execute(string.format("kill -%s %d 2>/dev/null", sig, p)) == 0
    end

    send("TERM", pid)
    for _ = 1, 20 do
        if not isProcAlive(pid) then break end
        ffiutil.sleep(0.1)
    end

    if isProcAlive(pid) and force then
        send("KILL", pid)
        for _ = 1, 10 do
            if not isProcAlive(pid) then break end
            ffiutil.sleep(0.1)
        end
    end

    -- Kindle 撤销 iptables
    if Device:isKindle() then
        os.execute(string.format("%s %s %s",
            "iptables -D INPUT -p tcp --dport", self.webdav_port,
            "-m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT"))
        os.execute(string.format("%s %s %s",
            "iptables -D OUTPUT -p tcp --sport", self.webdav_port,
            "-m conntrack --ctstate ESTABLISHED -j ACCEPT"))
    end

    if not isProcAlive(pid) then
        os.remove(pid_path)
        return true
    end
    return false, "webdav process did not exit"
end

-- 用户面停进程入口
function WebDAV:stop()
    local ok, err = self:stopPlugin(false)
    if not ok then
        logger.warn("WebDAV: graceful stop failed:", err)
        UIManager:show(InfoMessage:new{
            icon = "notice-warning",
            text = _("WebDAV server is still shutting down… Active connections may remain until they are closed."),
            timeout = 3,
        })
        return
    end
    UIManager:show(InfoMessage:new{
        text = _("WebDAV server stopped."),
        timeout = 2,
    })
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

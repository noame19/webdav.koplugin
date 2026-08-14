-- webdav.koplugin/main.lua
-- KOReader WebDAV 服务器插件主逻辑:
--   1. 仿官方 SSH.koplugin 的 toggle/菜单/进程管理模式
--   2. 集成 hacdias/webdav (Go 单文件二进制, YAML 配置内联在本文件)
--   3. Kindle 设备: 启停时维护 iptables INPUT/OUTPUT 规则(双向幂等)
--   4. 用户配置: 端口/数据目录/文件模式/用户名/密码/自启/强制关停, 持久化到 G_reader_settings
--
-- 重要(与旧设计文档假设的差异, 均已按 KOReader 实际行为修正):
--   * KOReader 的 PluginLoader 用 dofile() 加载插件 main.lua, 但**不会** chdir 到
--     插件目录, cwd 始终是 KOReader 安装目录(如 /mnt/us/koreader, 见各平台
--     koreader.sh 的 cd "$KOREADER_DIR")。官方 SSH.koplugin 能直接用相对路径
--     "./dropbear", 是因为它的 dropbear 二进制部署在 KOReader 根目录
--     (见 platform/kindle/extensions/koreader/bin/koreader-ext.sh 的
--     "(cd /mnt/us/koreader && ./dropbear ...)")。
--     本插件的 webdav 二进制位于插件目录内(plugins/webdav.koplugin/webdav),
--     因此必须用绝对路径: 否则依赖检查失败会静默禁用插件(菜单和插件列表都不显示)。
--   * 所有 .lua 文件必须是 UTF-8 无 BOM; 带 BOM 的 chunk 在部分 LuaJIT 版本上
--     直接语法错误, 插件同样无法加载(PC 端 luac 会跳过 BOM 所以测不出来)。
--
-- 设计依据:
--   docs/superpowers/specs/2026-08-11-koreader-webdav-plugin-design.md (v3.2, 部分修正)
--   计划文档:
--   docs/superpowers/plans/2026-08-11-koreader-webdav-koplugin.md

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

-- 常量
local PID_PATH = "/tmp/webdav_koreader.pid"
local LOG_PATH = "/tmp/webdav_koreader.log"
local SETTINGS_DIR_NAME = "webdav"
local CONFIG_FILE_NAME = "config.yml"

-- 插件目录定位: 从当前 chunk 的加载路径推导, 兼容默认安装位置和
-- extra_plugin_paths; 推导失败时回退到默认安装位置。
local function get_plugin_dir()
    local src = debug.getinfo(1, "S").source or ""
    if src:sub(1, 1) == "@" then src = src:sub(2) end
    local dir = src:match("^(.*)[/\\]main%.lua$")
    if dir then
        if dir:sub(1, 1) == "/" then return dir end
        -- 相对路径(如 "plugins/webdav.koplugin"), 以 KOReader 工作目录为基准绝对化
        dir = dir:gsub("^%.?/", "")
        return DataStorage:getFullDataDir() .. dir
    end
    return DataStorage:getFullDataDir() .. "plugins/webdav.koplugin"
end

local PLUGIN_DIR = get_plugin_dir()
local BIN_PATH = PLUGIN_DIR .. "/webdav"

-- 依赖检查: webdav 二进制必须存在(绝对路径, 见文件头注释)。
-- 注意: 二进制缺失时返回 { disabled = true }, KOReader 会静默跳过该插件
-- (既不出现在主菜单, 也不出现在插件管理器列表), 所以这里必须打日志便于排查。
if not util.pathExists(BIN_PATH) then
    logger.warn("[Network] webdav binary not found at " .. BIN_PATH .. ", plugin not loading")
    return { disabled = true }
end

local path = DataStorage:getFullDataDir()

-- YAML 配置生成(内联, 无外部文件依赖)
local webdav_config = {}

-- 把字符串转成 YAML 安全 scalar:
--   - 含控制字符(nil) → 调用方回退到默认值
--   - 只含安全字符且不是数字/关键字 → 直接返回(plain scalar)
--   - 否则用双引号包, 转义 \\ 和 "
local function yaml_safe_string(s)
    if s == nil or s == "" then return '""' end
    if s:find("[\x00-\x1f\x7f]") then return nil end
    local lower = s:lower()
    local looks_like_number = s:match("^[%-%+%d.eE]+$") ~= nil
    local is_yaml_keyword = lower == "true" or lower == "false" or lower == "null"
        or lower == "yes" or lower == "no" or lower == "on" or lower == "off"
    local safe_chars_only = not s:find("[^%w/._%-]")
    if safe_chars_only and not looks_like_number and not is_yaml_keyword then
        return s
    end
    s = s:gsub('\\', '\\\\'):gsub('"', '\\"')
    return '"' .. s .. '"'
end

function webdav_config.writeConfigYAML(port, directory, readonly, username, password)
    local permissions = readonly and "R" or "CRUD"
    -- username/password/directory 都走 yaml_safe_string 防御 YAML 注入
    -- 任何含控制字符的输入回退到占位符, 让 webdav 启动后报错(比静默吞掉更安全)
    local u = yaml_safe_string(username) or '"__invalid_username__"'
    local p = yaml_safe_string(password) or '"__invalid_password__"'
    local d = yaml_safe_string(directory) or '"/mnt/us"'
    return string.format([[
address: 0.0.0.0
port: %s
directory: %s
permissions: %s
users:
  - username: %s
    password: %s
log:
  format: console
  outputs:
    - stderr
]], tostring(port), d, permissions, u, p)
end
-- 输入校验辅助(模块级, 所有对话框共享)
local function trim(s)
    return (s or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function has_control_char(s)
    return s:find("[\x00-\x1f\x7f]") ~= nil
end

-- 验证目录: 存在 → ok; 不存在 → mkdir -p; 都失败 → 报错
-- 用 %q 防 shell 注入
local function validate_directory(value)
    if util.pathExists(value) then return true end
    if os.execute(string.format("mkdir -p %q", value)) ~= 0 then
        return false, "mkdir failed"
    end
    if not util.pathExists(value) then
        return false, "mkdir reported success but dir is still missing"
    end
    return true
end

-- 插件类
local WebDAV = WidgetContainer:extend{
    name = "webdav",
    is_doc_only = false,
}

-- PID 文件辅助: 读 + 探活
function WebDAV:readPID()
    local f = io.open(PID_PATH, "r")
    if not f then return nil end
    local s = f:read("*l")
    f:close()
    return s and tonumber(s) or nil
end

function WebDAV:isProcAlive(p)
    if not p then return false end
    -- /proc/$pid 是最直接的探活方式, Kindle/Kobo 都支持
    if util.pathExists("/proc/" .. p) then return true end
    -- /proc 不可用时回退到 kill -0 信号探测
    return os.execute(string.format("kill -0 %d 2>/dev/null", p)) == 0
end

-- 判断 webdav 进程是否在跑(读 PID + 探活 + 僵尸态自动清理)
function WebDAV:isRunning()
    if not util.pathExists(PID_PATH) then return false end
    local pid = self:readPID()
    if not pid then
        -- PID 文件存在但内容无效, 清理
        os.remove(PID_PATH)
        return false
    end
    if not self:isProcAlive(pid) then
        -- PID 文件存在但进程已死, 清理(防 toggle 卡死)
        os.remove(PID_PATH)
        return false
    end
    return true
end

-- Kindle iptables 规则管理(双向幂等)
-- add=true → 加规则; add=false → 删规则。两者都用 -C 探活避免无效操作/噪声
function WebDAV:applyKindleFirewall(add)
    if not Device:isKindle() then return end
    local op = add and "-A" or "-D"
    local specs = {
        string.format("INPUT -p tcp --dport %s -m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT",
            self.webdav_port),
        string.format("OUTPUT -p tcp --sport %s -m conntrack --ctstate ESTABLISHED -j ACCEPT",
            self.webdav_port),
    }
    for _, spec in ipairs(specs) do
        local present = os.execute("iptables -C " .. spec .. " 2>/dev/null") == 0
        if (add and not present) or (not add and present) then
            os.execute("iptables " .. op .. " " .. spec .. " 2>/dev/null")
        end
    end
end

-- 初始化: 读取持久化设置, 根据 autostart 决定是否启动, 注册菜单
function WebDAV:init()
    self.webdav_port = G_reader_settings:readSetting("webdav_port") or "3568"
    self.webdav_directory = G_reader_settings:readSetting("webdav_directory") or "/mnt/us"
    self.webdav_readonly = G_reader_settings:isTrue("webdav_readonly")
    self.webdav_username = G_reader_settings:readSetting("webdav_username") or "admin"
    self.webdav_password = G_reader_settings:readSetting("webdav_password") or "webdav12345"
    self.autostart = G_reader_settings:isTrue("webdav_autostart")
    self.force_kill_clients = G_reader_settings:isTrue("webdav_force_kill_clients")

    if self.autostart then
        -- pcall 包住: 即使 start() 出错, 也要让菜单能注册
        -- (避免因 iptables / 权限 / 二进制异常等导致用户看不到整个插件)
        local ok, err = pcall(function() self:start() end)
        if not ok then
            logger.warn("[Network] WebDAV autostart failed:", err)
        end
    end

    self.ui.menu:registerToMainMenu(self)
    self:onDispatcherRegisterActions()
end

-- 启动 webdav 进程
function WebDAV:start()
    if self:isRunning() then
        logger.dbg("[Network] Not starting WebDAV server, already running.")
        return
    end

    -- 1. 检查二进制可执行位(SCP 可能丢 +x, 仿 filebrowserplus 的修复)
    if os.execute(string.format("test -x %q", BIN_PATH)) ~= 0 then
        logger.warn("[Network] WebDAV binary not executable, attempting chmod +x")
        os.execute(string.format("chmod +x %q 2>/dev/null", BIN_PATH))
        if os.execute(string.format("test -x %q", BIN_PATH)) ~= 0 then
            UIManager:show(InfoMessage:new{
                icon = "notice-warning",
                text = T(_("Cannot execute %1. Check file permissions."), BIN_PATH),
            })
            return
        end
    end

    -- 2. mkdir settings 目录(失败显式报告, 不再静默)
    local settings_dir = path .. "settings/" .. SETTINGS_DIR_NAME
    if not util.pathExists(settings_dir) then
        if os.execute(string.format("mkdir -p %q", settings_dir)) ~= 0 then
            UIManager:show(InfoMessage:new{
                icon = "notice-warning",
                text = T(_("Failed to create settings directory: %1"), settings_dir),
            })
            return
        end
    end

    -- 3. 生成 YAML 配置(写失败不再继续启动, 否则会用空配置跑出意外行为)
    self.config_path = settings_dir .. "/" .. CONFIG_FILE_NAME
    local yaml = webdav_config.writeConfigYAML(
        self.webdav_port,
        self.webdav_directory,
        self.webdav_readonly,
        self.webdav_username,
        self.webdav_password)
    local f = io.open(self.config_path, "w")
    if not f then
        UIManager:show(InfoMessage:new{
            icon = "notice-warning",
            text = T(_("Cannot write config file: %1"), self.config_path),
        })
        return
    end
    f:write(yaml)
    f:close()

    -- 4. Kindle 防火墙放行(幂等)
    self:applyKindleFirewall(true)

    -- 5. 启动并保存 PID
    -- nohup + 重定向到 log 文件:
    --   - nohup 防止 KOReader 退出时 SIGHUP 把 webdav 带走
    --   - log 文件给后面探活失败时排错用
    local cmd = string.format(
        "nohup %q -c %q > %s 2>&1 & echo $! > %s",
        BIN_PATH, self.config_path, LOG_PATH, PID_PATH)
    logger.dbg("[Network] Launching WebDAV server:", cmd)
    if os.execute(cmd) ~= 0 then
        -- shell 本身就 launch 失败(noexec / nohup 不存在等), 清理半套状态
        self:applyKindleFirewall(false)
        UIManager:show(InfoMessage:new{
            icon = "notice-warning",
            text = _("Failed to launch WebDAV process."),
        })
        return
    end

    -- 6. 探活: shell 写完 PID 后给 webdav 一点时间启动, isRunning() 双重确认
    -- 这是关键修复: 原版只检查 os.execute 退码, 而 "& echo" 永远退 0,
    -- 导致端口冲突 / 二进制崩溃 / YAML 错误都会误报"启动成功"
    ffiutil.sleep(0.3)
    if not self:isRunning() then
        -- 启动失败, 清理全部状态
        os.remove(PID_PATH)
        self:applyKindleFirewall(false)
        UIManager:show(InfoMessage:new{
            icon = "notice-warning",
            text = T(_("WebDAV process exited immediately. See %1 for details.\n\nPort: %2\nDirectory: %3"),
                LOG_PATH, self.webdav_port, self.webdav_directory),
            timeout = 8,
        })
        return
    end

    UIManager:show(InfoMessage:new{
        timeout = 10,
        text = T(_("WebDAV server started.\n\nWebDAV port: %1\n%2"),
            self.webdav_port,
            Device.retrieveNetworkInfo and Device:retrieveNetworkInfo()
                or _("Could not retrieve network info.")),
    })
end

-- 内部: 实际停进程逻辑
---@param force boolean 若优雅停不掉是否强杀
---@return boolean ok, string|nil err
-- 该方法同时是 KOReader 插件管理器的 stopPlugin 钩子:
-- 用户在"工具 → 插件管理"里禁用/删除本插件时, PluginLoader:stopPluginInstance
-- 会调用 instance:stopPlugin(force), 确保 webdav 进程和 iptables 规则被清理。
function WebDAV:stopPlugin(force)
    if not self:isRunning() then
        return true
    end

    local pid = self:readPID()

    local function send(sig, p)
        if not p then return false end
        return os.execute(string.format("kill -%s %d 2>/dev/null", sig, p)) == 0
    end

    send("TERM", pid)
    for _ = 1, 20 do
        if not self:isProcAlive(pid) then break end
        ffiutil.sleep(0.1)
    end

    if self:isProcAlive(pid) and force then
        send("KILL", pid)
        for _ = 1, 10 do
            if not self:isProcAlive(pid) then break end
            ffiutil.sleep(0.1)
        end
    end

    -- Kindle 撤销 iptables(幂等)
    self:applyKindleFirewall(false)

    if not self:isProcAlive(pid) then
        os.remove(PID_PATH)
        return true
    end
    return false, "webdav process did not exit"
end

-- 用户面停进程入口
function WebDAV:stop()
    local ok, err = self:stopPlugin(self.force_kill_clients)
    if not ok then
        logger.warn("WebDAV: stop failed:", err)
        -- 兜底: 用 force_kill_clients 还是停不掉, 直接 killall 干掉所有 webdav
        -- (仿 SSH.koplugin 的最后兜底)
        if os.execute("killall -9 webdav 2>/dev/null") == 0 then
            os.remove(PID_PATH)
            self:applyKindleFirewall(false)
            UIManager:show(InfoMessage:new{
                text = _("WebDAV server forcefully stopped."),
                timeout = 2,
            })
            return
        end
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

-- 插件管理器 "Disable plugin and delete settings" 的钩子:
-- 清理 G_reader_settings 里的 webdav_* 配置和运行时生成的配置目录
function WebDAV:deletePluginSettings()
    local keys = {
        "webdav_port",
        "webdav_directory",
        "webdav_readonly",
        "webdav_username",
        "webdav_password",
        "webdav_autostart",
        "webdav_force_kill_clients",
    }
    for _, key in ipairs(keys) do
        G_reader_settings:delSetting(key)
    end
    local settings_dir = path .. "settings/" .. SETTINGS_DIR_NAME
    if util.pathExists(settings_dir) then
        os.execute(string.format("rm -rf %q", settings_dir))
    end
end

-- 主菜单 toggle 行为
function WebDAV:onToggleWebDAVServer()
    if self:isRunning() then
        self:stop()
    else
        self:start()
    end
end

-- 注册 dispatcher action(供 gestures 等插件绑定)
function WebDAV:onDispatcherRegisterActions()
    Dispatcher:registerAction("toggle_webdav_server",
        { category = "none", event = "ToggleWebDAVServer",
          title = _("Toggle WebDAV server"), general = true })
end

-- 主菜单注册
-- sorting_hint = "network" 把本项挂到"设置 → 网络"分组下
-- (KOReader MenuSorter 通过 sorting_hint 把菜单项归入已有分组;
--  不带 hint 的项会以孤儿项出现在主菜单最前面并带 "…" 前缀)
function WebDAV:addToMainMenu(menu_items)
    menu_items.webdav = {
        text = _("WebDAV server"),
        sorting_hint = "network",
        checked_func = function() return self:isRunning() end,
        hold_callback = function(touchmenu_instance)
            self:onToggleWebDAVServer()
            ffiutil.sleep(1)
            touchmenu_instance:updateItems()
        end,
        sub_item_table = {
            -- 子项 1: 启用 toggle
            {
                text = _("WebDAV server"),
                checked_func = function() return self:isRunning() end,
                check_callback_updates_menu = true,
                callback = function(touchmenu_instance)
                    self:onToggleWebDAVServer()
                    ffiutil.sleep(1)
                    touchmenu_instance:updateItems()
                end,
            },
            -- 子项 2: 端口
            {
                text_func = function()
                    return T(_("WebDAV port: %1"), self.webdav_port)
                end,
                keep_menu_open = true,
                enabled_func = function() return not self:isRunning() end,
                callback = function(touchmenu_instance)
                    self:show_port_dialog(touchmenu_instance)
                end,
            },
            -- 子项 3: 数据目录
            {
                text_func = function()
                    return T(_("Data directory: %1"), self.webdav_directory)
                end,
                keep_menu_open = true,
                enabled_func = function() return not self:isRunning() end,
                callback = function(touchmenu_instance)
                    self:show_directory_dialog(touchmenu_instance)
                end,
            },
            -- 子项 4: 文件模式 toggle(勾上=读写)
            {
                text_func = function()
                    return T(_("File mode: %1"),
                        self.webdav_readonly and _("Read only") or _("Read/Write"))
                end,
                checked_func = function() return not self.webdav_readonly end,
                enabled_func = function() return not self:isRunning() end,
                keep_menu_open = true,
                callback = function()
                    self.webdav_readonly = not self.webdav_readonly
                    G_reader_settings:flipNilOrFalse("webdav_readonly")
                end,
            },
            -- 子项 5: 用户名
            {
                text_func = function()
                    return T(_("Username: %1"), self.webdav_username)
                end,
                keep_menu_open = true,
                enabled_func = function() return not self:isRunning() end,
                callback = function(touchmenu_instance)
                    self:show_username_dialog(touchmenu_instance)
                end,
            },
            -- 子项 6: 密码(菜单里遮罩显示, 对话框内可编辑)
            {
                text_func = function()
                    return T(_("Password: %1"), string.rep("*", #self.webdav_password))
                end,
                help_text = _("Stored in plaintext in KOReader settings. Visible to anyone with shell access to the device."),
                keep_menu_open = true,
                enabled_func = function() return not self:isRunning() end,
                callback = function(touchmenu_instance)
                    self:show_password_dialog(touchmenu_instance)
                end,
            },
            -- 子项 7: 开机自启
            {
                text = _("Start with KOReader"),
                checked_func = function() return self.autostart end,
                keep_menu_open = true,
                callback = function()
                    self.autostart = not self.autostart
                    G_reader_settings:flipNilOrFalse("webdav_autostart")
                end,
            },
            -- 子项 8: 强制关停(separator 分组, 与 SSH 插件 force_kill_clients 对齐)
            {
                text = _("Force close on stop"),
                help_text = _("When enabled, all active WebDAV sessions are terminated immediately when stopping the server. Use this if a long upload or transfer is blocking shutdown."),
                checked_func = function() return self.force_kill_clients end,
                callback = function()
                    self.force_kill_clients = not self.force_kill_clients
                    G_reader_settings:flipNilOrFalse("webdav_force_kill_clients")
                end,
                separator = true,
            },
        },
    }
end

-- 端口 InputDialog
function WebDAV:show_port_dialog(touchmenu_instance)
    self.port_dialog = InputDialog:new{
        title = _("WebDAV port"),
        input = self.webdav_port,
        input_type = "number",
        input_hint = self.webdav_port,
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(self.port_dialog)
                    end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local value = tonumber(self.port_dialog:getInputText())
                        -- 1-65535 整数, 拒绝空/小数/越界
                        if value and value == math.floor(value) and value >= 1 and value <= 65535 then
                            self.webdav_port = tostring(value)
                            G_reader_settings:saveSetting("webdav_port", self.webdav_port)
                            UIManager:close(self.port_dialog)
                            touchmenu_instance:updateItems()
                        else
                            UIManager:show(InfoMessage:new{
                                icon = "notice-warning",
                                text = _("Port must be an integer between 1 and 65535."),
                                timeout = 3,
                            })
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(self.port_dialog)
    self.port_dialog:onShowKeyboard()
end

-- 数据目录 InputDialog
function WebDAV:show_directory_dialog(touchmenu_instance)
    self.directory_dialog = InputDialog:new{
        title = _("Data directory"),
        input = self.webdav_directory,
        input_type = "text",
        input_hint = "/mnt/us",
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(self.directory_dialog)
                    end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local value = trim(self.directory_dialog:getInputText())
                        if value == "" then
                            UIManager:show(InfoMessage:new{
                                icon = "notice-warning",
                                text = _("Directory cannot be empty."),
                                timeout = 3,
                            })
                            return
                        end
                        if has_control_char(value) then
                            UIManager:show(InfoMessage:new{
                                icon = "notice-warning",
                                text = _("Directory contains invalid characters."),
                                timeout = 3,
                            })
                            return
                        end
                        local ok, err = validate_directory(value)
                        if not ok then
                            UIManager:show(InfoMessage:new{
                                icon = "notice-warning",
                                text = T(_("Cannot use directory %1: %2"), value, err or "unknown error"),
                                timeout = 5,
                            })
                            return
                        end
                        self.webdav_directory = value
                        G_reader_settings:saveSetting("webdav_directory", self.webdav_directory)
                        UIManager:close(self.directory_dialog)
                        touchmenu_instance:updateItems()
                    end,
                },
            },
        },
    }
    UIManager:show(self.directory_dialog)
    self.directory_dialog:onShowKeyboard()
end

-- 用户名 InputDialog
function WebDAV:show_username_dialog(touchmenu_instance)
    self.username_dialog = InputDialog:new{
        title = _("Username"),
        input = self.webdav_username,
        input_type = "text",
        input_hint = "admin",
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(self.username_dialog)
                    end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local value = trim(self.username_dialog:getInputText())
                        if value == "" then
                            UIManager:show(InfoMessage:new{
                                icon = "notice-warning",
                                text = _("Username cannot be empty."),
                                timeout = 3,
                            })
                            return
                        end
                        if has_control_char(value) then
                            UIManager:show(InfoMessage:new{
                                icon = "notice-warning",
                                text = _("Username contains invalid characters."),
                                timeout = 3,
                            })
                            return
                        end
                        self.webdav_username = value
                        G_reader_settings:saveSetting("webdav_username", self.webdav_username)
                        UIManager:close(self.username_dialog)
                        touchmenu_instance:updateItems()
                    end,
                },
            },
        },
    }
    UIManager:show(self.username_dialog)
    self.username_dialog:onShowKeyboard()
end

-- 密码 InputDialog
-- 注意: KOReader 的密码遮罩参数是 text_type = "password"(InputText 的字段,
-- 附带 "Show password" 开关), 不是 input_type; input_type 只决定键盘类型。
function WebDAV:show_password_dialog(touchmenu_instance)
    self.password_dialog = InputDialog:new{
        title = _("Password"),
        input = self.webdav_password,
        text_type = "password",
        input_hint = "********",
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(self.password_dialog)
                    end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local value = self.password_dialog:getInputText()
                        if value == "" then
                            UIManager:show(InfoMessage:new{
                                icon = "notice-warning",
                                text = _("Password cannot be empty."),
                                timeout = 3,
                            })
                            return
                        end
                        if has_control_char(value) then
                            UIManager:show(InfoMessage:new{
                                icon = "notice-warning",
                                text = _("Password contains invalid characters."),
                                timeout = 3,
                            })
                            return
                        end
                        self.webdav_password = value
                        G_reader_settings:saveSetting("webdav_password", self.webdav_password)
                        UIManager:close(self.password_dialog)
                        touchmenu_instance:updateItems()
                    end,
                },
            },
        },
    }
    UIManager:show(self.password_dialog)
    self.password_dialog:onShowKeyboard()
end

return WebDAV

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

-- KOReader 进程内"本次会话是否已自动启动过 webdav"的标记。
-- is_doc_only=false 的插件每次开书/进 FileManager 都会被 KOReader 重新实例化
-- (frontend/apps/reader/readerui.lua:464, frontend/apps/filemanager/filemanager.lua:419),
-- 没有这个标记, "开机自启"会被每次开书重复触发, 违背用户意图。
-- 模块级变量随 KOReader 进程生命周期稳定, 进程退出时销毁, 下次启动自然重置,
-- 这正是"开机自启 = KOReader 启动那一刻的一次性动作"语义。
local webdav_autostart_session_done = false

-- 常量
local PID_PATH = "/tmp/webdav_koreader.pid"
local LOG_PATH = "/tmp/webdav_koreader.log"
local SETTINGS_DIR_NAME = "webdav"
local CONFIG_FILE_NAME = "config.yml"

-- 路径拼接: DataStorage:getFullDataDir() 返回的是**不带尾斜杠**的目录
-- (如 /mnt/us/koreader, 见 datastorage.lua 文档示例), 必须显式补 "/"。
local function join_path(base, tail)
    if base:sub(-1) == "/" then return base .. tail end
    return base .. "/" .. tail
end

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
        return join_path(DataStorage:getFullDataDir(), dir)
    end
    return join_path(DataStorage:getFullDataDir(), "plugins/webdav.koplugin")
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

-- 控制字符检查(0-31 和 127)。
-- 注意: 不能用模式匹配 "[\x00-\x1f\x7f]" —— \x00 转义后模式串含 NUL 字节,
-- 而 Lua 5.1/LuaJIT 的模式禁止内嵌 NUL("A pattern cannot contain embedded
-- zeros. Use %z instead."), 会报 "malformed pattern (missing ']')"。
-- PC 的 Lua 5.4 对此宽容, 所以本地测试测不出来, 设备上 toggle 才暴露。
-- 定义在 webdav_config 之后、yaml_safe_string 之前, 让 writeConfigYAML_spec
-- 的文本提取(从 "local webdav_config" 开始)能包含它。
local function has_control_char(s)
    for i = 1, #s do
        local b = s:byte(i)
        if b < 32 or b == 127 then return true end
    end
    return false
end

-- 把字符串转成 YAML 安全 scalar:
--   - 含控制字符(nil) → 调用方回退到默认值
--   - 只含安全字符且不是数字/关键字 → 直接返回(plain scalar)
--   - 否则用双引号包, 转义 \\ 和 "
local function yaml_safe_string(s)
    if s == nil or s == "" then return '""' end
    if has_control_char(s) then return nil end
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

-- 数据目录现在用 KOReader 文件夹选择器(filemanagerutil.showChooseDialog),
-- 只能选已存在的目录, 不再需要 validate_directory / mkdir。

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
    -- 调试日志开关: 开启时 webdav 日志写 /tmp/webdav_koreader.log, 关闭时丢弃
    self.webdav_debug_log = G_reader_settings:isTrue("webdav_debug_log")

    -- 自启动条件: 用户勾选了自启 && 本会话还没自启过 && webdav 进程当前未运行。
    -- 任一不满足 → init() 完全跳过, 不影响 webdav 当前开/关状态, 这保证:
    --   * KOReader 启动时按自启开关自启一次 (webdav_autostart_session_done 翻转)
    --   * 后续开书 / 进 FileManager 实例化新 widget 时跳过 (flag 已是 true)
    --   * 用户手动 toggle off 后保持关闭 (isRunning() 持续 false 但 flag 仍是 true)
    if self.autostart and not webdav_autostart_session_done and not self:isRunning() then
        -- pcall 包住: 即使 start() 出错, 也要让菜单能注册
        -- (避免因 iptables / 权限 / 二进制异常等导致用户看不到整个插件)
        webdav_autostart_session_done = true  -- 先置位, 启动失败时回滚让下次 init 重试
        local ok, err = pcall(function() self:start() end)
        if not ok then
            webdav_autostart_session_done = false
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
                text = T(_("无法执行 %1。请检查文件权限。"), BIN_PATH),
            })
            return
        end
    end

    -- 2. mkdir settings 目录(失败显式报告, 不再静默)
    local settings_dir = join_path(path, "settings/" .. SETTINGS_DIR_NAME)
    if not util.pathExists(settings_dir) then
        if os.execute(string.format("mkdir -p %q", settings_dir)) ~= 0 then
            UIManager:show(InfoMessage:new{
                icon = "notice-warning",
                text = T(_("无法创建设置目录: %1"), settings_dir),
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
            text = T(_("无法写入配置文件: %1"), self.config_path),
        })
        return
    end
    f:write(yaml)
    f:close()

    -- 4. Kindle 防火墙放行(幂等)
    self:applyKindleFirewall(true)

    -- 5. 启动并保存 PID
    -- nohup 防止 KOReader 退出时 SIGHUP 把 webdav 带走。
    -- 内存/GC: GOMEMLIMIT=64MiB 限制 Go 堆软上限, GOGC=400 降低 GC 频率
    --   (空闲时 GC 几乎不再触发, CPU 近零; 传大文件为流式, 64MiB 足够)。
    -- 日志: 调试开关开启时写 /tmp/webdav_koreader.log(注意 Kindle 的 /tmp 是
    --   tmpfs, 日志增长会占内存); 关闭时丢弃到 /dev/null。
    local log_target = self.webdav_debug_log and LOG_PATH or "/dev/null"
    local cmd = string.format(
        "GOMEMLIMIT=64MiB GOGC=400 nohup %q -c %q > %s 2>&1 & echo $! > %s",
        BIN_PATH, self.config_path, log_target, PID_PATH)
    logger.info("[Network] Launching WebDAV server:", cmd)
    if os.execute(cmd) ~= 0 then
        -- shell 本身就 launch 失败(noexec / nohup 不存在等), 清理半套状态
        self:applyKindleFirewall(false)
        UIManager:show(InfoMessage:new{
            icon = "notice-warning",
            text = _("启动 WebDAV 进程失败。"),
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
        -- 调试日志关闭时日志进了 /dev/null, 提示用户先开开关再重试
        local detail = self.webdav_debug_log
            and T(_("详情见 %1。"), LOG_PATH)
            or _("可先开启「调试日志」开关后重试, 以便查看原因。")
        UIManager:show(InfoMessage:new{
            icon = "notice-warning",
            text = T(_("WebDAV 进程启动后立即退出。%1\n\n端口: %2\n目录: %3"),
                detail, self.webdav_port, self.webdav_directory),
            timeout = 8,
        })
        return
    end

    UIManager:show(InfoMessage:new{
        timeout = 10,
        text = T(_("WebDAV 服务已启动\n\nWebDAV 端口: %1\n%2"),
            self.webdav_port,
            Device.retrieveNetworkInfo and Device:retrieveNetworkInfo()
                or _("无法获取网络信息。")),
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
-- 说明: 原"停止时强制关闭"开关已移除 —— webdav 是单进程 HTTP 服务,
-- SIGTERM 后唯一可能挂住的是活跃传输连接, 个人使用几乎遇不到;
-- 强制终止能力保留为默认行为(优雅 → 强杀 → killall 三级兜底)。
function WebDAV:stop()
    local ok, err = self:stopPlugin(true)
    if not ok then
        logger.warn("WebDAV: stop failed:", err)
        -- 兜底: 强杀还是停不掉, 直接 killall 干掉所有 webdav
        if os.execute("killall -9 webdav 2>/dev/null") == 0 then
            os.remove(PID_PATH)
            self:applyKindleFirewall(false)
            UIManager:show(InfoMessage:new{
                text = _("WebDAV 服务已被强制停止。"),
                timeout = 2,
            })
            return
        end
        UIManager:show(InfoMessage:new{
            icon = "notice-warning",
            text = _("WebDAV 服务仍在关闭中… 活动连接可能要等客户端关闭后才断开。"),
            timeout = 3,
        })
        return
    end
    UIManager:show(InfoMessage:new{
        text = _("WebDAV 服务已停止。"),
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
        "webdav_debug_log",
        "webdav_force_kill_clients", -- 旧版遗留键, 一并清理
    }
    for _, key in ipairs(keys) do
        G_reader_settings:delSetting(key)
    end
    local settings_dir = join_path(path, "settings/" .. SETTINGS_DIR_NAME)
    if util.pathExists(settings_dir) then
        os.execute(string.format("rm -rf %q", settings_dir))
    end
end

-- 主菜单 toggle 行为
-- 注意: KOReader 的 PluginLoader 会把 on* 事件处理器包进 HandlerSandbox,
-- 其中任何异常只会写 crash.log 而不会弹窗(表现为"点击没反应")。
-- 所以这里再包一层 pcall, 把错误直接弹给用户看, 便于定位。
function WebDAV:onToggleWebDAVServer()
    local ok, err = pcall(function()
        if self:isRunning() then
            self:stop()
        else
            self:start()
        end
    end)
    if not ok then
        logger.err("[Network] Toggle WebDAV server failed:", err)
        UIManager:show(InfoMessage:new{
            icon = "notice-warning",
            text = T(_("切换 WebDAV 服务失败: %1"), tostring(err)),
            timeout = 10,
        })
    end
end

-- 注册 dispatcher action(供 gestures 等插件绑定)
function WebDAV:onDispatcherRegisterActions()
    Dispatcher:registerAction("toggle_webdav_server",
        { category = "none", event = "ToggleWebDAVServer",
          title = _("切换 WebDAV 服务"), general = true })
end

-- 主菜单注册
-- sorting_hint = "network" 把本项挂到"设置 → 网络"分组下
-- (KOReader MenuSorter 通过 sorting_hint 把菜单项归入已有分组;
--  不带 hint 的项会以孤儿项出现在主菜单最前面并带 "…" 前缀)
-- 文案按 docs/superpowers/specs/2026-08-11-koreader-webdav-plugin-design.md
-- §15.3 的英文/中文对照表(中文直接作为 gettext key, 未翻译时显示中文原文)。
function WebDAV:addToMainMenu(menu_items)
    menu_items.webdav = {
        text = _("WebDAV 服务"),
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
                text = _("WebDAV 服务"),
                checked_func = function() return self:isRunning() end,
                check_callback_updates_menu = true,
                callback = function(touchmenu_instance)
                    self:onToggleWebDAVServer()
                    ffiutil.sleep(1)
                    touchmenu_instance:updateItems()
                end,
            },
            -- 子项 2: 状态(纯显示, 运行中/未运行)
            {
                text_func = function()
                    return self:isRunning() and _("状态: 运行中") or _("状态: 未运行")
                end,
            },
            -- 子项 3: 端口
            {
                text_func = function()
                    return T(_("WebDAV 端口: %1"), self.webdav_port)
                end,
                keep_menu_open = true,
                enabled_func = function() return not self:isRunning() end,
                callback = function(touchmenu_instance)
                    self:show_port_dialog(touchmenu_instance)
                end,
            },
            -- 子项 4: 数据目录(KOReader 文件夹选择器, 与屏保插件的
            -- "选择随机图片文件夹"同款, 不用手动输入路径)
            {
                text_func = function()
                    return T(_("数据目录: %1"), self.webdav_directory)
                end,
                keep_menu_open = true,
                enabled_func = function() return not self:isRunning() end,
                callback = function(touchmenu_instance)
                    self:show_directory_dialog(touchmenu_instance)
                end,
            },
            -- 子项 5: 文件模式 toggle(勾上=读写)
            {
                text_func = function()
                    return T(_("文件模式: %1"),
                        self.webdav_readonly and _("只读") or _("读写"))
                end,
                checked_func = function() return not self.webdav_readonly end,
                enabled_func = function() return not self:isRunning() end,
                keep_menu_open = true,
                callback = function()
                    self.webdav_readonly = not self.webdav_readonly
                    G_reader_settings:flipNilOrFalse("webdav_readonly")
                end,
            },
            -- 子项 6: 用户名
            {
                text_func = function()
                    return T(_("用户名: %1"), self.webdav_username)
                end,
                keep_menu_open = true,
                enabled_func = function() return not self:isRunning() end,
                callback = function(touchmenu_instance)
                    self:show_username_dialog(touchmenu_instance)
                end,
            },
            -- 子项 7: 密码(明文显示, 用户要求)
            {
                text_func = function()
                    return T(_("密码: %1"), self.webdav_password)
                end,
                help_text = _("以明文存储在 KOReader 设置中。任何能访问设备 shell 的人都可以看到。"),
                keep_menu_open = true,
                enabled_func = function() return not self:isRunning() end,
                callback = function(touchmenu_instance)
                    self:show_password_dialog(touchmenu_instance)
                end,
            },
            -- 子项 8: 开机自启
            {
                text = _("开机自启"),
                checked_func = function() return self.autostart end,
                keep_menu_open = true,
                callback = function()
                    self.autostart = not self.autostart
                    G_reader_settings:flipNilOrFalse("webdav_autostart")
                end,
            },
            -- 子项 9: 调试日志(separator 分组)
            -- 说明: 原"停止时强制关闭"开关已移除, 停止时固定"优雅→强杀→killall"兜底;
            -- 该开关位让给"调试日志": 开启后 webdav 日志落盘, 便于排查启动问题。
            {
                text = _("调试日志"),
                help_text = _("开启后，webdav 服务日志写入 /tmp/webdav_koreader.log，便于排查启动问题。默认关闭（日志丢弃，不占用内存）。"),
                checked_func = function() return self.webdav_debug_log end,
                keep_menu_open = true,
                callback = function()
                    self.webdav_debug_log = not self.webdav_debug_log
                    G_reader_settings:flipNilOrFalse("webdav_debug_log")
                end,
                separator = true,
            },
        },
    }
end

-- 端口 InputDialog
function WebDAV:show_port_dialog(touchmenu_instance)
    self.port_dialog = InputDialog:new{
        title = _("设置 WebDAV 端口"),
        input = self.webdav_port,
        input_type = "number",
        input_hint = self.webdav_port,
        buttons = {
            {
                {
                    text = _("取消"),
                    id = "close",
                    callback = function()
                        UIManager:close(self.port_dialog)
                    end,
                },
                {
                    text = _("保存"),
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
                                text = _("端口必须是 1 到 65535 之间的整数。"),
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

-- 数据目录选择
-- 复用 KOReader 官方的文件夹选择器(filemanagerutil.showChooseDialog,
-- 内部是 PathChooser, 与屏保插件"选择随机图片文件夹"完全同款),
-- 用户浏览目录树点选即可, 不用手动输入路径。
-- 提供 "使用默认" 按钮(default_path="/mnt/us")一键回到默认值。
function WebDAV:show_directory_dialog(touchmenu_instance)
    local filemanagerutil = require("apps/filemanager/filemanagerutil")
    filemanagerutil.showChooseDialog(
        _("当前 WebDAV 数据目录:"),
        function(path)
            self.webdav_directory = path
            G_reader_settings:saveSetting("webdav_directory", self.webdav_directory)
            if touchmenu_instance then
                touchmenu_instance:updateItems()
            end
        end,
        self.webdav_directory,
        "/mnt/us",
        nil, -- file_filter: 只选目录, 不选文件
        nil  -- reset_button
    )
end

-- 用户名 InputDialog
function WebDAV:show_username_dialog(touchmenu_instance)
    self.username_dialog = InputDialog:new{
        title = _("设置 WebDAV 用户名"),
        input = self.webdav_username,
        input_type = "text",
        input_hint = "admin",
        buttons = {
            {
                {
                    text = _("取消"),
                    id = "close",
                    callback = function()
                        UIManager:close(self.username_dialog)
                    end,
                },
                {
                    text = _("保存"),
                    is_enter_default = true,
                    callback = function()
                        local value = trim(self.username_dialog:getInputText())
                        if value == "" then
                            UIManager:show(InfoMessage:new{
                                icon = "notice-warning",
                                text = _("用户名不能为空。"),
                                timeout = 3,
                            })
                            return
                        end
                        if has_control_char(value) then
                            UIManager:show(InfoMessage:new{
                                icon = "notice-warning",
                                text = _("用户名包含无效字符。"),
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

-- 密码 InputDialog(明文显示, 用户要求)
function WebDAV:show_password_dialog(touchmenu_instance)
    self.password_dialog = InputDialog:new{
        title = _("设置 WebDAV 密码"),
        input = self.webdav_password,
        input_type = "text",
        input_hint = self.webdav_password,
        buttons = {
            {
                {
                    text = _("取消"),
                    id = "close",
                    callback = function()
                        UIManager:close(self.password_dialog)
                    end,
                },
                {
                    text = _("保存"),
                    is_enter_default = true,
                    callback = function()
                        local value = self.password_dialog:getInputText()
                        if value == "" then
                            UIManager:show(InfoMessage:new{
                                icon = "notice-warning",
                                text = _("密码不能为空。"),
                                timeout = 3,
                            })
                            return
                        end
                        if has_control_char(value) then
                            UIManager:show(InfoMessage:new{
                                icon = "notice-warning",
                                text = _("密码包含无效字符。"),
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

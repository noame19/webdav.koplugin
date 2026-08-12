-- webdav_config.lua
-- 把 webdav.koplugin 的运行时配置转成 hacdias/webdav 的 YAML 配置字符串。
-- 单独成模块是便于 PC 端单测，也是为了让 main.lua 保持简洁。
--
-- 调用方式:
--   local yaml = writeConfigYAML(port, directory, readonly, username, password)
--   返回 YAML 字符串(行尾不带额外空格)。

local M = {}

--- 生成 webdav 进程启动所需的 YAML 配置字符串
---@param port string|number 监听端口
---@param directory string 数据目录绝对路径
---@param readonly boolean true=只读(R) / false=读写(CRUD)
---@param username string basic auth 用户名
---@param password string basic auth 密码(明文,与 ssh 插件同款风险)
---@return string YAML 文本
function M.writeConfigYAML(port, directory, readonly, username, password)
    local permissions = readonly and "R" or "CRUD"
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
]], tostring(port), directory, permissions, username, password)
end

-- 兼容作为 require / loadfile 加载的模块使用
-- PC 端测试通过 loadfile 加载时,这一行把函数注入到 spec 的环境
writeConfigYAML = M.writeConfigYAML
return M

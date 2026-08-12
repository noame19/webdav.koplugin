-- writeConfigYAML_spec.lua
-- 验证 webdav.koplugin 启动时生成的 YAML 配置文件格式
--
-- 实现说明: main.lua 已把 writeConfigYAML 内联(避免漏拷 webdav_config.lua 导致插件崩)。
-- 本测试不复制实现,而是从 main.lua 文本中提取 "local webdav_config = {}" +
-- "function webdav_config.writeConfigYAML(...)" + 匹配 end,load 后拿到 webdav_config 表。
-- 这样 main.lua 改了实现,测试自动跟着变,不会出现测试和代码不一致。

local function load_webdav_config_from_main()
    local f, open_err = io.open("webdav.koplugin/main.lua", "r")
    if not f then
        error("无法打开 webdav.koplugin/main.lua: " .. tostring(open_err))
    end
    local content = f:read("*a")
    f:close()

    -- 1. 找 "local webdav_config" 起点
    local config_start = content:find("local webdav_config%s*=")
    if not config_start then
        error("main.lua 中找不到 'local webdav_config ='")
    end

    -- 2. 找 writeConfigYAML 函数定义
    local fn_start = content:find("function webdav_config%.writeConfigYAML")
    if not fn_start then
        error("main.lua 中找不到 'function webdav_config.writeConfigYAML'")
    end

    -- 3. 找匹配的 end(简单函数无嵌套,用 \nend\n 足够)
    local fn_end = content:find("\nend\n", fn_start)
    if not fn_end then
        error("main.lua 中找不到 writeConfigYAML 的匹配 end")
    end

    -- 4. 提取从 local webdav_config 到 end 的代码,加上 return
    local code = content:sub(config_start, fn_end + 3) .. "\nreturn webdav_config"
    local chunk, err = load(code, "writeConfigYAML_from_main")
    if not chunk then
        error("load 失败: " .. tostring(err) .. "\n代码:\n" .. code)
    end
    return chunk()
end

local webdav_config = load_webdav_config_from_main()

describe("writeConfigYAML", function()
    it("generates valid YAML with default settings", function()
        local yaml = webdav_config.writeConfigYAML("3568", "/tmp/fake-mnt-us", false, "admin", "webdav12345")
        assert.is_truthy(yaml:match("port: 3568"),
            "应包含监听端口 3568")
        -- Lua 模式里 '-' 是 lazy 量化符,字面量需要转义 '%-'
        assert.is_truthy(yaml:match("directory: /tmp/fake%-mnt%-us"),
            "应包含数据目录 /tmp/fake-mnt-us")
        assert.is_truthy(yaml:match("permissions: CRUD"),
            "读写模式应输出 permissions: CRUD")
        assert.is_truthy(yaml:match("username: admin"),
            "应包含用户名 admin")
        assert.is_truthy(yaml:match("password: webdav12345"),
            "应包含密码 webdav12345")
    end)

    it("uses R permission when readonly is true", function()
        local yaml = webdav_config.writeConfigYAML("3568", "/tmp/fake-mnt-us", true, "admin", "webdav12345")
        assert.is_truthy(yaml:match("permissions: R"),
            "只读模式应输出 permissions: R")
    end)

    it("binds to 0.0.0.0 so LAN clients can reach the device", function()
        local yaml = webdav_config.writeConfigYAML("3568", "/tmp/fake-mnt-us", false, "admin", "webdav12345")
        assert.is_truthy(yaml:match("address: 0.0.0.0"),
            "应绑定 0.0.0.0 以便局域网访问")
    end)

    it("accepts numeric port (tostring)", function()
        local yaml = webdav_config.writeConfigYAML(3568, "/mnt/us", false, "admin", "webdav12345")
        assert.is_truthy(yaml:match("port: 3568"),
            "数字端口应被 tostring 转换")
    end)
end)

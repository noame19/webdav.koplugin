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

    it("quotes password containing colon-space (YAML injection defense)", function()
        -- 攻击 payload: "mypass\nlog: bad: true\n" 在没转义时会破坏 YAML 结构
        -- 转义后必须输出成合法 YAML 双引号字符串
        local yaml = webdav_config.writeConfigYAML("3568", "/mnt/us", false, "admin", "pass: word")
        assert.is_truthy(yaml:match('password: "pass: word"'),
            "含 ': ' 的密码必须用双引号包起来,防止被解析成 YAML mapping")
    end)

    it("quotes username with at-sign and dot (uncommon but valid)", function()
        local yaml = webdav_config.writeConfigYAML("3568", "/mnt/us", false, "user@example.com", "pw")
        assert.is_truthy(yaml:match('username: "user@example%.com"'),
            "含 @ 的用户名必须用双引号包")
        -- "pw" 是纯字母,走 plain scalar 不加引号(回归现有 4 条用例)
        assert.is_truthy(yaml:match("password: pw"),
            "纯字母密码不应该加引号")
    end)

    it("quotes directory with space", function()
        local yaml = webdav_config.writeConfigYAML("3568", "/mnt/us/My Books", false, "admin", "pw")
        assert.is_truthy(yaml:match('directory: "/mnt/us/My Books"'),
            "含空格的目录必须用双引号包")
    end)

    it("quotes YAML keywords to prevent interpretation as boolean/null", function()
        -- true/false/null/yes/no/on/off 都是 YAML 1.1 关键字,会被解析成 bool
        for _, keyword in ipairs({"true", "false", "null", "yes", "no", "on", "off"}) do
            local yaml = webdav_config.writeConfigYAML("3568", "/mnt/us", false, keyword, keyword)
            assert.is_truthy(yaml:match('username: "' .. keyword .. '"'),
                "username=" .. keyword .. " 必须用双引号包,否则被解析成 YAML bool")
            assert.is_truthy(yaml:match('password: "' .. keyword .. '"'),
                "password=" .. keyword .. " 必须用双引号包")
        end
    end)

    it("quotes numeric-looking strings to prevent interpretation as number", function()
        -- 如果 username 配成 "1234",没转义会被 webdav 当整数解析
        local yaml = webdav_config.writeConfigYAML("3568", "/mnt/us", false, "12345", "67890")
        assert.is_truthy(yaml:match('username: "12345"'),
            "数字用户名必须用双引号包")
        assert.is_truthy(yaml:match('password: "67890"'),
            "数字密码必须用双引号包")
    end)

    it("keeps plain strings unchanged (no spurious quoting)", function()
        -- 回归:现有 4 条用例都要求 plain 输出,这条确保优化不会破坏兼容性
        local yaml = webdav_config.writeConfigYAML("3568", "/tmp/fake-mnt-us", false, "admin", "webdav12345")
        assert.is_truthy(yaml:match("\n  %- username: admin\n"),
            "普通 username 不应该被引号包")
        assert.is_truthy(yaml:match("\n    password: webdav12345\n"),
            "普通 password 不应该被引号包")
        assert.is_truthy(yaml:match("\ndirectory: /tmp/fake%-mnt%-us\n"),
            "普通 directory 不应该被引号包")
    end)

    it("escapes embedded double quotes and backslashes", function()
        -- 转义规则: \ -> \\, " -> \"
        local yaml = webdav_config.writeConfigYAML("3568", "/mnt/us", false, 'a"b', 'c\\d')
        assert.is_truthy(yaml:match('username: "a\\"b"'),
            '双引号必须转义为 \\"')
        assert.is_truthy(yaml:match('password: "c\\\\d"'),
            "反斜杠必须转义为 \\\\")
    end)

    it("falls back to placeholder when input contains control characters", function()
        -- 含 \n 的输入不应该被拼进 YAML(会破结构)
        local yaml = webdav_config.writeConfigYAML("3568", "/mnt/us", false,
            "admin\nlog: bad: true", "pw\nmore: evil")
        assert.is_truthy(yaml:match('username: "__invalid_username__"'),
            "含控制字符的 username 应该被占位符替换,而不是拼进 YAML")
        assert.is_truthy(yaml:match('password: "__invalid_password__"'),
            "含控制字符的 password 应该被占位符替换")
    end)
end)

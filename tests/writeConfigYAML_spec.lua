-- writeConfigYAML_spec.lua
-- 验证 webdav.koplugin 启动时生成的 YAML 配置文件格式
-- 在 PC 端用 Python busted.py 跑(KOReader 的 gettext 等运行时不存在,
-- 所以这里只用 _G 全局 stub G_reader_settings,并显式调用被测函数)

-- 准备一个 mock 的 settings（不依赖 KOReader 全局 G_reader_settings）
_G.G_reader_settings = {
    readSetting = function(self, key)
        local defaults = {
            webdav_port = "3568",
            webdav_directory = "/tmp/fake-mnt-us",
            webdav_readonly = false,
            webdav_username = "admin",
            webdav_password = "webdav12345",
        }
        return defaults[key]
    end,
    isTrue = function(self, key) return false end,
    saveSetting = function(self, key, value) end,
    flipNilOrFalse = function(self, key) end,
}

-- 加载被测模块（webdav.koplugin/webdav_config.lua 由 Task 5 写入）
-- 默认从仓库根跑：lua tests/busted.lua tests/xxx_spec.lua
-- 也可设置环境变量 WEBDAV_CONFIG_PATH 覆盖
local config_path = os.getenv("WEBDAV_CONFIG_PATH")
    or "webdav.koplugin/webdav_config.lua"
local chunk, err = loadfile(config_path)
if not chunk then
    -- 红阶段：模块还没写，我们要让测试失败而不是抛错
    -- 通过调用一个不存在的全局让 busted 报 FAIL
    writeConfigYAML = nil
    error("无法加载被测模块 " .. config_path .. ": " .. tostring(err))
end
chunk()

describe("writeConfigYAML", function()
    it("generates valid YAML with default settings", function()
        local yaml = writeConfigYAML("3568", "/tmp/fake-mnt-us", false, "admin", "webdav12345")
        assert.is_truthy(yaml:match("port: 3568"),
            "应包含监听端口 3568")
        -- 注意:Lua 模式里 '-' 是 lazy 量化符,字面量需要转义 '%-'
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
        local yaml = writeConfigYAML("3568", "/tmp/fake-mnt-us", true, "admin", "webdav12345")
        assert.is_truthy(yaml:match("permissions: R"),
            "只读模式应输出 permissions: R")
    end)

    it("binds to 0.0.0.0 so LAN clients can reach the device", function()
        local yaml = writeConfigYAML("3568", "/tmp/fake-mnt-us", false, "admin", "webdav12345")
        assert.is_truthy(yaml:match("address: 0.0.0.0"),
            "应绑定 0.0.0.0 以便局域网访问")
    end)
end)

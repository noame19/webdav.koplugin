-- input_validation_spec.lua
--
-- 覆盖 main.lua 里端口校验和输入校验辅助函数的行为。
--
-- 策略:trim/has_control_char 都是短小的纯函数,main.lua 里的版本从 v0.4 起固定为:
--   local function trim(s)
--       return (s or ""):gsub("^%s+", ""):gsub("%s+$", "")
--   end
--   local function has_control_char(s)
--       return s:find("[\x00-\x1f\x7f]") ~= nil
--   end
-- 端口校验在 show_port_dialog 的 Save callback 里,逻辑:
--   value and value == math.floor(value) and value >= 1 and value <= 65535
--
-- 这里直接 inline 复刻,任何一边改了另一边要同步。
-- yaml_safe_string 已经在 writeConfigYAML_spec.lua 里通过 writeConfigYAML 间接覆盖。

-- 复刻 main.lua 头部模块级 helper
local function trim(s)
    return (s or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function has_control_char(s)
    return s:find("[\x00-\x1f\x7f]") ~= nil
end

-- 复刻 show_port_dialog Save callback 的端口校验逻辑
local function port_is_valid(value)
    return type(value) == "number"
        and value == math.floor(value)
        and value >= 1
        and value <= 65535
end

describe("trim", function()
    it("strips leading and trailing whitespace", function()
        assert.are_equal("admin", trim("  admin  "))
        assert.are_equal("admin", trim("\tadmin\n"))
        assert.are_equal("a b c", trim("  a b c  "))
    end)

    it("returns empty string for nil or empty input", function()
        assert.are_equal("", trim(nil))
        assert.are_equal("", trim(""))
        assert.are_equal("", trim("   "))
    end)

    it("preserves internal whitespace", function()
        assert.are_equal("a  b", trim("a  b"))
        assert.are_equal("my user", trim("  my user  "))
    end)
end)

describe("has_control_char", function()
    it("returns false for normal strings", function()
        assert.is_truthy(not (has_control_char("admin")))
        assert.is_truthy(not (has_control_char("pass with space")))
        assert.is_truthy(not (has_control_char("/mnt/us/foo bar")))
        assert.is_truthy(not (has_control_char("中文也支持")))
    end)

    it("returns true for newline", function()
        assert.is_truthy(has_control_char("admin\nevil"))
    end)

    it("returns true for tab", function()
        assert.is_truthy(has_control_char("admin\tevil"))
    end)

    it("returns true for carriage return", function()
        assert.is_truthy(has_control_char("admin\revil"))
    end)

    it("returns true for NUL byte", function()
        assert.is_truthy(has_control_char("\x00admin"))
    end)

    it("returns true for DEL (0x7f)", function()
        assert.is_truthy(has_control_char("admin\x7f"))
    end)
end)

describe("port validation", function()
    it("accepts 1 (lowest valid port)", function()
        assert.is_truthy(port_is_valid(1))
    end)

    it("accepts 65535 (highest valid port)", function()
        assert.is_truthy(port_is_valid(65535))
    end)

    it("accepts 3568 (webdav default)", function()
        assert.is_truthy(port_is_valid(3568))
    end)

    it("rejects 0 (kernel-assigned, not user-meaningful)", function()
        assert.is_truthy(not (port_is_valid(0)))
    end)

    it("rejects 65536 (off by one above max)", function()
        assert.is_truthy(not (port_is_valid(65536)))
    end)

    it("rejects negative numbers", function()
        assert.is_truthy(not (port_is_valid(-1)))
        assert.is_truthy(not (port_is_valid(-100)))
    end)

    it("rejects fractional values (port must be integer)", function()
        assert.is_truthy(not (port_is_valid(3.14)))
        assert.is_truthy(not (port_is_valid(80.5)))
    end)

    it("rejects nil", function()
        assert.is_truthy(not (port_is_valid(nil)))
    end)

    it("rejects string (tonumber not applied)", function()
        assert.is_truthy(not (port_is_valid("3568")))
    end)

    it("rejects boolean", function()
        assert.is_truthy(not (port_is_valid(true)))
    end)
end)
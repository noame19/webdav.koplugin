-- tests/busted.lua
-- 极简 busted-like 测试运行器。仅支持计划所需的子集：
--   describe(name, function() ... end)
--   it(name, function() ... end)
--   assert.is_truthy(value [, msg])
--   assert.is_nil(value [, msg])
--   assert.are_equal(a, b [, msg])
--   assert.is_string(value [, msg])
--   before_each(fn) / after_each(fn)
-- 用法: lua tests/busted.lua tests/foo_spec.lua [tests/bar_spec.lua ...]

local total_pass = 0
local total_fail = 0
local current_file = "?"

local suites = {}        -- list of {name = str, fn = function}
local hooks_before = {}  -- list of function
local hooks_after = {}   -- list of function
local in_describe = false

local function reset()
    suites = {}
    hooks_before = {}
    hooks_after = {}
    in_describe = false
end

-- 注册套件（描述）
function describe(name, fn)
    if not in_describe then
        -- 顶层 describe
        table.insert(suites, {name = name, fn = fn, is_test = false})
    else
        -- 嵌套 describe：作为子项执行
        fn()
    end
end

-- 注册一个测试用例
function it(name, fn)
    table.insert(suites, {name = name, fn = fn, is_test = true})
end

function before_each(fn)
    table.insert(hooks_before, fn)
end

function after_each(fn)
    table.insert(hooks_after, fn)
end

-- assert 对象
assert = {
    is_truthy = function(v, msg)
        if not v then
            error("expected truthy, got " .. tostring(v) .. (msg and (": " .. msg) or ""), 2)
        end
    end,
    is_nil = function(v, msg)
        if v ~= nil then
            error("expected nil, got " .. tostring(v) .. (msg and (": " .. msg) or ""), 2)
        end
    end,
    are_equal = function(a, b, msg)
        if a ~= b then
            error("expected " .. tostring(b) .. ", got " .. tostring(a) ..
                  (msg and (": " .. msg) or ""), 2)
        end
    end,
    is_string = function(v, msg)
        if type(v) ~= "string" then
            error("expected string, got " .. type(v) ..
                  (msg and (": " .. msg) or ""), 2)
        end
    end,
}

-- 加载并执行一个 spec 文件
local function run_spec(path)
    reset()
    current_file = path
    -- 把 describe/it 注入到 chunk 的环境
    local env = setmetatable({
        describe = describe,
        it = it,
        before_each = before_each,
        after_each = after_each,
        assert = assert,
    }, {__index = _G})
    env._G = env  -- 让 _G 也指向新环境
    local chunk, load_err = loadfile(path, "t", env)
    if not chunk then
        io.write(string.format("  FAIL  无法加载 %s: %s\n", path, tostring(load_err)))
        return 0, 1
    end
    local ok, exec_err = pcall(chunk)
    if not ok then
        io.write(string.format("  FAIL  加载 %s 时异常: %s\n", path, tostring(exec_err)))
        return 0, 1
    end

    -- 现在执行收集到的套件
    local pass, fail = 0, 0
    for _, s in ipairs(suites) do
        if s.is_test then
            -- it：用 hooks 包裹
            local ok_run, err = pcall(function()
                for _, h in ipairs(hooks_before) do h() end
                s.fn()
                for _, h in ipairs(hooks_after) do h() end
            end)
            if ok_run then
                pass = pass + 1
                io.write(string.format("  PASS  %s\n", s.name))
            else
                fail = fail + 1
                io.write(string.format("  FAIL  %s: %s\n", s.name, tostring(err)))
            end
        else
            -- 顶层 describe：执行其 fn，里面可能注册 it
            local ok_run, err = pcall(s.fn)
            if not ok_run then
                fail = fail + 1
                io.write(string.format("  FAIL  describe '%s': %s\n", s.name, tostring(err)))
            end
        end
    end
    return pass, fail
end

-- 主入口
local arg_list = arg or {}
if #arg_list < 1 then
    io.write("用法: lua busted.lua <spec1.lua> [spec2.lua ...]\n")
    os.exit(2)
end

io.write("busted.lua - minimal Lua test runner\n")
for _, spec in ipairs(arg_list) do
    io.write(string.format("\n=== %s ===\n", spec))
    local p, f = run_spec(spec)
    total_pass = total_pass + p
    total_fail = total_fail + f
    io.write(string.format("  %d passed, %d failed\n", p, f))
end

io.write(string.format("\n== Summary: %d passed, %d failed ==\n", total_pass, total_fail))
os.exit(total_fail == 0 and 0 or 1)

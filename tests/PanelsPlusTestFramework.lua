--- Minimal, dependency-free test framework for plain Lua 5.4.
---
--- No luarocks, no busted, no external rocks -- just `describe`/`it` grouping,
--- a small `assert` table, and call-tracking `spy()` stubs, enough to unit
--- test pure-logic pieces of this plugin against mocked KOReader APIs.

local M = {}

local stats = { passed = 0, failed = 0 }
local name_stack = {}
local current_path = nil

local function fullName(name)
    if #name_stack == 0 then
        return name
    end
    return table.concat(name_stack, " > ") .. " > " .. name
end

function M.describe(name, fn)
    table.insert(name_stack, name)
    fn()
    table.remove(name_stack)
end

function M.it(name, fn)
    local full_name = fullName(name)
    local ok, err = pcall(fn)
    if ok then
        stats.passed = stats.passed + 1
        print("  [PASS] " .. full_name)
    else
        stats.failed = stats.failed + 1
        print("  [FAIL] " .. full_name)
        print("         " .. tostring(err))
    end
end

local function fail(msg, level)
    error(msg, (level or 1) + 1)
end

M.assert = {}

function M.assert.equals(expected, actual, msg)
    if expected ~= actual then
        fail(string.format("%s: expected %s, got %s", msg or "assert.equals failed",
            tostring(expected), tostring(actual)), 2)
    end
end

function M.assert.is_true(value, msg)
    if value ~= true then
        fail(string.format("%s: expected true, got %s", msg or "assert.is_true failed", tostring(value)), 2)
    end
end

function M.assert.is_false(value, msg)
    if value ~= false then
        fail(string.format("%s: expected false, got %s", msg or "assert.is_false failed", tostring(value)), 2)
    end
end

function M.assert.is_nil(value, msg)
    if value ~= nil then
        fail(string.format("%s: expected nil, got %s", msg or "assert.is_nil failed", tostring(value)), 2)
    end
end

function M.assert.is_not_nil(value, msg)
    if value == nil then
        fail(msg or "assert.is_not_nil failed: expected non-nil value", 2)
    end
end

function M.assert.near(expected, actual, tolerance, msg)
    tolerance = tolerance or 0
    if actual == nil or math.abs(expected - actual) > tolerance then
        fail(string.format("%s: expected %s within %s of %s", msg or "assert.near failed",
            tostring(actual), tostring(tolerance), tostring(expected)), 2)
    end
end

--- Create a call-tracking stub. Calling `s(...)` records the arguments and
--- returns `s.return_value` (settable). `s:called()`/`s:callCount()` inspect
--- the recorded calls, `s:lastCall()` returns the args table of the most
--- recent call.
---
--- @return table spy
function M.spy()
    local s = { calls = {}, return_value = nil }
    setmetatable(s, {
        __call = function(self, ...)
            table.insert(self.calls, { n = select("#", ...), ... })
            return self.return_value
        end,
    })
    function s:called()
        return #self.calls > 0
    end
    function s:callCount()
        return #self.calls
    end
    function s:lastCall()
        return self.calls[#self.calls]
    end
    return s
end

--- Print a pass/fail summary and return whether the whole run succeeded.
---
--- @return boolean all_passed
function M.summary()
    print(string.format("\n%d passed, %d failed", stats.passed, stats.failed))
    return stats.failed == 0
end

return M

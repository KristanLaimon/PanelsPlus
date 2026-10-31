--[[
Reading an Ink Away file that came from another device, safely. Ink Away's
own files are Lua that only builds tables (see Project.encode), and reading one
runs it. A file sent to the reader is checked first to be nothing but that:
tables, quoted strings, numbers, true, false and nil, with no names it could
call, no operators and no loops, so reading it can neither run code, nor loop,
nor build anything much bigger than itself. It is then read with a limit on
work and memory as well, and any reference it holds to a picture or a PDF
elsewhere on the reader is dropped, so a file sent from outside can never make
the reader show (or send back) its other files.
Plain Lua, so the headless tests drive it.
]]

local SafeData = {}

-- The only names a data file may hold: values, and what %.6g writes for
-- numbers that aren't.
local NAMES = { ["true"] = true, ["false"] = true, ["nil"] = true, inf = true, nan = true }

-- Is `str` a data file and nothing else ("return" then one table of plain
-- values)? Returns true, or false and why.
function SafeData.isData(str)
    if type(str) ~= "string" then return false, "not text" end
    local pos = 1
    local first = true
    while true do
        local s = str:find("[^%s]", pos)
        if not s then break end
        local c = str:sub(s, s)
        if c == '"' or c == "'" then
            -- a quoted string: to its closing quote, past escaped characters
            local i = s + 1
            while true do
                local j = str:find("[" .. c .. "\\\n]", i)
                if not j then return false, "an unfinished string" end
                local ch = str:sub(j, j)
                if ch == "\\" then
                    i = j + 2   -- (an escaped character, the line break of %q's "\<newline>" too)
                elseif ch == "\n" then
                    return false, "a line break in a string"
                else
                    pos = j + 1
                    break
                end
            end
        elseif c:match("[{}%[%]=,;]") then
            if c == "[" and str:sub(s + 1, s + 1):match("[%[=]") then return false, "a long string" end
            pos = s + 1
        elseif c == "-" then
            if str:sub(s + 1, s + 1) == "-" then return false, "a comment" end
            local nxt = str:find("[^%s]", s + 1)
            if not nxt or not str:sub(nxt, nxt):match("[%d%.in]") then return false, "a minus before no number" end
            pos = s + 1
        elseif c:match("[%d%.]") then
            local num = str:match("^0[xX]%x+", s) or str:match("^%d*%.?%d*[eE][%+%-]?%d+", s)
                or str:match("^%d*%.?%d*", s)
            if not num or num == "" or num == "." then return false, "a bad number" end
            pos = s + #num
            if str:sub(pos, pos):match("[%w_]") then return false, "a bad number" end
        elseif c:match("[%a_]") then
            local name = str:match("^[%a_][%w_]*", s)
            if first and name == "return" then
                first = false
            elseif not NAMES[name] then
                -- a key (name = value) is data too; any other name could be called
                local nxt = str:find("[^%s]", s + #name)
                if not (nxt and str:sub(nxt, nxt) == "=" and str:sub(nxt + 1, nxt + 1) ~= "=") then
                    return false, "the name " .. name
                end
            end
            pos = s + #name
        else
            return false, "the character " .. c
        end
        if first then return false, "no return at the start" end
    end
    if first then return false, "empty" end
    return true
end

-- Read `str` (already found to be data) into a table, with a limit on work
-- and memory as a second guard. Returns the table, or nil and why.
function SafeData.decode(str)
    local ok_data, why = SafeData.isData(str)
    if not ok_data then return nil, why end
    local chunk, err = load(str, "sent-data", "t", {})
    if not chunk then return nil, err end
    local okj, jit = pcall(require, "jit")
    if okj and type(jit) == "table" and jit.off then pcall(jit.off, chunk, true) end
    local mem0 = collectgarbage("count")
    local mem_cap = 32 * 1024 + #str / 1024 * 12   -- KB: a dozen times the file, plus room
    local work, work_cap = 0, 200 + #str / 2       -- thousands of instructions
    local old_hook, old_mask, old_count = debug.gethook()
    debug.sethook(function()
        work = work + 1
        if work > work_cap then error("too much work") end
        if collectgarbage("count") - mem0 > mem_cap then error("too big") end
    end, "", 1000)
    local ok, value = pcall(chunk)
    debug.sethook(old_hook, old_mask or "", old_count or 0)
    if not ok then return nil, value end
    if type(value) ~= "table" then return nil, "not a table" end
    return value
end

local PATH_KEYS = { path = true, src_path = true, bg = true, pdf_path = true }

-- Drop from `value` (in place) every reference to a file outside `keep`
-- (inside(path) says whether a path may stay): pictures, a background, a PDF.
-- Returns how many were dropped.
function SafeData.dropOutside(value, inside, seen)
    seen = seen or {}
    if type(value) ~= "table" or seen[value] then return 0 end
    seen[value] = true
    local n = 0
    for k, v in pairs(value) do
        if PATH_KEYS[k] and type(v) == "string" and not inside(v) then
            value[k] = nil
            n = n + 1
        elseif type(v) == "table" then
            n = n + SafeData.dropOutside(v, inside, seen)
        end
    end
    return n
end

return SafeData

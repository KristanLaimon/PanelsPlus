--[[
A small JSON reader and writer for the cloud services' replies (see ink/sync/).
Plain Lua, so the headless tests run the same code the reader does. Strings
are written as ASCII only (a service puts one in an HTTP header), numbers that
are whole come out without a decimal point, and keys come out in sorted order
so a request is the same every time.
]]

local Json = {}

local ESC = { ['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }

-- A Lua string as a JSON string: control characters and anything outside ASCII
-- as \uXXXX (UTF-8 is read back into code points, 4-byte ones as a pair).
local function quote(s)
    local out, i, n = { '"' }, 1, #s
    while i <= n do
        local c = s:byte(i)
        if c < 0x80 then
            local ch = string.char(c)
            out[#out + 1] = ESC[ch] or (c < 0x20 and string.format("\\u%04x", c) or ch)
            i = i + 1
        else
            local len = c >= 0xF0 and 4 or c >= 0xE0 and 3 or 2
            local cp = c % (len == 4 and 8 or len == 3 and 16 or 32)
            for k = 1, len - 1 do cp = cp * 64 + ((s:byte(i + k) or 0x80) % 64) end
            if cp >= 0x10000 then
                cp = cp - 0x10000
                out[#out + 1] = string.format("\\u%04x\\u%04x", 0xD800 + math.floor(cp / 1024), 0xDC00 + cp % 1024)
            else
                out[#out + 1] = string.format("\\u%04x", cp)
            end
            i = i + len
        end
    end
    out[#out + 1] = '"'
    return table.concat(out)
end

local function isArray(t)
    local n = 0
    for _k in pairs(t) do n = n + 1 end
    return n == #t and (n > 0 or getmetatable(t) == Json.ARRAY)
end

Json.ARRAY = {}   -- setmetatable({}, Json.ARRAY) is an empty list, not an empty object

local function enc(v, out)
    local t = type(v)
    if t == "string" then out[#out + 1] = quote(v)
    elseif t == "number" then
        out[#out + 1] = (v == math.floor(v) and math.abs(v) < 2^53) and string.format("%d", v) or string.format("%.14g", v)
    elseif t == "boolean" then out[#out + 1] = v and "true" or "false"
    elseif t == "nil" or v == Json.null then out[#out + 1] = "null"
    elseif t == "table" then
        if isArray(v) then
            out[#out + 1] = "["
            for i = 1, #v do
                if i > 1 then out[#out + 1] = "," end
                enc(v[i], out)
            end
            out[#out + 1] = "]"
        else
            local keys = {}
            for k in pairs(v) do keys[#keys + 1] = tostring(k) end
            table.sort(keys)
            out[#out + 1] = "{"
            for i, k in ipairs(keys) do
                if i > 1 then out[#out + 1] = "," end
                out[#out + 1] = quote(k) .. ":"
                enc(v[k], out)
            end
            out[#out + 1] = "}"
        end
    else
        error("cannot write a " .. t .. " as JSON")
    end
end

Json.null = setmetatable({}, { __tostring = function() return "null" end })

-- A Lua value as JSON text.
function Json.encode(v)
    local out = {}
    enc(v, out)
    return table.concat(out)
end

local function utf8(cp)
    if cp < 0x80 then return string.char(cp) end
    if cp < 0x800 then return string.char(0xC0 + math.floor(cp / 64), 0x80 + cp % 64) end
    if cp < 0x10000 then
        return string.char(0xE0 + math.floor(cp / 4096), 0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64)
    end
    return string.char(0xF0 + math.floor(cp / 262144), 0x80 + math.floor(cp / 4096) % 64,
        0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64)
end

local function skip(s, i) return s:find("[^ \t\r\n]", i) or #s + 1 end

local dec

local function decString(s, i)
    local out, n = {}, #s
    i = i + 1
    while i <= n do
        local c = s:sub(i, i)
        if c == '"' then return table.concat(out), i + 1 end
        if c == "\\" then
            local e = s:sub(i + 1, i + 1)
            if e == "u" then
                local hex = s:match("^%x%x%x%x", i + 2)
                if not hex then error("bad \\u escape at " .. i) end
                local cp = tonumber(hex, 16)
                i = i + 6
                if cp >= 0xD800 and cp < 0xDC00 then
                    local lo = s:match("^\\u(%x%x%x%x)", i)
                    if lo and tonumber(lo, 16) >= 0xDC00 then
                        cp = 0x10000 + (cp - 0xD800) * 1024 + (tonumber(lo, 16) - 0xDC00)
                        i = i + 6
                    end
                end
                out[#out + 1] = utf8(cp)
            else
                local map = { b = "\b", f = "\f", n = "\n", r = "\r", t = "\t", ["/"] = "/", ["\\"] = "\\", ['"'] = '"' }
                if not map[e] then error("bad escape at " .. i) end
                out[#out + 1] = map[e]
                i = i + 2
            end
        else
            local j = s:find('["\\]', i) or n + 1
            out[#out + 1] = s:sub(i, j - 1)
            i = j
        end
    end
    error("unterminated string")
end

function dec(s, i, depth)
    if depth > 64 then error("nested too deep") end
    i = skip(s, i)
    local c = s:sub(i, i)
    if c == "{" then
        local t = {}
        i = skip(s, i + 1)
        if s:sub(i, i) == "}" then return t, i + 1 end
        while true do
            i = skip(s, i)
            if s:sub(i, i) ~= '"' then error("expected a key at " .. i) end
            local k
            k, i = decString(s, i)
            i = skip(s, i)
            if s:sub(i, i) ~= ":" then error("expected : at " .. i) end
            local v
            v, i = dec(s, i + 1, depth + 1)
            t[k] = v
            i = skip(s, i)
            local d = s:sub(i, i)
            if d == "}" then return t, i + 1 end
            if d ~= "," then error("expected , or } at " .. i) end
            i = i + 1
        end
    elseif c == "[" then
        local t = setmetatable({}, Json.ARRAY)
        i = skip(s, i + 1)
        if s:sub(i, i) == "]" then return t, i + 1 end
        while true do
            local v
            v, i = dec(s, i, depth + 1)
            t[#t + 1] = v
            i = skip(s, i)
            local d = s:sub(i, i)
            if d == "]" then return t, i + 1 end
            if d ~= "," then error("expected , or ] at " .. i) end
            i = i + 1
        end
    elseif c == '"' then
        return decString(s, i)
    elseif s:sub(i, i + 3) == "true" then return true, i + 4
    elseif s:sub(i, i + 4) == "false" then return false, i + 5
    elseif s:sub(i, i + 3) == "null" then return nil, i + 4
    else
        local num = s:match("^-?%d+%.?%d*[eE]?[+-]?%d*", i)
        if not num or num == "" then error("unexpected text at " .. i) end
        return tonumber(num), i + #num
    end
end

-- JSON text as a Lua value (null becomes nil). Returns the value, or nil and why not.
function Json.decode(s)
    if type(s) ~= "string" then return nil, "not text" end
    local ok, v, i = pcall(dec, s, 1, 0)
    if not ok then return nil, tostring(v) end
    if skip(s, i) <= #s then return nil, "extra text after the value" end
    return v
end

return Json

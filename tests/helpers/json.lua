--[[
Panels+
File: tests/helpers/json.lua
Name: Test JSON decoder
Description: Provides a dependency-free JSON decoder for test and benchmark data.
Author: KristanLaimon
Year: 2026
Copyright (c) 2026 KristanLaimon
License: MIT; see the repository LICENSE file.
SPDX-License-Identifier: MIT
]]
--- Dependency-free pure-Lua JSON decoder for tests and evaluation tools.
---
--- Supports objects, arrays, strings (with escapes and unicode), numbers, booleans, and null.
--- Operates under standard Lua 5.1, 5.2, 5.3, 5.4, and LuaJIT.

local JSON = {}

function JSON.decode(str)
    if not str or type(str) ~= "string" or not str:find("%S") then
        return nil, "expected non-empty string"
    end

    local pos = 1
    local len = #str

    local function skipWhitespace()
        while pos <= len do
            local c = str:sub(pos, pos)
            if c == " " or c == "\t" or c == "\n" or c == "\r" then
                pos = pos + 1
            else
                break
            end
        end
    end

    local parseValue

    local function parseString()
        pos = pos + 1 -- opening quote
        local parts = {}
        while pos <= len do
            local c = str:sub(pos, pos)
            if c == '"' then
                pos = pos + 1
                return table.concat(parts)
            elseif c == "\\" then
                local esc = str:sub(pos + 1, pos + 1)
                local map = {
                    ['"'] = '"',
                    ["\\"] = "\\",
                    ["/"] = "/",
                    b = "\b",
                    f = "\f",
                    n = "\n",
                    r = "\r",
                    t = "\t",
                }
                if map[esc] then
                    table.insert(parts, map[esc])
                    pos = pos + 2
                elseif esc == "u" then
                    local hex = str:sub(pos + 2, pos + 5)
                    local cp = tonumber(hex, 16) or 63
                    if cp < 0x80 then
                        table.insert(parts, string.char(cp))
                    elseif cp < 0x800 then
                        table.insert(parts, string.char(0xC0 + math.floor(cp / 0x40), 0x80 + (cp % 0x40)))
                    else
                        table.insert(
                            parts,
                            string.char(
                                0xE0 + math.floor(cp / 0x1000),
                                0x80 + (math.floor(cp / 0x40) % 0x40),
                                0x80 + (cp % 0x40)
                            )
                        )
                    end
                    pos = pos + 6
                else
                    table.insert(parts, esc)
                    pos = pos + 2
                end
            else
                table.insert(parts, c)
                pos = pos + 1
            end
        end
        error("unterminated string in JSON at position " .. pos)
    end

    local function parseNumber()
        local start = pos
        while pos <= len and str:sub(pos, pos):match("[%d%.%-%+eE]") do
            pos = pos + 1
        end
        return tonumber(str:sub(start, pos - 1))
    end

    local function parseObject()
        pos = pos + 1 -- '{'
        local obj = {}
        skipWhitespace()
        if str:sub(pos, pos) == "}" then
            pos = pos + 1
            return obj
        end
        while true do
            skipWhitespace()
            local key = parseString()
            skipWhitespace()
            pos = pos + 1 -- ':'
            skipWhitespace()
            obj[key] = parseValue()
            skipWhitespace()
            local c = str:sub(pos, pos)
            pos = pos + 1
            if c == "}" then
                break
            end
        end
        return obj
    end

    local function parseArray()
        pos = pos + 1 -- '['
        local arr = {}
        skipWhitespace()
        if str:sub(pos, pos) == "]" then
            pos = pos + 1
            return arr
        end
        while true do
            skipWhitespace()
            table.insert(arr, parseValue())
            skipWhitespace()
            local c = str:sub(pos, pos)
            pos = pos + 1
            if c == "]" then
                break
            end
        end
        return arr
    end

    parseValue = function()
        skipWhitespace()
        local c = str:sub(pos, pos)
        if c == '"' then
            return parseString()
        elseif c == "{" then
            return parseObject()
        elseif c == "[" then
            return parseArray()
        elseif str:sub(pos, pos + 3) == "true" then
            pos = pos + 4
            return true
        elseif str:sub(pos, pos + 4) == "false" then
            pos = pos + 5
            return false
        elseif str:sub(pos, pos + 3) == "null" then
            pos = pos + 4
            return nil
        elseif c:match("[%d%-]") then
            return parseNumber()
        else
            error(string.format("unexpected character '%s' at position %d", c, pos))
        end
    end

    skipWhitespace()
    return parseValue()
end

--- Encode a Lua table/value to a formatted JSON string.
---
--- @param val any
--- @param indent string|nil Optional indentation string (default "  ")
--- @return string
function JSON.encode(val, indent)
    indent = indent or "  "
    local function encode_str(s)
        s = s:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t")
        return '"' .. s .. '"'
    end

    local function is_array(t)
        if #t == 0 then
            return false
        end
        local count = 0
        for _ in pairs(t) do
            count = count + 1
        end
        return count == #t
    end

    local function serialize(v, depth)
        local t = type(v)
        if v == nil then
            return "null"
        elseif t == "boolean" then
            return v and "true" or "false"
        elseif t == "number" then
            if v ~= v or v == math.huge or v == -math.huge then
                return "null"
            end
            if math.type and math.type(v) == "integer" then
                return string.format("%d", v)
            elseif math.floor(v) == v and math.abs(v) < 1e14 and not tostring(v):find("%.") then
                return string.format("%d", v)
            else
                return string.format("%.4f", v)
            end
        elseif t == "string" then
            return encode_str(v)
        elseif t == "table" then
            local prefix = string.rep(indent, depth)
            local inner_prefix = string.rep(indent, depth + 1)
            if is_array(v) then
                local items = {}
                for i = 1, #v do
                    table.insert(items, inner_prefix .. serialize(v[i], depth + 1))
                end
                return "[\n" .. table.concat(items, ",\n") .. "\n" .. prefix .. "]"
            else
                local keys = {}
                for k in pairs(v) do
                    table.insert(keys, tostring(k))
                end
                table.sort(keys)
                if #keys == 0 then
                    return "{}"
                end
                local items = {}
                for _, k in ipairs(keys) do
                    local val_str = serialize(v[k], depth + 1)
                    table.insert(items, inner_prefix .. encode_str(k) .. ": " .. val_str)
                end
                return "{\n" .. table.concat(items, ",\n") .. "\n" .. prefix .. "}"
            end
        end
        return "null"
    end

    return serialize(val, 0)
end

return JSON

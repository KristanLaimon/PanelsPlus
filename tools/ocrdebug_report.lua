#!/usr/bin/env lua
--- Turns `OCR.debug.session.log` into a compact, pre-classified JSON array
--- on stdout, so an AI (or a human) reviewing an OCR debug session never has
--- to open the crop PNGs in `OCR.debug.session.images/` just to answer "was
--- this a box-finding bug or an OCR-engine misread?".
---
--- Why this doesn't need to touch the images at all: every rectangle drawn
--- into a crop PNG (see `src/_ocrdebug.lua`'s `saveCropImage`) is drawn
--- *from* the log's own `box`/`user_box` numbers -- the image never contains
--- geometry the log doesn't already have. The only thing a PNG adds beyond
--- the log is the actual manga/comic art and lettering pixels, which only a
--- multimodal read (or a human) can meaningfully interpret anyway; no
--- automated color/rectangle scan of the pixels would add information a
--- generic image decoder isn't already available to produce standalone Lua
--- here (KOReader's PNG support lives in its C base library, not reachable
--- from a plain `lua`/`lua5.1` CLI). So: classify from the log, and only
--- reach for an actual image read on the specific entries worth a human
--- look -- see CLAUDE.md.
---
--- Usage:
---   lua tools/ocrdebug_report.lua [path/to/OCR.debug.session.log]
---   lua tools/ocrdebug_report.lua --summary [path/to/log]   -- counts only
---
--- With no path given, looks for OCR.debug.session.log next to this
--- script's own directory (i.e. the plugin root), matching where
--- `src/_ocrdebug.lua` writes it.
---
--- Output (default mode): a JSON array on stdout, one object per log line,
--- each with the original fields plus:
---   classification: "correct" | "box_bug" | "engine_miss"
---                  | "total_miss_no_box" | "total_miss_no_word"
---                  | "unclassified" (incorrect, but no user_box was drawn)
---   box_area, user_box_area, overlap_ratio, size_ratio (nil where not applicable)

--------------------------------------------------------------------------
-- Minimal JSON decoder (object/array/string/number/true/false/null only --
-- exactly what `OcrDebug.writeLog`'s `json.encode` output ever contains).
-- No external dependencies, so this script runs under any plain Lua 5.1+,
-- independent of the KOReader runtime.
--------------------------------------------------------------------------

local function jsonDecode(str)
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
                local map = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }
                if map[esc] then
                    table.insert(parts, map[esc])
                    pos = pos + 2
                elseif esc == "u" then
                    local hex = str:sub(pos + 2, pos + 5)
                    local codepoint = tonumber(hex, 16) or 63
                    -- Minimal UTF-8 encode; every field this tool cares about
                    -- (ocr_word, correct_text, paths) is otherwise plain ASCII
                    -- or already-UTF-8 text KOReader's json encoder passes
                    -- through unescaped, so this only ever fires on rare
                    -- control-character escapes.
                    if codepoint < 0x80 then
                        table.insert(parts, string.char(codepoint))
                    else
                        table.insert(parts, "?")
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
            if c == "}" then break end
            -- else expect ',' and continue
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
            if c == "]" then break end
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
        else
            return parseNumber()
        end
    end

    local ok, result = pcall(parseValue)
    if not ok then
        return nil, result
    end
    return result
end

--------------------------------------------------------------------------
-- Minimal JSON encoder for this tool's own fixed, flat output shape.
--------------------------------------------------------------------------

local function jsonEncodeString(s)
    s = s:gsub('[\\"]', "\\%0"):gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t")
    return '"' .. s .. '"'
end

local function jsonEncodeValue(v)
    local t = type(v)
    if v == nil then
        return "null"
    elseif t == "string" then
        return jsonEncodeString(v)
    elseif t == "number" then
        if v ~= v or v == math.huge or v == -math.huge then return "null" end
        return tostring(v)
    elseif t == "boolean" then
        return tostring(v)
    elseif t == "table" then
        -- Only ever used here for the box/user_box/tap/native sub-objects,
        -- which are plain string-keyed tables (never arrays).
        local parts = {}
        for k, val in pairs(v) do
            table.insert(parts, jsonEncodeString(k) .. ":" .. jsonEncodeValue(val))
        end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    return "null"
end

--------------------------------------------------------------------------
-- Geometry helpers.
--------------------------------------------------------------------------

--- @param a table|nil Rect {x,y,w,h}.
--- @param b table|nil Rect {x,y,w,h}.
--- @return number intersection_area
local function intersectionArea(a, b)
    if not a or not b then return 0 end
    local x0 = math.max(a.x, b.x)
    local y0 = math.max(a.y, b.y)
    local x1 = math.min(a.x + a.w, b.x + b.w)
    local y1 = math.min(a.y + a.h, b.y + b.h)
    if x1 <= x0 or y1 <= y0 then return 0 end
    return (x1 - x0) * (y1 - y0)
end

--------------------------------------------------------------------------
-- Classification.
--------------------------------------------------------------------------

-- If OCR's box covers less than this fraction of the user's corrected box,
-- it is pointed at substantially the wrong region (a "box bug" regardless
-- of size).
local MIN_CONTAINMENT_FOR_ENGINE_MISS = 0.3
-- If OCR's box area exceeds the user's corrected box area by more than this
-- multiple, it very likely merged in a neighbouring word/line (still a
-- "box bug") even when it does substantially overlap the correct region.
local MAX_SIZE_RATIO_FOR_ENGINE_MISS = 1.3
-- If either edge (left or right) of OCR's box sits further than this many
-- multiples of the box's own height from the matching edge of the user's
-- corrected box, that alone means "box bug": a merged box (e.g. "ES
-- PRIMOR-" when only "PRIMOR-" was tapped) can coincidentally end up almost
-- the same *area* as the correct box while still starting or ending in
-- clearly the wrong place, which the containment/size checks above can miss
-- on their own.
local MAX_EDGE_OFFSET_RATIO_FOR_ENGINE_MISS = 0.5

--- @param entry table Decoded log record.
--- @return table entry Same table, with classification/metric fields added.
local function classify(entry)
    if entry.verdict == "correct" then
        entry.classification = "correct"
        return entry
    end
    if entry.ocr_failed == "no_box" then
        entry.classification = "total_miss_no_box"
        return entry
    end
    if entry.ocr_failed == "no_word" then
        entry.classification = "total_miss_no_word"
        if entry.box and entry.user_box then
            entry.box_area = entry.box.w * entry.box.h
            entry.user_box_area = entry.user_box.w * entry.user_box.h
            entry.size_ratio = entry.box_area / entry.user_box_area
        end
        return entry
    end
    if not entry.user_box or not entry.box then
        entry.classification = "unclassified"
        return entry
    end

    local box_area = entry.box.w * entry.box.h
    local user_area = entry.user_box.w * entry.user_box.h
    local overlap = intersectionArea(entry.box, entry.user_box)
    local containment = user_area > 0 and (overlap / user_area) or 0
    local size_ratio = user_area > 0 and (box_area / user_area) or nil
    local left_offset = math.abs(entry.box.x - entry.user_box.x)
    local right_offset = math.abs((entry.box.x + entry.box.w) - (entry.user_box.x + entry.user_box.w))
    local edge_offset_ratio = entry.box.h > 0 and (math.max(left_offset, right_offset) / entry.box.h) or 0

    entry.box_area = box_area
    entry.user_box_area = user_area
    entry.overlap_ratio = containment
    entry.size_ratio = size_ratio
    entry.edge_offset_ratio = edge_offset_ratio

    if containment < MIN_CONTAINMENT_FOR_ENGINE_MISS then
        entry.classification = "box_bug"
    elseif size_ratio and size_ratio > MAX_SIZE_RATIO_FOR_ENGINE_MISS then
        entry.classification = "box_bug"
    elseif edge_offset_ratio > MAX_EDGE_OFFSET_RATIO_FOR_ENGINE_MISS then
        entry.classification = "box_bug"
    else
        entry.classification = "engine_miss"
    end
    return entry
end

--------------------------------------------------------------------------
-- Main.
--------------------------------------------------------------------------

local function pluginRootDir()
    local source = debug.getinfo(1, "S").source
    if source:sub(1, 1) == "@" then
        source = source:sub(2)
    end
    return source:match("^(.*)[/\\]tools[/\\]ocrdebug_report%.lua$") or "."
end

local function main(argv)
    local summary_only = false
    local log_path
    for _, arg in ipairs(argv) do
        if arg == "--summary" then
            summary_only = true
        else
            log_path = arg
        end
    end
    log_path = log_path or (pluginRootDir() .. "/OCR.debug.session.log")

    local f, open_err = io.open(log_path, "r")
    if not f then
        io.stderr:write("ocrdebug_report: could not open '" .. log_path .. "': " .. tostring(open_err) .. "\n")
        os.exit(1)
    end

    local entries = {}
    local line_no = 0
    for line in f:lines() do
        line_no = line_no + 1
        if line:match("%S") then
            local decoded, decode_err = jsonDecode(line)
            if decoded then
                table.insert(entries, classify(decoded))
            else
                io.stderr:write(string.format("ocrdebug_report: skipping unparsable line %d: %s\n", line_no, tostring(decode_err)))
            end
        end
    end
    f:close()

    if summary_only then
        local counts = {}
        for _, e in ipairs(entries) do
            counts[e.classification] = (counts[e.classification] or 0) + 1
        end
        local order = { "correct", "engine_miss", "box_bug", "total_miss_no_box", "total_miss_no_word", "unclassified" }
        io.write("{")
        for i, key in ipairs(order) do
            if i > 1 then io.write(",") end
            io.write(jsonEncodeString(key) .. ":" .. (counts[key] or 0))
        end
        io.write(string.format(',"total":%d}\n', #entries))
        return
    end

    local parts = {}
    for _, e in ipairs(entries) do
        table.insert(parts, jsonEncodeValue(e))
    end
    io.write("[" .. table.concat(parts, ",\n") .. "]\n")
end

--- Exposed for `tests/spec/ocrdebug_report_spec.lua` to test the classifier
--- and JSON round-trip directly, without shelling out to this file.
local M = {
    jsonDecode = jsonDecode,
    jsonEncodeValue = jsonEncodeValue,
    intersectionArea = intersectionArea,
    classify = classify,
}

-- Only run as a CLI when invoked directly (`lua tools/ocrdebug_report.lua`),
-- not when `require`d as a library -- Lua sets `arg[0]` to the launched
-- script's own path, which a `require` never does.
if arg and arg[0] and arg[0]:match("ocrdebug_report%.lua$") then
    main(arg)
end

return M

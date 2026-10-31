--[[
Ink Away's own translations. Stands in for KOReader's gettext `_`: a message found in
ink/l10n/<language>.po is translated from there, and anything else is left to
KOReader's own translations, so shared words ("Done") keep KOReader's wording. With
KOReader in English, or no file for its language, every message goes straight to
KOReader. Plain Lua apart from gettext; tests/l10n.lua drives it.
]]

local L10n = {}

local UNESCAPE = { n = "\n", t = "\t", r = "\r", ['"'] = '"', ["\\"] = "\\" }

-- The text inside one quoted .po line with its escapes decoded, or nil if the line
-- is not quoted.
local function unquote(line)
    local s = line:match('^%s*"(.*)"%s*$')
    return s and (s:gsub("\\(.)", function(c) return UNESCAPE[c] or c end))
end

-- msgid -> msgstr from the text of a .po file. Entries with no translation, marked
-- fuzzy, obsolete or given a context are left out, and so are plural forms (Ink Away
-- has none).
function L10n.parse(text)
    local out = {}
    local e, field = {}, nil   -- the entry being read, and the field a quoted line continues
    local function flush()
        if e.id and e.id ~= "" and e.str and e.str ~= "" and not (e.fuzzy or e.skip) then out[e.id] = e.str end
        e, field = {}, nil
    end
    for line in (text .. "\n"):gmatch("(.-)\r?\n") do
        if line:match("^%s*$") then
            flush()
        elseif line:match("^#") then
            -- a comment (or an obsolete entry, "#~"); only the fuzzy flag matters. One
            -- straight after a finished entry, with no blank line, is the next one's.
            if e.str then flush() end
            if line:match("^#,") and line:find("fuzzy", 1, true) then e.fuzzy = true end
        elseif line:match('^%s*"') then
            local piece = unquote(line)
            if piece and field then e[field] = e[field] .. piece end
        else
            local kw, rest = line:match("^%s*(%S+)%s*(.*)$")
            if kw == "msgid" then
                if e.str then flush() end
                e.id, field = unquote(rest) or "", "id"
            elseif kw == "msgstr" then
                e.str, field = unquote(rest) or "", "str"
            else
                if kw == "msgctxt" or kw == "msgid_plural" or kw:match("^msgstr%[") then e.skip = true end
                field = nil
            end
        end
    end
    flush()
    return out
end

local function readFile(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

-- The `_` for the language KOReader runs in (`gt.current_lang`: "es", "es_MX",
-- "es.utf8"), reading <dir><language>.po, or just the part before the "_" when
-- there is none for the full code. `gt` itself when the language is English or has
-- no file; a file that gives nothing is logged and ignored, never an error. Leaves the
-- language code in L10n.code, for the text case rules (ink/textcase.lua).
function L10n.build(gt, dir)
    local code = gt.current_lang and gt.current_lang:match("^[^.@]+")
    L10n.code = code
    if not code or code == "C" or code == "en" or code:match("^en_") then return gt end
    local text
    for _i, name in ipairs({ code, code:match("^([^_]+)_") }) do
        text = readFile(dir .. name .. ".po")
        if text then break end
    end
    if not text then return gt end
    local ok, map = pcall(L10n.parse, text)
    if not ok or next(map) == nil then
        local logged, logger = pcall(require, "logger")
        if logged then logger.warn("Ink Away: no translations in the file for " .. code) end
        return gt
    end
    return function(msgid) return map[msgid] or gt(msgid) end
end

-- What `_` is in the plugin: a callable table, so that parse and build are reachable
-- (KOReader's own `_` is one too).
local here = debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./"
local translate = L10n.build(require("gettext"), here .. "l10n/")
return setmetatable(L10n, { __call = function(_, msgid) return translate(msgid) end })

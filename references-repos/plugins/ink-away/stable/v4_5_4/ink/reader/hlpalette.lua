--[[
The colours a tap on a highlight offers (see ink/reader/hlcolour.lua), and how a
colour becomes what the reader keeps on a highlight. Plain Lua (the reader and
its settings are passed in), so the headless tests drive it.

The reader names a highlight's colour ("yellow") and looks the name up when it
draws, in its own list (Blitbuffer.HIGHLIGHT_COLORS) and in the custom colours
the person has set (ui.highlight.custom_colors, saved with KOReader's settings).
So a colour of the person's own is kept as a custom colour under a name of Ink
Away's ("ia_ff8800"), which the reader then draws like any other.

The palette is the person's list of colours, kept in the settings: the reader's
names ("red") and exact colours ("#FF8800"), in the order they were set.
]]

local Palette = {}

Palette.SETTING = "inkaway_hl_palette"
Palette.MAX = 18

-- The reader's own colours, in the order its colour menu has them.
Palette.DEFAULT = { "red", "orange", "yellow", "green", "olive", "cyan", "blue", "purple", "gray" }

-- The reader's colours, as it has them (a reader without the list gives these).
local NAMED = {
    red = "#FF3300", orange = "#FF8800", yellow = "#FFFF33", green = "#00AA66",
    olive = "#88FF77", cyan = "#00FFEE", blue = "#0066FF", purple = "#EE00FF",
}

local function named()
    local ok, B = pcall(require, "ffi/blitbuffer")
    local list = ok and type(B) == "table" and B.HIGHLIGHT_COLORS
    return type(list) == "table" and list or NAMED
end

-- "#ff8800" in the one form the palette keeps ("#FF8800"), or nil.
function Palette.hex(s)
    if type(s) ~= "string" then return nil end
    local h = s:match("^#(%x%x%x%x%x%x)$")
    return h and ("#" .. h:upper()) or nil
end

-- {r,g,b} as "#RRGGBB".
function Palette.fromRgb(rgb)
    local function c(v) return math.max(0, math.min(255, math.floor((tonumber(v) or 0) + 0.5))) end
    return string.format("#%02X%02X%02X", c(rgb[1]), c(rgb[2]), c(rgb[3]))
end

-- "#RRGGBB" as r, g, b.
function Palette.toRgb(hex)
    local h = Palette.hex(hex)
    if not h then return nil end
    return tonumber(h:sub(2, 3), 16), tonumber(h:sub(4, 5), 16), tonumber(h:sub(6, 7), 16)
end

-- Is `entry` one the palette may hold: one of the reader's names, "gray", or an exact colour.
function Palette.valid(entry)
    if type(entry) ~= "string" then return false end
    return entry == "gray" or named()[entry] ~= nil or Palette.hex(entry) ~= nil
end

-- The person's palette: their list, cleaned (anything unknown or twice dropped, the
-- length capped), or the reader's colours when they have not set one. `get(key)`
-- reads a setting.
function Palette.list(get)
    local saved = get and get(Palette.SETTING)
    if type(saved) ~= "table" then
        local out = {}
        for i, n in ipairs(Palette.DEFAULT) do out[i] = n end
        return out
    end
    local out, seen = {}, {}
    for _i, e in ipairs(saved) do
        local v = Palette.hex(e) or e
        if Palette.valid(v) and not seen[v] and #out < Palette.MAX then
            seen[v] = true
            out[#out + 1] = v
        end
    end
    return out
end

-- Is the palette as it comes?
function Palette.isDefault(get)
    local saved = get and get(Palette.SETTING)
    return type(saved) ~= "table"
end

-- The palette with `entry` added at the end (unchanged if it is there, or full).
function Palette.added(list, entry)
    local out = {}
    for i, e in ipairs(list) do
        if e == entry then return list end
        out[i] = e
    end
    if #out >= Palette.MAX or not Palette.valid(entry) then return list end
    out[#out + 1] = entry
    return out
end

-- The palette without `entry`.
function Palette.removed(list, entry)
    local out = {}
    for _i, e in ipairs(list) do
        if e ~= entry then out[#out + 1] = e end
    end
    return out
end

-- The name a custom colour is kept under in the reader.
function Palette.keyFor(hex)
    local h = Palette.hex(hex)
    return h and ("ia_" .. h:sub(2):lower()) or nil
end

-- The colour a highlight's name stands for, as "#RRGGBB" (nil for "gray" and for
-- a name nothing knows). `custom` is the reader's custom colours, if it has any.
function Palette.hexOf(name, custom)
    if type(name) ~= "string" then return nil end
    local c = type(custom) == "table" and custom[name]
    local code = type(c) == "table" and Palette.hex(c.code)
    if code then return code end
    return Palette.hex(named()[name])
end

-- The name to put on a highlight for a palette entry. A colour of the person's
-- own is kept as a custom colour of the reader's (`custom`, its table), once;
-- where the reader has no such table (an old one) it gives nil and the colour
-- cannot be used. Returns the name, or nil.
function Palette.nameFor(entry, custom)
    if entry == "gray" or named()[entry] then return entry end
    local hex = Palette.hex(entry)
    if not hex then return nil end
    -- one the reader already has by that colour (its own, or a custom one)
    for n, code in pairs(named()) do
        if Palette.hex(code) == hex then return n end
    end
    if type(custom) ~= "table" then return nil end
    local key = Palette.keyFor(hex)
    local have = custom[key]
    if type(have) ~= "table" or Palette.hex(have.code) ~= hex then
        custom[key] = { code = hex }
    end
    return key
end

-- The palette entry a highlight's colour is: its name when the palette has it,
-- or the exact colour a custom one stands for. Used to mark the current colour.
function Palette.entryOf(name, custom)
    if type(name) ~= "string" then return nil end
    if name:sub(1, 3) == "ia_" then
        local hex = Palette.hexOf(name, custom)
        if hex then return hex end
    end
    return name
end

-- Labels: what each colour means to the person ("Important", "Look this up"),
-- kept in the settings by palette entry ({ yellow = "...", ["#FF8800"] = "..." },
-- #81), shown with the colour in the highlight colour sheet.
Palette.LABELS = "inkaway_hl_labels"
Palette.LABEL_MAX = 32   -- characters

-- The label of colour `entry`, or nil.
function Palette.label(get, entry)
    local t = get and get(Palette.LABELS)
    local s = type(t) == "table" and t[entry]
    return type(s) == "string" and s ~= "" and s or nil
end

-- Has any colour a label?
function Palette.anyLabel(get)
    local t = get and get(Palette.LABELS)
    return type(t) == "table" and next(t) ~= nil
end

-- `labels` (the setting) with `entry` given `text`: trimmed and cut to
-- LABEL_MAX characters; empty takes the label off. Returns the new table, or
-- nil when no label is left.
function Palette.labelled(labels, entry, text)
    local out = {}
    for k, v in pairs(type(labels) == "table" and labels or {}) do
        if type(k) == "string" and type(v) == "string" and v ~= "" then out[k] = v end
    end
    text = type(text) == "string" and text:gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "") or ""
    -- (cut by characters, not bytes: UTF-8)
    local n, cut = 0, #text
    for pos in text:gmatch("()[%z\1-\127\194-\244][\128-\191]*") do
        n = n + 1
        if n > Palette.LABEL_MAX then cut = pos - 1; break end
    end
    text = text:sub(1, cut):gsub(" $", "")
    out[entry] = text ~= "" and text or nil
    return next(out) ~= nil and out or nil
end

return Palette

--[[
Ink Away's own preferences for the cloud sync (see ink/sync/areas.lua, "Pens,
colours and preferences"): the choices about how drawing and writing look and
behave, which the person would want the same on every reader. They are kept in
KOReader's settings, so before a run the chosen ones are written to a small file
(the sync carries files), and after it any that came from another reader are put
back into the settings.

Only the keys listed here travel. Nothing that belongs to one reader goes: not the
library or export folders, the screen, the pen's hardware, which side the toolbar
is on, the sync's own settings, the OCR key, or what was last opened.

Plain Lua (the settings are passed in), so the headless tests drive it.
]]

local Json = require("ink/sync/json")

local Prefs = {}

Prefs.REL = ".areas/settings/preferences.json"

Prefs.KEYS = {
    -- colours
    "inkaway_custom_colors", "inkaway_hl_palette", "inkaway_hl_labels", "inkaway_accent", "inkaway_accent_recent",
    "inkaway_night_colours", "inkaway_live_colour",
    -- pens and brushes
    "inkaway_pens", "inkaway_brushes", "inkaway_pen_style", "inkaway_pen_strip", "inkaway_pen_ui",
    "inkaway_arrow_head", "inkaway_stabilizer", "inkaway_symmetry",
    -- snapping, erasing
    "inkaway_snap_grid", "inkaway_snap_angle", "inkaway_snap_text", "inkaway_hold_straighten",
    "inkaway_eraser_outline", "inkaway_erase_whole", "inkaway_erase_bg", "inkaway_text_erase_protect",
    -- text
    "inkaway_text_font", "inkaway_text_size", "inkaway_text_grid_snap",
    -- paper and page
    "inkaway_paper", "inkaway_grid_style", "inkaway_grid_strength", "inkaway_grid_size",
    "inkaway_nb_style", "inkaway_nb_strength", "inkaway_nb_size", "inkaway_ghost",
    -- the library and pictures
    "inkaway_library_sort", "inkaway_search_inside", "inkaway_img_source", "inkaway_img_png_only",
    "inkaway_shelf_mixed", "inkaway_shelf_cover", "inkaway_clips_auto", "inkaway_clips_days",
}

local IS_KEY = {}
for _i, k in ipairs(Prefs.KEYS) do IS_KEY[k] = true end

-- Is `v` something a file can carry as it is: a boolean, number, string, or a table of those?
local function plain(v, depth)
    local t = type(v)
    if t == "boolean" or t == "string" then return true end
    if t == "number" then return v == v and v ~= math.huge and v ~= -math.huge end
    if t ~= "table" or depth > 6 then return false end
    for k, x in pairs(v) do
        if type(k) ~= "string" and type(k) ~= "number" then return false end
        if not plain(x, depth + 1) then return false end
    end
    return true
end

-- The chosen preferences: { [key] = value } for the keys that are set. `get(key)` reads a setting.
function Prefs.export(get)
    local out = {}
    for _i, k in ipairs(Prefs.KEYS) do
        local v = get(k)
        if v ~= nil and plain(v, 0) then out[k] = v end
    end
    return out
end

-- The file's text for a set of preferences (the same set always gives the same text).
function Prefs.encode(tbl)
    return Json.encode(tbl)
end

-- The preferences in a file's text, or nil if it is not one. Keys that do not travel are dropped.
function Prefs.decode(text)
    local t = Json.decode(text or "")
    if type(t) ~= "table" then return nil end
    local out = {}
    for k, v in pairs(t) do
        if IS_KEY[k] and plain(v, 0) then out[k] = v end
    end
    return out
end

-- Put preferences into the settings. Returns how many were set.
function Prefs.apply(tbl, set)
    local n = 0
    for _i, k in ipairs(Prefs.KEYS) do
        if tbl[k] ~= nil then set(k, tbl[k]); n = n + 1 end
    end
    return n
end

local function readFile(p)
    local f = io.open(p, "rb")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

-- Two files of preferences in one (both readers changed them while apart): all
-- the keys of either, and where both set one, the second file's (the cloud's).
-- Returns the text, or nil if either is not readable.
function Prefs.merge(first_path, second_path)
    local a, b = Prefs.decode(readFile(first_path)), Prefs.decode(readFile(second_path))
    if not (a and b) then return nil end
    local out = {}
    for k, v in pairs(a) do out[k] = v end
    for k, v in pairs(b) do out[k] = v end
    return Prefs.encode(out)
end

-- Is the file at `path` one of preferences?
function Prefs.valid(path)
    if Prefs.decode(readFile(path)) then return true end
    return false, "not preferences"
end

return Prefs

--[[
Ink Away's quick menu, opened from its icon in KOReader's top menu bar (see
ink/topbar.lua) or by a gesture: annotate the book, the book's notes, copy part of
the page, open Ink Away or its library, and the cloud sync, each one tap away and
each saying how to do the same with a gesture where one is set. It is drawn in Ink
Away's own sheet (its colours, dark theme and tiles), over the book or the file
browser, without opening the canvas.

The sheet's building blocks are the view's (ink/view/sheetkit.lua). The view
itself, with its canvas, is not made: a small stand-in borrows those methods.

The gesture part is plain Lua (the gesture manager's table and a way to name a
gesture are passed in), so the headless tests drive it.
]]

local Welcome = require("ink/welcome")

local Launcher = {}

local FIELD = "_launcher"

-- A translated text with %1, %2... filled in.
local function fillIn(s, ...)
    local args = { ... }
    return (s:gsub("%%(%d)", function(i) return tostring(args[tonumber(i)]) end))
end

-- The gesture `action` is on, in the gesture manager's table `data` (one table per
-- screen: gesture_reader, gesture_fm), looking in `sections` in order. One Ink Away
-- knows how to draw wins, else the first by name; nil when there is none.
function Launcher.gestureFor(data, action, sections)
    local first
    for _i, name in ipairs(sections or { "gesture_reader" }) do
        local s = type(data) == "table" and data[name]
        if type(s) == "table" then
            local ids = {}
            for ges, acts in pairs(s) do
                if type(acts) == "table" and acts[action] then ids[#ids + 1] = ges end
            end
            table.sort(ids)
            for _j, ges in ipairs(ids) do
                if Welcome.GESTURES[ges] then return ges end
            end
            first = first or ids[1]
        end
    end
    return first
end

-- The glyph (ink/icons) for a gesture Ink Away has no phrase for, or nil.
local function glyphFor(ges)
    if ges:find("^two_finger_tap_") then return "ges_two_tap" end
    if ges:find("^two_finger_swipe_north$") then return "ges_two_swipe_up" end
    if ges:find("^two_finger_swipe_south$") then return "ges_two_swipe_down" end
    if ges:find("^two_finger_swipe_east$") or ges:find("^two_finger_swipe_west$") then return "ges_two_swipe_side" end
    if ges == "two_finger_swipe_northwest" then return "ges_two_swipe_nw" end
    if ges == "two_finger_swipe_southwest" then return "ges_two_swipe_sw" end
    if ges:find("^hold_") then return "ges_hold" end
    if ges:find("^tap_") or ges:find("^double_tap_") then return "ges_tap" end
    if ges == "pinch_gesture" or ges == "spread_gesture" then return "ges_pinch" end
    return nil
end

-- How to say `ges` to a reader: the phrase and glyph Ink Away has for its own
-- choices, else a phrase built from the gesture manager's own name for it
-- (`name_of(ges)`, in KOReader's language). `_` translates, `T` fills %1.
-- Returns text and glyph, or nil.
function Launcher.gesturePhrase(ges, name_of, _, T)
    local known = Welcome.GESTURES[ges]
    if known then return _(known.text), known.glyph end
    local name = name_of and name_of(ges)
    if not name or name == "" then return nil end
    local text
    if ges:find("^double_tap_") then text = T(_("Double tap: %1"), name)
    elseif ges:find("^two_finger_tap_") then text = T(_("Two-finger tap: %1"), name)
    elseif ges:find("^tap_") then text = T(_("Tap: %1"), name)
    elseif ges:find("^hold_") then text = T(_("Hold: %1"), name)
    elseif ges:find("^one_finger_swipe_") then text = T(_("Swipe: %1"), name)
    elseif ges:find("^two_finger_swipe_") then text = T(_("Two-finger swipe %1"), name)
    else text = name end
    return text, glyphFor(ges)
end

-- KOReader's name for a gesture, from its gesture manager (which titles each
-- gesture "<name>   (<what it does>)"), or nil.
local function nameFrom(manager)
    if not (manager and type(manager.gestureTitleFunc) == "function") then return nil end
    return function(ges)
        local ok, title = pcall(manager.gestureTitleFunc, manager, ges)
        if not (ok and type(title) == "string") then return nil end
        return title:match("^(.-)   %(") or title
    end
end

-- The tiles to show: { { icon, title, note, glyph, run } } for `plugin` (the Ink
-- Away module of the KOReader screen that is up). `_` translates, `T` fills %1.
function Launcher.tiles(plugin, _, T)
    local in_book = plugin.book ~= nil
    local manager = plugin.ui and plugin.ui.gestures
    local data = manager and manager.data
    local name_of = nameFrom(manager)
    local function gesture(action, sections)
        local ges = Launcher.gestureFor(data, action, sections)
        if not ges then return nil end
        return Launcher.gesturePhrase(ges, name_of, _, T)
    end
    local out = {}
    local function add(icon, title, note, action, sections, run)
        local text, glyph = gesture(action, sections)
        out[#out + 1] = { icon = icon, title = title, note = text or note, glyph = text and glyph or nil, run = run }
    end
    if in_book then
        add("pen", _("Annotate the book"), _("Write and draw on this page"), "inkaway_annotate",
            { "gesture_reader" }, function() plugin:onInkAwayAnnotate() end)
        add("booknotes", _("Book notes"), _("Quick notes for the book you're reading"), "inkaway_booknotes",
            { "gesture_reader" }, function() plugin:onInkAwayBookNotes() end)
        if require("device"):isTouchDevice() then
            add("clipboard", _("Copy part of the screen"), _("Copy part of the page as a picture"), "inkaway_capture",
                { "gesture_reader" }, function() plugin:onInkAwayCapture() end)
        end
    end
    add("notebook", _("Open Ink Away"), _("Pick up where you left off"), "inkaway_open",
        { in_book and "gesture_reader" or "gesture_fm" }, function() plugin:openCanvas() end)
    add("library", _("Library"), _("All your notebooks and drawings"), "inkaway_library",
        { in_book and "gesture_reader" or "gesture_fm" }, function() plugin:openCanvas(true) end)
    return out
end

-- A stand-in for the view that owns the sheet: it has the view's sheet methods and
-- nothing open (so a sync from here has no notebook to save first).
local function newHost()
    local Screen = require("device").screen
    local InkAwayView = require("ink/view")
    local host = setmetatable({ screen_w = Screen:getWidth(), screen_h = Screen:getHeight(), closing = false },
        { __index = InkAwayView })
    host.leaveDocument = function() end
    -- the reader's theme colour, as the view applies it when it opens
    require("ink/accent").apply(host:getSetting("inkaway_accent"), host:colorScreen())
    return host
end

-- Show the quick menu for `plugin`.
function Launcher.show(plugin)
    local _ = require("ink/l10n")
    local UIManager = require("ui/uimanager")
    local VerticalGroup = require("ui/widget/verticalgroup")
    local VerticalSpan = require("ui/widget/verticalspan")
    local Screen = require("device").screen
    local host = Launcher.host
    if host and host[FIELD] then host:closeSheet(FIELD) end
    host = newHost()
    Launcher.host = host
    host:ensureUserIcons()
    local content_w = math.floor(host:sheetWidth() * 0.86)   -- (a small menu, not a full sheet)
    local function close() host:closeSheet(FIELD) end
    local function vspan(n) return VerticalSpan:new{ width = Screen:scaleBySize(n) } end
    local build = function()
        local g = VerticalGroup:new{ align = "left" }
        local function add(w) g[#g + 1] = w end
        add(host:sheetTitle(_("Ink Away"), content_w, _("Close"), close, nil, {
            { icon = "cloud", cb = function() close(); host:openSync() end } }))
        for i, t in ipairs(Launcher.tiles(plugin, _, fillIn)) do
            add(vspan(i == 1 and 8 or 6))
            -- the first is the main thing to do, in the theme colour; the others are quiet
            add(host:actionTile(t.icon, t.title, t.note, content_w, function()
                close()
                UIManager:nextTick(t.run)
            end, nil, t.glyph, i == 1 and "compact" or "quiet"))
        end
        return g
    end
    host:showSheet(FIELD, build)
    return host
end

return Launcher

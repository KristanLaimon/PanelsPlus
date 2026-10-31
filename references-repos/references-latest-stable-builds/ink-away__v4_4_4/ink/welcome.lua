--[[
What the notice the first time Ink Away opens says about its book features:
what annotating and book notes are, the gesture each got (see
ink/reader/entrygestures.lua), and a warning for one that couldn't get a gesture
or when KOReader's gesture manager is off. Plain Lua: the headless tests drive
it; ink/view/welcome.lua shows it.
]]

local TextCase = require("ink/textcase")

local Welcome = {}

-- The gestures Ink Away may set, in words and as a glyph (ink/icons).
Welcome.GESTURES = {
    one_finger_swipe_right_edge_up = { glyph = "ges_edge_up", text = "Swipe up along the right edge" },
    one_finger_swipe_right_edge_down = { glyph = "ges_edge_down", text = "Swipe down along the right edge" },
    two_finger_swipe_northwest = { glyph = "ges_two_swipe_nw",
        text = "Two-finger swipe from the bottom right to the top left" },
    two_finger_swipe_southwest = { glyph = "ges_two_swipe_sw",
        text = "Two-finger swipe from the top right to the bottom left" },
}

Welcome.FEATURES = {
    { id = "annotate", icon = "pen", title = "Annotate the book",
      text = "Write and draw on the book's pages. Your ink stays with the words when the font changes." },
    { id = "booknotes", icon = "booknotes", title = "Book notes",
      text = "Quick notes for the book you're reading, in a window over the page, with a page for each chapter." },
}

local function gesText(ges)
    local g = Welcome.GESTURES[ges]
    return g and g.text or ges
end

local function isEdge(ges)
    return ges:find("^one_finger_swipe_right_edge") ~= nil
end

-- A message with %1, %2... filled in (as the views' own T): all that content() does
-- to its sentences when it is given no translator.
function Welcome.fill(s, ...)
    local args = { ... }
    return (s:gsub("%%(%d)", function(i) return tostring(args[tonumber(i)]) end))
end

-- The notice's content for `state`, what the gesture setup saved (nil when it
-- never ran): { rows = { { feature, glyph, gesture, outside } }, info, warnings }.
-- A row's glyph and gesture are nil when the feature has none; `outside` says
-- what the same swipe does outside a book (book notes opens Ink Away). The
-- sentences it builds (`outside`, `info`, the warnings) are whole messages passed
-- to `_(message, values...)`, so a translation can reorder the values; by default
-- that fills them in as English (Welcome.fill). `lang` is KOReader's language code,
-- so a gesture phrase put in the middle of a sentence is lowercased the way that
-- language writes it. The rest is left for the view to translate.
function Welcome.content(state, _, lang)
    _ = _ or Welcome.fill
    local rows, warnings = {}, {}
    local placed = state and state.placed or {}
    local held = state and state.held or {}
    local off = state == nil or state.off
    local edge_what, missing = {}, {}
    for _i, h in ipairs(held) do
        if h.section == "gesture_reader" and isEdge(h.ges) and h.what and h.what ~= "" then
            edge_what[#edge_what + 1] = h.what
        end
    end
    local two_finger = false
    for _i, f in ipairs(Welcome.FEATURES) do
        local where = placed[f.id] or {}
        local ges = where.gesture_reader
        local row = { feature = f }
        if ges then
            row.glyph = Welcome.GESTURES[ges] and Welcome.GESTURES[ges].glyph
            row.gesture = gesText(ges)
            if not isEdge(ges) then two_finger = true end
            if f.id == "booknotes" and where.gesture_fm then
                row.outside = where.gesture_fm == ges and _("Outside a book, it opens Ink Away.")
                    or _("Outside a book, %1 opens Ink Away.", TextCase.lower(_(gesText(where.gesture_fm)), lang))
            end
        elseif not off then
            missing[#missing + 1] = f
        end
        rows[#rows + 1] = row
    end
    local info
    if two_finger then
        if #edge_what > 0 then
            info = _("The swipes along the right edge already do something on your reader (%1), so Ink Away uses two-finger swipes.",
                table.concat(edge_what, ", "))
        else
            info = _("The swipes along the right edge already do something on your reader, so Ink Away uses two-finger swipes.")
        end
    end
    if off then
        warnings[#warnings + 1] = _("KOReader's gesture manager is off, so Ink Away couldn't give these a gesture.")
    else
        for _i, f in ipairs(missing) do
            local parts = {}
            for _j, h in ipairs(held) do
                if h.feature == f.id and h.section == "gesture_reader" then
                    local part = TextCase.lower(_(gesText(h.ges)), lang)
                    parts[#parts + 1] = h.what and h.what ~= "" and _("%1 (%2)", part, h.what) or part
                end
            end
            if #parts > 0 then
                local list = parts[1]
                for i = 2, #parts do list = _("%1 and %2", list, parts[i]) end
                warnings[#warnings + 1] = _("%1 has no gesture: %2 already do something else.", _(f.title), list)
            else
                warnings[#warnings + 1] = _("%1 has no gesture: its gestures are taken.", _(f.title))
            end
        end
    end
    if #warnings > 0 then
        warnings[#warnings + 1] = _("Open them from the reader menu: Tools, Ink Away. Or give them a gesture in Settings, Taps and gestures, Gesture manager: the actions are \u{201C}Ink Away: annotate the book\u{201D} and \u{201C}Ink Away: book notes\u{201D}.")
    end
    return { rows = rows, info = info, warnings = warnings }
end

return Welcome

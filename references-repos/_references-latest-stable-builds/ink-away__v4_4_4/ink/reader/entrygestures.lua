--[[
The two book gestures, set up once in KOReader's gesture manager: book notes
(Ink Away itself outside a book) and annotating the book. Each has a first
choice along the right edge and, where that already does something (readers
with warmth light keep it there), a two-finger diagonal swipe instead:

  book notes  swipe up along the right edge, else a two-finger swipe from the
              bottom right to the top left
  annotate    swipe down along the right edge, else a two-finger swipe from
              the top right to the bottom left (in a book only)

A gesture is only taken when it does nothing yet. One that can't be placed is
reported, with what holds its gestures, in the notice shown the first time Ink
Away opens (see ink/view/welcome.lua).

The gesture manager keeps one table of gestures for the file browser and the
reader (gesture_fm, gesture_reader), shared by its instances, and writes it
out when told it changed. Plain Lua: the headless tests drive it.
]]

local EntryGestures = {}

EntryGestures.FEATURES = {
    { id = "booknotes", action = "inkaway_booknotes", sections = { "gesture_reader", "gesture_fm" },
      gestures = { "one_finger_swipe_right_edge_up", "two_finger_swipe_northwest" } },
    { id = "annotate", action = "inkaway_annotate", sections = { "gesture_reader" },
      gestures = { "one_finger_swipe_right_edge_down", "two_finger_swipe_southwest" } },
}

local function empty(t)
    return t == nil or (type(t) == "table" and next(t) == nil)
end

local function section(data, name)
    local s = data[name]
    if type(s) ~= "table" then
        s = {}
        data[name] = s
    end
    return s
end

-- Place each feature's gesture in `data` (the gesture manager's table).
-- Returns { [feature id] = { [section] = gesture or nil } }, `busy`, the
-- gestures wanted but in use: { { feature, section, ges, current = <its actions> } },
-- and how many gestures it set.
-- A feature takes one gesture free in all its sections when it can, so it is
-- the same everywhere; else each section the first one free there.
function EntryGestures.apply(data)
    local placed, busy, n = {}, {}, 0
    for _i, f in ipairs(EntryGestures.FEATURES) do
        local where = {}
        placed[f.id] = where
        local open = {}
        -- a gesture already ours stays (a second run changes nothing)
        for _j, name in ipairs(f.sections) do
            local s = section(data, name)
            for _k, ges in ipairs(f.gestures) do
                if type(s[ges]) == "table" and s[ges][f.action] then where[name] = ges; break end
            end
            if not where[name] then open[#open + 1] = name end
        end
        if #open > 0 then
            local common
            for _k, ges in ipairs(f.gestures) do
                local free = true
                for _j, name in ipairs(open) do
                    if not empty(data[name][ges]) then free = false; break end
                end
                if free then common = ges; break end
            end
            for _j, name in ipairs(open) do
                local s = data[name]
                local ges = common
                if not ges then
                    for _k, g in ipairs(f.gestures) do
                        if empty(s[g]) then ges = g; break end
                    end
                end
                if ges then
                    s[ges] = { [f.action] = true }
                    where[name] = ges
                    n = n + 1
                end
            end
        end
        -- what stood in the way of the gestures before the one taken (or of all)
        for _j, name in ipairs(f.sections) do
            local s = data[name]
            for _k, ges in ipairs(f.gestures) do
                if ges == where[name] then break end
                if not empty(s[ges]) and not s[ges][f.action] then
                    busy[#busy + 1] = { feature = f.id, section = name, ges = ges, current = s[ges] }
                end
            end
        end
    end
    return placed, busy, n
end

return EntryGestures

--[[
What gestures and pen buttons do. A short list of actions, the triggers a reader
can give them (finger gestures, and on a pen device its buttons), the defaults,
and the checks that keep a choice sensible: a pen button acts while it is held,
so it is offered only actions that make sense held, and a trigger does one
thing at a time. Kept in KOReader's settings (inkaway_gestures). Plain Lua, so
the headless tests drive it directly; ink/view/gestures.lua carries them out.
]]

local Actions = {}

local SETTING = "inkaway_gestures"

-- The actions. `held`: makes sense while a pen button is held (for that stroke);
-- `notebook`: only does something in a notebook.
Actions.LIST = {
    { id = "nothing",     label = "Nothing",                   held = true },
    { id = "undo",        label = "Undo" },
    { id = "redo",        label = "Redo" },
    { id = "highlighter", label = "Highlighter",               held = true },
    { id = "lasso",       label = "Lasso",                     held = true },
    { id = "eraser",      label = "Eraser",                    held = true },
    { id = "prev_pen",    label = "Previous pen",              held = true },
    { id = "fav1",        label = "Saved pen 1",               held = true },
    { id = "fav2",        label = "Saved pen 2",               held = true },
    { id = "fav3",        label = "Saved pen 3",               held = true },
    { id = "next_page",   label = "Next page",                 notebook = true },
    { id = "prev_page",   label = "Previous page",             notebook = true },
    { id = "browse",      label = "Browse notebooks" },
    { id = "library",     label = "Library" },
    { id = "pan",         label = "Move the page (Pan)" },
    { id = "toolbar",     label = "Hide or show the toolbar" },
    { id = "fit",         label = "Fit the page" },
    { id = "refresh",     label = "Refresh the screen" },
    { id = "contents",    label = "Go to the contents page", notebook = true },
}
local BY_ID = {}
for _i, a in ipairs(Actions.LIST) do BY_ID[a.id] = a end
function Actions.get(id) return BY_ID[id] end
function Actions.label(id) return (BY_ID[id] or BY_ID.nothing).label end

-- The triggers. `pen`: a pen control, acting while held; `second`: the second
-- side button, which no Kobo or Kindle pen has; `key`: the reader's page turn
-- buttons.
Actions.TRIGGERS = {
    { id = "two_tap",         label = "Two-finger tap" },
    { id = "two_double_tap",  label = "Two-finger double tap" },
    { id = "two_swipe_left",  label = "Two-finger swipe left" },
    { id = "two_swipe_right", label = "Two-finger swipe right" },
    { id = "two_swipe_up",    label = "Long two-finger swipe up" },
    { id = "two_swipe_down",  label = "Long two-finger swipe down" },
    { id = "pen_side",        label = "Side button",        pen = true },
    { id = "pen_side2",       label = "Second side button", pen = true, second = true },
    { id = "pen_eraser",      label = "Eraser end",         pen = true },
    { id = "key_fwd",         label = "Page turn button forward", key = true },
    { id = "key_back",        label = "Page turn button back",    key = true },
}
local TRIGGER = {}
for _i, t in ipairs(Actions.TRIGGERS) do TRIGGER[t.id] = t end
function Actions.trigger(id) return TRIGGER[id] end

-- What 4.0 did, kept as the defaults; the pen's side buttons highlight while held.
-- The long swipe down, which did nothing, refreshes the screen (#12).
Actions.DEFAULTS = {
    two_tap = "undo", two_double_tap = "redo",
    two_swipe_left = "next_page", two_swipe_right = "prev_page",
    two_swipe_up = "browse", two_swipe_down = "refresh",
    pen_side = "highlighter", pen_side2 = "highlighter", pen_eraser = "eraser",
    key_fwd = "next_page", key_back = "prev_page",
}

-- The actions a trigger may be given.
function Actions.choices(trigger_id)
    local t = TRIGGER[trigger_id]
    local out = {}
    for _i, a in ipairs(Actions.LIST) do
        if not (t and t.pen) or a.held then out[#out + 1] = a end
    end
    return out
end

-- Is `action` a sensible choice for `trigger`?
function Actions.allowed(trigger_id, action_id)
    local t, a = TRIGGER[trigger_id], BY_ID[action_id]
    if not (t and a) then return false end
    return not t.pen or a.held == true
end

-- The bindings: the saved ones over the defaults, dropping anything unknown.
function Actions.load(get)
    local saved = get(SETTING)
    local b = {}
    for k, v in pairs(Actions.DEFAULTS) do b[k] = v end
    if type(saved) == "table" then
        for k, v in pairs(saved) do
            if Actions.allowed(k, v) then b[k] = v end
        end
    end
    return b
end

function Actions.save(b, set)
    local out = {}
    for k, v in pairs(b) do out[k] = v end
    set(SETTING, out)
end

-- What choosing `action` for `trigger` would change, before it is done:
--   replaced  the action the trigger had (nil if the same or nothing)
--   also      the other triggers that already do this action
function Actions.preview(b, trigger_id, action_id)
    local info = { also = {} }
    local old = b[trigger_id]
    if old and old ~= action_id and old ~= "nothing" then info.replaced = old end
    if action_id ~= "nothing" then
        for _i, t in ipairs(Actions.TRIGGERS) do
            if t.id ~= trigger_id and b[t.id] == action_id then info.also[#info.also + 1] = t.id end
        end
    end
    return info
end

-- Give `trigger` the action. With `move`, the triggers that already had it get
-- Nothing, so one gesture does it. Returns false for a choice that is not allowed.
function Actions.set(b, trigger_id, action_id, move)
    if not Actions.allowed(trigger_id, action_id) then return false end
    if move then
        for _i, t in ipairs(Actions.TRIGGERS) do
            if t.id ~= trigger_id and b[t.id] == action_id then b[t.id] = "nothing" end
        end
    end
    b[trigger_id] = action_id
    return true
end

function Actions.reset(b)
    for k in pairs(b) do b[k] = nil end
    for k, v in pairs(Actions.DEFAULTS) do b[k] = v end
end

-- Things worth knowing about a trigger's current setting, in plain words.
function Actions.notes(b, trigger_id)
    local out = {}
    local a = b[trigger_id]
    if (trigger_id == "two_swipe_left" or trigger_id == "two_swipe_right") and a ~= "nothing" then
        out[#out + 1] = "When the page is zoomed in wider than the screen, sideways swipes move the page instead."
    end
    if trigger_id == "two_tap" and b.two_double_tap ~= "nothing"
            and not (b.two_tap == "undo" and b.two_double_tap == "redo") then
        out[#out + 1] = "With a double tap also set, a single two-finger tap waits a moment for a second one."
    end
    return out
end

return Actions

--[[
Pure pen helpers for palm rejection, testable without KOReader.

KOReader hands a plugin raw stylus events through Input:registerStylusCallback
(frontend/device/input.lua). The callback runs before gesture detection, once per
input frame while the pen is present, with a slot table {slot, id, x, y, tool,
timev}; returning true "dominates" the event so it never becomes a gesture.

Tool values are the ABS_MT_TOOL_TYPE constants KOReader uses: finger 0, pen 1,
eraser 2, highlighter 3.
]]

local Stylus = {}

Stylus.TOOL_FINGER = 0
Stylus.TOOL_PEN = 1
Stylus.TOOL_ERASER = 2
Stylus.TOOL_HIGHLIGHTER = 3

-- Apply the screen rotation to a raw slot position, as
-- GestureDetector:translateCoordinates does for a gesture (its only adjustment
-- after the raw position). The stylus callback fires before that step, so raw
-- coordinates need it. `mode` is 0 upright, 1 clockwise, 2 upside down or 3
-- counter-clockwise; `w` and `h` are the current (rotated) screen size.
-- Returns tx, ty.
function Stylus.rotate(x, y, mode, w, h)
    if mode == 1 then          -- clockwise (landscape)
        return w - y, x
    elseif mode == 2 then      -- upside down (portrait)
        return w - x, h - y
    elseif mode == 3 then      -- counter-clockwise (landscape)
        return y, h - x
    end
    return x, y                -- upright: unchanged
end

-- Kobo models made for a pen: Elipsa, Sage, Elipsa 2E, and the Libra Colour
-- with its Tolino twin. KOReader has no flag for a Kobo stylus.
Stylus.PEN_KOBOS = { Kobo_europa = true, Kobo_cadmus = true, Kobo_condor = true, Kobo_monza = true }

-- A pen slot's point on the screen, from the touch panel's coordinates, as the
-- screen `S` (KOReader's) is turned now.
function Stylus.screenXY(slot, S)
    local mode = 0
    if S.getTouchRotation then
        local rot = S:getTouchRotation()
        if rot == S.DEVICE_ROTATED_CLOCKWISE then mode = 1
        elseif rot == S.DEVICE_ROTATED_UPSIDE_DOWN then mode = 2
        elseif rot == S.DEVICE_ROTATED_COUNTER_CLOCKWISE then mode = 3 end
    end
    return Stylus.rotate(slot.x, slot.y, mode, S:getWidth(), S:getHeight())
end

-- The live Input facts Stylus.classify and Stylus.penAction need (see there),
-- from KOReader's Input `input`, the pen slot learned so far, and whether this
-- is Android.
function Stylus.facts(input, learned_slot, android)
    return {
        pen_slot          = input and input.pen_slot,
        learned_slot      = learned_slot,   -- slot a real TOOL_PEN was seen on
        wacom             = input and input.wacom_protocol == true,
        -- (pencil.koplugin's input.lua names them kobo_*_active)
        eraser_latch      = input and (input.stylus_eraser_active == true or input.kobo_eraser_active == true),
        highlighter_latch = input and (input.stylus_highlighter_active == true or input.kobo_highlighter_active == true),
        android           = android and true or false,
    }
end

-- Is a tool type one of the pen-like tools we take over?
function Stylus.isPen(tool)
    return tool == Stylus.TOOL_PEN
        or tool == Stylus.TOOL_ERASER
        or tool == Stylus.TOOL_HIGHLIGHTER
end

-- What a routed slot physically is. Input:routeStylusEvents hands the callback
-- any slot with a pen, eraser or highlighter tool, or on the dedicated pen slot,
-- so a routed slot is not necessarily the pen: Linux reports a rejected touch as
-- MT_TOOL_PALM, the same value (2) as the eraser, so a resting palm arrives
-- looking like the eraser.
--
-- The tool type comes first. A pen tip always reports TOOL_PEN (1), so TOOL_PEN
-- is trusted even where Input.pen_slot is never set; on a Wacom device whose
-- pen slot is known, only that slot is the pen (see below). The slot settles the
-- ambiguous eraser value: a stylus tool on the pen's own slot (preset by the
-- runtime, or learned from the first real pen frame) or, off Wacom, with a
-- barrel-button latch is the pen; any other bare 2 or 3 is a promoted palm.
--
-- `facts` carries what only the live Input object knows:
--   pen_slot          the digitizer's dedicated slot number (or nil)
--   learned_slot      the slot a genuine TOOL_PEN frame was last seen on
--   wacom             true on a Wacom protocol device (Kindle Scribe, reMarkable)
--   eraser_latch      Input.stylus_eraser_active (BTN_STYLUS held; pencil.koplugin's
--                     input.lua calls it kobo_eraser_active)
--   highlighter_latch Input.stylus_highlighter_active (BTN_STYLUS2 held;
--                     kobo_highlighter_active there)
--   android           true on Android, where KOReader reports only the pen (1)
--                     and its eraser end (2) as stylus tools
-- Returns one of the ROLE_ values below.
Stylus.ROLE_PEN   = "pen"     -- a trusted stylus: draw or erase with it
Stylus.ROLE_PALM  = "palm"    -- a palm promoted to a stylus tool number: discard
Stylus.ROLE_TOUCH = "touch"   -- an ordinary finger that only reached us in passing
Stylus.ROLE_PEN_OUT = "pen_out" -- the pen leaving range on its dedicated slot: end the stroke
function Stylus.classify(slot, facts)
    if not slot then return Stylus.ROLE_TOUCH end
    facts = facts or {}
    local tool = slot.tool
    local stylus_tool = Stylus.isPen(tool)
    local pen_slot = facts.pen_slot
    local learned = facts.learned_slot
    -- A Wacom pen is a digitizer of its own, which KOReader always puts on the
    -- pen slot (BTN_TOOL_PEN), so where that slot is known it is the only pen.
    -- Any other slot is the touch panel's, and a pen tool there is only the
    -- panel's guess about a small contact, such as a fingertip or the edge of a
    -- hand at the side of the screen. Learning such a slot made a palm resting
    -- on it draw, until a clean pen stroke learned the real slot again.
    local wacom_slot = facts.wacom and pen_slot ~= nil
    local on_pen_slot = (pen_slot ~= nil and slot.slot == pen_slot)
                     or (not wacom_slot and learned ~= nil and slot.slot == learned)

    -- 0. On a Wacom device KOReader writes the finger tool into the pen's own
    --    slot when the pen leaves range (BTN_TOOL_PEN 0). That frame is the pen
    --    going away, never a finger, and when the pen is lifted out of range in
    --    one quick motion it is the only lift we get, so it must end the stroke;
    --    otherwise the next pen-down draws a line from the previous stroke.
    if facts.wacom and on_pen_slot and not stylus_tool then return Stylus.ROLE_PEN_OUT end

    -- 1. A real pen tip is the pen, except a pen tool off a known Wacom pen slot,
    --    which is kept out like a palm: it never draws, and it is still kept from
    --    the gesture detector as before, which without the pen bridge could
    --    otherwise be left holding a contact whose lift went to another slot.
    if tool == Stylus.TOOL_PEN then
        if wacom_slot and not on_pen_slot then return Stylus.ROLE_PALM end
        return Stylus.ROLE_PEN
    end
    -- 2. On the pen's own slot (preset or learned) a stylus tool is the pen, its
    --    rear eraser, or a held barrel button.
    if on_pen_slot and stylus_tool then return Stylus.ROLE_PEN end
    -- 2b. On Android KOReader reports a palm as a finger, never as the eraser's
    --     number, so an eraser there is the pen's eraser end, even before the pen
    --     has drawn and its slot is learned (#36).
    if facts.android and tool == Stylus.TOOL_ERASER then return Stylus.ROLE_PEN end
    -- 3. KOReader rewrites the pen's tool to ERASER or HIGHLIGHTER while a side
    --    button is held; trust that latch even if the slot bookkeeping lags. Not
    --    on a known Wacom pen slot's device: there the held button's pen is on
    --    that slot (rule 2), and a palm (MT_TOOL_PALM, the eraser's number) on
    --    the panel while the button is held would otherwise draw.
    if not wacom_slot then
        if tool == Stylus.TOOL_ERASER and facts.eraser_latch then return Stylus.ROLE_PEN end
        if tool == Stylus.TOOL_HIGHLIGHTER and facts.highlighter_latch then return Stylus.ROLE_PEN end
    end
    -- 4. Any other stylus tool number is a promoted palm (a bare 2 or 3, or a
    --    stylus tool on a slot that is not the pen's). Everything else is an
    --    ordinary finger that only reached the callback in passing.
    if stylus_tool then return Stylus.ROLE_PALM end
    return Stylus.ROLE_TOUCH
end

-- Which part of a trusted pen is at work, for slots already classified ROLE_PEN;
-- what each does is the reader's choice (see ink/actions.lua). KOReader rewrites
-- the tool while BTN_STYLUS (eraser latch) or BTN_STYLUS2 (highlighter latch)
-- is held, and those buttons are different parts of the pen:
--   * a Wacom pen (the Kindle Scribe): BTN_STYLUS is the side button, and the
--     rear eraser is a tool of its own (BTN_TOOL_RUBBER, tool ERASER, no latch)
--       eraser latch       ACT_BUTTON1     highlighter latch  ACT_BUTTON2
--       tool ERASER        ACT_ERASER_END
--   * a Kobo pen: BTN_STYLUS is the eraser end (the Kobo Stylus 2's top, the
--     first Kobo Stylus's erase button) and BTN_STYLUS2 the side button that
--     highlights in Kobo's own notebooks
--       eraser latch       ACT_ERASER_END  highlighter latch  ACT_BUTTON1
--   anything else          ACT_DRAW (the current tool)
-- Reading the Kobo eraser end as the Scribe's side button made it highlight,
-- and left the settings for the eraser end and the side button unused (#13, #32).
Stylus.ACT_DRAW       = "draw"
Stylus.ACT_BUTTON1    = "button1"
Stylus.ACT_BUTTON2    = "button2"
Stylus.ACT_ERASER_END = "eraser_end"
function Stylus.penAction(slot, facts)
    facts = facts or {}
    if facts.eraser_latch then return facts.wacom and Stylus.ACT_BUTTON1 or Stylus.ACT_ERASER_END end
    if facts.highlighter_latch then return facts.wacom and Stylus.ACT_BUTTON2 or Stylus.ACT_BUTTON1 end
    if slot and slot.tool == Stylus.TOOL_ERASER then return Stylus.ACT_ERASER_END end
    return Stylus.ACT_DRAW
end

-- The trigger (ink/actions.lua) for each part of the pen.
Stylus.TRIGGER = { button1 = "pen_side", button2 = "pen_side2", eraser_end = "pen_eraser" }

-- Kinematic palm filter: a real nib cannot teleport. Some Wacom panels (the
-- Kindle Scribe among them) share one slot table between the pen digitizer and the
-- touch panel, so a resting palm's coordinates land in the pen's slot and look like
-- the nib jumping across the page. A sample further than `base + dt * speed`
-- pixels from the last accepted point is not the pen and is dropped. After `limit`
-- drops in a row one is accepted anyway, so a lift that was never reported cannot
-- wedge the stroke.
--   state  {x, y, drops} for one stroke (pass a fresh {} at pen-down)
--   dt_ms  elapsed ms since the last sample, or nil when there is no clock
--   scale  the screen DPI factor, so the thresholds hold at any resolution
-- Returns whether to accept the sample, and `restart`: true when an accepted
-- sample cannot continue the line (the drop limit was hit, or the pen reappears
-- far away after a gap no drawing pen leaves). The caller then ends the stroke and
-- starts a new one there instead of joining them. Without dt_ms every sample is
-- accepted.
function Stylus.acceptMove(state, x, y, dt_ms, scale, tune)
    tune = tune or {}
    scale = scale or 1
    if state.x == nil then                       -- first point of the stroke: seed
        state.x, state.y, state.drops = x, y, 0
        return true
    end
    if not (dt_ms and dt_ms >= 0) then           -- no reliable elapsed time: don't filter
        state.x, state.y, state.drops = x, y, 0
        return true
    end
    local base  = tune.jump_base  or 48          -- px allowed even at ~zero elapsed
    local speed = tune.max_speed  or 6           -- px per ms a real nib can move
    local gap   = tune.max_gap_ms or 120         -- cap dt so a long gap can't allow anything
    local limit = tune.limit      or 8
    local dx, dy = x - state.x, y - state.y
    local d2 = dx * dx + dy * dy
    -- A pen on the glass reports continuously; a long silence followed by a point
    -- well away from the last one is a new contact whose lift we never saw.
    if dt_ms > gap and d2 > (base * scale) * (base * scale) then
        state.x, state.y, state.drops = x, y, 0
        return true, true
    end
    local dt = dt_ms < gap and dt_ms or gap
    local allowed = (base + dt * speed) * scale
    if d2 <= allowed * allowed then
        state.x, state.y, state.drops = x, y, 0
        return true
    end
    state.drops = (state.drops or 0) + 1
    if state.drops >= limit then                  -- escape hatch: accept, as a new stroke
        state.x, state.y, state.drops = x, y, 0
        return true, true
    end
    return false
end

-- Milliseconds from a slot's timestamp. KOReader stamps slots with
-- time.timeval(ev.time), an fts number in microseconds; very old builds used a
-- {sec, usec} table. Returns nil when there is no usable stamp.
function Stylus.timevMs(tv)
    if type(tv) == "number" then return tv / 1000 end
    if type(tv) == "table" then
        local sec, usec = tv.tv_sec or tv.sec, tv.tv_usec or tv.usec
        if sec then return sec * 1000 + (usec or 0) / 1000 end
    end
    return nil
end

-- Fresh per-pen tracking state for step.
function Stylus.new()
    return { down = false }
end

-- Advance the down/move/up state machine with the slot's tracking id (>= 0 while
-- touching, nil or -1 when not) and return the transition: "down" (first
-- contact), "move" (still down), "up" (just lifted), or nil (still up).
function Stylus.step(st, id)
    local touching = id ~= nil and id >= 0
    if touching then
        if st.down then return "move" end
        st.down = true
        return "down"
    else
        if st.down then
            st.down = false
            return "up"
        end
        return nil
    end
end

return Stylus

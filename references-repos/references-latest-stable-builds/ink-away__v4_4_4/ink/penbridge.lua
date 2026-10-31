--[[
Keeps a Wacom pen's events on the pen's own slot while the canvas is open.

KOReader reads the pen (a single-touch digitizer: ABS_X, ABS_Y, BTN_TOUCH) and
the touch panel (multi-touch: ABS_MT_*) through one "current slot" cursor. When
the panel moves that cursor to a resting palm's slot, the pen's next coordinates
land on the palm, and its lift (BTN_TOUCH 0) is dropped because KOReader honours
it only while the current slot holds a pen. The pen slot never sees the lift, and
the next pen-down continues the previous stroke with a straight line.

While installed, the bridge gives each device its own cursor:
  * ABS_X, ABS_Y and ABS_PRESSURE always go to the pen slot;
  * BTN_TOUCH goes to the pen slot whenever the pen is in range or touching, so
    a lift is never lost;
  * every ABS_MT_* event goes to the panel slot the panel last selected.
It also moves the pen slot out of the panel's 0..9 range (to 15), so a hand with
several contacts never shares it. Everything is restored on uninstall.

Where KOReader says which device an event came from (ev.fd, KOReader 2026.07.1
and later), the panel's own ABS_X, ABS_Y, ABS_PRESSURE and BTN_TOUCH are
dropped: some panels report a resting hand that way too (Linux's pointer
emulation), which would move the pen to the hand and lift it there. The panel
is the device that sends ABS_MT_* events; the pen is the one that sends
BTN_TOOL_PEN. Without ev.fd nothing is dropped.

KOReader pauses input as it opens a book, as the reader sleeps and for some
popups (Input:inhibitInput): it holds its handlers aside in _abs_ev_handler and
_key_ev_handler, and puts them back on the Input itself afterwards. The bridge
installs over KOReader's stock handlers however they are held, and removes
itself from wherever it is, so a pause neither keeps it out nor leaves it behind.

The approach follows pierspad's Notebook plugin (MIT). It is installed only on
Wacom-protocol devices that use KOReader's stock touch handlers.
]]

local PenBridge = {}

local EV_ABS = 3
local ABS_X, ABS_Y, ABS_PRESSURE = 0, 1, 24
local ABS_MT_SLOT = 47
local ABS_MT_FIRST, ABS_MT_LAST = 48, 61     -- ABS_MT_TOUCH_MAJOR .. ABS_MT_TOOL_Y
local BTN_TOUCH = 330
local BTN_TOOL_PEN, BTN_TOOL_RUBBER = 320, 321
local EV_SYN = 0
local TOOL_FINGER, TOOL_PEN, TOOL_ERASER = 0, 1, 2

PenBridge.PEN_SLOT = 15

local function slotData(input, n)
    return input.ev_slots and input.ev_slots[n]
end

-- Make sure the slot record exists without touching this frame's slot list.
local function ensureSlot(input, n)
    if not input.ev_slots then return nil end
    if not input.ev_slots[n] then
        if input.initMtSlot then input:initMtSlot(n) else input.ev_slots[n] = { slot = n } end
    end
    return input.ev_slots[n]
end

-- Where KOReader holds each handler while input is paused (Input:inhibitInput).
local HELD = { handleTouchEv = "_abs_ev_handler", handleKeyBoardEv = "_key_ev_handler" }

-- KOReader's stock handler `name` for `input` (its class's), or nil.
local function stock(input, name)
    local mt = getmetatable(input)
    local cls = mt and (type(mt.__index) == "table" and mt.__index or mt)
    return cls and cls[name]
end

-- The handler `name` in effect: the one held aside while input is paused, else
-- the one on the Input. Returns the handler and the field it is in.
local function current(input, name)
    local held = rawget(input, HELD[name])
    if held ~= nil then return held, HELD[name] end
    return input[name], name
end

-- Can the bridge run on this Input? Only Wacom-protocol devices that still use the
-- stock handlers (a device or plugin with its own handler is left alone).
function PenBridge.supported(input)
    if not (input ~= nil and input.wacom_protocol == true and input.pen_slot ~= nil
        and type(input.setupSlotData) == "function"
        and type(input.setCurrentMtSlot) == "function"
        and type(input.setCurrentMtSlotChecked) == "function") then
        return false
    end
    for name in pairs(HELD) do
        local fn = current(input, name)
        if type(fn) ~= "function" or fn ~= stock(input, name) then return false end
    end
    return true
end

-- Install on `input`. Returns a handle for uninstall, or nil when not supported.
function PenBridge.install(input)
    if not PenBridge.supported(input) then return nil end
    local h = { input = input, orig_pen_slot = input.pen_slot }
    -- the panel's slot cursor: where KOReader's cursor is now, unless that is the pen
    local cur = input.cur_slot
    h.panel_slot = (cur ~= nil and cur ~= input.pen_slot) and cur or (input.main_finger_slot or 0)

    -- move the pen slot, carrying over whether the pen is in range now (the canvas
    -- is often opened with the pen hovering, and BTN_TOOL_PEN is not sent again)
    local new_slot = PenBridge.PEN_SLOT
    local old = slotData(input, h.orig_pen_slot)
    local fresh = ensureSlot(input, new_slot)
    if fresh then
        fresh.tool = old and old.tool or nil
        fresh.id = -1
        fresh.x, fresh.y = old and old.x, old and old.y
    end
    input.pen_slot = new_slot

    local touch = stock(input, "handleTouchEv")    -- KOReader's (checked above)
    local key = stock(input, "handleKeyBoardEv")
    h.touch, h.key = touch, key
    h.panel_fds = {}

    -- Is `ev` from the touch panel, by the device it came from? Only known
    -- where KOReader gives ev.fd; the pen's own device never counts.
    local function fromPanel(ev)
        local fd = ev.fd
        if fd == nil then return false end
        if h.pen_fd ~= nil then return fd ~= h.pen_fd end
        return h.panel_fds[fd] == true
    end

    local function penActive(this)
        local p = slotData(this, this.pen_slot)
        if not p then return false end
        return p.tool == TOOL_PEN or p.tool == TOOL_ERASER or (p.id ~= nil and p.id >= 0)
    end

    -- Each returns true when it took the event itself.
    local function steerTouch(this, ev)
        if ev.type == EV_SYN then h.touch_pending = nil; return false end
        if ev.type ~= EV_ABS then return false end
        local code = ev.code
        if code >= ABS_MT_SLOT and code <= ABS_MT_LAST and ev.fd ~= nil and ev.fd ~= h.pen_fd then
            h.panel_fds[ev.fd] = true                    -- the touch panel's device
        end
        if code == ABS_MT_SLOT then
            h.panel_slot = ev.value
        elseif code >= ABS_MT_FIRST and code <= ABS_MT_LAST then
            if this.cur_slot ~= h.panel_slot then this:setupSlotData(h.panel_slot) end
        elseif (code == ABS_X or code == ABS_Y or code == ABS_PRESSURE) and fromPanel(ev) then
            return true                                  -- a hand reported the legacy way: drop it
        elseif code == ABS_X or code == ABS_Y then
            this:setupSlotData(this.pen_slot)
            this:setCurrentMtSlotChecked(code == ABS_X and "x" or "y", ev.value)
            return true
        elseif code == ABS_PRESSURE then
            this:setupSlotData(this.pen_slot)
            this:setCurrentMtSlotChecked("pressure", ev.value)
            -- KOReader drops hovering pen frames on pressure 0 when it knows the
            -- pressure axis; keep that behaviour on the pen slot.
            if ev.value == 0 and this.pressure_event == ABS_PRESSURE then
                local p = slotData(this, this.pen_slot)
                if p and p.tool == TOOL_PEN then this:setCurrentMtSlot("id", -1) end
            end
            return true
        end
        return false
    end
    local function steerKey(this, ev)
        if (ev.code == BTN_TOOL_PEN or ev.code == BTN_TOOL_RUBBER) and ev.fd ~= nil then
            h.pen_fd = ev.fd                             -- the pen's device
            h.panel_fds[ev.fd] = nil
        end
        if ev.code == BTN_TOUCH and fromPanel(ev) then
            return true                                  -- a hand reported the legacy way: drop it
        end
        if ev.code == BTN_TOUCH then
            if penActive(this) then
                this:setupSlotData(this.pen_slot)
                this:setCurrentMtSlot("id", ev.value == 1 and this.pen_slot or -1)
                return true
            end
            -- Some reports put the touch before the pen's "in range" key in the
            -- same frame. Hold it until that key arrives, or the contact-down is
            -- lost and the whole stroke is taken for hovering.
            h.touch_pending = ev.value
        elseif (ev.code == BTN_TOOL_PEN or ev.code == BTN_TOOL_RUBBER) and ev.value == 1
                and h.touch_pending == 1 then
            key(this, ev)                                -- KOReader sets the pen tool
            this:setupSlotData(this.pen_slot)
            this:setCurrentMtSlot("id", this.pen_slot)
            h.touch_pending = nil
            return true
        end
        return false
    end

    -- A fault in the bridge must never take KOReader's input loop down: it removes
    -- itself and the event goes to KOReader as if the bridge had never been there.
    local touch_wrapper = function(this, ev)
        if not h.dead then
            local ok, took = pcall(steerTouch, this, ev)
            if ok and took then return nil end
            if not ok then h.dead = true; pcall(PenBridge.uninstall, h) end
        end
        return touch(this, ev)
    end
    local key_wrapper = function(this, ev)
        if not h.dead then
            local ok, took = pcall(steerKey, this, ev)
            if ok and took then return nil end
            if not ok then h.dead = true; pcall(PenBridge.uninstall, h) end
        end
        return key(this, ev)
    end

    -- in place of KOReader's handlers, wherever they are now (held aside while
    -- input is paused: KOReader then puts the bridge back on the Input itself)
    local _, touch_field = current(input, "handleTouchEv")
    local _, key_field = current(input, "handleKeyBoardEv")
    input[touch_field], input[key_field] = touch_wrapper, key_wrapper
    h.touch_wrapper, h.key_wrapper = touch_wrapper, key_wrapper
    return h
end

-- Restore KOReader's handlers and the original pen slot.
function PenBridge.uninstall(h)
    if not h then return end
    local input = h.input
    -- From now on the wrappers only hand events on, wherever they still are.
    h.dead = true
    -- Unwind what is still ours: on the Input (KOReader's stock handler is its
    -- class's), or held aside while input is paused (KOReader's comes back when
    -- it resumes). Another wrapper may sit on top: leave it, ours passes through.
    for name, held in pairs(HELD) do
        local mine = name == "handleTouchEv" and h.touch_wrapper or h.key_wrapper
        if rawget(input, name) == mine then input[name] = nil end
        if rawget(input, held) == mine then input[held] = name == "handleTouchEv" and h.touch or h.key end
    end
    if input.pen_slot == PenBridge.PEN_SLOT then
        local moved = slotData(input, PenBridge.PEN_SLOT)
        local back = ensureSlot(input, h.orig_pen_slot)
        if back then
            back.tool = moved and moved.tool or TOOL_FINGER
            back.id = -1
        end
        if moved then moved.id = -1 end
        input.pen_slot = h.orig_pen_slot
        if input.cur_slot == PenBridge.PEN_SLOT then input.cur_slot = input.main_finger_slot or 0 end
    end
end

return PenBridge

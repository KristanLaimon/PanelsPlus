--[[
Touch and pen input that bypasses KOReader's gesture detector: palm rejection
through the stylus callback (handing the pen back to the detector when it works
the UI), and raw finger tracking for the drawing tools.
Part of InkAwayView (see ink/view.lua).
]]

local Device = require("device")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("ink/l10n")
local PenBridge = require("ink/penbridge")
local PenTest = require("ink/pentest")
local Pens = require("ink/pens")
local Pressure = require("ink/pressure")
local Stylus = require("ink/stylus")

local Screen = Device.screen

-- After the pen lifts, keep ignoring finger touches this long: a resting palm
-- usually lifts a fraction of a second after the pen, so this stops it landing a
-- stray mark or tap in the gap.
local PEN_LIFT_DEBOUNCE = 0.35
local PEN_KOBOS = Stylus.PEN_KOBOS

-- Raw finger tracking (see installRawFinger): the tools drawn straight from touch
-- frames, and how young or short a raw stroke may be for a second finger landing
-- to cancel it (the first finger of a two-finger pan or pinch) rather than commit
-- a dot.
local RAW_TOOLS = { pen = true, erase = true }
local RAW_HANDOFF_CANCEL_MS = 250
local RAW_HANDOFF_CANCEL_PX = 24

-- A raw lift followed by a new contact this soon (kernel event time) is the panel
-- dropping the contact for a frame or two, so the stroke carries on across it. A
-- longer gap is a real lift between letters and commits the stroke, so quick
-- handwriting is never joined up by straight connectors.
local RAW_BRIDGE_MS = 40
local timevMs = Stylus.timevMs

-- A raw finger's stroke is drawn once the finger has moved RAW_START_SLOP
-- (scaled px, about a millimetre) or rested RAW_START_MS, or lifts. Until then
-- nothing is on screen, so the first finger of a two-finger tap (undo) or a pinch
-- leaves no dot to clear away. The stroke then starts where the finger landed and
-- takes every point it passed, so none of it is lost.
local RAW_START_SLOP = 6
local RAW_START_MS = 90

-- How far (screen px) a gesture may sit from where the stylus hook last saw the
-- pen and still count as the pen's own, while it works the UI.
local PEN_UI_SLOP = 3

-- A pen contact that lands on a floating button (zoom, Pan, the toolbar's
-- chevron, the pen or layer strip) is a tap on it when it moves less than
-- PEN_TAP_SLOP_DP (density-independent px: 8 is about 1.3 mm, the distance
-- Android uses to tell a tap from a drag) and lifts within KOReader's hold time
-- (PEN_TAP_MS unless its gesture settings change it). One that moves further is
-- a stroke, drawn from where the pen landed.
local PEN_TAP_SLOP_DP = 8
local PEN_TAP_MS = 500

local InkAwayView = {}

------------------------------------------------------------------------------
-- Palm rejection: on a device with a pen, KOReader can hand us the raw stylus
-- stream before it becomes a gesture. We "dominate" (swallow) the pen and drive
-- our own drawing from it, and while the pen is down we ignore finger gestures,
-- so a resting palm never draws. See ink/stylus.lua for the pure pieces.
------------------------------------------------------------------------------

-- Can this KOReader build deliver raw stylus events, and tell the pen from a
-- finger? On a finger-only reader the callback simply never fires, so the setting
-- is harmless there.
function InkAwayView:penCapable()
    if not (Device.input and type(Device.input.registerStylusCallback) == "function") then return false end
    return not self:onAndroid() or self:androidPenTypes()
end

-- Does this KOReader say which touches are a pen on Android? Up to 2026.07.1 it
-- reports every touch there as a finger (pen types came in August 2026), so palm
-- rejection would take the pen for a hand and move the page with it.
function InkAwayView:androidPenTypes()
    if InkAwayView._android_pen_types == nil then
        local ok, r = pcall(function() return require("android").lib.AMOTION_EVENT_TOOL_TYPE_STYLUS ~= nil end)
        InkAwayView._android_pen_types = (ok and r) and true or false
    end
    return InkAwayView._android_pen_types
end

-- Does the device have a stylus? This only picks the default of the palm
-- rejection toggle. KOReader flags the Wacom pen devices (Kindle Scribe,
-- reMarkable) with wacom_protocol but has no reliable flag for Kobo styluses, so
-- those default to off and are switched on by hand.
function InkAwayView:deviceHasStylus()
    return Device.input and Device.input.wacom_protocol == true and true or false
end

-- Several Ink Away views can be open at once (a book's notes over its
-- annotation, the canvas over a book), and KOReader keeps one stylus callback.
-- The views holding the pen, oldest first, and the callback that held it before
-- the first of them (another plugin's), so a view that closes gives the pen
-- back to the one under it, or to that callback, never to nobody while a view
-- still draws. They share one pen bridge, which goes with the last of them.
local holders, outside_cb, ours = {}, nil, setmetatable({}, { __mode = "k" })
local shared_bridge, bridge_users = nil, 0

-- With palm rejection off the pen draws as a touch, through KOReader's gesture
-- detector, and Ink Away only watches it: the part of the pen that touches down
-- on the page (the eraser end, or the pen with a side button held) swaps in what
-- the reader chose for it, for that stroke, and it is put back once the stroke
-- is finished. No frame is ever taken (false), so drawing, menus and fingers are
-- what they were without the watch. KOReader marks the eraser end and a held
-- button only for a reader that watches the pen, which is why they did nothing
-- with palm rejection off, though the pen test saw them (#13).
function InkAwayView:watchPen(input, slot)
    local facts = self:stylusFacts(input)
    local role = Stylus.classify(slot, facts)
    local sn = slot.slot or 0
    -- the pen's slot, learned from a plain pen frame as with palm rejection on
    -- (see onStylusSlot), so the eraser end and a held button are trusted there
    if role == Stylus.ROLE_PEN and slot.tool == Stylus.TOOL_PEN and slot.slot ~= nil then
        self._learned_pen_slot = slot.slot
    end
    if role ~= Stylus.ROLE_PEN and role ~= Stylus.ROLE_PEN_OUT then return false end
    if self._watch_slot ~= nil and sn ~= self._watch_slot then return false end
    self._watch_state = self._watch_state or Stylus.new()
    local step = Stylus.step(self._watch_state, role == Stylus.ROLE_PEN_OUT and -1 or slot.id)
    if step == "down" then
        self._watch_slot = sn
        if self._watch_settle then UIManager:unschedule(self._watch_settle) end
        self:restoreHeld()
        local act = Stylus.penAction(slot, facts)
        -- (on the page only: a tap on the toolbar or a menu keeps the tool as it is)
        local on_page
        if slot.x and slot.y then on_page = not self:penOnUI(self:penScreenXY(slot))
        else local top = self:touchTarget(); on_page = top == nil or top == self end
        if act ~= Stylus.ACT_DRAW and on_page then self:holdAction(act) end
    elseif step == "up" then
        self._watch_slot = nil
        self._watch_tries = 0
        -- the stroke the swap was for is finished after this frame reaches the
        -- gesture detector, and committed a moment later: put the tool back then
        self._watch_settle = self._watch_settle or function()
            if self.closing then return end
            if (self.capturing or self.pending_lift or self.lassoing) and self._watch_tries < 40 then
                self._watch_tries = self._watch_tries + 1
                UIManager:scheduleIn(0.05, self._watch_settle)
                return
            end
            self:restoreHeld()
        end
        UIManager:nextTick(self._watch_settle)
    end
    return false
end

-- Take the pen for this view.
function InkAwayView:takeStylus()
    if self._stylus_cb then return end
    local inp = Device.input
    local cb = function(i, slot) return self:onStylusSlot(i, slot) end
    self._stylus_cb = cb
    ours[cb] = true
    if #holders == 0 then
        local cur = inp.stylus_callback
        outside_cb = (cur and not ours[cur]) and cur or nil
    end
    holders[#holders + 1] = self
    inp:registerStylusCallback(cb)
end

-- Give the pen back (see takeStylus); a callback registered since this view
-- took the pen (another plugin's, a pen test) is left in place.
function InkAwayView:releaseStylus()
    local cb = self._stylus_cb
    if not cb then return end
    if self._watch_settle then UIManager:unschedule(self._watch_settle) end
    self._stylus_cb = nil
    for i = #holders, 1, -1 do
        if holders[i] == self or holders[i].closing then table.remove(holders, i) end
    end
    local inp = Device.input
    if not inp or inp.stylus_callback ~= cb then return end
    local top = holders[#holders]
    if top and top._stylus_cb then
        pcall(function() inp:registerStylusCallback(top._stylus_cb) end)
    elseif outside_cb then
        pcall(function() inp:registerStylusCallback(outside_cb) end)
    else
        pcall(function() inp:unregisterStylusCallback() end)
    end
    if #holders == 0 then outside_cb = nil end
end

-- Hook the pen to match self.palm_reject. Called at startup and whenever the
-- setting is toggled. With palm rejection on Ink Away takes the pen's frames;
-- with it off it only watches them (see watchPen), so the pen's eraser end and
-- side buttons still do what they are set to.
function InkAwayView:applyPalmReject()
    if not self:penCapable() then return end
    if self.palm_reject then
        self:takeStylus()
        -- Keep the pen's events on the pen's own slot so a resting palm can never
        -- swallow its lift (Wacom devices only; see ink/penbridge.lua). A bridge
        -- another open view installed is shared.
        if not self._pen_bridge and not self.closing then
            if not (shared_bridge and not shared_bridge.dead and shared_bridge.input == Device.input) then
                local ok, h = pcall(PenBridge.install, Device.input)
                shared_bridge, bridge_users = ok and h or nil, 0
            end
            self._pen_bridge = shared_bridge
            if shared_bridge then bridge_users = bridge_users + 1 end
        end
        self:installPressure()
    else
        self:removePenBridge()
        if self._stylus_cb then self:resetPenState() end
        self:takeStylus()
    end
end

-- Can this reader give a pen's pressure? A Wacom pen (Kindle Scribe,
-- reMarkable), a Kobo made for a pen, or a reader Ink Away has seen a pen on;
-- never Android, where KOReader passes none. Pen pressure (Beta) is offered
-- only here.
function InkAwayView:pressureReader()
    if self:onAndroid() or not self:penCapable() then return false end
    local inp = Device.input
    if inp and inp.wacom_protocol then return true end
    if PEN_KOBOS[Device.model] then return true end
    return self:getSetting("inkaway_pen_seen", false) == true
end

-- Is the pen's own pressure used? With Pen pressure (Beta) on, on a reader that
-- can give it, and palm rejection on (the pen's frames, pressure and all, come
-- through onStylusSlot only then). Otherwise Ballpoint and Fountain follow the
-- drawing speed and the other pens draw at their width (see beginStroke).
function InkAwayView:realPressure()
    return self.pen_pressure == true and self.palm_reject and self:pressureReader() or false
end

-- Keep the pen's pressure where KOReader drops it (a Kobo stylus); on a Wacom
-- pen the bridge above already keeps it. See ink/pressure.lua.
function InkAwayView:installPressure()
    if self._pressure_hook or self.closing or not self:realPressure() then return end
    local inp = Device.input
    if inp and not inp.wacom_protocol then
        local ok, h = pcall(Pressure.install, inp)
        self._pressure_hook = ok and h or nil
    end
end

function InkAwayView:removePressure()
    if self._pressure_hook then pcall(Pressure.uninstall, self._pressure_hook); self._pressure_hook = nil end
    if self._pressure_sensor then self._pressure_sensor:close(); self._pressure_sensor = nil end
end

-- The pressure range's top, from the kernel when it says, else the largest value
-- seen so far (at least 255).
function InkAwayView:pressureMax()
    local p = self._pressure_probe
    if p == nil then
        local ok, r = pcall(Pressure.probe)
        p = ok and r or {}
        self._pressure_probe = p
    end
    if p.hi then return p.hi - (p.lo or 0) end
    return math.max(255, self._pressure_seen or 0)
end

-- A pen slot's raw pressure above the range's bottom, or nil when the pen gives
-- none or none is wanted: real pressure off, or the pen in hand does not draw
-- with it. A Wacom firmware that sends no pressure events is asked directly.
function InkAwayView:slotPressure(slot)
    if not self:realPressure() then return nil end
    if self.tool ~= "pen" or not Pens.usesPressure(self.pen_style) then return nil end
    local raw = slot.pressure
    if type(raw) ~= "number" then
        local inp = self._stylus_input or Device.input
        if not (inp and inp.wacom_protocol) then return nil end
        if self._pressure_sensor == nil then
            local ok, s = pcall(Pressure.openSensor)
            self._pressure_sensor = (ok and s) or false
        end
        raw = self._pressure_sensor and self._pressure_sensor:read()
        if type(raw) ~= "number" then return nil end
    end
    local lo = (self._pressure_probe and self._pressure_probe.lo) or 0
    raw = raw - lo
    if raw > (self._pressure_seen or 0) then self._pressure_seen = raw end
    return raw
end

function InkAwayView:removePenBridge()
    self:removePressure()
    local h = self._pen_bridge
    if not h then return end
    self._pen_bridge = nil
    if h == shared_bridge then
        bridge_users = bridge_users - 1
        if bridge_users > 0 and not h.dead then return end   -- another view still draws
        shared_bridge, bridge_users = nil, 0
    end
    pcall(PenBridge.uninstall, h)
end

------------------------------------------------------------------------------
-- Driving the drawing from the pen
------------------------------------------------------------------------------

-- Drop all in-flight pen and palm state, when palm rejection is turned off or the
-- view closes. Also restores a tool swapped in for the eraser end or side button,
-- so turning it off mid-stroke never leaves the tool stuck on erase or lasso.
function InkAwayView:resetPenState()
    UIManager:unschedule(self._pen_clear)
    if self._watch_settle then UIManager:unschedule(self._watch_settle) end
    self._watch_state, self._watch_slot = nil, nil
    self._pen_fab, self._pen_fab_stroke = nil, nil
    self:restoreHeld()
    self._pen_state = Stylus.new()
    self._pen_started = false
    self._pen_feeding = false
    self._pen_owner = nil
    self._reject_finger = false
    self._palm_slots = {}
    self._palm_count = 0
    self._pen_kin = nil
    self._pen_last_ms = nil
    self._learned_pen_slot = nil
    self._stylus_input = nil
    self._pen_hold_at = nil
    UIManager:unschedule(self._pen_hold_cb)
    self._pen_ui_contact, self._pen_ui = false, nil
    UIManager:unschedule(self._pen_ui_end)
end

-- True while finger input must be ignored: the pen or a palm is physically down,
-- the pen hovers in range, or the short grace after everything lifts
-- (_reject_finger). Latching on physical presence, not the timer alone, means a
-- stray palm frame's timer can never drop rejection mid-stroke and let a line
-- appear between palm and pen. Pen-fed events set _pen_feeding to pass through,
-- and so does a gesture at `pos` that is the pen itself working the UI.
function InkAwayView:fingerRejected(pos)
    if self._pen_feeding then return false end
    if pos and self._pen_ui and self:penUiGesture(pos) then return false end
    return self._pen_state.down or self._palm_count > 0 or self._reject_finger
        or self:penInRange()
end

------------------------------------------------------------------------------
-- Fingers that navigate, and page swipes
------------------------------------------------------------------------------

-- What a finger touch on the page does instead of using the tool: "navigate" or
-- "nothing", from the Finger on the page setting, or nil when it uses the tool.
-- With palm rejection on the pen does the writing and a finger never draws: a
-- hand resting on the page while the pen is away is a finger too.
function InkAwayView:fingerOnPage()
    if self._pen_feeding or not self.palm_reject then return nil end
    return self.finger_mode == "nothing" and "nothing" or "navigate"
end

-- Is a gesture at `pos` a finger that palm rejection keeps from writing? The pen,
-- fed to the tool or tapping the UI, is not.
function InkAwayView:navFinger(pos)
    if not self:fingerOnPage() then return false end
    return not (pos and self._pen_ui and self:penUiGesture(pos))
end

-- Is the page zoomed in past where it starts (filling the drawing area)?
function InkAwayView:zoomedIn()
    return self.view.zoom > (self.zoom_min or 0) * 1.001
end

-- Is the page zoomed in wider than the drawing area, so it can pan sideways?
function InkAwayView:sidewaysRoom()
    local v = self.view
    return v.canvas_w * v.zoom > v.area_w + 1
end

-- Do sideways swipes turn pages? On a notebook page, unless it is zoomed in so
-- far that sideways moves pan it.
function InkAwayView:pageSwipes()
    return self.notebook ~= nil and not self:sidewaysRoom()
end

-- Turn the page for a swipe that moved (dx, dy) screen px, if it was sideways
-- enough and far enough: to the left for the next page, as in the reader.
-- Returns whether it turned.
function InkAwayView:swipeTurn(dx, dy)
    if not self:pageSwipes() then return false end
    if math.abs(dx) < self.view.area_w / 8 or math.abs(dx) <= 1.5 * math.abs(dy) then return false end
    self:nbGo(dx < 0 and 1 or -1)
    return true
end

-- A navigating finger moved to `pos`: pan by the step, unless it is a sideways
-- swipe on a page that cannot pan sideways (it turns the page at the lift).
function InkAwayView:fingerNavPan(pos)
    local n = self._finger_nav
    if n.mode ~= "navigate" or not pos then return true end
    local dx, dy = pos.x - n.lx, pos.y - n.ly
    n.lx, n.ly = pos.x, pos.y
    if self:pageSwipes() and math.abs(pos.x - n.x) > math.abs(pos.y - n.y) then return true end
    self:panByScreen(dx, dy)
    return true
end

-- A navigating finger lifted at `pos`, or flicked `dir`: a long enough sideways
-- drag or a sideways flick turns the page.
function InkAwayView:fingerNavEnd(pos, dir)
    local n = self._finger_nav
    self._finger_nav = nil
    if pos then
        local len = math.abs(pos.x - n.x) + math.abs(pos.y - n.y)
        if n.mode == "navigate" then self:noPenDrag(len) end
        self:fingerNote(n.mode, len)
    end
    if self._view_stale then self:liveFlush() end   -- show where the pan ended
    if n.mode ~= "navigate" or not self:pageSwipes() then return true end
    if dir == "west" or dir == "east" then
        self:nbGo(dir == "west" and 1 or -1)
    elseif pos then
        local dx, dy = pos.x - n.x, pos.y - n.y
        if math.abs(dx) >= self.view.area_w / 6 and math.abs(dx) > 2 * math.abs(dy) then
            self:nbGo(dx < 0 and 1 or -1)
        end
    end
    return true
end

-- The first finger drag on the page with palm rejection on, ever: say that the
-- pen draws and a finger moves the page (or does nothing), and where to change
-- it. A reader who wanted to draw with a finger could not find why it did not
-- (#41). A tap never shows it.
function InkAwayView:fingerNote(mode, len)
    if len < Screen:scaleBySize(40) or self:getSetting("inkaway_finger_note_seen", false) == true then return end
    self:setSetting("inkaway_finger_note_seen", true)
    local text = mode == "nothing"
        and _("Palm rejection is on, so the pen draws and a finger does nothing on the page.\n\nTo draw with a finger, turn off Palm rejection in the pen menu, Pen and input.")
        or _("Palm rejection is on, so the pen draws and a finger moves the page.\n\nTo draw with a finger, turn off Palm rejection in the pen menu, Pen and input.")
    self:tell(text)
end

-- A finger dragged the page `len` px while palm rejection waited for a pen that
-- never came. A few such drags in a session and no pen at all mean the pen most
-- likely arrives as a finger here: say so once per KOReader session.
function InkAwayView:noPenDrag(len)
    if self._pen_seen or InkAwayView._no_pen_hinted or len < Screen:scaleBySize(40) then return end
    self._no_pen_drags = (self._no_pen_drags or 0) + 1
    if self._no_pen_drags < PenTest.NO_PEN_DRAGS then return end
    InkAwayView._no_pen_hinted = true
    self:tell(_(PenTest.NO_PEN_HINT))
end

-- A hold at `pos` by a navigating finger: open the picture's, shape's or text
-- box's menu there (duplicate, delete, turn...), as a hold does with the Move
-- tool.
function InkAwayView:holdMenuAt(pos)
    local hit = self:hitTestImage(pos.x, pos.y) or self:hitTestShape(pos.x, pos.y)
        or self:hitTestText(pos.x, pos.y)
    if hit and self:selectOps({ hit.idx }, "pan") then self:openSelectionMenu() end
end

-- Is the pen hovering over (or on) the screen? On a Wacom device KOReader keeps
-- the pen's tool on its slot from the moment it comes into range until it leaves,
-- so this is a cheap live check. A hand that lands while the pen hovers just
-- above the page is the writing hand, not a finger meant to draw or pan.
function InkAwayView:penInRange()
    if not self.palm_reject then return false end
    local inp = self._stylus_input or Device.input
    if not (inp and inp.wacom_protocol and inp.pen_slot and inp.ev_slots) then return false end
    local p = inp.ev_slots[inp.pen_slot]
    return p ~= nil and (p.tool == Stylus.TOOL_PEN or p.tool == Stylus.TOOL_ERASER)
end

-- Translate a raw slot position into the screen coordinates a finger gesture
-- would carry (raw position, then the screen rotation).
function InkAwayView:penScreenXY(slot)
    return Stylus.screenXY(slot, Screen)
end

-- The live Input facts Stylus.classify needs to tell a real pen from a promoted
-- palm: the dedicated pen slot, whether this is a Wacom-protocol device, and the
-- barrel-button latches KOReader keeps.
function InkAwayView:stylusFacts(input)
    return Stylus.facts(input or Device.input, self._learned_pen_slot, self:onAndroid())
end

-- Milliseconds since the previous stylus frame, from the slot's own timestamp,
-- for the kinematic palm filter; nil when there is no usable timestamp (the
-- filter then stays off). timev is in microseconds, see Stylus.timevMs.
function InkAwayView:penFrameMs(slot)
    local ms = Stylus.timevMs(slot.timev)
    if not ms then self._pen_last_ms = nil; return nil end
    local prev = self._pen_last_ms
    self._pen_last_ms = ms
    if not prev then return nil end
    local dt = ms - prev
    if dt < 0 then return nil end
    return dt
end

-- Hold finger rejection open for the lift debounce and restart the clear timer.
-- Called on every pen and palm frame, so fingers stay ignored while either is
-- present and the timer clears it once activity stops.
function InkAwayView:holdReject()
    self._reject_finger = true
    UIManager:unschedule(self._pen_clear)
    UIManager:scheduleIn(PEN_LIFT_DEBOUNCE, self._pen_clear)
end

-- A palm KOReader promoted to a stylus tool number and routed to us. It never
-- draws; we only track that it is down and keep fingers rejected. A palm whose
-- tool reverts to an ordinary finger reappears as a normal gesture, and the held
-- rejection window (refreshed by onIaTouch and onIaPan) covers it until it lifts.
function InkAwayView:penPalm(slot)
    local key = slot.slot or 0
    local id = tonumber(slot.id)
    local promoted = false
    if id and id >= 0 then
        local prev = self._palm_slots[key]
        if prev == nil then
            self._palm_count = self._palm_count + 1
            promoted = true              -- a slot that was an ordinary touch is now a palm
        elseif prev ~= id then
            promoted = true              -- a new physical generation on the same slot
        end
        self._palm_slots[key] = id
    elseif id and id < 0 then
        if self._palm_slots[key] then
            self._palm_slots[key] = nil
            self._palm_count = math.max(0, self._palm_count - 1)
        end
    end
    self:holdReject()
    -- The digitizer flags a palm only after it has landed, so it first arrives as
    -- an ordinary touch and may already have opened a stroke. On the promotion,
    -- drop that contact's mark, unless the pen itself is drawing (a different,
    -- trusted slot whose stroke must never be dropped).
    if promoted and not self._pen_started and not self._pen_owner then
        self:penDropFingerOps()
    end
end

-- The stylus callback (registered on KOReader's Input). Runs before gesture
-- detection; returning true keeps the slot out of gesture detection. A slot
-- reaches us when its tool is a pen, eraser or highlighter, or it sits on the pen
-- slot; that includes a resting palm (MT_TOOL_PALM == ERASER == 2), so slots are
-- classified first and only a trusted pen drives the drawing.
function InkAwayView:onStylusSlot(inp, slot)
    if self.closing then return false end
    if not self.palm_reject then return self:watchPen(inp or Device.input, slot) end
    local input = inp or Device.input
    self._stylus_input = input
    local facts = self:stylusFacts(input)
    local role = Stylus.classify(slot, facts)
    -- Learn the pen's slot from the first genuine pen-tip frame, so the rear eraser
    -- and a held barrel button (which report the ambiguous ERASER value) are trusted
    -- on that same slot even when the runtime never set Input.pen_slot. The pen slot
    -- is fixed per device, so once learned it stays until palm rejection is reset.
    if role == Stylus.ROLE_PEN then self._pen_seen = true end
    -- a pen tip seen on this reader: Pen pressure (Beta) is offered from now on
    if role == Stylus.ROLE_PEN and slot.tool == Stylus.TOOL_PEN and not self._pen_seen_kept then
        self._pen_seen_kept = true
        if self:getSetting("inkaway_pen_seen", false) ~= true then self:setSetting("inkaway_pen_seen", true) end
    end
    if role == Stylus.ROLE_PEN and slot.tool == Stylus.TOOL_PEN and slot.slot ~= nil
            and (self._pen_owner == nil or slot.slot == self._pen_owner) then
        self._learned_pen_slot = slot.slot
    end
    -- One slot owns the pen stroke. Another slot that also classifies as a pen is
    -- demoted to a palm: two slots feeding one pen state machine draw lines between
    -- them. This happens off Wacom (Kobo), where a resting palm promoted to the
    -- eraser or highlighter tool by a held barrel button looks like a pen; on Wacom
    -- only the pen slot is ever ROLE_PEN.
    local sn = slot.slot or 0
    -- The pen's own slot (from the runtime or learned) is never demoted. This also
    -- lets a pen whose first frame carried no slot number (so the owner defaulted
    -- to 0) keep drawing once its slotted frames arrive.
    local is_pen_slot = (self._learned_pen_slot ~= nil and sn == self._learned_pen_slot)
                     or (input and input.pen_slot ~= nil and sn == input.pen_slot)
    -- A pen contact working the UI stays with the gesture detector until it lifts
    -- or leaves range (see penUiStart). Another pen-like contact meanwhile is a palm.
    if self._pen_ui_contact then
        if (sn == self._pen_ui.slot or is_pen_slot)
                and (role == Stylus.ROLE_PEN or role == Stylus.ROLE_PEN_OUT) then
            return self:penUiFrame(slot, role == Stylus.ROLE_PEN_OUT)
        elseif role == Stylus.ROLE_PEN then
            role = Stylus.ROLE_PALM
        end
    end
    -- A pen contact on a floating button waits to see whether it is a tap or a
    -- stroke (see penFabFrame); once it is a stroke, this frame is drawn below.
    if self._pen_fab then
        if (sn == self._pen_fab.slot or is_pen_slot)
                and (role == Stylus.ROLE_PEN or role == Stylus.ROLE_PEN_OUT) then
            if self:penFabFrame(slot, role == Stylus.ROLE_PEN_OUT, facts) then return true end
        elseif role == Stylus.ROLE_PEN then
            role = Stylus.ROLE_PALM
        end
    end
    if role == Stylus.ROLE_PEN and self._pen_owner ~= nil and sn ~= self._pen_owner
            and not is_pen_slot then
        role = Stylus.ROLE_PALM
    end
    if role == Stylus.ROLE_PEN_OUT then
        -- The pen left range. If its lift never arrived, this is the lift.
        if Stylus.step(self._pen_state, -1) == "up" then
            self:penUp()
            self._pen_owner = nil
        end
        return true          -- the gesture detector never saw this contact start
    elseif role == Stylus.ROLE_PALM then
        self:penPalm(slot)   -- remember it, keep fingers out; never draw
        return true          -- dominate: keep it out of gesture detection
    elseif role == Stylus.ROLE_TOUCH then
        return false         -- a real finger that only reached us in passing
    end
    -- ROLE_PEN: a trusted pen drives our own touch, pan and release. Palms are
    -- filtered out above, so an eraser tool here is the pen's own rear eraser or a
    -- held barrel button. When the pen may tap the UI (pen_ui), a contact that
    -- lands on it is handed to the gesture detector instead, decided on its first
    -- point.
    if self.pen_ui and not self._pen_started and slot.id ~= nil and slot.id >= 0
            and slot.x and slot.y then
        local x, y = self:penScreenXY(slot)
        local fab = self:penFabAt(x, y)
        if fab then return self:penFabStart(sn, slot, fab, x, y) end
        if self:penOnUI(x, y) then return self:penUiStart(sn, x, y) end
    end
    local action = Stylus.step(self._pen_state, slot.id)
    if action == "down" then
        self._pen_owner = sn        -- this slot owns the stroke until it lifts
        self:penDown(slot, facts)
    elseif action == "move" then
        self:penMove(slot)
    elseif action == "up" then
        self:penUp()
        self._pen_owner = nil
    end
    return true   -- swallow the pen; we handle it ourselves
end

-- Feed one synthetic touch, pan or release into the normal handlers, marked so
-- the finger-rejection guard lets it through. The pen goes through the same tool
-- routing as a finger (pen, eraser, shapes, text, pan, moving images and shapes).
function InkAwayView:feedPen(kind, x, y)
    self._pen_feeding = true
    local ges = { pos = { x = x, y = y } }
    if kind == "down" then self:onIaTouch(nil, ges)
    elseif kind == "move" then self:onIaPan(nil, ges)
    elseif kind == "up" then self:onIaPanRelease(nil, ges) end
    self._pen_feeding = false
end

-- Discard anything a palm or finger began just before the pen touched down, so a
-- hand that rests on the screen before writing leaves no stray mark.
function InkAwayView:penDropFingerOps()
    if self.capturing then
        UIManager:unschedule(self._finalize)
        self.pending_lift = nil
        self.capturing = false
        self:elipsaStroke(false)
        self:eraserCursorHide()   -- (the page is drawn again just below)
        if self._wipe then self:wipeCancel() end
        if self._wl then self:washEnd() end
        if self._sm then self:smudgeEnd() end
        self.canvas:cancelStroke()
        self.last_cx, self.last_cy = nil, nil
        self:recompose()
    end
    self:cancelShape()      -- drop a half-drawn shape
    self.pan_last = nil
    self.lassoing, self.lasso_scr = false, nil
end

function InkAwayView:penDown(slot, facts)
    -- restore a tool swapped in for the eraser end or side button if the last lift was lost
    self:restoreHeld()
    self._reject_finger = true
    self._pen_started = false      -- the stroke opens on the first point with coordinates
    self._pen_kin = {}             -- fresh kinematic-filter state for this stroke
    self._pen_last_ms = nil
    UIManager:unschedule(self._pen_clear)
    self:penDropFingerOps()
    -- The side buttons and the rear eraser end do what the reader chose (by
    -- default: highlight while a button is held, erase with the eraser end), for
    -- this stroke only: the tool or pen swapped in is put back at the lift, so
    -- they act as held modifiers. A lasso selection lives in self.selection, so it
    -- survives the restore and can be moved by holding the button again.
    local act = Stylus.penAction(slot, facts)
    if act ~= Stylus.ACT_DRAW then self:holdAction(act) end
    self:penMove(slot)             -- if this frame already carries coordinates, open here
end

function InkAwayView:penMove(slot)
    if not (slot.x and slot.y) then return end   -- a coordinate-less down/hover frame
    local x, y = self:penScreenXY(slot)
    -- Kinematic palm filter: drop a sample that jumped implausibly far in the elapsed
    -- time (a resting palm's coordinates written into the pen slot), keeping the
    -- stroke open. It seeds itself on the first point and no-ops without a timestamp,
    -- so a normal stroke is never affected. See Stylus.acceptMove.
    if self._pen_kin then
        local dt = self:penFrameMs(slot)
        local keep, restart = Stylus.acceptMove(self._pen_kin, x, y, dt, self._dpi_factor or 1)
        if not keep then return end
        -- The point is real but cannot continue this line (a lift we never got):
        -- finish the stroke where it was and open a new one here, never a connector.
        if restart and self._pen_started then
            self:feedPen("up", self._pen_last_x or x, self._pen_last_y or y)
            self:flushPending()
            self._pen_started = false
        end
    end
    self._pen_last_x, self._pen_last_y = x, y
    self._pen_raw_pressure = self:slotPressure(slot)
    -- Some pen protocols announce the contact one frame before the first
    -- coordinates, so the stroke is opened by whichever frame first has a point.
    if not self._pen_started then
        self._pen_started = true
        self:feedPen("down", x, y)
        -- The pen never produces KOReader's hold gesture, so time a long press here:
        -- holding still in a text box being edited opens the paste bubble.
        if self.editing_text and not self._clip_press then
            self._pen_hold_at = { x = x, y = y }
            UIManager:unschedule(self._pen_hold_cb)
            UIManager:scheduleIn(0.5, self._pen_hold_cb)
        end
    else
        local h = self._pen_hold_at
        if h and math.abs(x - h.x) + math.abs(y - h.y) > Screen:scaleBySize(12) then
            self._pen_hold_at = nil
            UIManager:unschedule(self._pen_hold_cb)
        end
        self:feedPen("move", x, y)
    end
end

function InkAwayView:penUp()
    self._pen_raw_pressure = nil
    if self._pen_hold_at then
        self._pen_hold_at = nil
        UIManager:unschedule(self._pen_hold_cb)
    end
    if self._pen_started then
        self:feedPen("up", self._pen_last_x or 0, self._pen_last_y or 0)
        self:flushPending()      -- the pen lift is clean; commit now, no coalesce wait
        self._pen_started = false
    end
    self:restoreHeld()
    -- keep ignoring fingers briefly: a palm often lifts a moment after the pen
    UIManager:unschedule(self._pen_clear)
    UIManager:scheduleIn(PEN_LIFT_DEBOUNCE, self._pen_clear)
end

------------------------------------------------------------------------------
-- The pen on the UI (Pen taps menus and buttons)
--
-- A pen contact that lands on the toolbar, a floating control, the notebook bar,
-- or anything shown over the canvas (a menu, a dialog, the keyboard) is left to
-- KOReader's gesture detector, which treats it as a finger until it lifts. The
-- choice is made on the contact's first point, so a stroke that starts on the
-- canvas keeps drawing wherever it goes.
------------------------------------------------------------------------------

-- The widget a touch reaches first: the topmost one shown, passing over toasts
-- and messages that close by themselves, which never hold on to a touch.
function InkAwayView:touchTarget()
    local stack = UIManager._window_stack
    if type(stack) ~= "table" then
        return UIManager.getTopmostVisibleWidget and UIManager:getTopmostVisibleWidget()
    end
    for i = #stack, 1, -1 do
        local w = stack[i] and stack[i].widget
        if w and not w.invisible and not w.toast and not w.timeout then return w end
    end
end

-- Does a pen contact landing at screen (x, y) go to the UI rather than the canvas?
function InkAwayView:penOnUI(x, y)
    local top = self:touchTarget()
    if top and top ~= self then return true end
    return not self:inArea(x, y) or self:fabHit(x, y) ~= nil
end

-- Start a UI contact: leave it to the gesture detector and remember where the pen
-- is, so its own gestures get past the finger rejection while a palm elsewhere is
-- still kept out (see penUiGesture).
function InkAwayView:penUiStart(sn, x, y)
    -- a first frame without coordinates may already have opened a pen stroke; it
    -- drew nothing, so forget it
    if self._pen_state.down then
        self._pen_state = Stylus.new()
        self._pen_owner, self._pen_kin = nil, nil
        self:restoreHeld()
    end
    self._pen_ui_contact = true
    self._pen_ui = { slot = sn, x0 = x, y0 = y, x = x, y = y }
    UIManager:unschedule(self._pen_ui_end)
    self._reject_finger = true
    UIManager:unschedule(self._pen_clear)
    return false
end

-- One frame of a UI contact, passed on to the gesture detector. The contact ends
-- on the lift or when the pen leaves range (given a lift there if it never came).
-- Its tap or release is dispatched after this frame, so the pass-through for its
-- gestures lasts until the next tick.
function InkAwayView:penUiFrame(slot, leaving)
    if slot.id ~= nil and slot.id >= 0 then
        if not leaving then
            if slot.x and slot.y then
                local u = self._pen_ui
                u.x, u.y = self:penScreenXY(slot)
            end
            return false
        end
        slot.id = -1
    end
    self._pen_ui_contact = false
    UIManager:nextTick(self._pen_ui_end)
    UIManager:unschedule(self._pen_clear)
    UIManager:scheduleIn(PEN_LIFT_DEBOUNCE, self._pen_clear)
    return false
end

-- The floating button under a pen contact's first point, while the canvas is the
-- topmost window (with a menu over it the pen works that, as before).
function InkAwayView:penFabAt(x, y)
    local top = self:touchTarget()
    if (top and top ~= self) or not self:inArea(x, y) then return nil end
    return self:fabHit(x, y)
end

-- The pen's tap slop in screen px (see PEN_TAP_SLOP_DP).
function InkAwayView:penTapSlop()
    if not self._pen_tap_slop then
        local ok, px = pcall(function() return Screen:scaleByDPI(PEN_TAP_SLOP_DP) end)
        if not (ok and type(px) == "number" and px > 0) then px = Screen:scaleBySize(PEN_TAP_SLOP_DP) end
        self._pen_tap_slop = px
    end
    return self._pen_tap_slop
end

-- How long a pen tap on a floating button may last: KOReader's hold time, after
-- which it is a hold, which the buttons ignore (a finger's hold does nothing there
-- either).
function InkAwayView:penTapMs()
    local ok, ms = pcall(function() return tonumber(G_reader_settings:readSetting("ges_hold_interval_ms")) end)
    return (ok and ms and ms > 0) and ms or PEN_TAP_MS
end

-- The pen landed on a floating button: keep the contact until it lifts (a tap on
-- the button) or moves past the slop (a stroke from where it landed). KOReader
-- reuses its slot tables, so the landing frame is copied.
function InkAwayView:penFabStart(sn, slot, kind, x, y)
    if self._pen_state.down then   -- a coordinate-less first frame may have opened a stroke
        self._pen_state = Stylus.new()
        self._pen_owner, self._pen_kin = nil, nil
        self:restoreHeld()
    end
    self._pen_fab = { kind = kind, slot = sn, x = x, y = y,
        tv = Stylus.timevMs(slot.timev), now = self:nowMs(),
        first = { slot = slot.slot, id = slot.id, x = slot.x, y = slot.y, tool = slot.tool,
                  timev = slot.timev, pressure = slot.pressure } }
    self._reject_finger = true
    UIManager:unschedule(self._pen_clear)
    return true
end

-- One more frame of a contact that landed on a floating button. Returns true when
-- it is taken here, or false when it has just become a stroke, opened at the
-- landing point, so the caller draws this frame as its next point.
function InkAwayView:penFabFrame(slot, leaving, facts)
    local f = self._pen_fab
    if leaving or slot.id == nil or slot.id < 0 then
        self._pen_fab = nil
        UIManager:unschedule(self._pen_clear)
        UIManager:scheduleIn(PEN_LIFT_DEBOUNCE, self._pen_clear)
        -- the time from the same clock as the landing: the frames' own, or ours
        local tv = Stylus.timevMs(slot.timev)
        local held = (tv and f.tv) and (tv - f.tv) or (self:nowMs() - f.now)
        if held <= self:penTapMs() then self:fabAction(f.kind) end   -- held longer: nothing, as a finger's hold
        return true
    end
    if not (slot.x and slot.y) then return true end
    local x, y = self:penScreenXY(slot)
    local dx, dy, slop = x - f.x, y - f.y, self:penTapSlop()
    if dx * dx + dy * dy <= slop * slop then return true end
    self._pen_fab = nil
    Stylus.step(self._pen_state, f.first.id)   -- the contact's down
    self._pen_owner = f.slot
    self._pen_fab_stroke = true                -- its touch lands on the button: draw, not press
    self:penDown(f.first, facts)
    self._pen_fab_stroke = nil
    return false
end

-- Is a gesture at `pos` the pen's own UI contact? The detector reports the pen
-- where the stylus hook last saw it, or for a swipe where it landed.
function InkAwayView:penUiGesture(pos)
    local u = self._pen_ui
    if not (u and pos.x and pos.y) then return false end
    return (math.abs(pos.x - u.x) <= PEN_UI_SLOP and math.abs(pos.y - u.y) <= PEN_UI_SLOP)
        or (math.abs(pos.x - u.x0) <= PEN_UI_SLOP and math.abs(pos.y - u.y0) <= PEN_UI_SLOP)
end

------------------------------------------------------------------------------
-- Raw finger tracking
--
-- KOReader's GestureDetector emits nothing for a contact until it has moved
-- PAN_THRESHOLD (scaleByDPI(35), 5.6 mm on any panel) from where it landed, so a
-- letter that stays inside that box would arrive as a touch and a tap: a straight
-- line from the first contact to the lift. The freehand tools therefore draw a
-- contact that lands in the drawing area straight from its touch frames, by
-- wrapping the detector's feedEvent (every Input:handleTouchEv* variant calls it
-- once per SYN_REPORT with the frame's slots). The owned slot is removed from its
-- very first frame, so the detector never opens a Contact for it: no hold or tap
-- timers, no duplicate gestures. Everything else (toolbar, floating controls,
-- other tools, a second finger, dialogs) stays on the gesture path, and pen
-- devices with palm rejection on keep their own stylus path.
------------------------------------------------------------------------------

function InkAwayView:installRawFinger()
    local gd = Device.input and Device.input.gesture_detector
    if self._raw_installed or not (gd and type(gd.feedEvent) == "function"
            and type(gd.getContact) == "function") then return false end
    local orig = gd.feedEvent              -- the class method, or another plugin's wrapper
    local wrapper
    wrapper = function(gd_self, tevs)
        if self._raw_wrapper == wrapper then
            local ok, kept = pcall(self.onRawFrame, self, gd_self, tevs)
            if not ok then
                logger.warn("Ink Away: raw finger tracking disabled:", kept)
                self._raw_wrapper = nil    -- transparent from now on
                pcall(self.flushPending, self)
            elseif kept then
                tevs = kept
            end
        end
        return orig(gd_self, tevs)
    end
    self._raw_gd, self._raw_own = gd, rawget(gd, "feedEvent")
    self._raw_wrapper, self._raw_installed = wrapper, wrapper
    self._raw = { kept = {}, buf = {} }
    self._raw_start_cb = self._raw_start_cb or function()
        if self._raw and self._raw.wait then self:rawStart() end
    end
    gd.feedEvent = wrapper
    -- KOReader drops every contact at once, without their lifts, when Android
    -- cancels a gesture (Input:resetState): the finger we own goes with them
    if type(gd.dropContacts) == "function" then
        local orig_drop = gd.dropContacts
        local drop
        drop = function(gd_self, ...)
            if self._raw_drop == drop then pcall(self.rawDropped, self) end
            return orig_drop(gd_self, ...)
        end
        self._raw_drop_own, self._raw_drop = rawget(gd, "dropContacts"), drop
        gd.dropContacts = drop
    end
    return true
end

function InkAwayView:uninstallRawFinger()
    if not self._raw_installed then return end
    local gd = self._raw_gd
    if self._raw and self._raw.slot ~= nil then pcall(self.rawRelease, self, false) end
    if self._raw_start_cb then UIManager:unschedule(self._raw_start_cb) end
    if gd and rawget(gd, "feedEvent") == self._raw_installed then
        gd.feedEvent = self._raw_own       -- nil falls back to the class method
    end                                    -- else a wrapper chained on top: ours stays transparent
    if gd and self._raw_drop and rawget(gd, "dropContacts") == self._raw_drop then
        gd.dropContacts = self._raw_drop_own
    end
    self._raw_wrapper, self._raw_installed, self._raw_gd, self._raw = nil, nil, nil, nil
    self._raw_drop, self._raw_drop_own = nil, nil
end

-- KOReader dropped its contacts without their lifts (Android cancelled the
-- gesture: the system took the touch, as a Boox does with a palm). The finger
-- we own is gone too, and its stroke with it, as KOReader drops a cancelled
-- gesture. Left owned, the next finger would hand it back to the detector as a
-- first finger that never lifts, and every tap after that would be a
-- two-finger tap.
function InkAwayView:rawDropped()
    local r = self._raw
    if not r then return end
    if r.slot ~= nil then
        if r.wait then self:rawDropWaiting() else self:penDropFingerOps() end
    end
    r.slot, r.id, r.tev = nil, nil, nil
    r.ignore_slot, r.ignore_id = nil, nil
end

-- May a contact landing at screen (x, y) be drawn from its raw frames?
function InkAwayView:rawCanOwn(gd, x, y)
    if self.closing or self.palm_reject then return false end
    if not RAW_TOOLS[self.tool] then return false end
    if (gd.contact_count or 0) > 0 then return false end   -- multi-touch in progress
    if self._raw.ignore_slot ~= nil then return false end  -- our handed-off finger is still down
    if self:fingerRejected() then return false end
    if not self:inArea(x, y) or self:fabHit(x, y) then return false end
    if self.selecting_crop or self.selection then return false end
    local top = UIManager.getTopmostVisibleWidget and UIManager:getTopmostVisibleWidget()
    if top and top ~= self then return false end
    return true
end

-- Draw the owned contact's stroke, held back until now (see RAW_START_SLOP): from
-- where the finger landed through every point it has passed since.
function InkAwayView:rawStart()
    local r = self._raw
    if not (r and r.wait) then return end
    r.wait = false
    UIManager:unschedule(self._raw_start_cb)
    self:feedPen("down", r.x0, r.y0)
    local buf = r.buf
    for i = 1, #buf, 2 do self:feedPen("move", buf[i], buf[i + 1]) end
    for i = #buf, 1, -1 do buf[i] = nil end
end

-- Forget a stroke that was never drawn.
function InkAwayView:rawDropWaiting()
    local r = self._raw
    if not (r and r.wait) then return end
    r.wait = false
    UIManager:unschedule(self._raw_start_cb)
    for i = #r.buf, 1, -1 do r.buf[i] = nil end
end

-- End the owned contact: a lift, or a hand-off because a second finger landed.
-- A hand-off of a stroke that barely started (the first finger of a two-finger
-- tap, pan or pinch) is cancelled rather than committed as a stray dot; one not
-- yet drawn just goes.
function InkAwayView:rawRelease(handoff, tev)
    local r = self._raw
    if r.slot == nil then return end
    r.ignore_slot, r.ignore_id = r.slot, r.id
    r.slot, r.id = nil, nil
    if handoff and r.wait then
        self:rawDropWaiting()
        return
    end
    if r.wait then self:rawStart() end   -- a lift before the stroke was drawn: a dot
    if handoff then
        local now = tev and timevMs(tev.timev)
        local young = now and r.t0 and (now - r.t0) < RAW_HANDOFF_CANCEL_MS
        if young or r.len < RAW_HANDOFF_CANCEL_PX then
            self:penDropFingerOps()
            return
        end
        self:feedPen("up", r.x, r.y)
        self:flushPending()
        return
    end
    r.ignore_slot, r.ignore_id = nil, nil
    r.lift_t = tev and timevMs(tev.timev)
    self:feedPen("up", r.x, r.y)
end

-- The frame's changed slots, before the detector sees them. Returns a copy
-- without the owned slot, or nil to pass the frame through untouched. The tev
-- tables are Input's persistent per-slot records, so values are copied out.
-- When a second finger lands, the first one's record goes to the detector in
-- that same frame, so it sees both fingers from then on: a resting first finger
-- sends no frames of its own, and without this a two-finger tap would reach it as
-- a one-finger tap.
function InkAwayView:onRawFrame(gd, tevs)
    local r = self._raw
    local strip, handoff_tev
    for i = 1, #tevs do
        local tev = tevs[i]
        local slot, id = tev.slot or 0, tev.id
        local down = id ~= nil and id >= 0
        if r.slot ~= nil and slot == r.slot then
            if down and id == r.id then
                if self:fingerRejected() then  -- a pen took over: never co-drive one stroke
                    r.ignore_slot, r.ignore_id, r.slot, r.id = r.slot, r.id, nil, nil
                elseif tev.x and tev.y then
                    local x, y = self:penScreenXY(tev)
                    if x ~= r.x or y ~= r.y then
                        r.len = r.len + math.abs(x - r.x) + math.abs(y - r.y)
                        r.x, r.y = x, y
                        if r.wait then
                            local buf = r.buf
                            buf[#buf + 1], buf[#buf + 2] = x, y
                            local slop = Screen:scaleBySize(RAW_START_SLOP)
                            if math.abs(x - r.x0) > slop or math.abs(y - r.y0) > slop then self:rawStart() end
                        else
                            self:feedPen("move", x, y)
                        end
                    end
                end
                strip = strip or {}; strip[i] = true
            else
                self:rawRelease(false, tev)    -- lift, or the slot got a new contact id
                if not down then strip = strip or {}; strip[i] = true end
            end
        elseif r.slot ~= nil and down and not gd:getContact(slot) then
            handoff_tev = r.tev
            self:rawRelease(true, tev)         -- second finger: multi-touch goes to gestures
        end
        if r.ignore_slot == slot and (not down or id ~= r.ignore_id) then
            r.ignore_slot, r.ignore_id = nil, nil
        end
        if r.slot == nil and down and tev.x and tev.y and not gd:getContact(slot)
                and not (strip and strip[i])
                and not (r.ignore_slot == slot and r.ignore_id == id) then
            local x, y = self:penScreenXY(tev)
            if self:rawCanOwn(gd, x, y) then
                local t = timevMs(tev.timev)
                if self.pending_lift and not (t and r.lift_t and t - r.lift_t <= RAW_BRIDGE_MS) then
                    self:flushPending()       -- a real lift: never bridge to the next letter
                end
                r.slot, r.id, r.x, r.y, r.len = slot, id, x, y, 0
                r.t0, r.tev, r.x0, r.y0 = t, tev, x, y
                r.wait = true              -- drawn once it moves or rests (see rawStart)
                UIManager:unschedule(self._raw_start_cb)
                UIManager:scheduleIn(RAW_START_MS / 1000, self._raw_start_cb)
                strip = strip or {}; strip[i] = true
            end
        end
    end
    if handoff_tev then
        local present = false
        for i = 1, #tevs do
            if tevs[i] == handoff_tev then present = true; if strip then strip[i] = nil end end
        end
        if not present then
            strip = strip or {}
            local kept = r.kept
            for k = #kept, 1, -1 do kept[k] = nil end
            kept[1] = handoff_tev
            for i = 1, #tevs do if not strip[i] then kept[#kept + 1] = tevs[i] end end
            return kept
        end
    end
    if not strip then return nil end
    local kept = r.kept
    for k = #kept, 1, -1 do kept[k] = nil end
    for i = 1, #tevs do if not strip[i] then kept[#kept + 1] = tevs[i] end end
    return kept
end

return InkAwayView

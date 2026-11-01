--[[
Fast ink on a Boox. KOReader's Onyx driver (the "qualcomm" platform of its
Android launcher) is "full-only": KOReader asks the panel itself only for the
refreshes that flash the whole screen. Every other refresh is just posted to the
app's window, and the waveform is whatever the reader set for KOReader in Boox's
E-Ink Center: in the default modes the slow grey one, about half a second for
each update, and on some models nothing at all until the pen lifts.

While Ink Away is open there, its fast refreshes also ask the panel for the fast
black-and-white waveform (DU) over their rect, right after the window is posted,
through KOReader's own call and with the constants KOReader's driver gives that
panel, as KOReader does itself on the e-ink Androids it drives fully. A live
request also covers the one before it, in case that one reached the panel before
the frame did. Once a stroke ends, its whole rect is asked for again a moment
later, and the refresh that settles grey and colour once the pen rests asks for
the grey waveform.

Plain Lua: the KOReader pieces (the android module, the screen) are passed in,
so the headless tests drive it.
]]

local EinkDrive = {}

-- A live request waits this long after its window post, so the panel takes the
-- new frame (Android composes it at the next display frame).
EinkDrive.FAST_DELAY_MS = 20
-- A request this soon after the previous one covers both rects.
EinkDrive.JOIN_MS = 150
-- The whole stroke, asked for again after the pen lifts.
EinkDrive.TAIL_DELAY_MS = 120

local state = nil        -- the installed drive, shared by every open Ink Away view
local detected = nil     -- detect()'s answer, once known (false: not a Boox)

-- The waveforms to ask for, when KOReader drives this panel only for full-screen
-- refreshes and its driver is Onyx's: { fast, ui, delay_fast, delay_ui }, else
-- nil. `android` is KOReader's android module (required when not given).
function EinkDrive.detect(android)
    if detected ~= nil and not android then return detected or nil end
    local found = false
    local a = android
    if not a then
        local ok, m = pcall(require, "android")
        a = ok and m or nil
    end
    if a then
        local ok, eink, platform = pcall(a.isEink)
        local okf, full = pcall(a.isEinkFull)
        if ok and eink and platform == "qualcomm" and okf and not full then
            local okc, _full, _partial, _full_ui, partial_ui, fast, _delay, delay_ui, delay_fast = pcall(a.getEinkConstants)
            if okc and type(fast) == "number" and fast > 0 and type(partial_ui) == "number" and partial_ui > 0 then
                found = { fast = fast, ui = partial_ui,
                    delay_fast = tonumber(delay_fast) or 0, delay_ui = tonumber(delay_ui) or 100 }
            end
        end
    end
    if not android then detected = found end
    return found or nil
end

-- Ask the panel for `mode` over the screen rect after `delay` ms. A failing call
-- turns the drive off for the rest of the session rather than fail every refresh.
local function request(s, fb, mode, delay, x, y, w, h)
    if s.broken then return false end
    local ok, err = pcall(fb._updatePartial, fb, mode, delay, x, y, w, h)
    if not ok then
        s.broken = true
        if s.log then s.log("Ink Away: fast e-ink refresh disabled:", err) end
        return false
    end
    s.asked = s.asked + 1
    return true
end

-- A fast refresh went out: ask for the fast waveform over it and the previous
-- rect, if that was recent.
local function fast(s, fb, x, y, w, h)
    if not (x and y and w and h) then
        x, y, w, h = 0, 0, fb:getWidth(), fb:getHeight()
    end
    local t = s.now()
    local l = s.last
    local rx, ry, rw, rh = x, y, w, h
    if l.t and t - l.t <= EinkDrive.JOIN_MS then
        local x0, y0 = math.min(x, l.x), math.min(y, l.y)
        rw, rh = math.max(x + w, l.x + l.w) - x0, math.max(y + h, l.y + l.h) - y0
        rx, ry = x0, y0
    end
    l.x, l.y, l.w, l.h, l.t = x, y, w, h, t
    request(s, fb, s.c.fast, math.max(s.c.delay_fast, EinkDrive.FAST_DELAY_MS), rx, ry, rw, rh)
end

-- Start driving `screen` (KOReader's framebuffer) with the waveforms `c` (from
-- detect). Each open view acquires it once and releases it on close; the screen
-- is hooked while any holds it. `now` gives milliseconds; `log` warns.
-- Returns whether the drive is on.
function EinkDrive.acquire(screen, c, now, log)
    if state then
        state.users = state.users + 1
        return true
    end
    if not (screen and c and type(screen._updatePartial) == "function"
            and type(screen.refreshFastImp) == "function") then return false end
    local s = { screen = screen, c = c, users = 1, now = now or function() return 0 end, log = log,
        last = {}, asked = 0, own = rawget(screen, "refreshFastImp") }
    local orig = screen.refreshFastImp      -- the class method, or another plugin's wrapper
    s.wrapper = function(fb, x, y, w, h, d)
        local r = orig(fb, x, y, w, h, d)    -- the window post
        if state == s then fast(s, fb, x, y, w, h) end
        return r
    end
    screen.refreshFastImp = s.wrapper
    state = s
    return true
end

-- One view is done with the drive; the last one unhooks the screen. A wrapper
-- another plugin put on top of ours stays, and ours passes through.
function EinkDrive.release()
    local s = state
    if not s then return end
    s.users = s.users - 1
    if s.users > 0 then return end
    state = nil
    if rawget(s.screen, "refreshFastImp") == s.wrapper then
        s.screen.refreshFastImp = s.own       -- nil falls back to the class method
    end
end

-- Is the drive on?
function EinkDrive.active()
    return state ~= nil and not state.broken
end

-- Ask for a rect already posted, or about to be in this round of painting:
-- "fast" for a stroke that just ended, "ui" for the grey settle. Screen coordinates.
function EinkDrive.ask(kind, x, y, w, h)
    local s = state
    if not s or w <= 0 or h <= 0 then return false end
    local fb = s.screen
    if fb.calculateRealCoordinates then x, y, w, h = fb:calculateRealCoordinates(x, y, w, h) end
    if kind == "ui" then
        return request(s, fb, s.c.ui, math.max(s.c.delay_ui, EinkDrive.FAST_DELAY_MS), x, y, w, h)
    end
    return request(s, fb, s.c.fast, EinkDrive.TAIL_DELAY_MS, x, y, w, h)
end

-- How many requests went to the panel (tests and the pen test).
function EinkDrive.asked()
    return state and state.asked or 0
end

-- Forget what detect() found (tests).
function EinkDrive.reset()
    detected = nil
end

return EinkDrive

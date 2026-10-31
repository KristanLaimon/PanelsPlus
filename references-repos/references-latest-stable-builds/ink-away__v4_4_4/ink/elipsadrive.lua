--[[
Fast ink on the original Kobo Elipsa. Each update of its screen holds KOReader
until the panel has taken it, and meanwhile no pen or finger frame is read, so
the ink trailed well behind the nib (#45). While Ink Away is open there, its
fast updates go to a helper process instead (ink/elipsaworker.lua), which waits
on the panel while KOReader goes on reading the pen.

One update is with the helper at a time. Everything drawn meanwhile becomes one
rectangle, sent next, so the screen catches up with the pen rather than
replaying where it was. While Ink Away draws a stroke (see ElipsaDrive.stroke),
the helper also makes the grey updates inside its drawing area, so a
highlighter or anything else drawn in grey keeps up too (#50). Any other
refresh (a menu, a full refresh), a turn of the screen or KOReader closing the
screen first waits for the helper, stops it and shows what was left, so updates
keep KOReader's order. The helper starts again with the next update it takes.

A helper still busy with a slow update is waited for; only one that has gone,
or answers wrongly, has failed. Then the updates are made as before until the
next stroke, which tries the helper again; after three failures in a row it is
left off until Ink Away opens again.

Only on the Elipsa of 2021 (KOReader's Kobo_europa), not the Sage or the Elipsa
2E. Plain Lua: the screen and the helper are passed in, so the headless tests
drive it.
]]
local ElipsaDrive = {}
local state
local POLL_SEC = 0.01
local WAIT_ROUNDS = 5          -- waits (of the helper's 3 s each) for a busy helper before it counts as stuck
local MAX_FAILURES = 3         -- failures in a row before the helper is left off

-- Is this the original Elipsa, with the screen its helper needs?
function ElipsaDrive.supported(device, screen)
    return device.model == "Kobo_europa" and type(device.isSunxi) == "function" and device:isSunxi()
        and screen and screen.fd and screen.fd >= 0 and screen.data ~= nil
        and screen.layer ~= nil and screen.marker_data ~= nil and screen.waveform_fast ~= nil
        and type(screen.mech_refresh) == "function" and true or false
end

-- Keep all changed pixels while a slower driver call is in progress. Rects
-- carry their waveform; a grey and a fast one together are shown grey, which
-- shows all of both.
local function union(a, b, grey)
    if not b then return a end
    if not a then return b end
    local x, y = math.min(a.x, b.x), math.min(a.y, b.y)
    a.w, a.h = math.max(a.x + a.w, b.x + b.w) - x, math.max(a.y + a.h, b.y + b.h) - y
    a.x, a.y = x, y
    if a.mode ~= b.mode then a.mode = grey end
    return a
end

-- Take over the fast updates for an open view (the views open at once share
-- it). `uim` is KOReader's UIManager; `factory` starts the helper (the tests
-- give one that blocks like the panel, without forking).
function ElipsaDrive.acquire(device, screen, uim, log, factory)
    if state then
        if state.screen ~= screen or state.gave_up then return false end
        state.users = state.users + 1
        return true
    end
    if not ElipsaDrive.supported(device, screen) then return false end
    local s = { screen = screen, users = 1, uim = uim, log = log, hooks = {}, failures = 0 }
    local refresh = screen.mech_refresh
    factory = factory or function() return require("ink/elipsaworker").start(screen, refresh) end

    -- A failed transport returns its outstanding rectangle to the caller for a
    -- synchronous repaint. Nothing is silently lost on startup or worker failure.
    local function stop(failed)
        uim:unschedule(s.tick)
        if s.worker then
            if not s.worker:close(failed) and log then log("Ink Away: Elipsa handwriting mode could not be disabled") end
            s.worker = nil
        end
        s.busy = nil
    end
    local function fail(reason)
        s.pending = union(s.pending, s.busy, screen.waveform_ui)
        s.broken = true
        s.failures = s.failures + 1
        s.gave_up = s.failures >= MAX_FAILURES or nil
        stop(true)
        if log then
            log(s.gave_up and "Ink Away: Elipsa refresh worker failed; using normal refreshes"
                or "Ink Away: Elipsa refresh worker failed; normal refreshes until the next stroke",
                reason or "transport failed")
        end
    end
    local function complete(wait)
        if not s.busy then return true end
        local marker = s.worker:poll(wait)
        -- (a slow update still going is waited for, within reason)
        local rounds = 1
        while wait and marker == nil and rounds < WAIT_ROUNDS do
            marker = s.worker:poll(true)
            rounds = rounds + 1
        end
        if marker == nil and not wait then return false end
        if not marker then fail(marker == nil and "no answer" or nil); return false end
        screen.marker_data[0] = marker
        s.busy = nil
        s.failures = 0
        return true
    end
    local function send()
        if not s.pending or s.busy or s.broken then return end
        if not s.worker then
            local ok, worker, err = pcall(factory)
            if not ok or not worker then fail(ok and err or worker); return end
            s.worker = worker
        end
        s.busy, s.pending = s.pending, nil
        if not s.worker:send(s.busy) then fail() end
    end
    local function repaint()
        local r = s.pending
        s.pending = nil
        if r then refresh(screen, false, false, r.mode or screen.waveform_fast, r.x, r.y, r.w, r.h) end
    end

    -- Fence the worker before UI waveforms, rotation, waiting, or closing ION.
    function s.barrier()
        uim:unschedule(s.tick)
        if s.busy then complete(true) end
        if not s.broken then
            send()
            if s.busy then complete(true) end
        end
        stop(s.broken)
        repaint()
    end
    -- Poll without blocking the input loop and submit the newest pending union.
    function s.tick()
        if state ~= s then return end
        complete(false)
        send()
        if s.broken then repaint() end
        if s.busy then uim:scheduleIn(POLL_SEC, s.tick) end
    end

    -- Preserve other plugins' wrappers, including ones installed after this one.
    local function hook(name, wrapper)
        local orig = screen[name]
        if type(orig) ~= "function" then return end
        local h = { own = rawget(screen, name) }
        h.wrapper = function(fb, ...)
            if state ~= s then return orig(fb, ...) end
            return wrapper(orig, fb, ...)
        end
        s.hooks[name], screen[name] = h, h.wrapper
    end
    -- Does the helper take this update? A fast one, or while a stroke is drawn a
    -- grey one inside its drawing area; never a flash, an unmerged one or the
    -- first after a turn of the screen.
    local function takes(fb, no_merge, flashing, mode, x, y, w, h)
        if s.broken or no_merge or flashing or fb._just_rotated then return false end
        if not (x and y and w and h and w > 1 and h > 1) then return false end
        if mode == fb.waveform_fast then return true end
        local a = s.live
        return a ~= nil and mode ~= nil and mode == fb.waveform_ui
            and x >= a.x and y >= a.y and x + w <= a.x + a.w and y + h <= a.y + a.h
    end
    hook("mech_refresh", function(orig, fb, no_merge, flashing, mode, x, y, w, h, ...)
        if takes(fb, no_merge, flashing, mode, x, y, w, h) then
            s.pending = union(s.pending, { x = x, y = y, w = w, h = h, mode = mode }, fb.waveform_ui)
            uim:unschedule(s.tick)
            s.tick()
            return
        end
        s.barrier()
        return orig(fb, no_merge, flashing, mode, x, y, w, h, ...)
    end)
    for _, name in ipairs({ "setRotationMode", "reinit", "close", "refreshWaitForLastImp" }) do
        hook(name, function(orig, fb, ...)
            s.barrier()
            return orig(fb, ...)
        end)
    end
    state = s
    return true
end

-- Are the fast updates going to the helper?
function ElipsaDrive.active() return state ~= nil and not state.broken end

-- Ink Away starts a stroke in `area` (a screen rect { x, y, w, h }), or ends
-- it (nil). While it lasts the helper also takes the grey updates inside the
-- area. A stroke after a failure tries the helper again, unless it gave up.
function ElipsaDrive.stroke(area)
    local s = state
    if not s then return end
    if area and s.screen.calculateRealCoordinates then
        local x, y, w, h = s.screen:calculateRealCoordinates(area.x, area.y, area.w, area.h)
        area = { x = x, y = y, w = w, h = h }
    end
    s.live = area
    if area and s.broken and not s.gave_up then s.broken = nil end
end

-- The last view out drains work and restores the screen before freeing buffers.
function ElipsaDrive.release()
    local s = state
    if not s then return end
    s.users = s.users - 1
    if s.users > 0 then return end
    s.barrier()
    state = nil
    for name, h in pairs(s.hooks) do
        if rawget(s.screen, name) == h.wrapper then s.screen[name] = h.own end
    end
end

return ElipsaDrive

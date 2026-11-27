--[[
Posting only the changed part of the screen to the app's window on Android,
while Ink Away is open there.

KOReader copies its whole screen buffer into the Android window on every
refresh (framebuffer_android's _updateWindow locks the window with no dirty
rect): 10 to 18 MB on a Boox for each piece of live ink, a few pixels across,
and Android then treats the whole window as changed, so the reader's e-ink
service may redraw far more than the ink. Here the window is locked with the
refresh's rect: Android keeps the rest of the window (copying it back from the
frame before, or asking for all of it when it cannot, in which case all of it is
copied as before), and the window's damage is that rect.

The refreshes keep KOReader's own code: only the window post is replaced, for
the refreshes that have a rect, while some view holds it (acquire/release). The
hooks stay once installed (a refresh then calls straight through), so another
plugin's wrapper on the same refreshes is never cut out of the chain. Anything
odd (a window format, size or rotation this does not expect, a failed lock)
posts the whole screen as KOReader does; an error turns it off for the session.

The pieces it needs (the android module, ffi, the blitbuffer module) are passed
in, so the headless tests drive it.
]]

local AndroidWindow = {}

-- The refreshes that post the window before asking the panel (framebuffer_android).
AndroidWindow.IMPS = { "refreshFastImp", "refreshUIImp", "refreshPartialImp",
    "refreshFlashUIImp", "refreshFlashPartialImp" }

local state = nil     -- { users, broken, rect, posted, partial } once installed
local hooked = {}     -- screen -> true: its refreshes are hooked

-- The screen rect (x, y, w, h, in the buffer's own rotation) back from the window
-- buffer's: the inverse of BlitBuffer:getPhysicalRect for buffer `bb`.
function AndroidWindow.logicalRect(bb, px, py, pw, ph)
    local r = bb:getRotation()
    local W, H = bb.w, bb.h          -- (the buffer's own, unrotated size)
    if r == 1 then return py, W - px - pw, ph, pw end
    if r == 2 then return W - px - pw, H - py - ph, pw, ph end
    if r == 3 then return H - py - ph, px, ph, pw end
    return px, py, pw, ph
end

-- Post the rect (x, y, w, h, screen coordinates) of `fb`'s buffer to the window.
-- Returns false when it did not (the whole screen is posted instead).
local function post(s, fb, x, y, w, h)
    local d = s.deps
    local android, ffi, BB = d.android, d.ffi, d.BB
    local window = android.app and android.app.window
    if window == nil then return false end
    local ext = fb.full_bb or fb.bb
    x, y, w, h = ext:getBoundedRect(x, y, w, h)
    if w <= 0 or h <= 0 then return false end
    local px, py, pw, ph = ext:getPhysicalRect(x, y, w, h)
    local dirty = ffi.new("ARect[1]")
    dirty[0].left, dirty[0].top, dirty[0].right, dirty[0].bottom = px, py, px + pw, py + ph
    local buffer = ffi.new("ANativeWindow_Buffer[1]")
    if android.lib.ANativeWindow_lock(window, buffer, dirty) < 0 then return false end
    -- from here the window is locked: it is always posted
    local C = ffi.C
    local b = buffer[0]
    local win
    if (b.format == C.WINDOW_FORMAT_RGBA_8888 or b.format == C.WINDOW_FORMAT_RGBX_8888)
            and b.width == ext.w and b.height == ext.h then
        win = BB.new(b.width, b.height, BB.TYPE_BBRGB32, b.bits, b.stride * 4, b.stride)
    end
    if win then
        win:setInverse(ext:getInverse())
        win:setRotation(ext:getRotation())
        -- what Android asks for may be more than the rect (all of it, when it
        -- could not keep the frame before)
        local dl, dt = dirty[0].left, dirty[0].top
        local lx, ly, lw, lh = AndroidWindow.logicalRect(ext, dl, dt, dirty[0].right - dl, dirty[0].bottom - dt)
        if win:getInverse() == 1 and BB:getUseCBB() and win:getType() == ext:getType() then
            win:invertblitFrom(ext, lx, ly, lx, ly, lw, lh)
        else
            win:blitFrom(ext, lx, ly, lx, ly, lw, lh)
            if win:getInverse() == 1 then win:invertRect(lx, ly, lw, lh) end
        end
        s.partial = s.partial + 1
    end
    android.lib.ANativeWindow_unlockAndPost(window)
    if not win then
        -- a window this does not draw into: KOReader's own post, which locks it anew
        return false
    end
    return true
end

-- Hook `screen`'s refreshes (once): while held, a refresh with a rect posts only it.
local function hook(screen)
    if hooked[screen] then return end
    hooked[screen] = true
    local update = screen._updateWindow
    screen._updateWindow = function(fb, ...)
        local s = state
        local r = s and s.users > 0 and not s.broken and s.rect
        if r then
            s.rect = nil
            local ok, done = pcall(post, s, fb, r[1], r[2], r[3], r[4])
            if ok and done then return end
            if not ok then
                s.broken = true
                if s.deps.log then s.deps.log("Ink Away: partial window posts off:", done) end
            end
        end
        return update(fb, ...)
    end
    for _i, name in ipairs(AndroidWindow.IMPS) do
        local orig = screen[name]
        if type(orig) == "function" then
            screen[name] = function(fb, x, y, w, h, ...)
                local s = state
                if s and s.users > 0 and x and y and w and h then s.rect = { x, y, w, h } end
                local r1, r2 = orig(fb, x, y, w, h, ...)
                if s then s.rect = nil end
                return r1, r2
            end
        end
    end
end

-- Can this screen post a part of itself: KOReader on Android, with the window
-- calls and the rect type it needs? `deps` = { android, ffi, BB, log }.
function AndroidWindow.supported(screen, deps)
    local a, ffi = deps and deps.android, deps and deps.ffi
    if not (screen and a and ffi and deps.BB) then return false end
    if type(screen._updateWindow) ~= "function" then return false end
    if not (a.lib and a.app) then return false end
    local ok = pcall(function() return ffi.new("ARect[1]") and a.lib.ANativeWindow_lock end)
    return ok
end

-- A view starts using it. Returns whether it is on.
function AndroidWindow.acquire(screen, deps)
    if not AndroidWindow.supported(screen, deps) then return false end
    if state and state.broken then return false end
    if not state then state = { users = 0, partial = 0, deps = deps } end
    state.deps = deps
    hook(screen)
    state.users = state.users + 1
    return true
end

-- A view is done with it; with no view left, refreshes post the whole screen again.
function AndroidWindow.release()
    if state and state.users > 0 then state.users = state.users - 1 end
end

-- Is it on?
function AndroidWindow.active()
    return state ~= nil and state.users > 0 and not state.broken
end

-- How many refreshes posted only their rect (tests, the pen test).
function AndroidWindow.partialPosts()
    return state and state.partial or 0
end

-- Forget everything (tests).
function AndroidWindow.reset()
    state = nil
    hooked = {}
end

return AndroidWindow

--[[
When Boox's own pen layer inks (see ink/booxink.lua), and where.

While a view wants it (a pen that draws opaque ink, nothing open over the page),
the firmware inks the pen's strokes on the e-ink itself, at the pen's own speed,
inside the drawing area and outside its floating controls. Ink Away still gets
every point and draws the stroke as it really is (its colour, texture,
pressure) when the pen lifts, over the firmware's black preview. Anything else
(the eraser, the lasso, text, a see-through or light pen, a sheet, a dialog, a
menu, a turned screen) pauses it first, so the firmware never inks where Ink Away
would not. Asking again for what is already set sends nothing.

The window hooks (watch) pause it the moment anything is shown over the view
(before that is drawn), and look again once it closes. They are installed once,
and pass through when no view holds the layer.

Plain Lua: the client is passed in, so the headless tests drive it.
]]

local BooxDrive = {}

local client = nil       -- the pen layer's client, once looked for (false: none)
local watched = false
local screen_hooks, input_hooks = {}, {}
local pending = {}
local focused = true
local focus_task, focus_manager

-- Drop delayed work when its owner closes, pauses or loses Android focus.
local function cancelPending()
    for screen, p in pairs(pending) do
        p.um:unschedule(p.task)
        pending[screen] = nil
    end
    if focus_task then focus_manager:unschedule(focus_task); focus_task = nil end
end

-- The pen layer's client on this reader, or nil: looked for once, on Android only.
-- `make` builds it (BooxInk.new); `android` says whether this is Android.
function BooxDrive.client(make, android)
    if client == nil then
        client = false
        if android then
            local ok, c = pcall(make)
            if ok and c and c.ok then client = c end
            BooxDrive.probed = ok and c or nil   -- (found or not: what the pen test reports)
        end
    end
    return client or nil
end

-- A drive for one view, over `c` (a client).
function BooxDrive.new(c)
    return setmetatable({ c = c, state = nil, region = nil, look = nil, posts = nil }, { __index = BooxDrive })
end

local function rectsKey(rs)
    local parts = {}
    for _i, r in ipairs(rs or {}) do
        parts[#parts + 1] = string.format("%d,%d,%d,%d", r.x, r.y, r.w, r.h)
    end
    return table.concat(parts, ";")
end

-- Is the firmware inking now?
function BooxDrive:inking()
    return self.state == 2 and self.posts ~= true and self.c:usable()
end

-- Set what the view wants: `want` = { limit = { rects }, exclude = { rects },
-- width, color, style } to ink there, or nil to pause. Returns whether it inks.
function BooxDrive:apply(want)
    local c = self.c
    if not c:usable() then return false end
    if not want then
        if self.state == 2 or self.state == 1 then
            if c:setPenState(3) then self.state, self.posts = 3, true end
        end
        return false
    end
    local look = string.format("%.2f|%d|%d", want.width or 2, want.color or -16777216, want.style or 0)
    if look ~= self.look then
        if not c:setStroke(want.width or 2, want.color or -16777216, want.style or 0) then return false end
        self.look = look
    end
    local region = rectsKey(want.limit) .. "/" .. rectsKey(want.exclude)
    if region ~= self.region then
        if not c:setRegion(want.limit, want.exclude) then return false end
        self.region = region
    end
    if self.state == nil or self.state == 0 then
        if not c:setPenState(1) then return false end
        self.state = 1
    end
    if self.state ~= 2 then
        if not c:setPenState(2) then return false end
        self.state = 2
        self.posts = nil -- a pen-state transition can change the firmware gate
    end
    if want.posts ~= nil and self.posts ~= want.posts then
        if not c:setPosting(want.posts) then return false end
        self.posts = want.posts
    end
    return self:inking()
end

-- The view is done: the firmware stops inking and forgets the area.
function BooxDrive:stop()
    local c = self.c
    if self.state ~= nil and self.state ~= 0 and c:usable() then
        c:setPenState(0)
        c:setRegion({}, {})
    end
    self.state, self.region, self.look, self.posts = 0, nil, nil, true
end

------------------------------------------------------------------------------
-- The views that use the layer, and the windows shown over them
--
-- There is one pen layer, so one drive: the views that use it are kept in the
-- order they opened (the notes window over the annotation mode, say), and the
-- newest decides; when it closes, the one under it decides again. A view has a
-- booxInkUpdate method that asks for what it wants (BooxDrive.want).
------------------------------------------------------------------------------

local drive = nil
local views = {}

-- `view` starts using the layer through client `c`. Returns the shared drive.
function BooxDrive.join(view, c)
    if not drive or drive.c ~= c then drive = BooxDrive.new(c) end
    for i = #views, 1, -1 do if views[i] == view then table.remove(views, i) end end
    views[#views + 1] = view
    return drive
end

-- `view` is done with it: the one under it decides again, and with none left
-- the firmware stops inking.
function BooxDrive.leave(view)
    cancelPending()
    for i = #views, 1, -1 do if views[i] == view then table.remove(views, i) end end
    local top = views[#views]
    if top then
        if top.booxInkUpdate then pcall(top.booxInkUpdate, top) end
    elseif drive then
        pcall(drive.stop, drive)
    end
end

-- The view that decides now, if any.
function BooxDrive.holder()
    return views[#views]
end

-- `view` asks for `want` (see BooxDrive:apply); only the deciding view is heard.
function BooxDrive.want(view, want)
    if not drive or views[#views] ~= view then return false end
    if not focused then want = nil end
    if not want or want.posts then cancelPending() end
    return drive:apply(want)
end

-- Has the firmware the panel now, for whichever view? (A request of our own would
-- only get in its way: see ink/einkdrive.lua.)
function BooxDrive.busy()
    return drive ~= nil and drive:inking()
end

-- Is the firmware inking for `view`?
function BooxDrive.inkingFor(view)
    return drive ~= nil and views[#views] == view and drive:inking()
end

-- Pause before anything but a passing toast is shown over the deciding view; ask
-- again after something closes. `UIManager` is KOReader's.
function BooxDrive.watch(UIManager)
    if watched then return end
    watched = true
    local show, close = UIManager.show, UIManager.close
    UIManager.show = function(um, widget, ...)
        local v = views[#views]
        if v and drive and widget ~= v and type(widget) == "table" and not widget.toast and not widget.timeout then
            cancelPending()
            if v.booxInkRelease then pcall(v.booxInkRelease, v) end
            pcall(drive.apply, drive, nil)
        end
        return show(um, widget, ...)
    end
    UIManager.close = function(um, widget, ...)
        local r1, r2 = close(um, widget, ...)
        local v = views[#views]
        if v and widget ~= v then
            um:nextTick(function()
                if views[#views] == v then pcall(v.booxInkUpdate, v) end
            end)
        end
        return r1, r2
    end
end

-- Android may show system panels without sending Suspend. Release normal
-- posts on genuine focus loss, but not its synthetic touch-cancel (value 42).
function BooxDrive.watchInput(input, C, um)
    if not input or input_hooks[input] or type(input.handleMiscEv) ~= "function" then return end
    input_hooks[input] = true
    local orig = input.handleMiscEv
    input.handleMiscEv = function(inp, ev, ...)
        local code = ev.code
        if ev.value ~= 42 and (code == C.APP_CMD_LOST_FOCUS or code == C.APP_CMD_TERM_WINDOW
                or code == C.APP_CMD_PAUSE or code == C.APP_CMD_DESTROY) then
            focused = false
            cancelPending()
            local v = views[#views]
            if v then
                if v.booxInkRelease then pcall(v.booxInkRelease, v)
                else v._boox_contact = nil end
            end
            if drive then pcall(drive.apply, drive, nil) end
        end
        local r1, r2 = orig(inp, ev, ...)
        if ev.value ~= 42 and code == C.APP_CMD_GAINED_FOCUS then
            focused = true
            cancelPending()
            focus_manager = um
            focus_task = function()
                focus_task = nil
                local v = views[#views]
                if focused and v and v.booxInkUpdate then v:booxInkUpdate() end
            end
            um:scheduleIn(0.05, focus_task) -- let Android show the returned window first
        end
        return r1, r2
    end
end

-- Android has to compose the posted window before the raw-handwriting repaint.
-- Coalesce refreshes until that next frame; no per-sample software refreshes
-- are introduced while the firmware is drawing a pen stroke.
function BooxDrive.watchScreen(screen, um)
    if screen_hooks[screen] then return end
    screen_hooks[screen] = true
    for _i, name in ipairs({ "refreshFastImp", "refreshUIImp", "refreshPartialImp", "refreshFullImp",
            "refreshFlashUIImp", "refreshFlashPartialImp" }) do
        local orig = screen[name]
        if type(orig) == "function" then
            screen[name] = function(fb, x, y, w, h, ...)
                local r1, r2 = orig(fb, x, y, w, h, ...)
                local owner = drive
                local v = views[#views]
                if owner and owner:inking() and focused and v then
                    local W, H = fb:getWidth(), fb:getHeight()
                    x, y, w, h = x or 0, y or 0, w or W, h or H
                    local x0, y0 = math.max(0, math.floor(x)), math.max(0, math.floor(y))
                    local x1, y1 = math.min(W, math.ceil(x + w)), math.min(H, math.ceil(y + h))
                    if x1 > x0 and y1 > y0 and v._boox_defer then
                        -- held back until the pen rests: what to show then (booxInkRelease)
                        local b = v._boox_blocked
                        if b then
                            b.x0, b.y0 = math.min(b.x0, x0), math.min(b.y0, y0)
                            b.x1, b.y1 = math.max(b.x1, x1), math.max(b.y1, y1)
                        else
                            v._boox_blocked = { x0 = x0, y0 = y0, x1 = x1, y1 = y1 }
                        end
                    elseif x1 > x0 and y1 > y0 then
                        local p = pending[screen]
                        if p then
                            p.x0, p.y0 = math.min(p.x0, x0), math.min(p.y0, y0)
                            p.x1, p.y1 = math.max(p.x1, x1), math.max(p.y1, y1)
                        else
                            p = { x0 = x0, y0 = y0, x1 = x1, y1 = y1, um = um }
                            pending[screen] = p
                            p.task = function()
                                if pending[screen] ~= p then return end
                                pending[screen] = nil
                                local top = views[#views]
                                if drive == owner and owner:inking() and focused and top and not top._boox_defer then
                                    if not owner.c:repaint(p.x0, p.y0, p.x1 - p.x0, p.y1 - p.y0) then
                                        um:setDirty(nil, "full") -- the failed client unlocked ordinary posts
                                    end
                                end
                            end
                            um:scheduleIn(0.04, p.task)
                        end
                    end
                end
                return r1, r2
            end
        end
    end
end

-- Forget everything but the window hooks (tests).
function BooxDrive.reset()
    cancelPending()
    client, drive, views = nil, nil, {}
    BooxDrive.probed = nil
    focused = true
end

return BooxDrive

--[[
The Boox pen layer, reached from Lua: the Onyx firmware draws the pen's ink on
the e-ink itself, straight from the pen, while the app is told where it may
(the way Boox's own notes app writes, and Onyx's pen kit for apps). Ink Away
then draws the stroke as it really is once the pen lifts (see ink/booxdrive.lua).

These are Onyx firmware methods, not part of Android: older firmware puts them
on View as instance methods; Note X3 Pro puts them on ViewUpdateHelper as static
methods. They are found once,
by name and signature, through KOReader's JNI helper; on any other device, or a
Boox without them, `usable()` is false and nothing is ever called. A Java
exception from any call clears it and turns the layer off for the session.

  * setScreenHandWritingPenState(int)        0 stop, 1 start, 2 drawing, 3 paused
  * setScreenHandWritingRegionLimit(View, int[])    where the pen inks: l, t, r, b, ...
  * setScreenHandWritingRegionExclude(View, int[])  where it does not, inside that
  * static setStrokeWidth(float), setStrokeColor(int), setStrokeStyle(int)

Signatures as Onyx's own SDK looks them up (onyxsdk-device, SDMDevice). The JNI
helper attaches the thread for each call, so method IDs and the window's view are
kept as global references.
]]

local BooxInk = {}

BooxInk.STOP, BooxInk.START, BooxInk.DRAWING, BooxInk.PAUSED = 0, 1, 2, 3

local VIEW = "android/view/View"
-- Note X3 Pro firmware 4.2 exposes the whole pen API here, as static methods.
local HELPER = "android/onyx/ViewUpdateHelper"

-- A client for the pen layer. `android` is KOReader's android module (required
-- when not given), `ffi` LuaJIT's. Returns the client; client.ok says whether the
-- firmware has the layer.
function BooxInk.new(android, ffi, log)
    local self = { ok = false, broken = false, log = log, calls = 0 }
    if not android then
        local okr, m = pcall(require, "android")
        android = okr and m or nil
    end
    ffi = ffi or require("ffi")
    if not (android and android.jni and android.app and android.app.activity) then return setmetatable(self, { __index = BooxInk }) end
    self.android, self.ffi = android, ffi
    setmetatable(self, { __index = BooxInk })
    local ok, err = pcall(self.probe, self)
    if not ok then
        self.ok = false
        if log then log("Ink Away: Boox pen layer not found:", err) end
    end
    return self
end

-- Run fn(env) with the thread attached; a pending Java exception is cleared and
-- reported as false.
function BooxInk:withEnv(fn)
    local android = self.android
    return android.jni:context(android.app.activity.vm, function(jni)
        local env = jni.env
        local r1, r2 = fn(env, jni)
        if env[0].ExceptionCheck(env) ~= 0 then
            env[0].ExceptionClear(env)
            return false, "a Java exception"
        end
        return r1, r2
    end)
end

-- Find the methods and the window's view (once).
function BooxInk:probe()
    local found, why = self:withEnv(function(env, jni)
        local function clear()
            if env[0].ExceptionCheck(env) ~= 0 then env[0].ExceptionClear(env) end
        end
        local function class(name)
            local c = env[0].FindClass(env, name)
            clear()
            if c == nil then return nil end
            local g = env[0].NewGlobalRef(env, c)
            env[0].DeleteLocalRef(env, c)
            return g
        end
        local function method(cls, name, sig)
            if cls == nil then return nil end
            local m = env[0].GetMethodID(env, cls, name, sig)
            clear()
            return m ~= nil and m or nil
        end
        local function static(cls, name, sig)
            if cls == nil then return nil end
            local m = env[0].GetStaticMethodID(env, cls, name, sig)
            clear()
            return m ~= nil and m or nil
        end
        local view_cls = class(VIEW)
        if view_cls == nil then return false, "android.view.View missing" end
        local helper_cls = class(HELPER)
        -- Select a complete backend; never call a static method on the decor view.
        for _i, backend in ipairs({
            { cls = view_cls, name = VIEW, static = false },
            { cls = helper_cls, name = HELPER, static = true },
        }) do
            local lookup = backend.static and static or method
            local state = lookup(backend.cls, "setScreenHandWritingPenState", "(I)V")
            local limit = lookup(backend.cls, "setScreenHandWritingRegionLimit", "(Landroid/view/View;[I)V")
            if state and limit then
                self.pen_cls, self.pen_static = backend.cls, backend.static
                self.backend = backend.name .. (backend.static and " (static)" or " (instance)")
                self.pen_state, self.region_limit = state, limit
                self.region_exclude = lookup(backend.cls, "setScreenHandWritingRegionExclude", "(Landroid/view/View;[I)V")
                break
            end
        end
        if not self.pen_state then return false, "pen state/region methods missing on View and ViewUpdateHelper" end
        -- Raw handwriting gates ordinary Android panel updates. A client must
        -- be able both to repaint that mode and to unlock normal posts on exit.
        for _i, cls in ipairs({ view_cls, helper_cls }) do
            if not self.enable_post then
                self.enable_post = static(cls, "enablePost", "(I)V")
                if self.enable_post then self.post_cls = cls end
            end
            if not self.handwriting_repaint then
                self.handwriting_repaint = static(cls, "handwritingRepaint", "(Landroid/view/View;IIII)V")
                if self.handwriting_repaint then self.repaint_cls = cls end
            end
        end
        if not (self.enable_post and self.handwriting_repaint) then
            return false, "handwriting repaint/post control missing"
        end
        -- the stroke's look, where the firmware has it
        for _i, cls in ipairs({ view_cls, helper_cls }) do
            local w = static(cls, "setStrokeWidth", "(F)V")
            if w then
                self.width_cls, self.stroke_width = cls, w
                self.stroke_color = static(cls, "setStrokeColor", "(I)V")
                self.stroke_style = static(cls, "setStrokeStyle", "(I)V")
                break
            end
        end
        -- the window's view: the pen inks where it is told, in its coordinates (the screen's)
        local activity = self.android.app.activity.clazz
        local window = jni:callObjectMethod(activity, "getWindow", "()Landroid/view/Window;")
        clear()
        if window == nil then return false, "activity window missing" end
        local decor = jni:callObjectMethod(window, "getDecorView", "()Landroid/view/View;")
        clear()
        env[0].DeleteLocalRef(env, window)
        if decor == nil then return false, "window decor view missing" end
        self.view = env[0].NewGlobalRef(env, decor)
        env[0].DeleteLocalRef(env, decor)
        self.view_cls = view_cls
        return true
    end)
    self.ok = found == true
    self.why = (not self.ok) and (why or "probe failed") or nil
    if self.log then
        if self.ok then self.log("Ink Away: Boox pen layer found:", self.backend)
        else self.log("Ink Away: Boox pen layer not found:", why or "probe failed") end
    end
    return self.ok
end

-- Call `fn(env, args)` for the layer; false (and the layer off for the session)
-- if it fails.
function BooxInk:call(fn)
    if not self.ok or self.broken then return false end
    local ok, r, why = pcall(self.withEnv, self, fn)
    if not ok or r == false then
        self.broken = true
        self:releaseScreen()
        if self.log then self.log("Ink Away: Boox pen layer off:", ok and why or r) end
        return false
    end
    self.calls = self.calls + 1
    return true
end

-- The firmware's pen calls by name, wherever Ink Away may look, whatever their
-- signature: { "ViewUpdateHelper.enablePost", ... }. For a firmware where the search
-- failed, so its report says what it has. Slow (it reads the names of every method of
-- View), so only the pen test asks, and only on a Boox.
function BooxInk:surveyMethods()
    local out = {}
    if not self.android then return out end
    pcall(self.withEnv, self, function(env, jni)
        local function clear()
            if env[0].ExceptionCheck(env) ~= 0 then env[0].ExceptionClear(env); return true end
            return false
        end
        for _i, class in ipairs({ VIEW, HELPER }) do
            local cls = env[0].FindClass(env, class)
            clear()
            if cls ~= nil then
                local arr = jni:callObjectMethod(cls, "getMethods", "()[Ljava/lang/reflect/Method;")
                if not clear() and arr ~= nil then
                    for k = 0, env[0].GetArrayLength(env, arr) - 1 do
                        local m = env[0].GetObjectArrayElement(env, arr, k)
                        if not clear() and m ~= nil then
                            local js = jni:callObjectMethod(m, "getName", "()Ljava/lang/String;")
                            if not clear() and js ~= nil then
                                local name = jni:to_string(js)
                                clear()
                                if type(name) == "string" and (name:find("HandWriting", 1, true)
                                        or name:find("andwriting", 1, true) or name:find("Scribble", 1, true)
                                        or name == "enablePost" or name:find("^setStroke")) then
                                    out[#out + 1] = class:match("[^/]+$") .. "." .. name
                                end
                                env[0].DeleteLocalRef(env, js)
                            end
                            env[0].DeleteLocalRef(env, m)
                        end
                    end
                    env[0].DeleteLocalRef(env, arr)
                end
                env[0].DeleteLocalRef(env, cls)
            end
        end
        return true
    end)
    return out
end

-- Best-effort cleanup bypassing the broken-client guard. Each call clears its
-- own Java exception so even a failed pen command cannot lock ordinary updates.
function BooxInk:releaseScreen()
    if self.enable_post then
        pcall(self.withEnv, self, function(env)
            local a = self.ffi.new("jvalue[1]"); a[0].i = 1
            env[0].CallStaticVoidMethodA(env, self.post_cls, self.enable_post, a)
            return true
        end)
    end
    if self.pen_state and self.view then
        pcall(self.withEnv, self, function(env)
            local a = self.ffi.new("jvalue[1]"); a[0].i = BooxInk.STOP
            self:invokePen(env, self.pen_state, a)
            return true
        end)
    end
end

-- Invoke a pen method using the class and calling convention chosen by probe.
function BooxInk:invokePen(env, mid, args)
    if self.pen_static then
        env[0].CallStaticVoidMethodA(env, self.pen_cls, mid, args)
    else
        env[0].CallVoidMethodA(env, self.view, mid, args)
    end
end

-- The pen layer's state: BooxInk.STOP, START, DRAWING or PAUSED.
function BooxInk:setPenState(n)
    local ffi = self.ffi
    local ok = self:call(function(env)
        local a = ffi.new("jvalue[1]")
        a[0].i = n
        if n == BooxInk.PAUSED or n == BooxInk.STOP then
            a[0].i = 1
            env[0].CallStaticVoidMethodA(env, self.post_cls, self.enable_post, a)
            if env[0].ExceptionCheck(env) ~= 0 then return false end
            a[0].i = n
        end
        self:invokePen(env, self.pen_state, a)
        return true
    end)
    if ok and n == BooxInk.DRAWING and not self.reported_active then
        self.reported_active = true
        if self.log then self.log("Ink Away: Boox pen layer enabled:", self.backend) end
    end
    return ok
end

-- Keep raw pen capture prepared while allowing ordinary Android posts. Enter
-- scribble mode only for a real contact; preparing after DOWN misses its start.
function BooxInk:setPosting(enabled)
    return self:call(function(env)
        local a = self.ffi.new("jvalue[1]")
        a[0].i = enabled and 1 or 0
        env[0].CallStaticVoidMethodA(env, self.post_cls, self.enable_post, a)
        return true
    end)
end

-- Commit the app's posted pixels while raw handwriting owns the panel. Unlike
-- refreshScreen, this is the firmware's handwriting-mode repaint (LTRB).
function BooxInk:repaint(x, y, w, h)
    local ok = self:call(function(env)
        local a = self.ffi.new("jvalue[5]")
        a[0].l = self.view
        a[1].i, a[2].i = math.floor(x), math.floor(y)
        a[3].i, a[4].i = math.ceil(x + w), math.ceil(y + h)
        env[0].CallStaticVoidMethodA(env, self.repaint_cls, self.handwriting_repaint, a)
        return true
    end)
    if ok and not self.reported_repaint then
        self.reported_repaint = true
        if self.log then self.log("Ink Away: Boox handwriting repaint active") end
    end
    return ok
end

local function intArray(env, ffi, list)
    local n = #list
    local arr = env[0].NewIntArray(env, n)
    if arr == nil then return nil end
    if n > 0 then
        local buf = ffi.new("int32_t[?]", n)
        for i = 1, n do buf[i - 1] = math.floor(list[i] + 0.5) end
        env[0].SetIntArrayRegion(env, arr, 0, n, buf)
    end
    return arr
end

local function flatten(rects)
    local out = {}
    for _i, r in ipairs(rects or {}) do
        out[#out + 1], out[#out + 2], out[#out + 3], out[#out + 4] = r.x, r.y, r.x + r.w, r.y + r.h
    end
    return out
end

-- Where the pen inks: `limit` and `exclude` are lists of screen rects { x, y, w, h }.
function BooxInk:setRegion(limit, exclude)
    local ffi = self.ffi
    return self:call(function(env)
        local function send(mid, rects)
            if not mid then return true end
            local arr = intArray(env, ffi, flatten(rects))
            if arr == nil then return false end
            local a = ffi.new("jvalue[2]")
            a[0].l = self.view
            a[1].l = arr
            self:invokePen(env, mid, a)
            env[0].DeleteLocalRef(env, arr)
            return env[0].ExceptionCheck(env) == 0
        end
        return send(self.region_limit, limit) and send(self.region_exclude, exclude or {})
    end)
end

-- The ink's look while the pen moves: its width in screen pixels, its colour
-- (0xAARRGGBB) and style (0 even, 1 following pressure). Where the firmware has
-- no such call the ink keeps its own.
function BooxInk:setStroke(width, color, style)
    if not self.stroke_width then return true end
    local ffi = self.ffi
    return self:call(function(env)
        local a = ffi.new("jvalue[1]")
        a[0].f = width
        env[0].CallStaticVoidMethodA(env, self.width_cls, self.stroke_width, a)
        if env[0].ExceptionCheck(env) ~= 0 then return false end
        if self.stroke_color then
            a[0].i = color
            env[0].CallStaticVoidMethodA(env, self.width_cls, self.stroke_color, a)
            if env[0].ExceptionCheck(env) ~= 0 then return false end
        end
        if self.stroke_style then
            a[0].i = style or 0
            env[0].CallStaticVoidMethodA(env, self.width_cls, self.stroke_style, a)
        end
        return true
    end)
end

-- Can it ink (found, and nothing has failed)?
function BooxInk:usable()
    return self.ok and not self.broken
end

return BooxInk

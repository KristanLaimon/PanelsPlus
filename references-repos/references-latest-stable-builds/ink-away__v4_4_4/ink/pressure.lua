--[[
Pen pressure from the device. KOReader keeps no pressure for plugins, so:

  * Kindle Scribe (Wacom): ink/penbridge.lua already stores ABS_PRESSURE on the
    pen's slot. Some firmwares send no pressure events at all; then the digitizer
    is asked for its current value directly (an EVIOCGABS ioctl, read-only: no
    input is taken, grabbed or injected). Approach credited in NOTICE.md.
  * Kobo styluses: KOReader reads ABS_MT_PRESSURE only to see a lift and throws
    the value away. A pass-through hook keeps it on the slot after KOReader has
    handled the event, changing nothing else.
  * The range of the values comes from the kernel (the same ioctl), so a light
    and a firm press mean the same on every device.

Android has no pressure: KOReader's Android input never reads it.
]]

local Pressure = {}

local ABS_PRESSURE, ABS_MT_PRESSURE = 0x18, 0x3a
local EV_ABS = 3
-- EVIOCGABS(abs) = _IOR('E', 0x40 + abs, struct input_absinfo), 24 bytes
local function eviocgabs(abs) return 0x80184540 + abs end

local ffi_ok, ffi = pcall(require, "ffi")
local declared = false
local function declare()
    if declared or not ffi_ok then return declared end
    declared = pcall(ffi.cdef, [[
        typedef struct { int value, minimum, maximum, fuzz, flat, resolution; } inkaway_absinfo;
        int open(const char *pathname, int flags, ...);
        int close(int fd);
        int ioctl(int fd, unsigned long request, ...);
    ]])
    return declared
end

local O_RDONLY, O_NONBLOCK = 0, 0x800

-- The input devices, as { path, name }.
local function devices()
    local ok, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok or not lfs or lfs.attributes("/sys/class/input", "mode") ~= "directory" then return {} end
    local out = {}
    for name in lfs.dir("/sys/class/input") do
        if name:match("^event%d+$") then
            local f = io.open("/sys/class/input/" .. name .. "/device/name", "r")
            local label = f and f:read("*l")
            if f then f:close() end
            out[#out + 1] = { path = "/dev/input/" .. name, name = label or "" }
        end
    end
    return out
end

-- The range of one axis on an open device, or nil.
local function axis(fd, info, abs)
    if ffi.C.ioctl(fd, eviocgabs(abs), info) ~= 0 then return nil end
    local lo, hi = info[0].minimum, info[0].maximum
    if hi <= lo then return nil end
    return lo, hi
end

-- What the device offers: the pen's pressure range { lo, hi } (the Wacom
-- digitizer's ABS_PRESSURE, else the widest ABS_MT_PRESSURE), and the path of a
-- Wacom digitizer for direct reads. Probed once; nil fields where unknown.
local probed
function Pressure.probe()
    if probed then return probed end
    probed = {}
    if not declare() then return probed end
    local info = ffi.new("inkaway_absinfo[1]")
    for _i, d in ipairs(devices()) do
        local fd = ffi.C.open(d.path, O_RDONLY + O_NONBLOCK)
        if fd >= 0 then
            local wacom = d.name:lower():find("wacom") ~= nil
            local lo, hi = axis(fd, info, ABS_PRESSURE)
            if wacom and lo then
                probed.lo, probed.hi, probed.wacom_path = lo, hi, d.path
            else
                local mlo, mhi = axis(fd, info, ABS_MT_PRESSURE)
                if mlo and not probed.wacom_path and (not probed.hi or mhi > probed.hi) then
                    probed.lo, probed.hi = mlo, mhi
                end
            end
            ffi.C.close(fd)
        end
    end
    return probed
end

-- A reader of the Wacom digitizer's current pressure, for firmwares that send
-- no pressure events: sensor:read() gives the raw value, or nil.
function Pressure.openSensor()
    local p = Pressure.probe()
    if not (p.wacom_path and declare()) then return nil end
    local fd = ffi.C.open(p.wacom_path, O_RDONLY + O_NONBLOCK)
    if fd < 0 then return nil end
    local info = ffi.new("inkaway_absinfo[1]")
    local sensor = {}
    function sensor:read()
        if fd < 0 or ffi.C.ioctl(fd, eviocgabs(ABS_PRESSURE), info) ~= 0 then return nil end
        return info[0].value
    end
    function sensor:close()
        if fd >= 0 then ffi.C.close(fd); fd = -1 end
    end
    return sensor
end

-- Keep ABS_MT_PRESSURE on the slot it belongs to (Kobo). Wraps the Input
-- instance's handleTouchEv: KOReader handles every event first, untouched, and
-- only then is the value copied onto the current slot. Returns a handle for
-- Pressure.uninstall, or nil.
function Pressure.install(input)
    if not (input and type(input.handleTouchEv) == "function") then return nil end
    local orig = input.handleTouchEv
    local h = { input = input, own = rawget(input, "handleTouchEv") }
    h.wrapper = function(this, ev)
        local r = orig(this, ev)
        if ev.type == EV_ABS and ev.code == ABS_MT_PRESSURE and h.active then
            local slots = this.ev_slots
            local s = slots and slots[this.cur_slot]
            if s then s.pressure = ev.value end
        end
        return r
    end
    h.active = true
    input.handleTouchEv = h.wrapper
    return h
end

function Pressure.uninstall(h)
    if not h then return end
    h.active = false   -- left in a chain by someone else: now transparent
    if rawget(h.input, "handleTouchEv") == h.wrapper then h.input.handleTouchEv = h.own end
end

return Pressure

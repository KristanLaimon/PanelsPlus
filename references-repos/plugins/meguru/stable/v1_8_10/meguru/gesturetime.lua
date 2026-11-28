-- The clock touch gestures are stamped with, so their times stay comparable.

local C = require("ffi").C
local Device = require("device")
local time = require("ui/time")

local GestureTime = {}

-- nil when the detector could not name the clock: then no comparison is safe.
function GestureTime.clockId()
    local input = Device.input
    local detector = input and input.gesture_detector
    if not detector or type(detector.getClockSource) ~= "function" then
        return nil
    end
    local ok, id = pcall(detector.getClockSource, detector)
    if not ok or not id or id == -1 then
        return nil
    end
    return id
end

-- Paint stamps must come from the gesture clock, not from time.now().
function GestureTime.now(id)
    if not id then
        return nil
    end
    if id == C.CLOCK_REALTIME then
        return time.realtime_coarse()
    end
    if C.CLOCK_BOOTTIME and id == C.CLOCK_BOOTTIME
            and type(time.boottime) == "function" then
        return time.boottime()
    end
    return time.monotonic_coarse()
end

-- A stamp from another clock says nothing about a gesture's own time.
function GestureTime.predates(gesture_time, painted_at, clock_id, stamp_id)
    if not (gesture_time and painted_at and clock_id
            and clock_id == stamp_id) then
        return false
    end
    return gesture_time < painted_at
end

return GestureTime

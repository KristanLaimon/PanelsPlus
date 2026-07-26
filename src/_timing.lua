local logger = require("logger")
local time = require("ui/time")

--- Opt-in timing instrumentation for the panel pipeline.
---
--- Panel detection and panel rendering costs are dominated by device-side work
--- that cannot be measured from a desktop build, so the plugin needs a way to
--- report real timings from the e-reader itself. Spans are no-ops (and allocate
--- nothing beyond a shared closure) unless `Timing.enabled` is set from the
--- `debug_timing` setting.
---
--- @class PPTimingModule
--- @field enabled boolean Whether spans log their duration.
local Timing = {
    enabled = false,
}

--- Shared no-op returned while instrumentation is disabled.
local function noop() end

--- Start a named span.
---
--- @param name string Span label written to the log.
--- @return fun(detail:any|nil) stop Call to log the elapsed milliseconds.
function Timing.span(name)
    if not Timing.enabled then
        return noop
    end

    local start = time.now()
    return function(detail)
        local elapsed = time.to_ms(time.since(start))
        if detail ~= nil then
            logger.info(string.format("[Panels+] %s %dms (%s)", name, elapsed, tostring(detail)))
        else
            logger.info(string.format("[Panels+] %s %dms", name, elapsed))
        end
    end
end

--- Log a one-off message through the same prefix as spans.
---
--- @param message string Message body.
function Timing.log(message)
    if not Timing.enabled then
        return
    end
    logger.info("[Panels+] " .. message)
end

return Timing

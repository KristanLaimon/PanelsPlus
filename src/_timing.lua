local logger = require("logger")
local time = require("ui/time")
local util = require("util")

--- Opt-in timing instrumentation for the panel pipeline.
---
--- Panel detection and panel rendering costs are dominated by device-side work
--- that cannot be measured from a desktop build, so the plugin needs a way to
--- report real timings from the e-reader itself. Spans are no-ops (and allocate
--- nothing beyond a shared closure) unless `Timing.enabled` is set from the
--- `debug_mode` setting.
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
--- Accepts an optional `string.format` argument list. Formatting is deferred
--- until after the enabled check, so hot paths (gesture dispatch, panel
--- transitions) that always pass a format call don't pay for it when logging
--- is off, matching the "allocate nothing beyond a shared closure" contract
--- spans already have.
---
--- @param fmt string Message body, or a `string.format` pattern.
--- @param ... any Optional `string.format` arguments.
function Timing.log(fmt, ...)
    if not Timing.enabled then
        return
    end
    local message = select("#", ...) > 0 and string.format(fmt, ...) or fmt
    logger.info("[Panels+] " .. message)
end

--- Read current free system memory, in whole megabytes.
---
--- `util.calcFreeMem()` is Linux-only (parses `/proc/meminfo`) and reports
--- bytes already discounted to 85% of MemAvailable. This is the only figure
--- available from Lua that tracks the OOM killer's own view of headroom, which
--- matters because a SIGKILL from the kernel leaves no Lua traceback behind:
--- a memory trend logged in the run-up is the only postmortem evidence left.
---
--- @return integer|nil free_mb Free memory in MB, or nil off Linux.
function Timing.freeMB()
    local ok, free_bytes = pcall(util.calcFreeMem)
    if not ok or not free_bytes then
        return nil
    end
    return math.floor(free_bytes / (1024 * 1024))
end

--- Log a one-off message annotated with current free memory and Lua heap size.
---
--- Intended for points that precede known OOM-risk work (large caches, batch
--- renders, rapid re-detection) so a crash log shows the memory trend leading
--- up to a kill, not just the last timing span that happened to run.
---
--- Accepts an optional `string.format` argument list, deferred the same way
--- `Timing.log` defers it.
---
--- @param fmt string Message body, or a `string.format` pattern.
--- @param ... any Optional `string.format` arguments.
function Timing.memory(fmt, ...)
    if not Timing.enabled then
        return
    end
    local label = select("#", ...) > 0 and string.format(fmt, ...) or fmt
    local free_mb = Timing.freeMB()
    logger.info(string.format(
        "[Panels+] memory %s free=%s lua=%dKB",
        label,
        free_mb and (free_mb .. "MB") or "?",
        math.floor(collectgarbage("count"))
    ))
end

return Timing

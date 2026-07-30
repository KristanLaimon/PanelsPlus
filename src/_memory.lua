local util = require("util")

--- Shared free-memory headroom check.
---
--- `util.calcFreeMem()` is Linux-only (parses `/proc/meminfo`) and reports
--- bytes already discounted to ~85% of `MemAvailable`. Every caller that
--- gates work on available memory needs to agree on what happens when that
--- figure isn't available at all (non-Linux platforms, or the read failing)
--- -- always assume there is headroom rather than blocking work outright,
--- since the alternative is a false positive that disables a whole feature
--- on platforms this check can't actually see.
---
--- @class PPMemoryModule
local Memory = {}

--- @return integer|nil free_bytes Free bytes, or nil when unavailable.
function Memory.freeBytes()
    local ok, free_bytes = pcall(util.calcFreeMem)
    if not ok or not free_bytes then
        return nil
    end
    return free_bytes
end

--- @param min_bytes integer Minimum free bytes required.
--- @return boolean allowed `true` when unavailable (assume headroom) or free_bytes >= min_bytes.
function Memory.hasHeadroom(min_bytes)
    local free_bytes = Memory.freeBytes()
    return not free_bytes or free_bytes >= min_bytes
end

return Memory

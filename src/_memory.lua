--[[
Panels+
File: src/_memory.lua
Name: Memory
Description: Calculates free-memory headroom and guards large plugin allocations.
Author: KristanLaimon
Year: 2026
Copyright (c) 2026 KristanLaimon
License: MIT; see the repository LICENSE file.
SPDX-License-Identifier: MIT
]]
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

--- Return whether there is room for both a safety floor and a known upcoming
--- allocation. `calcFreeMem()` is sampled before the allocation, so checking
--- only a fixed floor lets one large comic page consume the entire remainder
--- on low-memory devices.
---
--- @param min_bytes integer Memory that must remain free after the work.
--- @param allocation_bytes integer|nil Conservative temporary-allocation estimate.
--- @return boolean allowed `true` when free memory is unavailable, otherwise enough for both.
function Memory.hasAllocationHeadroom(min_bytes, allocation_bytes)
    local free_bytes = Memory.freeBytes()
    return not free_bytes or free_bytes >= min_bytes + math.max(0, allocation_bytes or 0)
end

return Memory

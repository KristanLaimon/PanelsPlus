--[[
Panels+
File: tests/spec/memory_spec.lua
Name: Memory specs
Description: Verifies allocation headroom and low-memory prefetch policy.
Author: KristanLaimon
Year: 2026
Copyright (c) 2026 KristanLaimon
License: MIT; see the repository LICENSE file.
SPDX-License-Identifier: MIT
]]
local framework = require("tests.PanelsPlusTestFramework")
local describe, it, assert = framework.describe, framework.it, framework.assert

local Memory = require("src._memory")

describe("Memory allocation reservation", function()
    it("requires the safety floor and the next allocation to fit together", function()
        local original_free_bytes = Memory.freeBytes
        Memory.freeBytes = function()
            return 150
        end

        assert.is_false(Memory.hasAllocationHeadroom(100, 51))
        assert.is_true(Memory.hasAllocationHeadroom(100, 50))

        Memory.freeBytes = original_free_bytes
    end)

    it("allows next-page prefetch on low memory when detector is not exact", function()
        local Cache = require("src.cache")
        local original_has_headroom = Memory.hasHeadroom
        local checked_min = nil
        Memory.hasHeadroom = function(min)
            checked_min = min
            return true
        end

        local scheduled = false
        local mock_ui_mgr = package.loaded["ui/uimanager"]
        local original_schedule = mock_ui_mgr.scheduleIn
        mock_ui_mgr.scheduleIn = function(_, _, _)
            scheduled = true
        end

        local instance = {
            settings = {
                detector = "auto",
                native_detect_min_free_bytes = 100 * 1024 * 1024,
                prefetch_min_free_bytes = 15 * 1024 * 1024,
            },
            panel_prefetch_actions = {},
            panel_cache = {},
            getDetector = function()
                return "auto"
            end,
            getPanelCacheKey = function(_, p)
                return tostring(p)
            end,
            getCachedPanels = function()
                return nil
            end,
        }
        for k, v in pairs(Cache) do
            instance[k] = v
        end

        instance:preloadPanels(2)
        assert.equals(15 * 1024 * 1024, checked_min)
        assert.is_true(scheduled)

        instance.getDetector = function()
            return "exact"
        end
        instance:preloadPanels(3)
        assert.equals(100 * 1024 * 1024, checked_min)

        Memory.hasHeadroom = original_has_headroom
        mock_ui_mgr.scheduleIn = original_schedule
    end)
end)

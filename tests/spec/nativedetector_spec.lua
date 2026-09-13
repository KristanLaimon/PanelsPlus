--[[
Panels+
File: tests/spec/nativedetector_spec.lua
Name: NativeDetector specs
Description: Verifies native fallback memory guards and embedded-image KOPT adaptation.
Author: KristanLaimon
Year: 2026
Copyright (c) 2026 KristanLaimon
License: MIT; see the repository LICENSE file.
SPDX-License-Identifier: MIT
]]
--- Native detector safety checks that do not require KOReader's LuaJIT FFI.
local framework = require("tests.PanelsPlusTestFramework")
local describe, it, assert = framework.describe, framework.it, framework.assert

local Memory = require("src._memory")
local NativeDetector = require("src._nativedetector")

describe("NativeDetector embedded-image path", function()
    it("does not allocate a KOPT bitmap when the native memory guard rejects it", function()
        local original_has_headroom = Memory.hasHeadroom
        Memory.hasHeadroom = function()
            return false
        end

        local panels = NativeDetector.collectFromBlitbuffer({ w = 1200, h = 1800 }, {
            native_detect_min_free_bytes = 1,
        })

        Memory.hasHeadroom = original_has_headroom
        assert.equals(0, #panels)
    end)

    it("rejects Deep before loading KOPT when its estimated working set does not fit", function()
        local original_has_allocation_headroom = Memory.hasAllocationHeadroom
        Memory.hasAllocationHeadroom = function()
            return false
        end

        local panels = NativeDetector.collectFromBlitbuffer({ w = 1200, h = 1800 }, {
            native_detect_min_free_bytes = 1,
        })

        Memory.hasAllocationHeadroom = original_has_allocation_headroom
        assert.equals(0, #panels)
    end)

    it("adapts an extracted bitmap into the shared KOPT probe routine", function()
        local original_has_headroom = Memory.hasHeadroom
        local original_has_allocation_headroom = Memory.hasAllocationHeadroom
        local original_kopt = package.loaded["ffi/koptcontext"]
        local original_blitbuffer = package.loaded["ffi/blitbuffer"]
        local original_ffi = package.loaded.ffi
        local copied_rows, freed_context, freed_greyscale = 0, false, false
        local pointer = setmetatable({}, {
            __add = function(self)
                return self
            end,
        })

        Memory.hasHeadroom = function()
            return true
        end
        Memory.hasAllocationHeadroom = function()
            return true
        end
        package.loaded.ffi = {
            copy = function()
                copied_rows = copied_rows + 1
            end,
        }
        package.loaded["ffi/blitbuffer"] = {
            TYPE_BB8 = 1,
            new = function(width, height)
                return {
                    w = width,
                    h = height,
                    stride = width,
                    data = pointer,
                    blitFrom = function() end,
                    free = function()
                        freed_greyscale = true
                    end,
                }
            end,
        }
        package.loaded["ffi/koptcontext"] = {
            k2pdfopt = {
                bmp_alloc = function(source)
                    source.data = pointer
                end,
                bmp_bytewidth = function(source)
                    return source.width
                end,
            },
            new = function()
                return {
                    src = { red = {}, green = {}, blue = {} },
                    getPanelFromPage = function(_, _)
                        return { x = 0, y = 0, w = 120, h = 180 }
                    end,
                    free = function()
                        freed_context = true
                    end,
                }
            end,
        }

        local panels = NativeDetector.collectFromBlitbuffer({ w = 120, h = 180 }, {
            mode = "comic",
            panel_grid_cols = 2,
            panel_grid_rows = 2,
            native_detect_min_free_bytes = 1,
        })

        Memory.hasHeadroom = original_has_headroom
        Memory.hasAllocationHeadroom = original_has_allocation_headroom
        package.loaded["ffi/koptcontext"] = original_kopt
        package.loaded["ffi/blitbuffer"] = original_blitbuffer
        package.loaded.ffi = original_ffi

        assert.equals(1, #panels)
        assert.equals(180, copied_rows)
        assert.is_true(freed_context)
        assert.is_true(freed_greyscale)
    end)
end)

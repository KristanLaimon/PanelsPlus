--[[
Panels+
File: tests/spec/pagebitmap_spec.lua
Name: PageBitmap specs
Description: Verifies background estimation, color classification, resampling, and memory fallback.
Author: KristanLaimon
Year: 2026
Copyright (c) 2026 KristanLaimon
License: MIT; see the repository LICENSE file.
SPDX-License-Identifier: MIT
]]
--- Specs for colour-aware background sampling in `src/_pagebitmap.lua`.
---
--- These stay render-free: they exercise the same RGB measurements used by the
--- page-map builder without needing a document or a real blitbuffer.

local framework = require("tests.PanelsPlusTestFramework")
local describe, it, assert = framework.describe, framework.it, framework.assert

local PageBitmap = require("src._pagebitmap")

describe("PageBitmap colour-aware background sampling", function()
    it("detects the same manga panels before and after conversion trims the paper margin", function()
        local Blitbuffer = require("ffi/blitbuffer")
        local ComponentDetector = require("src._componentdetector")
        local settings = { mode = "manga", segment_target_width = 480 }
        local function image(margin)
            return {
                w = 100 + margin * 2,
                h = 140 + margin * 2,
                isRGB = function()
                    return true
                end,
                getType = function()
                    return Blitbuffer.TYPE_BBRGB24
                end,
                getRotation = function()
                    return 0
                end,
                getInverse = function()
                    return 0
                end,
                getPixel = function(_, x, y)
                    x, y = x - margin, y - margin
                    local paper = x < 0 or y < 0 or x >= 100 or y >= 140 or (x >= 46 and x < 54) or (y >= 66 and y < 74)
                    local value = paper and 255 or 110
                    return {
                        getColorRGB24 = function()
                            return { r = value, g = value, b = value }
                        end,
                    }
                end,
                free = function()
                    error("detection must retain the source for panel crops")
                end,
            }
        end

        local padded = PageBitmap.buildFromBlitbuffer(image(10), settings)
        local trimmed = PageBitmap.buildFromBlitbuffer(image(0), settings)
        assert.equals(255, padded.background)
        assert.equals(255, trimmed.background)
        local original_panels = ComponentDetector.detectPage(padded, settings)
        local converted_panels = ComponentDetector.detectPage(trimmed, settings)
        assert.equals(4, #original_panels)
        assert.equals(4, #converted_panels)
        -- Compare centres: the detector's one-cell bleed is clipped at the
        -- trimmed image edge, but panel locations and manga order must agree.
        for i, panel in ipairs(original_panels) do
            local converted = converted_panels[i]
            assert.near(panel.x + panel.w / 2 - 10, converted.x + converted.w / 2, 1)
            assert.near(panel.y + panel.h / 2 - 10, converted.y + converted.h / 2, 1)
        end
    end)

    it("normalizes extracted-image detection to the fixed-page target raster", function()
        local width, height = PageBitmap._detectionRasterSize(1600, 2400, 480)
        assert.equals(480, width)
        assert.equals(720, height)

        -- Fixed-page rendering does not enlarge smaller source pages, and
        -- embedded images must retain that same behaviour.
        width, height = PageBitmap._detectionRasterSize(400, 600, 480)
        assert.equals(400, width)
        assert.equals(600, height)

        -- Keep an extracted vertical strip bounded too: it must never create
        -- an unbounded map merely because its width is already small.
        width, height = PageBitmap._detectionRasterSize(400, 2400, 480)
        assert.equals(160, width)
        assert.equals(960, height)
    end)

    it("estimates a conservative temporary resize working set", function()
        local bytes = PageBitmap._embeddedResizeWorkingSetBytes(1600, 2400, 480, 720)
        assert.equals(1600 * 2400 * 4 + 480 * 720 * 8 + 4 * 1024 * 1024, bytes)
    end)

    it("skips a resize when its allocation would breach the memory floor", function()
        local Memory = require("src._memory")
        local original_check = Memory.hasAllocationHeadroom
        local requested_floor, requested_bytes
        Memory.hasAllocationHeadroom = function(floor, bytes)
            requested_floor, requested_bytes = floor, bytes
            return false
        end

        assert.is_false(PageBitmap._hasEmbeddedResizeHeadroom(1600, 2400, 480, 720))
        assert.equals(15 * 1024 * 1024, requested_floor)
        assert.equals(PageBitmap._embeddedResizeWorkingSetBytes(1600, 2400, 480, 720), requested_bytes)

        Memory.hasAllocationHeadroom = original_check
    end)

    it("computes bounded sparse sampling step for low-memory fallback", function()
        -- Normal aspect ratio
        assert.equals(3, PageBitmap._embeddedSparseStep(1600, 2400, 480))
        -- Small image
        assert.equals(1, PageBitmap._embeddedSparseStep(400, 600, 480))
        -- Tall reflow image: caps step so height does not exceed target_width * 2
        assert.equals(3, PageBitmap._embeddedSparseStep(400, 2400, 480))
    end)

    it("skips copy and returns original bb when image already fits within bounds", function()
        local bb = { w = 400, h = 600 }
        local raster, owned, resampled = PageBitmap._makeEmbeddedDetectionRaster(bb, 480)
        assert.equals(bb, raster)
        assert.is_nil(owned)
        assert.is_false(resampled)
    end)

    it("resizes when memory headroom is available and marks raster as owned", function()
        local Memory = require("src._memory")
        local RenderImage = require("ui/renderimage")
        local original_check = Memory.hasAllocationHeadroom
        local original_scale = RenderImage.scaleBlitBuffer
        Memory.hasAllocationHeadroom = function()
            return true
        end

        local fake_copy = { w = 1600, h = 2400 }
        local copied = false
        local fake_bb = {
            w = 1600,
            h = 2400,
            copy = function()
                copied = true
                return fake_copy
            end,
        }
        local fake_raster = { w = 480, h = 720 }
        RenderImage.scaleBlitBuffer = function(self, bb_arg, w, h, free_orig)
            assert.equals(fake_copy, bb_arg)
            assert.equals(480, w)
            assert.equals(720, h)
            assert.is_true(free_orig)
            return fake_raster
        end

        local raster, owned, resampled = PageBitmap._makeEmbeddedDetectionRaster(fake_bb, 480)
        assert.is_true(copied)
        assert.equals(fake_raster, raster)
        assert.equals(fake_raster, owned)
        assert.is_true(resampled)

        Memory.hasAllocationHeadroom = original_check
        RenderImage.scaleBlitBuffer = original_scale
    end)

    it("falls back to bounded sparse sampling and frees copy when resize throws error", function()
        local Memory = require("src._memory")
        local RenderImage = require("ui/renderimage")
        local original_check = Memory.hasAllocationHeadroom
        local original_scale = RenderImage.scaleBlitBuffer
        Memory.hasAllocationHeadroom = function()
            return true
        end

        local freed = false
        local fake_copy = {
            w = 1600,
            h = 2400,
            free = function()
                freed = true
            end,
        }
        local fake_bb = {
            w = 1600,
            h = 2400,
            copy = function()
                return fake_copy
            end,
        }
        RenderImage.scaleBlitBuffer = function()
            error("simulated scaling failure")
        end

        local raster, owned, resampled = PageBitmap._makeEmbeddedDetectionRaster(fake_bb, 480)
        assert.equals(fake_bb, raster)
        assert.is_nil(owned)
        assert.is_false(resampled)
        assert.is_true(freed, "intermediate copy must be freed if scaling fails")

        Memory.hasAllocationHeadroom = original_check
        RenderImage.scaleBlitBuffer = original_scale
    end)

    it("uses the border's solid RGB colour as the background", function()
        local background = { r = 145, g = 120, b = 0 }
        local panel = { r = 0, g = 170, b = 75 }
        local function sample(x, y)
            if x == 0 or y == 0 or x == 5 or y == 5 then
                return background.r, background.g, background.b
            end
            return panel.r, panel.g, panel.b
        end

        local r, g, b = PageBitmap._estimateBackground(sample, 6, 6)
        assert.equals(background.r, r)
        assert.equals(background.g, g)
        assert.equals(background.b, b)
    end)

    it("uses white gutters as paper after manga conversion trims the margins", function()
        local function sample(_, y)
            if y == 50 then
                return 255, 255, 255
            end
            return 110, 110, 110
        end

        local r, g, b = PageBitmap._estimateBackground(sample, 100, 100)
        assert.equals(255, r)
        assert.equals(255, g)
        assert.equals(255, b)
    end)

    it("keeps grayscale and RGB separator decisions equivalent at the 80% boundary", function()
        for _, vertical in ipairs({ false, true }) do
            for _, white_count in ipairs({ 0, 79, 80, 81, 100 }) do
                -- Include stride padding and sparse sampling in the byte path.
                local stride, step, data = 208, 2, {}
                local function sample(x, y)
                    local gx, gy = x / step, y / step
                    local white = vertical and gx == 50 and gy >= 100 - white_count
                        or not vertical and gy == 50 and gx >= 100 - white_count
                    local value = white and 255 or 110
                    return value, value, value
                end
                for y = 0, 99 do
                    for x = 0, 99 do
                        data[y * step * stride + x * step] = sample(x * step, y * step)
                    end
                end
                local expected = white_count >= 80 and 255 or 110
                assert.equals(expected, PageBitmap._estimateBackground(sample, 200, 200, step))
                assert.equals(expected, PageBitmap._estimateBackgroundGrey(data, stride, 200, 200, step))
            end
        end
    end)

    it("preserves near-black paper even when white panel interiors span the page", function()
        for _, background in ipairs({ 0, 16, 31 }) do
            local data = {}
            local function sample(_, y)
                local value = y == 50 and 255 or background
                return value, value, value
            end
            for y = 0, 99 do
                for x = 0, 99 do
                    data[y * 100 + x] = sample(x, y)
                end
            end
            assert.equals(background, PageBitmap._estimateBackground(sample, 100, 100))
            assert.equals(background, PageBitmap._estimateBackgroundGrey(data, 100, 100, 100))
        end
    end)

    it("keeps a same-luminance coloured panel distinct from its background", function()
        -- These colours differ by only five luminance levels, so the old
        -- greyscale-only map treated the panel and backdrop as the same area.
        local background = { r = 145, g = 120, b = 0 }
        local panel = { r = 0, g = 170, b = 75 }

        assert.near(
            PageBitmap._luminance(background.r, background.g, background.b),
            PageBitmap._luminance(panel.r, panel.g, panel.b),
            5
        )
        assert.is_true(
            PageBitmap._colourDistance(panel.r, panel.g, panel.b, background.r, background.g, background.b) > 40
        )
    end)

    it("keeps greyscale threshold behaviour unchanged", function()
        assert.equals(42, PageBitmap._colourDistance(42, 42, 42, 0, 0, 0))
    end)

    it("does not block documents without configurable table", function()
        assert.is_nil(PageBitmap.getBlockReason({}))
        assert.is_nil(PageBitmap.getBlockReason({ configurable = { text_wrap = 0 } }))
        assert.equals("reflow mode", PageBitmap.getBlockReason({ configurable = { text_wrap = 1 } }))
        local mock_kopt = {
            is_optimizing_page = function()
                return true
            end,
        }
        assert.equals(
            "page optimization enabled",
            PageBitmap.getBlockReason({ configurable = { text_wrap = 0 }, koptinterface = mock_kopt })
        )
    end)
end)

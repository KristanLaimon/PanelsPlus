--[[
Panels+
File: tests/spec/componentdetector_spec.lua
Name: ComponentDetector specs
Description: Verifies connected-component extraction, frame heuristics, fallback, and scratch reuse.
Author: KristanLaimon
Year: 2026
Copyright (c) 2026 KristanLaimon
License: MIT; see the repository LICENSE file.
SPDX-License-Identifier: MIT
]]
local framework = require("tests.PanelsPlusTestFramework")
local describe, it, assert = framework.describe, framework.it, framework.assert
local Detector = require("src._componentdetector")

local function page()
    local map = { w = 480, h = 640, native_w = 960, native_h = 1280, scale_x = 2, scale_y = 2, ink = 0, data = {} }
    for index = 0, map.w * map.h - 1 do
        map.data[index] = 0
    end
    return map
end

local function ink(map, x, y)
    local index = y * map.w + x
    if map.data[index] == 0 then
        map.data[index] = 1
        map.ink = map.ink + 1
    end
end

local function frame(map, x, y, w, h, slope)
    for dy = 0, h - 1 do
        local left = x + math.floor(dy * (slope or 0))
        for dx = 0, w - 1 do
            if dy == 0 or dy == h - 1 or dx == 0 or dx == w - 1 then
                ink(map, left + dx, y + dy)
            end
        end
    end
end

describe("Experimental component detector", function()
    it("preserves thin frames around empty artwork", function()
        local map = page()
        frame(map, 20, 20, 440, 600)
        local original_ink = map.ink
        local panels = Detector.detectPage(map, { mode = "manga" })
        assert.equals(1, #panels)
        assert.equals(38, panels[1].x)
        assert.equals(884, panels[1].w)
        assert.equals(original_ink, map.ink)
        local count = 0
        for index = 0, map.w * map.h - 1 do
            count = count + map.data[index]
        end
        assert.equals(original_ink, count, "Component traversal must not consume the source ink map")
    end)

    it("separates tilted adjacent frames using diagonal connectivity", function()
        local map = page()
        frame(map, 20, 20, 200, 300, 0.06)
        frame(map, 250, 20, 200, 300, 0.06)
        frame(map, 20, 360, 440, 260)
        local panels = Detector.detectPage(map, { mode = "manga" })
        assert.equals(3, #panels)
        assert.equals(498, panels[1].x)
        assert.equals(38, panels[2].x)
        assert.equals(718, panels[3].y)
    end)

    it("filters contained regions without treating partial overlap as containment", function()
        local map = page()
        frame(map, 20, 20, 440, 600)
        frame(map, 100, 100, 150, 150)
        assert.equals(1, #Detector.segment(map))

        -- These slanted neighboring frames have overlapping bounding boxes
        -- but their strokes remain disjoint throughout their height.
        map = page()
        frame(map, 10, 20, 200, 300, 0.12)
        frame(map, 215, 20, 200, 300, 0.12)
        assert.equals(2, #Detector.segment(map))
    end)

    it("keeps framed letterboxes while rejecting small unframed marks", function()
        local map = page()
        frame(map, 20, 20, 440, 440)
        frame(map, 20, 500, 440, 42)
        for x = 120, 319 do
            local y = 570 + math.floor((x - 120) / 5)
            ink(map, x, y)
            ink(map, x, y + 1)
        end
        local panels = Detector.segment(map)
        assert.equals(2, #panels)
        assert.equals(88, panels[2].h)
    end)

    it("clips padded boxes at native page edges", function()
        local map = page()
        frame(map, 0, 0, 480, 640)
        local panels = Detector.detectPage(map)
        assert.equals(1, #panels)
        assert.equals(0, panels[1].x)
        assert.equals(0, panels[1].y)
        assert.equals(960, panels[1].w)
        assert.equals(1280, panels[1].h)
    end)

    it("does not connect opposite page edges through adjacent row offsets", function()
        local map = page()
        frame(map, 0, 0, 40, 640)
        frame(map, 440, 0, 40, 640)
        local panels = Detector.segment(map)
        assert.equals(2, #panels)
        assert.equals(0, panels[1].x)
        assert.equals(82, panels[1].w)
        assert.equals(878, panels[2].x)
        assert.equals(82, panels[2].w)
        assert.equals(1280, panels[1].h)
        assert.equals(1280, panels[2].h)
    end)

    it("uses the full page when sparse title artwork fails coverage", function()
        local map = page()
        frame(map, 300, 10, 60, 100)
        frame(map, 365, 120, 60, 100)
        local panels, accepted = Detector.detectPage(map)
        assert.is_false(accepted)
        assert.equals(1, #panels)
        assert.equals(1280, panels[1].h)
    end)

    it("falls back on blank pages and excessive component counts", function()
        local map = page()
        local panels, accepted = Detector.detectPage(map)
        assert.is_false(accepted)
        assert.equals(1, #panels)
        frame(map, 20, 20, 200, 300)
        frame(map, 250, 20, 200, 300)
        panels, accepted = Detector.detectPage(map, { segment_max_panels = 1 })
        assert.is_false(accepted)
        assert.equals(960, panels[1].w)
    end)

    it("reuses scratch buffers across detections and cleans up on clearScratch", function()
        local map = page()
        frame(map, 20, 20, 440, 600)
        local panels1 = Detector.detectPage(map, { mode = "manga" })
        assert.equals(1, #panels1)

        -- Subsequent detection reuses scratch buffers
        local panels2 = Detector.detectPage(map, { mode = "manga" })
        assert.equals(1, #panels2)
        assert.equals(panels1[1].x, panels2[1].x)

        -- Clean up clears references cleanly
        Detector.clearScratch()

        -- Next detection seamlessly reinitializes scratch
        local panels3 = Detector.detectPage(map, { mode = "manga" })
        assert.equals(1, #panels3)
        assert.equals(panels1[1].x, panels3[1].x)
        Detector.clearScratch()
    end)
end)

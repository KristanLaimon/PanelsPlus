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
local Detector = require("src._smartcomponentdetector")

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
    it("keeps Safe independent of Smart refinements and applies its own coverage guard", function()
        local Safe = require("src._safecomponentdetector")
        local old_detect = Detector.detectPage
        local ok, err = pcall(function()
            Detector.detectPage = function()
                error("Safe must not invoke Smart")
            end
            local map = page()
            frame(map, 20, 20, 200, 600)
            frame(map, 250, 20, 200, 600)
            local panels, accepted = Safe.detectPage(map, { mode = "manga" })
            assert.is_true(accepted)
            assert.equals(2, #panels)
            assert.equals(498, panels[1].x)
            assert.equals(404, panels[1].w)
            local blank, blank_ok = Safe.detectPage(page(), { mode = "manga" })
            assert.is_false(blank_ok)
            assert.equals(1, #blank)
            assert.equals(960, blank[1].w)
        end)
        Detector.detectPage = old_detect
        assert.is_true(ok, tostring(err))
    end)

    it("keeps a survivor when overlapping candidates have conflicting size and frame evidence", function()
        local Segmenter = require("src._segmenter")
        local old_segment, old_accept = Detector.segment, Segmenter.accept
        local large = { x = 0, y = 0, w = 400, h = 600, frame_sides = 1 }
        local small = { x = 0, y = 0, w = 200, h = 400, frame_sides = 4 }
        local ok, err = pcall(function()
            Segmenter.accept = function()
                return true
            end
            for _, candidates in ipairs({ { large, small }, { small, large } }) do
                Detector.segment = function()
                    return candidates
                end
                local panels = Detector.detectPage({ native_w = 1000, native_h = 800 }, { mode = "manga" })
                assert.equals(1, #panels)
                assert.equals(small, panels[1])
            end
        end)
        Detector.segment, Segmenter.accept = old_segment, old_accept
        assert.is_true(ok, tostring(err))
    end)

    it("groups detached footnote letters while ignoring a narrow page number", function()
        local map = page()
        frame(map, 20, 20, 210, 520)
        frame(map, 250, 20, 210, 520)
        for x = 30, 240, 12 do
            for dx = 0, 5 do
                for y = 580, 590 do
                    ink(map, x + dx, y)
                end
            end
        end
        for x = 235, 242 do
            for y = 620, 630 do
                ink(map, x, y)
            end
        end
        local panels = Detector.detectPage(map, { mode = "manga" })
        assert.equals(3, #panels)
        assert.equals(1160, panels[3].y)
        assert.is_true(panels[3].w > 400)
        assert.equals(2, #Detector.detectPage(map, { mode = "comic" }), "Comic credits must not become extra panels")
    end)

    it("joins only the panels sharing a balloon and leaves the remaining frame separate", function()
        local map = page()
        for y = 0, map.h - 1 do
            for x = 0, map.w - 1 do
                if ((x - 210) / 65) ^ 2 + ((y - 150) / 35) ^ 2 > 1 then
                    ink(map, x, y)
                end
            end
        end
        local old_segment = Detector.segment
        local ok, err = pcall(function()
            Detector.segment = function()
                return {
                    { x = 0, y = 0, w = 400, h = 600, frame_sides = 4 },
                    { x = 440, y = 0, w = 400, h = 600, frame_sides = 4 },
                    { x = 0, y = 700, w = 800, h = 500, frame_sides = 4 },
                }
            end
            local panels = Detector.detectPage(map, { mode = "manga" })
            assert.equals(2, #panels)
            assert.equals(840, panels[1].w)
            assert.equals(700, panels[2].y)
        end)
        Detector.segment = old_segment
        assert.is_true(ok, tostring(err))
    end)

    it("retains the larger equally framed overlap regardless of component iteration order", function()
        local Segmenter = require("src._segmenter")
        local old_segment, old_accept = Detector.segment, Segmenter.accept
        local larger = { x = 0, y = 0, w = 400, h = 600, frame_sides = 3 }
        local smaller = { x = 0, y = 200, w = 400, h = 400, frame_sides = 3 }
        local separate = { x = 500, y = 0, w = 400, h = 600, frame_sides = 3 }
        Segmenter.accept = function()
            return true
        end
        local results = {}
        for _, candidates in ipairs({ { smaller, larger, separate }, { larger, smaller, separate } }) do
            Detector.segment = function()
                return candidates
            end
            results[#results + 1] = Detector.detectPage({ native_w = 1000, native_h = 800 }, { mode = "comic" })
        end
        Detector.segment, Segmenter.accept = old_segment, old_accept
        for _, panels in ipairs(results) do
            assert.equals(2, #panels)
            assert.equals(larger, panels[1])
            assert.equals(separate, panels[2])
        end
    end)

    it("preserves thin frames around empty artwork", function()
        local map = page()
        frame(map, 20, 20, 440, 600)
        local original_ink = map.ink
        local panels = Detector.detectPage(map, { mode = "manga" })
        assert.equals(1, #panels)
        assert.equals(40, panels[1].x)
        assert.equals(880, panels[1].w)
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
        assert.equals(500, panels[1].x)
        assert.equals(40, panels[2].x)
        assert.equals(720, panels[3].y)
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
        assert.equals(84, panels[2].h)
    end)

    it("retains compact closed frames below the ordinary artwork size floor", function()
        local map = page()
        frame(map, 20, 20, 440, 520)
        frame(map, 20, 590, 38, 24)
        frame(map, 70, 590, 38, 24)
        local panels = Detector.segment(map)
        assert.equals(3, #panels)
        assert.equals(76, panels[2].w)
        assert.equals(48, panels[2].h)
    end)

    it("keeps native bounds at page edges", function()
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
        assert.equals(80, panels[1].w)
        assert.equals(880, panels[2].x)
        assert.equals(80, panels[2].w)
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

    it("keeps one framed illustration despite straight lines inside its artwork", function()
        local map = page()
        frame(map, 20, 20, 440, 600)
        for _, y in ipairs({ 160, 300, 440 }) do
            for x = 20, 459 do
                ink(map, x, y)
            end
        end
        map.dark = map.data
        local panels = Detector.detectPage(map, { mode = "manga" })
        assert.equals(1, #panels)
        assert.equals(40, panels[1].x)
        assert.equals(1200, panels[1].h)
    end)

    it("retains the parent when structural fragments leave substantial artwork uncovered", function()
        local map, alternate = page(), page()
        frame(map, 20, 20, 440, 600)
        frame(alternate, 25, 25, 430, 250)
        frame(alternate, 25, 360, 430, 250)
        map.structural = alternate.data
        local panels = Detector.detectPage(map, { mode = "manga" })
        assert.equals(1, #panels)
        assert.equals(1200, panels[1].h)
    end)

    it("still separates complete frames joined only by gray shading", function()
        local map = page()
        frame(map, 20, 20, 200, 600)
        frame(map, 240, 20, 200, 600)
        local structural = {}
        for i = 0, map.w * map.h - 1 do
            structural[i] = map.data[i]
        end
        for y = 100, 500 do
            for x = 219, 240 do
                ink(map, x, y)
            end
        end
        map.structural = structural
        local panels = Detector.detectPage(map, { mode = "manga" })
        assert.equals(2, #panels)
    end)

    it("does not overwrite caller coverage settings or global defaults", function()
        local map = page()
        local settings = { mode = "manga", segment_page_coverage_min = 0.7 }
        Detector.detectPage(map, settings)
        assert.equals(0.7, settings.segment_page_coverage_min)
        settings = { mode = "manga" }
        Detector.detectPage(map, settings)
        assert.is_nil(settings.segment_page_coverage_min)
        local defaults = require("src._settings").defaults
        local previous = defaults.segment_page_coverage_min
        Detector.detectPage(map)
        assert.equals(previous, defaults.segment_page_coverage_min)
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
    it("matches eight-neighbor flood fill on fragmented runs and page boundaries", function()
        local Scanner = require("src._componentscan")
        local seed = 417
        local function random(n)
            seed = seed * 16807 % 2147483647
            return seed % n
        end
        for trial = 1, 80 do
            local w, h = 1 + random(32), 1 + random(33)
            local map = { w = w, h = h, data = {} }
            for k = 0, w * h - 1 do
                map.data[k] = random(100) < trial % 101 and 1 or 0
            end
            local seen, expected = {}, {}
            for k = 0, w * h - 1 do
                if map.data[k] == 1 and not seen[k] then
                    local pixels, head = { k }, 1
                    seen[k] = true
                    while head <= #pixels do
                        local v = pixels[head]
                        head = head + 1
                        local y = math.floor(v / w)
                        local x = v - y * w
                        for dy = -1, 1 do
                            for dx = -1, 1 do
                                local nx, ny = x + dx, y + dy
                                local neighbor = ny * w + nx
                                if
                                    nx >= 0
                                    and nx < w
                                    and ny >= 0
                                    and ny < h
                                    and map.data[neighbor] == 1
                                    and not seen[neighbor]
                                then
                                    seen[neighbor] = true
                                    pixels[#pixels + 1] = neighbor
                                end
                            end
                        end
                    end
                    table.sort(pixels)
                    expected[#expected + 1] = pixels
                end
            end
            local count = 0
            Scanner.collect(map, 0, 1, function(_, pixels, n)
                count = count + 1
                local actual = {}
                for k = 0, n - 1 do
                    actual[#actual + 1] = pixels[k]
                end
                table.sort(actual)
                assert.equals(#expected[count], #actual)
                for k, pixel in ipairs(actual) do
                    assert.equals(expected[count][k], pixel)
                end
            end)
            assert.equals(#expected, count)
        end
    end)

    it("reuses one traversal workspace across Safe and Smart and reallocates after cleanup", function()
        local ffi = require("ffi")
        local Safe = require("src._safecomponentdetector")
        local map = page()
        frame(map, 20, 20, 200, 600)
        frame(map, 250, 20, 200, 600)
        Safe.clearScratch()
        Detector.clearScratch()
        local original_new, allocations = ffi.new, 0
        local ok, err = pcall(function()
            ffi.new = function(...)
                allocations = allocations + 1
                return original_new(...)
            end
            Safe.detectPage(map, { mode = "manga" })
            local safe_allocations = allocations
            assert.is_true(safe_allocations > 0)
            Detector.detectPage(map, { mode = "manga" })
            -- Smart only adds its white bitmap; the component buffers already fit.
            assert.equals(safe_allocations + 1, allocations)
            allocations = 0
            Safe.detectPage(map, { mode = "manga" })
            Detector.detectPage(map, { mode = "manga" })
            assert.equals(0, allocations)
            Safe.clearScratch()
            Detector.clearScratch()
            Safe.detectPage(map, { mode = "manga" })
            assert.is_true(allocations > 0)
        end)
        ffi.new = original_new
        Safe.clearScratch()
        Detector.clearScratch()
        assert.is_true(ok, tostring(err))
    end)
end)

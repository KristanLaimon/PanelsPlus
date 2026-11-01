--[[
Panels+
File: tests/panelviewport_spec.lua
Name: PanelViewport specs
Description: Verifies screen-shaped no-crop viewports and edge clamping.
Author: KristanLaimon
Year: 2026
Copyright (c) 2026 KristanLaimon
License: MIT; see the repository LICENSE file.
SPDX-License-Identifier: MIT
]]
local framework = require("tests.PanelsPlusTestFramework")
local describe, it, assert = framework.describe, framework.it, framework.assert

local PanelViewport = require("src._panelviewport")

describe("PanelViewport no-crop geometry", function()
    it("gives different panel-centred viewports instead of the whole source image", function()
        local source_size = { w = 1200, h = 1600 }
        local first = PanelViewport.noCrop({ x = 100, y = 200, w = 200, h = 300 }, source_size)
        local second = PanelViewport.noCrop({ x = 800, y = 900, w = 200, h = 300 }, source_size)

        assert.equals(225, first.union_w)
        assert.equals(300, first.union_h)
        assert.equals(225, second.union_w)
        assert.equals(300, second.union_h)
        assert.near(87.5, first.union_x, 0.001)
        assert.near(200, first.union_y, 0.001)
        assert.near(787.5, second.union_x, 0.001)
        assert.near(900, second.union_y, 0.001)
    end)

    it("keeps a screen-aspect viewport within the source at an edge", function()
        local viewport = PanelViewport.noCrop({ x = 0, y = 0, w = 300, h = 100 }, { w = 1200, h = 1600 })

        assert.near(0, viewport.union_x, 0.001)
        assert.near(0, viewport.union_y, 0.001)
        assert.near(300, viewport.union_w, 0.001)
        assert.near(250, viewport.union_h, 0.001)
        assert.near(2, viewport.scale, 0.001)
    end)
end)

describe("PanelViewport cropped transition coverage", function()
    it("covers overlapping endpoints once without exposing their bounding-box gaps", function()
        local function inside(r, x, y)
            return x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h
        end
        for _, b in ipairs({
            { x = 20, y = 20, w = 30, h = 30 }, -- partial overlap
            { x = 15, y = 15, w = 10, h = 10 }, -- contained
            { x = 0, y = 0, w = 50, h = 50 }, -- containing
            { x = 10, y = 40, w = 30, h = 10 }, -- touching
            { x = 45, y = 0, w = 10, h = 50 }, -- separated
        }) do
            local a = { x = 10, y = 10, w = 30, h = 30 }
            local clips = PanelViewport.transitionClips(a, b)
            for x = 0.5, 59.5 do
                for y = 0.5, 59.5 do
                    local count = 0
                    for _, clip in ipairs(clips) do
                        if inside(clip, x, y) then
                            count = count + 1
                        end
                    end
                    assert.equals((inside(a, x, y) or inside(b, x, y)) and 1 or 0, count)
                end
            end
        end
    end)
end)

--[[
Panels+
File: tests/spec/geometry_spec.lua
Name: Geometry specs
Description: Verifies manga and comic reading order across staggered and stacked layouts.
Author: KristanLaimon
Year: 2026
Copyright (c) 2026 KristanLaimon
License: MIT; see the repository LICENSE file.
SPDX-License-Identifier: MIT
]]
--- Regression coverage for panel reading order.

local framework = require("tests.PanelsPlusTestFramework")
local describe, it, assert = framework.describe, framework.it, framework.assert

local Geometry = require("src._geometry")

local function panel(id, x, y, w, h)
    return { id = id, x = x, y = y, w = w, h = h }
end

local function orderedIDs(panels)
    local ids = {}
    for _, rect in ipairs(panels) do
        table.insert(ids, rect.id)
    end
    return table.concat(ids, ",")
end

describe("Geometry.sortReadingOrder comic mode", function()
    it("keeps vertically staggered tiers out of one left-to-right row", function()
        -- The former union-find grouping links each neighbouring pair and
        -- turns all three panels into one row. It consequently sorts by x as
        -- middle, top, bottom, even though the top panel must be read first.
        local panels = {
            panel("middle", 0, 40, 100, 100),
            panel("bottom", 220, 80, 100, 100),
            panel("top", 220, 0, 100, 100),
        }

        Geometry.sortReadingOrder(panels, "comic")

        assert.equals("top,middle,bottom", orderedIDs(panels))
    end)

    it("reads panels with a shared tier top from left to right", function()
        local panels = {
            panel("right", 220, 4, 100, 96),
            panel("left", 0, 0, 200, 140),
        }

        Geometry.sortReadingOrder(panels, "comic")

        assert.equals("left,right", orderedIDs(panels))
    end)

    it("keeps a borderless panel with a slightly lower ink top in its row", function()
        -- The left panel has no frame, so its detected rectangle begins at the
        -- first drawing rather than the row's actual top edge. It still reads
        -- before its framed neighbour to the right.
        local panels = {
            panel("framed-right", 163, 527, 280, 111),
            panel("borderless-left", 35, 555, 125, 83),
        }

        Geometry.sortReadingOrder(panels, "comic")

        assert.equals("borderless-left,framed-right", orderedIDs(panels))
    end)

    it("reads a left-hand stack before its tall trailing panel", function()
        -- The tall right-hand panel starts alongside panel 3 but spans the
        -- three rows of panels to its left. Comic flow must complete that
        -- left-hand stack before returning to the right.
        local panels = {
            panel("4", 170, 120, 150, 380),
            panel("6", 0, 330, 70, 100),
            panel("2", 170, 0, 150, 100),
            panel("1", 0, 0, 150, 100),
            panel("7", 80, 330, 70, 100),
            panel("5", 0, 250, 150, 60),
            panel("3", 0, 120, 150, 110),
        }

        Geometry.sortReadingOrder(panels, "comic")

        assert.equals("1,2,3,5,6,7,4", orderedIDs(panels))
    end)
end)

describe("Geometry.sortReadingOrder manga mode", function()
    it("keeps vertically staggered tiers out of one right-to-left row", function()
        local panels = {
            panel("middle", 220, 40, 100, 100),
            panel("bottom", 0, 80, 100, 100),
            panel("top", 0, 0, 100, 100),
        }

        Geometry.sortReadingOrder(panels, "manga")

        assert.equals("top,middle,bottom", orderedIDs(panels))
    end)

    it("reads panels with a shared tier top from right to left", function()
        local panels = {
            panel("right", 220, 4, 100, 96),
            panel("left", 0, 0, 200, 140),
        }

        Geometry.sortReadingOrder(panels, "manga")

        assert.equals("right,left", orderedIDs(panels))
    end)

    it("keeps a borderless panel with a slightly lower ink top in its row", function()
        -- The right panel has no frame, so its detected rectangle begins at
        -- the first drawing rather than the row's actual top edge. Manga flow
        -- still reads it before its framed neighbour to the left.
        local panels = {
            panel("framed-left", 35, 527, 280, 111),
            panel("borderless-right", 163, 555, 125, 83),
        }

        Geometry.sortReadingOrder(panels, "manga")

        assert.equals("borderless-right,framed-left", orderedIDs(panels))
    end)

    it("reads a right-hand stack before its tall trailing panel", function()
        -- This is the right-to-left mirror of the comic layout: the tall
        -- left-hand panel starts alongside panel 3 but the right-hand stack
        -- must finish before manga flow returns to it.
        local panels = {
            panel("4", 0, 120, 150, 380),
            panel("6", 250, 330, 70, 100),
            panel("2", 0, 0, 150, 100),
            panel("1", 170, 0, 150, 100),
            panel("7", 170, 330, 70, 100),
            panel("5", 170, 250, 150, 60),
            panel("3", 170, 120, 150, 110),
        }

        Geometry.sortReadingOrder(panels, "manga")

        assert.equals("1,2,3,5,6,7,4", orderedIDs(panels))
    end)
end)

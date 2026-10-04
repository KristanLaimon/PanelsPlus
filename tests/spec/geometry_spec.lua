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

describe("Geometry.sortReadingOrder padded and nested layouts", function()
    local layouts = {
        {
            name = "finishes each row despite overlapping crop padding",
            -- Horimiya-style borders overlap the next tier by six pixels.
            boxes = {
                panel("1", 500, 0, 400, 406),
                panel("2", 0, 0, 450, 406),
                panel("3", 500, 400, 400, 406),
                panel("4", 0, 400, 450, 406),
                panel("5", 500, 800, 400, 400),
                panel("6", 0, 800, 450, 400),
            },
            expected = "1,2,3,4,5,6",
        },
        {
            name = "finishes an inset stack before the taller trailing panel",
            -- Nagatoro p.37: the full-height left panel begins above the stack.
            boxes = {
                panel("1", 585, 135, 411, 378),
                panel("2", 585, 536, 411, 345),
                panel("3", 585, 901, 411, 316),
                panel("4", 585, 1237, 411, 340),
                panel("5", 33, 0, 548, 1696),
            },
            expected = "1,2,3,4,5",
        },
        {
            name = "recognizes a nested stack despite horizontal border padding",
            -- Nagatoro p.75: children overlap their neighbour by ten pixels.
            boxes = {
                panel("1", 33, 0, 1086, 681),
                panel("2", 634, 700, 366, 464),
                panel("3", 634, 1155, 366, 541),
                panel("4", 33, 700, 611, 996),
            },
            expected = "1,2,3,4",
        },
        {
            name = "keeps later row members behind a deferred predecessor",
            boxes = {
                panel("1", 790, 996, 350, 334),
                panel("2", 790, 1312, 326, 347),
                panel("3", 464, 1015, 326, 644),
                panel("4", 69, 1015, 395, 403),
                panel("5", 69, 1436, 395, 223),
            },
            expected = "1,2,3,4,5",
        },
        {
            name = "does not defer a panel for a partly overlapping staggered neighbour",
            -- Mirrored Scott p.89: the next tier only overlaps the lower third.
            boxes = {
                panel("1", 708, 0, 474, 620),
                panel("2", 82, 34, 674, 1013),
                panel("3", 745, 670, 437, 1010),
                panel("4", 160, 1095, 619, 356),
                panel("5", 108, 1495, 648, 113),
            },
            expected = "1,2,3,4,5",
        },
    }
    for _, mode in ipairs({ "manga", "comic" }) do
        for _, layout in ipairs(layouts) do
            it(mode .. " " .. layout.name, function()
                for _, scale in ipairs({ 0.5, 1, 2 }) do
                    for offset = 0, #layout.boxes - 1 do
                        local panels = {}
                        for i = 1, #layout.boxes do
                            local box = layout.boxes[(i + offset - 1) % #layout.boxes + 1]
                            local x = mode == "comic" and 1300 - box.x - box.w or box.x
                            panels[i] = panel(box.id, x * scale, box.y * scale, box.w * scale, box.h * scale)
                        end
                        assert.equals(panels, Geometry.sortReadingOrder(panels, mode))
                        assert.equals(layout.expected, orderedIDs(panels))
                        Geometry.sortReadingOrder(panels, mode)
                        assert.equals(layout.expected, orderedIDs(panels), "Sorting must be idempotent")
                    end
                end
            end)
        end
    end
end)

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

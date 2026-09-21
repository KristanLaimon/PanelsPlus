--[[
Panels+
File: tests/spec/panelviewer_transform_spec.lua
Name: PanelViewer transform specs
Description: Verifies page/screen coordinate round trips, rotation, panning, and clipping.
Author: KristanLaimon
Year: 2026
Copyright (c) 2026 KristanLaimon
License: MIT; see the repository LICENSE file.
SPDX-License-Identifier: MIT
]]
--- Round-trip specs for `PanelViewer:screenToPageTransform` /
--- `PanelViewer:pageToScreenTransform`, the coordinate math behind both
--- panel-zoom rendering and the touch-and-hold dictionary/highlight
--- feature. This is regression coverage for the "big black square"
--- highlight bug investigation: these functions were traced by hand and
--- found consistent, so pinning that down here protects the fix that
--- builds on top of them (`paintHighlights`'s anomalous-box clamp).

local framework = require("tests.PanelsPlusTestFramework")
local describe, it, assert = framework.describe, framework.it, framework.assert

local PanelViewer = require("src._panelviewer")

--- Build a PanelViewer instance with a fake `_image_wg` exposing the
--- geometry fields the transform functions read.
local function newViewer(opts)
    local wg = {
        getSize = function() end,
        getCurrentWidth = function()
            return opts.bb_w
        end,
        getCurrentHeight = function()
            return opts.bb_h
        end,
        dimen = { x = opts.widget_x or 0, y = opts.widget_y or 0 },
        _offset_x = opts.offset_x or 0,
        _offset_y = opts.offset_y or 0,
    }
    return PanelViewer:new({
        page = 1,
        _images_list_cur = 1,
        image_rects = { opts.rect },
        rotated = opts.rotated,
        _image_wg = wg,
    })
end

local ROTATIONS = { false, 90, 180, 270 }

describe("PanelViewer transform round-trip (page -> screen -> page)", function()
    for _, rotated in ipairs(ROTATIONS) do
        it("recovers the original page-space box center under rotated=" .. tostring(rotated), function()
            local rect = { x = 100, y = 200, w = 300, h = 400 }
            local viewer = newViewer({ rect = rect, bb_w = 600, bb_h = 800, rotated = rotated })

            local box = { x = 150, y = 250, w = 50, h = 40 }
            local box_center_x = box.x + box.w / 2
            local box_center_y = box.y + box.h / 2

            local screen_rect = viewer:pageToScreenTransform(box)
            assert.is_not_nil(screen_rect, "expected an on-screen rect for a box inside the crop")

            local pos = {
                x = screen_rect.x + screen_rect.w / 2,
                y = screen_rect.y + screen_rect.h / 2,
            }
            local page_pos = viewer:screenToPageTransform(pos)
            assert.is_not_nil(page_pos)

            assert.near(box_center_x, page_pos.x, 3, "round-tripped x")
            assert.near(box_center_y, page_pos.y, 3, "round-tripped y")
        end)
    end

    it("still round-trips correctly with a non-zero pan offset and widget position", function()
        local rect = { x = 100, y = 200, w = 300, h = 400 }
        local viewer = newViewer({
            rect = rect,
            bb_w = 600,
            bb_h = 800,
            rotated = false,
            widget_x = 5,
            widget_y = 10,
            offset_x = 20,
            offset_y = 15,
        })

        local box = { x = 150, y = 250, w = 50, h = 40 }
        local screen_rect = viewer:pageToScreenTransform(box)
        assert.is_not_nil(screen_rect)

        local pos = {
            x = screen_rect.x + screen_rect.w / 2,
            y = screen_rect.y + screen_rect.h / 2,
        }
        local page_pos = viewer:screenToPageTransform(pos)
        assert.is_not_nil(page_pos)
        assert.near(box.x + box.w / 2, page_pos.x, 3)
        assert.near(box.y + box.h / 2, page_pos.y, 3)
    end)
end)

describe("PanelViewer:pageToScreenTransform clipping", function()
    it("clips a box larger than the crop to the full zoomed bitmap", function()
        local rect = { x = 100, y = 200, w = 300, h = 400 }
        local viewer = newViewer({ rect = rect, bb_w = 600, bb_h = 800, rotated = false })

        local oversized_box = { x = 0, y = 0, w = 1000, h = 1000 }
        local screen_rect = viewer:pageToScreenTransform(oversized_box)

        assert.is_not_nil(screen_rect)
        assert.equals(0, screen_rect.x)
        assert.equals(0, screen_rect.y)
        assert.equals(600, screen_rect.w)
        assert.equals(800, screen_rect.h)
    end)

    it("returns nil for a box entirely outside the crop", function()
        local rect = { x = 100, y = 200, w = 300, h = 400 }
        local viewer = newViewer({ rect = rect, bb_w = 600, bb_h = 800, rotated = false })

        local outside_box = { x = 1000, y = 1000, w = 50, h = 50 }
        local screen_rect = viewer:pageToScreenTransform(outside_box)

        assert.is_nil(screen_rect)
    end)
end)

-- The round trip passes when both functions are wrong in the same way, so
-- these check against the drawn bitmap. `ImageWidget.rotation_angle` turns it
-- counter-clockwise: at 270 the page's top edge is on the right of the view,
-- at 90 on the left.
describe("PanelViewer transforms in a quarter-turned view", function()
    -- A 1600x800 part of the page, shown turned in a 400x800 bitmap.
    local RECT = { x = 0, y = 0, w = 1600, h = 800 }

    local function turnedViewer(rotated, drawn_angle)
        local viewer = newViewer({ rect = RECT, bb_w = 400, bb_h = 800, rotated = rotated })
        viewer._image_wg.rotation_angle = drawn_angle
        return viewer
    end

    it("maps the top right of a view turned clockwise to the page's top left", function()
        local page_pos = turnedViewer(270):screenToPageTransform({ x = 396, y = 8 })

        assert.near(16, page_pos.x, 1, "page x")
        assert.near(8, page_pos.y, 1, "page y")
    end)

    it("maps the bottom left of a view turned counter-clockwise to the page's top left", function()
        local page_pos = turnedViewer(90):screenToPageTransform({ x = 4, y = 792 })

        assert.near(16, page_pos.x, 1, "page x")
        assert.near(8, page_pos.y, 1, "page y")
    end)

    it("draws a box from the page's top left in the top right of a view turned clockwise", function()
        local screen_rect = turnedViewer(270):pageToScreenTransform({ x = 0, y = 0, w = 160, h = 80 })

        assert.near(360, screen_rect.x, 1, "screen x")
        assert.near(0, screen_rect.y, 1, "screen y")
        assert.near(40, screen_rect.w, 1, "screen w")
        assert.near(80, screen_rect.h, 1, "screen h")
    end)

    it("draws a box from the page's top left in the bottom left of a view turned counter-clockwise", function()
        local screen_rect = turnedViewer(90):pageToScreenTransform({ x = 0, y = 0, w = 160, h = 80 })

        assert.near(0, screen_rect.x, 1, "screen x")
        assert.near(720, screen_rect.y, 1, "screen y")
    end)

    it("follows the angle ImageViewer drew its own auto-rotation at", function()
        -- `rotated == true` is ImageViewer's auto-rotation, which picks 90 or 270
        -- from the screen orientation and the invert settings.
        local clockwise = turnedViewer(true, 270):screenToPageTransform({ x = 396, y = 8 })
        local counter = turnedViewer(true, 90):screenToPageTransform({ x = 4, y = 792 })

        assert.near(16, clockwise.x, 1, "clockwise page x")
        assert.near(8, clockwise.y, 1, "clockwise page y")
        assert.near(16, counter.x, 1, "counter-clockwise page x")
        assert.near(8, counter.y, 1, "counter-clockwise page y")
    end)
end)

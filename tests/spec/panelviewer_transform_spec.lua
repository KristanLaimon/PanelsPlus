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

--[[
Panels+
File: tests/spec/foldjoin_spec.lua
Name: Fold join specs
Description: Verifies detection and removal of the black strip between the two halves of a double-page spread.
Author: KristanLaimon
Year: 2026
Copyright (c) 2026 KristanLaimon
License: MIT; see the repository LICENSE file.
SPDX-License-Identifier: MIT
]]
--- Specs for `src/_foldjoin.lua` and its use in the collector and the viewer.

local framework = require("tests.PanelsPlusTestFramework")
local describe, it, assert = framework.describe, framework.it, framework.assert

local FoldJoin = require("src._foldjoin")
local PanelCollector = require("src._panelcollector")
local PanelViewer = require("src._panelviewer")
local Settings = require("src._settings")

--- Sampler for a light page with dark columns `x0..x1`.
local function pageWithBand(x0, x1, noise_every)
    return function(x, y)
        if x >= x0 and x <= x1 then
            if noise_every and y % noise_every == 0 then
                return 230
            end
            return 5
        end
        return 240
    end
end

--- Like `pageWithBand`, with half-dark columns at the strip's edges.
local function pageWithBlurredBand(x0, x1, blur_left, blur_right)
    return function(x, y)
        if x >= x0 and x <= x1 then
            return 5
        elseif (x < x0 and x >= x0 - blur_left) or (x > x1 and x <= x1 + blur_right) then
            return 110
        end
        return 240
    end
end

--- Fake bitmap backed by a sampler.
local function bitmap(width, height, sample)
    return {
        getWidth = function()
            return width
        end,
        getHeight = function()
            return height
        end,
        getType = function()
            return 1
        end,
        getPixel = function(_, x, y)
            return {
                getColor8 = function()
                    return { a = sample(x, y) }
                end,
            }
        end,
    }
end

describe("FoldJoin.findBand", function()
    it("finds a full-height black strip at the centre", function()
        local x0, x1 = FoldJoin.findBand(1000, 400, pageWithBand(490, 510))

        assert.equals(490, x0)
        assert.equals(510, x1)
    end)

    it("accepts a strip slightly off centre and a few light pixels in it", function()
        local x0, x1 = FoldJoin.findBand(1000, 400, pageWithBand(500, 515, 100))

        assert.equals(500, x0)
        assert.equals(515, x1)
    end)

    it("returns nothing for a page without a strip", function()
        assert.is_nil(FoldJoin.findBand(1000, 400, function()
            return 240
        end))
    end)

    it("returns nothing for dark artwork that runs across the fold", function()
        assert.is_nil(FoldJoin.findBand(1000, 400, function()
            return 5
        end))
        assert.is_nil(FoldJoin.findBand(1000, 400, pageWithBand(400, 600)))
    end)

    it("returns nothing for a strip away from the centre", function()
        assert.is_nil(FoldJoin.findBand(1000, 400, pageWithBand(300, 320)))
    end)

    it("looks where the caller says the fold is, for a panel that is not centred on it", function()
        local x0, x1 = FoldJoin.findBand(1000, 400, pageWithBand(300, 320), { centre = 310, reach = 30, max_band = 40 })

        assert.equals(300, x0)
        assert.equals(320, x1)
    end)
end)

describe("FoldJoin coordinate mapping", function()
    -- 2% removed and the joined halves centred, so 1% padding at each end.
    local fold = { u0 = 0.49, u1 = 0.51, pad = 0.01 }

    it("maps positions in the joined image back to the source", function()
        assert.near(0.245, FoldJoin.toSourceU(0.255, fold), 0.0001)
        assert.near(0.755, FoldJoin.toSourceU(0.745, fold), 0.0001)
        assert.near(0, FoldJoin.toSourceU(0.005, fold), 0.0001)
        assert.near(1, FoldJoin.toSourceU(0.999, fold), 0.0001)
    end)

    it("maps source positions to the joined image", function()
        assert.near(0.255, FoldJoin.toJoinedU(0.245, fold), 0.0001)
        assert.near(0.745, FoldJoin.toJoinedU(0.755, fold), 0.0001)
        assert.near(0.5, FoldJoin.toJoinedU(0.5, fold), 0.0001)
    end)

    it("changes nothing without a fold", function()
        assert.equals(0.3, FoldJoin.toSourceU(0.3, nil))
        assert.equals(0.3, FoldJoin.toJoinedU(0.3, nil))
    end)
end)

describe("FoldJoin.joinBitmap", function()
    it("keeps the bitmap's size, so the viewer does not rescale it", function()
        local joined, fold = FoldJoin.joinBitmap(bitmap(1000, 400, pageWithBand(490, 510)))

        assert.equals(1000, joined.w)
        assert.equals(400, joined.h)
        assert.near(0.49, fold.u0, 0.0001)
        assert.near(0.511, fold.u1, 0.0001)
        assert.near(0.01, fold.pad, 0.0001)
    end)

    it("also removes the half-dark columns at the strip's edges", function()
        local _, fold = FoldJoin.joinBitmap(bitmap(1000, 400, pageWithBlurredBand(490, 510, 2, 1)))

        assert.near(0.488, fold.u0, 0.0001)
        assert.near(0.512, fold.u1, 0.0001)
    end)

    it("keeps the edge trim inside the widest strip it may remove", function()
        -- A 40 px strip is the limit for a 1000 px image, so its blurred edges stay.
        local _, fold = FoldJoin.joinBitmap(bitmap(1000, 400, pageWithBlurredBand(480, 519, 2, 2)))

        assert.near(0.48, fold.u0, 0.0001)
        assert.near(0.52, fold.u1, 0.0001)
    end)

    it("returns nothing when there is no strip", function()
        assert.is_nil(FoldJoin.joinBitmap(bitmap(1000, 400, function()
            return 240
        end)))
    end)
end)

describe("Fold join in the panel collector", function()
    local function spreadDocument()
        return {
            getPageDimensions = function()
                return { w = 1600, h = 1000 }
            end,
            drawPagePart = function()
                return bitmap(1000, 400, pageWithBand(490, 510)), false
            end,
        }
    end

    it("joins the whole-spread image and records the fold", function()
        local settings = Settings.withDefaults({ auto_rotate_double_pages = false })
        local images = PanelCollector.buildImages(
            { document = spreadDocument() },
            1,
            { { x = 0, y = 0, w = 1600, h = 1000 } },
            settings
        )

        local image = images[1]()

        assert.equals(1000, image.w)
        assert.is_not_nil(images.folds[1])
    end)

    it("joins a panel that crosses the fold, looking where the fold is in that panel", function()
        local document = spreadDocument()
        -- The panel starts at x=400 of a 1600 wide page, so the fold (x=800) is at 40% of it.
        document.drawPagePart = function()
            return bitmap(1000, 400, pageWithBand(395, 405)), false
        end
        local settings = Settings.withDefaults({ auto_rotate_double_pages = false })
        local panels = { { x = 400, y = 100, w = 1000, h = 400 }, { x = 0, y = 600, w = 300, h = 300 } }
        local images = PanelCollector.buildImages({ document = document }, 1, panels, settings)

        images[1]()
        images[2]()

        assert.is_not_nil(images.folds[1])
        assert.is_nil(images.folds[2])
    end)

    it("leaves the image alone when the setting is off", function()
        local settings = Settings.withDefaults({ auto_rotate_double_pages = false, join_spread_fold = false })
        local images = PanelCollector.buildImages(
            { document = spreadDocument() },
            1,
            { { x = 0, y = 0, w = 1600, h = 1000 } },
            settings
        )

        local image = images[1]()

        assert.equals(1000, image.getWidth())
        assert.is_nil(images.folds)
    end)
end)

describe("Fold join in the viewer's coordinate transforms", function()
    local function viewerWithFold(fold)
        return PanelViewer:new({
            page = 1,
            _images_list_cur = 1,
            _images_list = { folds = { fold } },
            image_rects = { { x = 0, y = 0, w = 1000, h = 500 } },
            rotated = false,
            _image_wg = {
                getSize = function() end,
                getCurrentWidth = function()
                    return 1000
                end,
                getCurrentHeight = function()
                    return 500
                end,
                dimen = { x = 0, y = 0 },
                _offset_x = 0,
                _offset_y = 0,
            },
        })
    end

    it("maps a press right of the seam past the removed strip", function()
        local viewer = viewerWithFold({ u0 = 0.49, u1 = 0.51, pad = 0.01 })

        assert.near(245, viewer:screenToPageTransform({ x = 255, y = 100 }).x, 1)
        assert.near(755, viewer:screenToPageTransform({ x = 745, y = 100 }).x, 1)
    end)

    it("draws a box right of the seam where the joined image shows it", function()
        local viewer = viewerWithFold({ u0 = 0.49, u1 = 0.51, pad = 0.01 })

        local screen_rect = viewer:pageToScreenTransform({ x = 755, y = 100, w = 50, h = 20 })

        assert.near(745, screen_rect.x, 1)
    end)
end)

describe("Fold join setting in the menus", function()
    local MainMenu = require("src.menu")
    local UIManager = require("ui/uimanager")
    local ViewerController = require("src.viewer_controller")

    it("is a checkbox in the main menu, on by default", function()
        local called_with
        local menu_items = {}
        MainMenu.addToMainMenu({
            settings = Settings.withDefaults({}),
            getModeText = function()
                return "Panels+"
            end,
            setJoinSpreadFold = function(_, enabled)
                called_with = enabled
            end,
        }, menu_items)
        local item
        for _, candidate in ipairs(menu_items.panels_plus.sub_item_table) do
            if candidate.text == "Remove the fold line from double-page spreads" then
                item = candidate
            end
        end

        assert.is_true(item.checked_func())
        item.callback()
        assert.is_false(called_with)
    end)

    it("is listed under [Rotation] in the viewer's settings and rebuilds the viewer on a spread", function()
        local rebuilt = false
        local controller = setmetatable({
            settings = Settings.withDefaults({}),
            setJoinSpreadFold = function(self, enabled)
                self.settings.join_spread_fold = enabled
            end,
            showPanelViewerForPage = function(_, page)
                rebuilt = true
                return { page = page }
            end,
        }, { __index = ViewerController })
        local viewer = { page = 2, panels = { { x = 0, y = 0, w = 1692, h = 1200 } }, panel_is_full_page = { true } }

        controller:showMoreConfigMenu(viewer)
        for _, item in ipairs(UIManager._last_shown.item_table) do
            if item.text == "[Rotation]: Remove spread fold line (Actual: true)" then
                item.callback()
            end
        end

        assert.is_false(controller.settings.join_spread_fold)
        assert.is_true(rebuilt)
    end)
end)

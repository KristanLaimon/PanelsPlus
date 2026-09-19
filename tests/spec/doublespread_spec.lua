--[[
Panels+
File: tests/spec/doublespread_spec.lua
Name: Double-spread rotation specs
Description: Verifies automatic image rotation and manual overrides.
Author: KristanLaimon
Year: 2026
Copyright (c) 2026 KristanLaimon
License: MIT; see the repository LICENSE file.
SPDX-License-Identifier: MIT
]]
local framework = require("tests.PanelsPlusTestFramework")
local describe, it, assert, spy = framework.describe, framework.it, framework.assert, framework.spy
local Screen = require("device").screen
local DoubleSpread = require("src._doublespread")
local PanelViewer = require("src._panelviewer")
local PanelCollector = require("src._panelcollector")
local ViewerController = require("src.viewer_controller")

local wide = { x = 0, y = 0, w = 1400, h = 900 }
local normal = { x = 0, y = 0, w = 700, h = 1000 }

describe("Double-page image auto-rotation", function()
    it("rotates only wide full-page images on portrait screens", function()
        assert.is_true(DoubleSpread.shouldRotate(wide, true))
        assert.is_false(DoubleSpread.shouldRotate(wide, false))
        assert.is_true(DoubleSpread.shouldRotate(wide, false, true))
        assert.is_false(DoubleSpread.shouldRotate(normal, true))

        local get_width, get_height = Screen.getWidth, Screen.getHeight
        Screen.getWidth = function()
            return 800
        end
        Screen.getHeight = function()
            return 600
        end
        assert.is_false(DoubleSpread.shouldRotate(wide, true))
        Screen.getWidth, Screen.getHeight = get_width, get_height
    end)

    it("returns to document rotation on the next ordinary panel", function()
        local viewer = PanelViewer:new({
            panels = { wide, normal },
            panel_is_full_page = { true, true },
            _images_list = { rotated = false },
            auto_rotate_double_pages = true,
        })
        viewer:applyImageRotation(1)
        assert.equals(90, viewer.rotated)
        viewer:applyImageRotation(2)
        assert.is_false(viewer.rotated)
    end)

    it("rotates a spread opened directly at a later panel", function()
        local rendered = {}
        local viewer = PanelViewer:new({
            image = {
                function()
                    rendered[#rendered + 1] = 1
                    return {}
                end,
                function()
                    rendered[#rendered + 1] = 2
                    return {}
                end,
                rotated = false,
            },
            images_list_nb = 2,
            initial_image_num = 2,
            panels = { normal, wide },
            panel_is_full_page = { true, true },
            replaceButtonTable = function() end,
            update = function() end,
        })
        viewer:init()
        assert.equals(2, viewer._images_list_cur)
        assert.equals(2, #viewer._images_list)
        assert.equals(1, #rendered)
        assert.equals(2, rendered[1])
        assert.equals(90, viewer.rotated)
    end)

    it("uses KOReader's inverted portrait direction when selected", function()
        local reader_settings = G_reader_settings
        G_reader_settings = {
            isTrue = function(_, key)
                return key == "imageviewer_rotation_portrait_invert"
            end,
        }
        local viewer = PanelViewer:new({
            panels = { wide },
            panel_is_full_page = { true },
            _images_list = { rotated = false },
        })
        viewer:applyImageRotation(1)
        G_reader_settings = reader_settings
        assert.equals(270, viewer.rotated)
    end)

    it("keeps manual image rotation authoritative until Auto is selected", function()
        local viewer = PanelViewer:new({
            panels = { wide },
            panel_is_full_page = { true },
            _images_list = { rotated = false },
            _images_list_cur = 1,
            image_rotation = false,
            auto_rotate_double_pages = true,
            replaceButtonTable = function() end,
            update = function() end,
        })
        viewer:applyImageRotation(1)
        assert.is_false(viewer.rotated)
        viewer:onSetImageRotation("auto")
        assert.is_nil(viewer.image_rotation)
        assert.equals(90, viewer.rotated)
        viewer.auto_rotate_double_pages = false
        viewer:applyImageRotation(1)
        assert.is_false(viewer.rotated)
    end)

    it("renders the source page directly in No crop mode before rotating", function()
        local rendered_rect
        local image = {
            copy = function(self)
                return self
            end,
        }
        local document = {
            getPageDimensions = function()
                return { w = wide.w, h = wide.h }
            end,
            drawPagePart = function(_, _, rect)
                rendered_rect = rect
                return image, false
            end,
        }
        local images, rects = PanelCollector.buildImages({ document = document }, 1, { wide }, {
            crop_mode = "none",
            auto_rotate_double_pages = true,
            full_page_panel_ratio = 0.92,
        })
        assert.equals(image, images[1]())
        assert.equals(wide.w, rendered_rect.w)
        assert.equals(wide.h, rendered_rect.h)
        assert.equals(wide.w, rects[1].w)
    end)

    it("renders fixed spreads at their rotated fit resolution", function()
        local rendered_zoom, rendered_rect
        local image = {
            copy = function(self)
                return self
            end,
        }
        local document = {
            getPageDimensions = function()
                return { w = 2000, h = 1000 }
            end,
            transformRect = function(_, rect, zoom)
                return { w = rect.w * zoom, h = rect.h * zoom }
            end,
            renderPage = function(_, _, rect, zoom)
                rendered_rect, rendered_zoom = rect, zoom
                return { bb = image }
            end,
        }
        local images, _, full_page_flags = PanelCollector.buildImages({ document = document }, 1, { wide }, {
            crop_mode = "strict",
            auto_rotate_double_pages = true,
            full_page_panel_ratio = 0.92,
        })
        assert.equals(image, images[1]())
        assert.is_false(full_page_flags[1])
        assert.near(800 / wide.w, rendered_zoom, 0.0001)
        assert.near(wide.w * rendered_zoom, rendered_rect.scaled_rect.w, 0.0001)
    end)

    it("rebuilds a spread when changing the manual rotation", function()
        local saved, opened = spy(), spy()
        local controller = setmetatable({
            setImageRotation = saved,
            showPanelViewerForPage = opened,
        }, { __index = ViewerController })
        local viewer = {
            page = 4,
            panels = { wide },
            panel_is_full_page = { true },
            _images_list_cur = 1,
            crop_mode = "strict",
        }
        assert.equals("reopened", controller:setViewerImageRotation(viewer, nil))
        assert.is_true(saved:called())
        assert.equals(4, opened:lastCall()[2])
    end)

    it("skips smooth canvases when either side needs spread rotation", function()
        local switched = spy()
        local viewer = PanelViewer:new({
            panels = { normal, wide },
            panel_is_full_page = { true, true },
            _images_list_cur = 1,
            auto_rotate_double_pages = true,
            switchToImageNum = switched,
        })
        viewer:animateSwitchToImageNum(2)
        assert.equals(2, switched:lastCall()[2])

        local crossed = spy()
        viewer.nav_boundary_peek_callback = function()
            return { target_rect = wide, target_is_full_page = true }
        end
        viewer.boundary_callback = crossed
        viewer:animateBoundaryTransition("next")
        assert.is_true(crossed:called())
    end)
end)

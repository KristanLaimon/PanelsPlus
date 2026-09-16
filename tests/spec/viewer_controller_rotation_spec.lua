--[[
Panels+
File: tests/spec/viewer_controller_rotation_spec.lua
Name: ViewerController rotation specs
Description: Verifies device orientation preservation across page boundaries.
Author: KristanLaimon
Year: 2026
Copyright (c) 2026 KristanLaimon
License: MIT; see the repository LICENSE file.
SPDX-License-Identifier: MIT
]]
--- Regression coverage for preserving a chosen device orientation while
--- Panels+ crosses from the last panel of one page to the first of another.

local framework = require("tests.PanelsPlusTestFramework")
local describe, it, assert, spy = framework.describe, framework.it, framework.assert, framework.spy

local Screen = require("device").screen
local UIManager = require("ui/uimanager")
local ViewerController = require("src.viewer_controller")
local PanelViewer = require("src._panelviewer")

describe("ViewerController device rotation across page boundaries", function()
    local original_broadcast_event
    local original_on_rotation

    local function resetScreen()
        Screen:setRotationMode(0)
        original_broadcast_event = UIManager.broadcastEvent
        original_on_rotation = UIManager.onRotation
    end

    local function restoreUIManager()
        UIManager.broadcastEvent = original_broadcast_event
        UIManager.onRotation = original_on_rotation
    end

    it("restores the selected rotation when GotoPage resets it", function()
        resetScreen()
        Screen:setRotationMode(2)
        local broadcast_spy, rotation_spy = spy(), spy()
        UIManager.broadcastEvent = function(_, event)
            broadcast_spy(event)
            if event.name == "SetRotationMode" then
                Screen:setRotationMode(event.args[1])
            end
        end
        UIManager.onRotation = function()
            rotation_spy()
        end

        local shown_spy = spy()
        local current_viewer = {}
        local controller = setmetatable({
            ui = {
                handleEvent = function(_, event)
                    assert.equals("GotoPage", event.name)
                    -- Simulate a document/plugin rotation applied while the
                    -- normal KOReader page-change event is handled.
                    Screen:setRotationMode(0)
                end,
            },
            showPanelViewerForPage = function(_, page, panels, start_idx, options)
                shown_spy(page, panels, start_idx, options)
                return true
            end,
        }, { __index = ViewerController })

        local result = controller:commitBoundaryTransition("next", current_viewer, {
            next_page = 2,
            panels = { { x = 0, y = 0, w = 1, h = 1 } },
            start_idx = 1,
        })

        assert.is_true(result)
        assert.equals(2, Screen:getRotationMode())
        assert.equals(1, broadcast_spy:callCount())
        assert.equals("SetRotationMode", broadcast_spy:lastCall()[1].name)
        assert.equals(2, broadcast_spy:lastCall()[1].args[1])
        assert.equals(1, rotation_spy:callCount())
        assert.is_true(shown_spy:called())
        assert.equals(current_viewer, shown_spy:lastCall()[4].replace_viewer)
        assert.equals("next", shown_spy:lastCall()[4].boundary_direction)
        restoreUIManager()
    end)

    it("does not redraw when the page handoff leaves rotation unchanged", function()
        resetScreen()
        Screen:setRotationMode(3)
        local broadcast_spy, rotation_spy = spy(), spy()
        UIManager.broadcastEvent = function(_, event)
            broadcast_spy(event)
        end
        UIManager.onRotation = function()
            rotation_spy()
        end

        ViewerController.restoreDeviceRotation({}, 3)

        assert.is_false(broadcast_spy:called())
        assert.is_false(rotation_spy:called())
        restoreUIManager()
    end)
end)

describe("PanelViewer Android screen resize", function()
    it("renders a wide crop at the landscape canvas width after rotation", function()
        local old_width, old_height = Screen.getWidth, Screen.getHeight
        local screen_w, screen_h = 824, 1648
        Screen.getWidth = function()
            return screen_w
        end
        Screen.getHeight = function()
            return screen_h
        end

        local document = {
            getPageDimensions = function()
                return { w = 800, h = 1600 }
            end,
            drawPagePart = function(_, _, rect)
                local scale = math.min(screen_w / rect.w, screen_h / rect.h)
                return {
                    getWidth = function()
                        return math.floor(rect.w * scale)
                    end,
                },
                    false
            end,
        }
        local controller = setmetatable({
            settings = { crop_mode = "strict" },
            ui = { document = document },
            preloadNextPanels = function() end,
        }, { __index = ViewerController })
        controller:showPanelViewerForPage(7, { { x = 0, y = 0, w = 800, h = 250 } }, 1)
        local portrait_viewer = UIManager._last_shown
        portrait_viewer.region = { w = screen_w, h = screen_h }
        assert.equals(824, portrait_viewer.image[1]():getWidth())

        screen_w, screen_h = 1648, 824
        portrait_viewer:onScreenResize({ w = screen_w, h = screen_h })
        local landscape_viewer = UIManager._last_shown
        assert.is_true(landscape_viewer ~= portrait_viewer)
        assert.equals(1648, landscape_viewer.image[1]():getWidth())

        Screen.getWidth, Screen.getHeight = old_width, old_height
    end)

    it("reopens the current panel after auto-rotation changes a Palma-sized canvas", function()
        local old_close = UIManager.close
        local shown = spy()
        local closed = spy()
        UIManager.close = function(_, viewer)
            closed(viewer)
            -- Closing a real viewer releases these fields, so the controller
            -- must capture the page and panel list before the close.
            viewer.panels = nil
            viewer.page = nil
        end

        local panels = { { x = 0, y = 0, w = 800, h = 250 }, { x = 0, y = 250, w = 800, h = 250 } }
        local controller = setmetatable({
            settings = { crop_mode = "strict" },
            ui = { document = {
                getPageDimensions = function()
                    return { w = 800, h = 1600 }
                end,
            } },
            preloadNextPanels = function() end,
        }, { __index = ViewerController })
        controller:showPanelViewerForPage(7, panels, 1, { buttons_visible = true })
        local viewer = UIManager._last_shown
        viewer.region = { w = 824, h = 1648 }
        viewer._images_list_cur = 2
        controller.showPanelViewerForPage = shown

        viewer:onScreenResize({ w = 1648, h = 824 })

        assert.equals(1, closed:callCount())
        assert.equals(1, shown:callCount())
        assert.equals(7, shown:lastCall()[2])
        assert.equals(panels, shown:lastCall()[3])
        assert.equals(2, shown:lastCall()[4])
        assert.is_true(shown:lastCall()[5].buttons_visible)
        UIManager.close = old_close
    end)

    it("ignores duplicate resize events for an already sized viewer", function()
        local resized = spy()
        local viewer = PanelViewer:new({
            region = { w = 1648, h = 824 },
            screen_resize_callback = resized,
        })

        viewer:onScreenResize({ w = 1648, h = 824 })
        assert.is_false(resized:called())
    end)
end)

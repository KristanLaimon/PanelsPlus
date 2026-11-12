--[[
Panels+
File: tests/panelviewer_gesture_zoom_spec.lua
Name: Panel gesture zoom specs
Description: Verifies configurable gesture zoom targeting and restoration.
Author: KristanLaimon
Year: 2026
Copyright (c) 2026 KristanLaimon
License: MIT; see the repository LICENSE file.
SPDX-License-Identifier: MIT
]]
local framework = require("tests.PanelsPlusTestFramework")
local describe, it, assert = framework.describe, framework.it, framework.assert
local PanelViewer = require("src._panelviewer")

describe("Panel gesture zoom", function()
    for _, zoom in ipairs({ "hold", "two_finger_tap" }) do
        it("zooms and restores with independently selected " .. zoom, function()
            local zoom_calls, updates = 0, 0
            local viewer = PanelViewer:new({
                panel_zoom_settings = {
                    panel_gesture = zoom,
                    panel_zoom_gesture = zoom,
                    panel_gesture_zoom = true,
                    panel_gesture_zoom_factor = 1.75,
                },
                scale_factor = 0,
                _scale_to_fit = true,
                _center_x_ratio = 0.5,
                _center_y_ratio = 0.5,
                _image_wg = {
                    dimen = { x = 10, y = 20 },
                    _offset_x = 20,
                    _offset_y = 40,
                    getSize = function() end,
                    getCurrentWidth = function()
                        return 400
                    end,
                    getCurrentHeight = function()
                        return 800
                    end,
                },
                onZoomIn = function(self, increment)
                    assert.equals(0.75, increment)
                    self.scale_factor = 1.75
                    zoom_calls = zoom_calls + 1
                end,
                replaceButtonTable = function() end,
                update = function()
                    updates = updates + 1
                end,
            })
            local gesture = { ges = zoom, pos = { x = 90, y = 180 } }
            assert.is_true(viewer:onGesture(gesture))
            assert.equals(1, zoom_calls)
            assert.equals(0.25, viewer._center_x_ratio)
            assert.equals(0.25, viewer._center_y_ratio)
            if gesture.ges == "hold" then
                assert.is_true(viewer:onGesture({ ges = "hold_release" }))
            end
            local saved = viewer._gesture_zoom_restore
            viewer:refreshPanelColors()
            assert.equals(saved, viewer._gesture_zoom_restore)
            assert.equals(1.75, viewer.scale_factor)
            assert.is_true(viewer:onGesture(gesture))
            assert.equals(1, zoom_calls)
            assert.equals(0, viewer.scale_factor)
            assert.is_true(viewer._scale_to_fit)
            assert.equals(0.5, viewer._center_x_ratio)
            assert.equals(2, updates)
        end)
    end
    it("clears the saved view when switching panels", function()
        local viewer = PanelViewer:new({
            image = "first",
            _images_list = { "first", "second" },
            _images_list_cur = 1,
            _gesture_zoom_restore = { scale = 0 },
            applyImageRotation = function() end,
            update = function() end,
            requestPanelPrerender = function() end,
        })
        viewer:switchToImageNum(2)
        assert.equals(nil, viewer._gesture_zoom_restore)
    end)

    it("keeps disabled and unselected gestures on the normal input path", function()
        local forwarded = 0
        local viewer = PanelViewer:new({
            panel_zoom_settings = { panel_gesture = "hold", panel_gesture_zoom = false },
            dispatchReaderGesture = function()
                forwarded = forwarded + 1
                return true
            end,
            toggleGestureZoom = function()
                error("Unexpected zoom")
            end,
        })
        viewer:onGesture({ ges = "two_finger_tap" })
        viewer.panel_zoom_settings.panel_gesture_zoom = true
        viewer:onGesture({ ges = "hold" })
        assert.equals(2, forwarded)
    end)

    it("shows the current zoom gesture and saves enable and magnification choices", function()
        local menu = require("src.menu")
        local saves = 0
        local controller = {
            settings = { panel_gesture = "hold" },
            saveSettings = function()
                saves = saves + 1
            end,
        }
        local items = menu.panelZoomItems(controller)
        assert.equals("Two-finger tap", items[1].mandatory)
        assert.is_false(items[2].checked_func())
        items[2].callback()
        assert.is_true(items[2].checked_func())
        for index, factor in ipairs({ 1.25, 1.5, 1.75, 2 }) do
            items[index + 2].callback()
            assert.equals(factor, controller.settings.panel_gesture_zoom_factor)
            assert.is_true(items[index + 2].checked_func())
        end
        local choices = items[1].sub_item_table
        assert.is_true(choices[2].checked_func())
        choices[1].callback()
        assert.is_true(choices[1].checked_func())
        assert.equals("Long press", menu.panelZoomItems(controller)[1].mandatory)
        controller.settings.panel_gesture = "two_finger_tap"
        assert.equals("Long press", menu.panelZoomItems(controller)[1].mandatory)
        choices[2].callback()
        assert.is_true(choices[2].checked_func())
        assert.equals("Two-finger tap", menu.panelZoomItems(controller)[1].mandatory)
        assert.equals(7, saves)
        assert.equals(2, #menu.panelGestureItems(controller))
    end)
end)

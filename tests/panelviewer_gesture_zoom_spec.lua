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
    for _, zoom in ipairs({ "hold", "two_finger_tap", "spread" }) do
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

    it("defaults to spread and shows enable state and exclusive gesture choices", function()
        local menu = require("src.menu")
        local saves = 0
        local controller = {
            settings = {},
            saveSettings = function()
                saves = saves + 1
            end,
        }
        local items = menu.panelZoomItems(controller)
        assert.equals(5, #items)
        assert.equals("Deactivated", items[1].mandatory_func())
        items[1].callback()
        assert.equals("Activated", menu.panelZoomItems(controller)[1].mandatory_func())
        assert.is_true(items[5].checked_func())
        for index, gesture in ipairs({ "hold", "two_finger_tap", "spread" }) do
            items[index + 2].callback()
            assert.equals(gesture, controller.settings.panel_zoom_gesture)
            for other = 3, 5 do
                assert.equals(other == index + 2, items[other].checked_func())
            end
        end
        assert.equals(4, saves)
    end)

    it("keeps the settings proxy empty, live in both directions, and rejects other settings", function()
        local settings = {
            mode = "manga",
            panel_gesture_zoom = false,
            panel_zoom_gesture = "spread",
            panel_gesture_zoom_factor = 1.5,
        }
        local proxy = require("src._panelzoom").proxy(settings)
        assert.equals(nil, next(proxy))
        assert.equals(nil, proxy.mode)
        assert.is_false(pcall(function()
            proxy.mode = "comic"
        end))
        assert.equals("manga", settings.mode)
        for key, value in pairs({
            panel_gesture_zoom = true,
            panel_zoom_gesture = "hold",
            panel_gesture_zoom_factor = 2.35,
        }) do
            settings[key] = value
            assert.equals(value, proxy[key])
            proxy[key] = nil
            assert.equals(nil, settings[key])
            proxy[key] = value
            assert.equals(value, settings[key])
        end
        assert.equals(nil, next(proxy))
    end)

    it("paints the slider within the image without changing its dimensions", function()
        local old_text = package.loaded["ui/widget/textwidget"]
        local labels, paints, freed = {}, {}, 0
        package.loaded["ui/widget/textwidget"] = {
            new = function(_, options)
                labels[#labels + 1] = options.text
                return {
                    getSize = function()
                        return { w = 30, h = 12 }
                    end,
                    paintTo = function() end,
                    free = function()
                        freed = freed + 1
                    end,
                }
            end,
        }
        local ok, err = pcall(function()
            local image_rect = { x = 0, y = 0, w = 500, h = 600 }
            local viewer = PanelViewer:new({
                buttons_visible = true,
                panel_zoom_settings = { panel_gesture_zoom_factor = 1.75 },
                _image_wg = { dimen = image_rect },
            })
            local bb = {
                paintRect = function(_, x, y, w, h)
                    paints[#paints + 1] = { x = x, y = y, w = w, h = h }
                end,
            }
            viewer:paintZoomSlider(bb)
            assert.equals(500, image_rect.w)
            assert.equals(600, image_rect.h)
            local slider = viewer._zoom_slider_rect
            assert.is_true(slider.x + slider.w < image_rect.w)
            assert.is_true(slider.y + slider.h < image_rect.h)
            assert.equals("3×", labels[1])
            assert.equals("1×", labels[2])
            assert.equals("0.3×", labels[3])
            local cap = paints[7]
            assert.is_true(cap.w > cap.h * 2)
            assert.is_true(slider.track_y > slider.y)
            assert.is_true(slider.track_y + slider.track_h < slider.y + slider.h)
            assert.equals(3, freed)
            assert.equals(9, #paints)
            viewer.buttons_visible = false
            viewer:paintZoomSlider(bb)
            assert.equals(nil, viewer._zoom_slider_rect)
            assert.equals(9, #paints)
        end)
        package.loaded["ui/widget/textwidget"] = old_text
        if not ok then
            error(err)
        end
    end)

    it("drags over the image from 0.3 to 3 without compounding zoom and saves on release", function()
        local saves, updates = 0, 0
        local viewer = PanelViewer:new({
            buttons_visible = true,
            panel_zoom_settings = {},
            panel_zoom_save_callback = function()
                saves = saves + 1
            end,
            _zoom_slider_rect = { x = 200, y = 100, w = 48, h = 270 },
            scale_factor = 0,
            _scale_to_fit = true,
            _center_x_ratio = 0.5,
            _center_y_ratio = 0.5,
            _image_wg = {
                getScaleFactor = function()
                    return 2
                end,
            },
            _applyNewScaleFactor = function(self, factor)
                self.scale_factor = factor
            end,
            update = function()
                updates = updates + 1
            end,
        })
        assert.is_false(viewer:handleZoomSliderGesture({ ges = "tap", pos = { x = 50, y = 200 } }))
        assert.is_true(viewer:onGesture({ ges = "pan", pos = { x = 210, y = 370 } }))
        assert.equals(0.3, viewer.panel_zoom_settings.panel_gesture_zoom_factor)
        assert.equals(0.6, viewer.scale_factor)
        assert.equals(0, saves)
        viewer:onGesture({ ges = "pan", pos = { x = 210, y = 247 } })
        assert.equals(1.5, viewer.panel_zoom_settings.panel_gesture_zoom_factor)
        assert.equals(3, viewer.scale_factor)
        viewer:onGesture({ ges = "pan", pos = { x = 210, y = 256 } })
        assert.equals(1.4, viewer.panel_zoom_settings.panel_gesture_zoom_factor)
        assert.equals(2.8, viewer.scale_factor)
        viewer:onGesture({ ges = "pan", pos = { x = 100, y = 100 } })
        assert.equals(3, viewer.panel_zoom_settings.panel_gesture_zoom_factor)
        assert.equals(6, viewer.scale_factor)
        viewer:onGesture({ ges = "pan_release" })
        assert.equals(1, saves)
        assert.equals(nil, viewer._zoom_slider_dragging)
        viewer:toggleGestureZoom()
        assert.equals(0, viewer.scale_factor)
        assert.is_true(viewer._scale_to_fit)
        assert.equals(1, updates)
        viewer:onGesture({ ges = "pan", start_pos = { x = 210, y = 200 }, pos = { x = 100, y = 100 } })
        viewer:onGesture({ ges = "swipe", pos = { x = 210, y = 200 }, end_pos = { x = 100, y = 370 } })
        assert.equals(0.3, viewer.panel_zoom_settings.panel_gesture_zoom_factor)
        assert.equals(nil, viewer._zoom_slider_dragging)
        assert.equals(2, saves)
    end)
end)

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
    it("looks up the original OCR word after dragging away from it", function()
        local finder = require("src._wordfinder")
        local old_find, old_read = finder.findWordBox, finder.readWord
        local detected, looked_up
        local ok, err = pcall(function()
            finder.findWordBox = function(_, page, x, y)
                detected = { page = page, x = x, y = y }
                return { x = 40, y = 50, w = 30, h = 20 }
            end
            finder.readWord = function() return "Hello" end
            local highlight = {
                onHold = function() return false end,
                onHoldPan = function(self) self.selected_text = nil; self.is_word_selection = false end,
                _resetHoldTimer = function() end,
                onHoldRelease = function(self)
                    if self.is_word_selection and self.selected_text then looked_up = self.selected_text.text end
                end,
            }
            local viewer = PanelViewer:new({
                panel_zoom_settings = { panel_zoom_enabled = true, panel_zoom_gesture_type = "hold" },
                screenToPageTransform = function(_, pos) return { page = 1, x = pos.x, y = pos.y } end,
                reader_ui = {
                    document = { configurable = { text_wrap = 0 } },
                    highlight = highlight, view = { highlight = { temp = {} } },
                },
            })
            viewer:onGesture({ ges = "hold", pos = { x = 50, y = 60 } })
            viewer:onGesture({ ges = "hold_pan", pos = { x = 200, y = 300 } })
            viewer:onGesture({ ges = "hold_pan", pos = { x = 400, y = 500 } })
            viewer:onGesture({ ges = "hold_release", pos = { x = 400, y = 500 } })
            assert.equals(50, detected.x)
            assert.equals(60, detected.y)
            assert.equals("Hello", looked_up)
            assert.is_nil(viewer._phrase_hold_action)
            assert.is_nil(viewer._gesture_zoom_restore)
        end)
        finder.findWordBox, finder.readWord = old_find, old_read
        if not ok then error(err) end
    end)
    it("uses a hold and drag for text selection instead of toggling zoom", function()
        local start, moved, released, zoomed = nil, 0, 0, 0
        local viewer = PanelViewer:new({
            panel_zoom_settings = { panel_zoom_enabled = true, panel_zoom_gesture_type = "hold" },
            onHold = function(_, _, ges) start = ges.pos end,
            onHoldPan = function() moved = moved + 1 end,
            onHoldRelease = function() released = released + 1 end,
            toggleGestureZoom = function() zoomed = zoomed + 1; return true end,
        })
        local original = { x = 50, y = 60 }
        assert.is_true(viewer:onGesture({ ges = "hold", pos = original }))
        assert.is_true(viewer:onGesture({ ges = "hold_pan", pos = { x = 80, y = 60 } }))
        assert.is_true(viewer:onGesture({ ges = "hold_pan", pos = { x = 100, y = 60 } }))
        assert.is_true(viewer:onGesture({ ges = "hold_release" }))
        assert.equals(original, start)
        assert.equals(0, moved)
        assert.equals(1, released)
        assert.equals(0, zoomed)
        viewer:onGesture({ ges = "hold", pos = original })
        viewer:onGesture({ ges = "hold_release" })
        assert.equals(1, zoomed)
    end)

    it("explains OCR selection when long press is selected", function()
        local manager = require("ui/uimanager")
        local old_tick, old_info = manager.nextTick, package.loaded["ui/widget/infomessage"]
        local scheduled
        manager.nextTick = function(_, callback) scheduled = callback end
        package.loaded["ui/widget/infomessage"] = { new = function(_, options) return options end }
        local ok, err = pcall(function()
            local controller = { settings = {}, saveSettings = function() end }
            require("src.menu").panelZoomItems(controller)[3].callback()
            assert.equals("hold", controller.settings.panel_zoom_gesture_type)
            assert.equals("function", type(scheduled))
            scheduled()
            assert.equals("Important Note: Now long press is used for zoom-in and zoom-out, but OCR Text dictionary look up was using that shortcut, now, to select a word, try with long press + dragging (in any direction). This shortcut override only applies while using long press as zoom-gesture", manager._last_shown.text)
        end)
        manager.nextTick, package.loaded["ui/widget/infomessage"] = old_tick, old_info
        if not ok then error(err) end
    end)
    it("keeps the source buffer alive when a resize reuses it", function()
        local image_viewer = require("ui/widget/imageviewer")
        local previous_clean = image_viewer._clean_image_wg
        local ok, err = pcall(function()
            image_viewer._clean_image_wg = function(self)
                self._image_wg:free()
                self._image_wg = nil
            end
            local freed = 0
            local source = { free = function() freed = freed + 1 end }
            local widget = {
                _bb = source, _bb_disposable = true,
                free = function(self) if self._bb_disposable then self._bb:free() end end,
            }
            local viewer = PanelViewer:new({ image = source, _image_wg = widget })
            viewer:_clean_image_wg()
            assert.equals(0, freed)
            assert.is_nil(viewer._image_wg)
            local scaled = { free = function() freed = freed + 1 end }
            viewer._image_wg = {
                _bb = scaled, _bb_disposable = true,
                free = function(self) if self._bb_disposable then self._bb:free() end end,
            }
            viewer:_clean_image_wg()
            assert.equals(1, freed)
        end)
        image_viewer._clean_image_wg = previous_clean
        if not ok then error(err) end
    end)
    it("moves the slider without zooming and saves or cancels its position", function()
        local saves, returns = 0, 0
        local settings = { panel_zoom_slider_x = 0.4, panel_zoom_slider_y = 0.5 }
        local viewer = PanelViewer:new({
            buttons_visible = true, fullscreen = true, progress_bar_visible = true,
            panel_zoom_settings = settings,
            panel_zoom_save_callback = function() saves = saves + 1 end,
            _zoom_slider_rect = { x = 80, y = 100, w = 40, h = 100 },
            getPanelViewportSize = function() return 400, 600 end,
            update = function() end,
        })
        local function returned() returns = returns + 1 end
        viewer:startZoomSliderPositioning(returned)
        assert.is_false(viewer.buttons_visible)
        viewer:onGesture({ ges = "pan", pos = { x = 380, y = 550 } })
        assert.equals(0.4, settings.panel_zoom_slider_x)
        viewer:finishZoomSliderPositioning(false)
        assert.equals(0.4, settings.panel_zoom_slider_x)
        assert.equals(0, saves)
        assert.is_true(viewer.buttons_visible)
        viewer:startZoomSliderPositioning(returned)
        viewer:onGesture({ ges = "pan", pos = { x = 380, y = 550 } })
        viewer:finishZoomSliderPositioning(true)
        assert.equals(1, settings.panel_zoom_slider_x)
        assert.equals(1, settings.panel_zoom_slider_y)
        assert.equals(1, saves)
        assert.equals(2, returns)
    end)

    it("uses the configured slider limits", function()
        local zoom = require("src._panelzoom")
        local min, max = zoom.range({ panel_zoom_slider_min = 0.1, panel_zoom_slider_max = 8 })
        assert.equals(0.1, min)
        assert.equals(8, max)
        assert.equals(8, zoom.factor(8))
    end)

    it("coalesces slider updates after mouse-wheel zoom and applies the final value", function()
        local image_viewer = require("ui/widget/imageviewer")
        local previous_zoom = image_viewer.onZoomIn
        local ok, err = pcall(function()
            image_viewer.onZoomIn = function(self) self.scale_factor = 3 end
            local renders = 0
            local viewer = PanelViewer:new({
                buttons_visible = true, scale_factor = 0, _scale_factor_0 = 2,
                panel_zoom_settings = { panel_zoom_factor = 1.5 },
                _zoom_slider_rect = { x = 200, y = 100, w = 48, h = 270 },
                _image_wg = { getScaleFactor = function() return 2 end },
                _applyNewScaleFactor = function(self, value) self.scale_factor = value; renders = renders + 1 end,
                update = function() end,
            })
            viewer:onPan(nil, { mousewheel_direction = 1 })
            assert.equals(3, viewer.scale_factor)
            viewer:onGesture({ ges = "pan", pos = { x = 210, y = 247 } })
            assert.equals(3, viewer.scale_factor)
            assert.equals(1, renders)
            viewer:onGesture({ ges = "pan", pos = { x = 210, y = 200 } })
            viewer:onGesture({ ges = "pan", pos = { x = 210, y = 150 } })
            assert.equals(1, renders)
            viewer:onGesture({ ges = "pan_release" })
            assert.equals(2, renders)
            assert.equals(2 * viewer.panel_zoom_settings.panel_zoom_factor, viewer.scale_factor)
        end)
        image_viewer.onZoomIn = previous_zoom
        if not ok then error(err) end
    end)

    it("synchronizes manual zoom with the slider relative to the original view", function()
        local image_viewer = require("ui/widget/imageviewer")
        local old_in, old_out = image_viewer.onZoomIn, image_viewer.onZoomOut
        local ok, err = pcall(function()
            image_viewer.onZoomIn = function(self, inc) self.scale_factor = self.scale_factor * (1 + inc); return true end
            image_viewer.onZoomOut = function(self, dec) self.scale_factor = self.scale_factor * (1 - dec); return true end
            local saves = 0
            local viewer = PanelViewer:new({
                scale_factor = 2, _scale_to_fit = true,
                panel_zoom_settings = { panel_zoom_factor = 1.5 },
                panel_zoom_save_callback = function() saves = saves + 1 end,
                _image_wg = {}, update = function() end,
            })
            viewer:onZoomIn(0.5)
            assert.equals(1.5, viewer.panel_zoom_settings.panel_zoom_factor)
            viewer:onZoomIn(1)
            assert.equals(3, viewer.panel_zoom_settings.panel_zoom_factor)
            viewer:onZoomOut(0.5)
            assert.equals(1.5, viewer.panel_zoom_settings.panel_zoom_factor)
            assert.equals(2, saves)
            viewer:toggleGestureZoom()
            assert.equals(2, viewer.scale_factor)
            assert.is_true(viewer._scale_to_fit)
            viewer.panel_zoom_settings.panel_zoom_mode = "in_config"
            viewer:onZoomIn(1)
            assert.equals(1.5, viewer.panel_zoom_settings.panel_zoom_factor)
        end)
        image_viewer.onZoomIn, image_viewer.onZoomOut = old_in, old_out
        if not ok then error(err) end
    end)

    it("resizes from an edge and persists the dimensions only on save", function()
        local settings = {}
        local viewer = PanelViewer:new({
            buttons_visible = true, panel_zoom_settings = settings,
            _zoom_slider_rect = { x = 100, y = 100, w = 50, h = 200 },
            getPanelViewportSize = function() return 400, 600 end,
            update = function() end,
        })
        viewer:startZoomSliderPositioning(nil, true)
        viewer:onGesture({ ges = "pan", start_pos = { x = 150, y = 200 }, pos = { x = 220, y = 200 } })
        assert.equals(120, viewer._zoom_slider_positioning.width)
        viewer:finishZoomSliderPositioning(false)
        assert.is_nil(settings.panel_zoom_slider_width)
        viewer:startZoomSliderPositioning(nil, true)
        viewer:onGesture({ ges = "pan", start_pos = { x = 150, y = 200 }, pos = { x = 220, y = 200 } })
        viewer:finishZoomSliderPositioning(true)
        assert.equals(0.3, settings.panel_zoom_slider_width)
        assert.equals(200 / 600, settings.panel_zoom_slider_height)
    end)

    it("composites the slider at the configured opacity", function()
        local blit = require("ffi/blitbuffer")
        local old_new, old_text = blit.new, package.loaded["ui/widget/textwidget"]
        local opacity, freed
        blit.new = function()
            return { fill = function() end, paintRect = function() end, free = function() freed = true end }
        end
        package.loaded["ui/widget/textwidget"] = {
            new = function()
                return { getSize = function() return { w = 20, h = 12 } end, paintTo = function() end, free = function() end }
            end,
        }
        local ok, err = pcall(function()
            local viewer = PanelViewer:new({
                buttons_visible = true,
                panel_zoom_settings = { panel_zoom_slider_opacity = 40 },
                _image_wg = { dimen = { x = 0, y = 0, w = 500, h = 600 } },
            })
            viewer:paintZoomSlider({
                getType = function() return 0 end,
                addblitFrom = function(_, _, _, _, _, _, _, _, alpha) opacity = alpha end,
            })
            assert.equals(0.4, opacity)
            assert.is_true(freed)
        end)
        blit.new, package.loaded["ui/widget/textwidget"] = old_new, old_text
        if not ok then error(err) end
    end)
    it("migrates saved zoom settings without overwriting new names", function()
        local settings = require("src._settings").withDefaults({
            panel_gesture_zoom = false,
            panel_zoom_gesture = "hold",
            panel_gesture_zoom_factor = 2,
            panel_zoom_factor = 3,
        })
        assert.is_false(settings.panel_zoom_enabled)
        assert.equals("hold", settings.panel_zoom_gesture_type)
        assert.equals(3, settings.panel_zoom_factor)
        assert.is_nil(settings.panel_gesture_zoom)
        assert.is_nil(settings.panel_zoom_gesture)
        assert.is_nil(settings.panel_gesture_zoom_factor)
    end)
    for _, zoom in ipairs({ "hold", "two_finger_tap", "spread" }) do
        it("zooms and restores with independently selected " .. zoom, function()
            local zoom_calls, updates = 0, 0
            local viewer = PanelViewer:new({
                panel_zoom_settings = {
                    panel_gesture = zoom,
                    panel_zoom_gesture_type = zoom,
                    panel_zoom_enabled = true,
                    panel_zoom_factor = 1.75,
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
            if gesture.ges == "hold" then
                assert.equals(0, zoom_calls)
                assert.is_true(viewer:onGesture({ ges = "hold_release" }))
            end
            assert.equals(1, zoom_calls)
            assert.equals(0.25, viewer._center_x_ratio)
            assert.equals(0.25, viewer._center_y_ratio)
            local saved = viewer._gesture_zoom_restore
            viewer:refreshPanelColors()
            assert.equals(saved, viewer._gesture_zoom_restore)
            assert.equals(1.75, viewer.scale_factor)
            assert.is_true(viewer:onGesture(gesture))
            if gesture.ges == "hold" then
                assert.is_true(viewer:onGesture({ ges = "hold_release" }))
            end
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
            panel_zoom_settings = { panel_gesture = "hold", panel_zoom_enabled = false },
            dispatchReaderGesture = function()
                forwarded = forwarded + 1
                return true
            end,
            toggleGestureZoom = function()
                error("Unexpected zoom")
            end,
        })
        viewer:onGesture({ ges = "two_finger_tap" })
        viewer.panel_zoom_settings.panel_zoom_enabled = true
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
        assert.equals(8, #items)
        assert.equals("Disabled", items[1].mandatory_func())
        items[1].callback()
        assert.equals("Enabled", menu.panelZoomItems(controller)[1].mandatory_func())
        assert.is_true(items[5].checked_func())
        for index, gesture in ipairs({ "hold", "two_finger_tap", "spread" }) do
            items[index + 2].callback()
            assert.equals(gesture, controller.settings.panel_zoom_gesture_type)
            for other = 3, 5 do
                assert.equals(other == index + 2, items[other].checked_func())
            end
        end
        assert.equals(4, saves)
        items[8].callback()
        assert.equals("in_config", controller.settings.panel_zoom_mode)
        assert.equals(16, #items)
        items[16].callback()
        assert.equals(5, controller.settings.panel_zoom_factor)
        assert.equals(5, require("src._panelzoom").factor(controller.settings.panel_zoom_factor))
        items[7].callback()
        assert.equals(8, #items)
    end)

    it("keeps the settings proxy empty, live in both directions, and rejects other settings", function()
        local settings = {
            mode = "manga",
            panel_zoom_enabled = false,
            panel_zoom_gesture_type = "spread",
            panel_zoom_factor = 1.5,
        }
        local proxy = require("src._panelzoom").proxy(settings)
        assert.equals(nil, next(proxy))
        assert.equals(nil, proxy.mode)
        assert.is_false(pcall(function()
            proxy.mode = "comic"
        end))
        assert.equals("manga", settings.mode)
        for key, value in pairs({
            panel_zoom_enabled = true,
            panel_zoom_gesture_type = "hold",
            panel_zoom_factor = 2.35,
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
                labels.colors = labels.colors or {}
                labels.colors[#labels.colors + 1] = options.fgcolor
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
                panel_zoom_settings = { panel_zoom_factor = 1.75 },
                _image_wg = { dimen = image_rect },
            })
            local bb = {
                paintRect = function(_, x, y, w, h, color)
                    paints[#paints + 1] = { x = x, y = y, w = w, h = h, color = color }
                end,
            }
            viewer:paintZoomSlider(bb)
            assert.equals(500, image_rect.w)
            assert.equals(600, image_rect.h)
            local slider = viewer._zoom_slider_rect
            assert.equals(64, slider.w)
            assert.equals(320, slider.h)
            assert.equals(12, image_rect.x + image_rect.w - slider.x - slider.w)
            assert.equals(12, image_rect.y + image_rect.h - slider.y - slider.h)
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
            local Blitbuffer = require("ffi/blitbuffer")
            assert.equals(Blitbuffer.COLOR_DARK_GRAY, paints[1].color)
            assert.equals(Blitbuffer.COLOR_DARK_GRAY, labels.colors[1])
            viewer._gesture_zoom_restore = {}
            viewer:paintZoomSlider(bb)
            assert.equals(Blitbuffer.COLOR_BLACK, paints[10].color)
            assert.equals(Blitbuffer.COLOR_BLACK, labels.colors[4])
            viewer.panel_zoom_settings.panel_zoom_mode = "in_config"
            viewer:paintZoomSlider(bb)
            assert.is_nil(viewer._zoom_slider_rect)
            assert.equals(18, #paints)
            viewer.buttons_visible = false
            viewer:paintZoomSlider(bb)
            assert.equals(nil, viewer._zoom_slider_rect)
            assert.equals(18, #paints)
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
        assert.is_true(viewer:handleZoomSliderGesture({ ges = "touch", pos = { x = 210, y = 200 } }))
        assert.is_true(viewer:handleZoomSliderGesture({ ges = "tap", pos = { x = 210, y = 200 } }))
        assert.is_nil(viewer._zoom_slider_dragging)
        assert.is_false(viewer:handleZoomSliderGesture({ ges = "touch", pos = { x = 50, y = 200 } }))
        assert.equals(1, saves)
        viewer:handleZoomSliderGesture({ ges = "touch", pos = { x = 210, y = 200 } })
        viewer:handleZoomSliderGesture({ ges = "hold", pos = { x = 210, y = 200 } })
        viewer:handleZoomSliderGesture({ ges = "hold_release", pos = { x = 210, y = 200 } })
        assert.is_nil(viewer._zoom_slider_dragging)
        viewer:handleZoomSliderGesture({ ges = "touch", pos = { x = 210, y = 200 } })
        assert.is_false(viewer:handleZoomSliderGesture({ ges = "touch", pos = { x = 50, y = 200 } }))
        assert.is_false(viewer:handleZoomSliderGesture({ ges = "hold", pos = { x = 50, y = 200 } }))
        saves = 0
        updates = 0
        assert.is_true(viewer:onGesture({ ges = "pan", pos = { x = 210, y = 370 } }))
        assert.equals(0.3, viewer.panel_zoom_settings.panel_zoom_factor)
        assert.equals(0.6, viewer.scale_factor)
        assert.equals(0, saves)
        viewer:onGesture({ ges = "pan", pos = { x = 210, y = 247 } })
        assert.equals(1.5, viewer.panel_zoom_settings.panel_zoom_factor)
        assert.equals(0.6, viewer.scale_factor)
        local pending = viewer._zoom_slider_pending
        viewer:onGesture({ ges = "pan", pos = { x = 210, y = 256 } })
        assert.equals(1.4, viewer.panel_zoom_settings.panel_zoom_factor)
        assert.equals(pending, viewer._zoom_slider_pending)
        assert.equals(0.6, viewer.scale_factor)
        local previous_updates = updates
        viewer:onGesture({ ges = "pan", pos = { x = 210, y = 256 } })
        assert.equals(previous_updates, updates)
        viewer:onGesture({ ges = "pan", pos = { x = 100, y = 100 } })
        assert.equals(1.4, viewer.panel_zoom_settings.panel_zoom_factor)
        assert.equals(0.6, viewer.scale_factor)
        viewer:onGesture({ ges = "pan_release" })
        assert.equals(2.8, viewer.scale_factor)
        assert.is_nil(viewer._zoom_slider_pending)
        assert.equals(1, saves)
        assert.equals(nil, viewer._zoom_slider_dragging)
        viewer:toggleGestureZoom()
        assert.equals(0, viewer.scale_factor)
        assert.is_true(viewer._scale_to_fit)
        assert.equals(1, updates)
        viewer:onGesture({ ges = "pan", start_pos = { x = 210, y = 200 }, pos = { x = 100, y = 100 } })
        viewer:onGesture({ ges = "swipe", pos = { x = 210, y = 200 }, end_pos = { x = 100, y = 370 } })
        assert.equals(1.4, viewer.panel_zoom_settings.panel_zoom_factor)
        assert.equals(nil, viewer._zoom_slider_dragging)
        assert.equals(2, saves)
    end)
end)

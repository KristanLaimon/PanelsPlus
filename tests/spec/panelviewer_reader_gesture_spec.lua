--[[
Panels+
File: tests/spec/panelviewer_reader_gesture_spec.lua
Name: PanelViewer reader-gesture specs
Description: Verifies safe forwarding of KOReader gestures and stale-document cleanup.
Author: KristanLaimon
Year: 2026
Copyright (c) 2026 KristanLaimon
License: MIT; see the repository LICENSE file.
SPDX-License-Identifier: MIT
]]
--- Regression coverage for reader-menu gestures arriving after their document
--- has closed, or failing inside reader-owned code.

local framework = require("tests.PanelsPlusTestFramework")
local describe, it, assert, spy = framework.describe, framework.it, framework.assert, framework.spy

local PanelViewer = require("src._panelviewer")
local ImageViewer = require("ui/widget/imageviewer")

local function newViewer(reader_ui, close_spy)
    return setmetatable({
        reader_ui = reader_ui,
        isOpen = function()
            return true
        end,
        onClose = close_spy,
    }, { __index = PanelViewer })
end

describe("PanelViewer reader gesture lifecycle", function()
    it("closes and consumes a stale reader gesture after document closure", function()
        local close_spy, handler_spy = spy(), spy()
        local viewer = newViewer({ document = nil }, close_spy)

        local handled = viewer:runReaderGestureHandler(handler_spy, {})

        assert.is_true(handled)
        assert.equals(1, close_spy:callCount())
        assert.is_false(handler_spy:called())
    end)

    it("does not dispatch cached touch zones after document closure", function()
        local close_spy, handler_spy = spy(), spy()
        local viewer = newViewer({
            document = nil,
            gestures = {},
            _ordered_touch_zones = {
                {
                    def = { id = "readermenu_ext_tap" },
                    handler = handler_spy,
                    gs_range = {
                        match = function()
                            return true
                        end,
                    },
                },
            },
        }, close_spy)
        viewer.isImagePannable = function()
            return false
        end

        local handled = viewer:dispatchReaderGesture({})

        assert.is_true(handled)
        assert.equals(1, close_spy:callCount())
        assert.is_false(handler_spy:called())
    end)

    it("closes instead of rethrowing a reader gesture handler failure", function()
        local close_spy = spy()
        local viewer = newViewer({ document = {} }, close_spy)

        local handled = viewer:runReaderGestureHandler(function()
            error("reader menu unavailable")
        end, {})

        assert.is_true(handled)
        assert.equals(1, close_spy:callCount())
    end)
end)

describe("PanelViewer bundled OCR selection", function()
    it("uses the selected language for KOReader's initial hold and restores its settings", function()
        local seen = {}
        local document = {
            configurable = { doc_language = "jpn" },
            koptinterface = { tessocr_data = "/reader/tessdata" },
        }
        local view = { screenToPageTransform = function() end }
        local highlight = {
            panel_zoom_enabled = true,
            onHold = function(self)
                seen.language = document.configurable.doc_language
                seen.datadir = document.koptinterface.tessocr_data
                self.selected_text = { text = "hola", sboxes = {} }
                self.is_word_selection = true
                return true
            end,
        }
        local viewer = newViewer({ document = document, view = view, highlight = highlight })
        viewer.ocr_bundled_language = "spa"
        viewer.screenToPageTransform = function()
            return { page = 1, x = 5, y = 5 }
        end

        assert.is_true(viewer:onHold(nil, { pos = {} }))
        assert.equals("spa_fast", seen.language)
        assert.is_true(seen.datadir:match("/data/ocr$") ~= nil)
        assert.equals("jpn", document.configurable.doc_language)
        assert.equals("/reader/tessdata", document.koptinterface.tessocr_data)
        assert.is_true(highlight.panel_zoom_enabled)
    end)

    it("accepts the selected-text state from older KOReader hold handlers", function()
        local document = { configurable = { text_wrap = 0 } }
        local view = {
            screenToPageTransform = function()
                return nil
            end,
            highlight = { temp = {} },
        }
        local highlight = {
            panel_zoom_enabled = true,
            onHold = function(self)
                -- Older builds may complete selection without returning true.
                self.selected_text = { text = "legacy", sboxes = {} }
                self.is_word_selection = true
            end,
        }
        local viewer = newViewer({ document = document, view = view, highlight = highlight })
        viewer.screenToPageTransform = function()
            return { page = 1, x = 5, y = 5 }
        end

        assert.is_true(viewer:onHold(nil, { pos = {} }))
        assert.is_true(viewer._panels_plus_text_holding)
    end)

    it("does not start ImageViewer panning after an unsuccessful OCR hold", function()
        local document = { configurable = { text_wrap = 0 } }
        local view = {
            screenToPageTransform = function()
                return nil
            end,
            highlight = { temp = {} },
        }
        local highlight = {
            panel_zoom_enabled = true,
            onHold = function()
                return false
            end,
        }
        local viewer = newViewer({ document = document, view = view, highlight = highlight })
        viewer.screenToPageTransform = function()
            return { page = 1, x = 5, y = 5 }
        end
        local original_on_hold = ImageViewer.onHold
        local original_on_hold_release = ImageViewer.onHoldRelease
        local image_hold_called = false
        local image_hold_release_called = false
        ImageViewer.onHold = function()
            image_hold_called = true
            return true
        end
        ImageViewer.onHoldRelease = function()
            image_hold_release_called = true
            return true
        end

        local handled = viewer:onHold(nil, { pos = {} })
        local released = viewer:onHoldRelease(nil, { pos = {} })
        ImageViewer.onHold = original_on_hold
        ImageViewer.onHoldRelease = original_on_hold_release

        assert.is_true(handled)
        assert.is_true(released)
        assert.is_false(image_hold_called)
        assert.is_false(image_hold_release_called)
        assert.is_nil(viewer._panels_plus_text_holding)
    end)
end)

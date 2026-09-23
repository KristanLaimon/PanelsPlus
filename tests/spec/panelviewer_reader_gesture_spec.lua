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
            onHold = function()
                seen.language = document.configurable.doc_language
                seen.datadir = document.koptinterface.tessocr_data
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
end)

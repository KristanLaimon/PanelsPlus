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

--[[
Panels+
File: tests/spec/panelviewer_keyboard_nav_spec.lua
Name: PanelViewer keyboard-navigation specs
Description: Verifies direction-aware keyboard navigation and key-repeat behavior.
Author: KristanLaimon
Year: 2026
Copyright (c) 2026 KristanLaimon
License: MIT; see the repository LICENSE file.
SPDX-License-Identifier: MIT
]]
local framework = require("tests.PanelsPlusTestFramework")
local describe, it, assert, spy = framework.describe, framework.it, framework.assert, framework.spy

local PanelViewer = require("src._panelviewer")

describe("PanelViewer keyboard navigation with A/D and Left/Right keys", function()
    it("navigates forward with D/Right and backward with A/Left in comic mode", function()
        local next_spy, prev_spy = spy(), spy()
        local viewer = PanelViewer:new({
            reading_mode = "comic",
            onShowNextImage = next_spy,
            onShowPrevImage = prev_spy,
        })

        viewer:onPanelNavRight()
        assert.equals(1, next_spy:callCount())
        assert.equals(0, prev_spy:callCount())

        viewer:onPanelNavLeft()
        assert.equals(1, next_spy:callCount())
        assert.equals(1, prev_spy:callCount())
    end)

    it("navigates forward with A/Left and backward with D/Right in manga mode", function()
        local next_spy, prev_spy = spy(), spy()
        local viewer = PanelViewer:new({
            reading_mode = "manga",
            onShowNextImage = next_spy,
            onShowPrevImage = prev_spy,
        })

        viewer:onPanelNavLeft()
        assert.equals(1, next_spy:callCount())
        assert.equals(0, prev_spy:callCount())

        viewer:onPanelNavRight()
        assert.equals(1, next_spy:callCount())
        assert.equals(1, prev_spy:callCount())
    end)

    it("turns pages forward with D and Right arrow, backward with A and Left arrow in comic mode", function()
        local next_spy, prev_spy = spy(), spy()
        local viewer = PanelViewer:new({
            reading_mode = "comic",
            onShowNextImage = next_spy,
            onShowPrevImage = prev_spy,
        })

        viewer:onKeyPress("D")
        viewer:onKeyPress("Right")
        assert.equals(2, next_spy:callCount())
        assert.equals(0, prev_spy:callCount())

        viewer:onKeyPress("A")
        viewer:onKeyPress("Left")
        assert.equals(2, next_spy:callCount())
        assert.equals(2, prev_spy:callCount())
    end)

    it("turns pages forward with A and Left arrow, backward with D and Right arrow in manga mode", function()
        local next_spy, prev_spy = spy(), spy()
        local viewer = PanelViewer:new({
            reading_mode = "manga",
            onShowNextImage = next_spy,
            onShowPrevImage = prev_spy,
        })

        viewer:onKeyPress("A")
        viewer:onKeyPress("Left")
        assert.equals(2, next_spy:callCount())
        assert.equals(0, prev_spy:callCount())

        viewer:onKeyPress("D")
        viewer:onKeyPress("Right")
        assert.equals(2, next_spy:callCount())
        assert.equals(2, prev_spy:callCount())
    end)

    it("handles Key objects and onKeyRepeat for Left, Right, A, and D", function()
        local next_spy, prev_spy = spy(), spy()
        local viewer = PanelViewer:new({
            reading_mode = "comic",
            onShowNextImage = next_spy,
            onShowPrevImage = prev_spy,
        })

        viewer:onKeyPress({ key = "Right" })
        viewer:onKeyPress({ key = "D" })
        viewer:onKeyRepeat("Right")
        viewer:onKeyRepeat("D")
        assert.equals(4, next_spy:callCount())
        assert.equals(0, prev_spy:callCount())

        viewer:onKeyPress({ key = "Left" })
        viewer:onKeyPress({ key = "A" })
        viewer:onKeyRepeat("Left")
        viewer:onKeyRepeat("A")
        assert.equals(4, next_spy:callCount())
        assert.equals(4, prev_spy:callCount())
    end)

    it("crosses document page boundaries with Left, Right, A, and D", function()
        local boundary_spy = spy()
        boundary_spy.return_value = true

        -- Last panel in comic mode: D and Right cross to next page
        local viewer_last = PanelViewer:new({
            reading_mode = "comic",
            _images_list_cur = 3,
            _images_list_nb = 3,
            boundary_callback = boundary_spy,
        })

        viewer_last:onKeyPress("D")
        assert.is_true(boundary_spy:called())
        assert.equals("next", boundary_spy:lastCall()[1])

        viewer_last:onKeyPress("Right")
        assert.equals(2, boundary_spy:callCount())
        assert.equals("next", boundary_spy:lastCall()[1])

        -- First panel in comic mode: A and Left cross to previous page
        local viewer_first = PanelViewer:new({
            reading_mode = "comic",
            _images_list_cur = 1,
            _images_list_nb = 3,
            boundary_callback = boundary_spy,
        })

        viewer_first:onKeyPress("A")
        assert.equals(3, boundary_spy:callCount())
        assert.equals("previous", boundary_spy:lastCall()[1])

        viewer_first:onKeyPress("Left")
        assert.equals(4, boundary_spy:callCount())
        assert.equals("previous", boundary_spy:lastCall()[1])
    end)

    it("handles onKeyPress strings for A, a, D, d, Left, Right in comic mode", function()
        local next_spy, prev_spy = spy(), spy()
        local viewer = PanelViewer:new({
            reading_mode = "comic",
            onShowNextImage = next_spy,
            onShowPrevImage = prev_spy,
        })

        viewer:onKeyPress("D")
        viewer:onKeyPress("d")
        viewer:onKeyPress("Right")
        assert.equals(3, next_spy:callCount())
        assert.equals(0, prev_spy:callCount())

        viewer:onKeyPress("A")
        viewer:onKeyPress("a")
        viewer:onKeyPress("Left")
        assert.equals(3, next_spy:callCount())
        assert.equals(3, prev_spy:callCount())
    end)

    it("handles onKeyPress strings for A, a, D, d, Left, Right in manga mode", function()
        local next_spy, prev_spy = spy(), spy()
        local viewer = PanelViewer:new({
            reading_mode = "manga",
            onShowNextImage = next_spy,
            onShowPrevImage = prev_spy,
        })

        viewer:onKeyPress("A")
        viewer:onKeyPress("a")
        viewer:onKeyPress("Left")
        assert.equals(3, next_spy:callCount())
        assert.equals(0, prev_spy:callCount())

        viewer:onKeyPress("D")
        viewer:onKeyPress("d")
        viewer:onKeyPress("Right")
        assert.equals(3, next_spy:callCount())
        assert.equals(3, prev_spy:callCount())
    end)

    it("handles onKeyPress with Key objects and ignores modified chords", function()
        local next_spy, prev_spy = spy(), spy()
        local viewer = PanelViewer:new({
            reading_mode = "comic",
            onShowNextImage = next_spy,
            onShowPrevImage = prev_spy,
        })

        -- Plain key press
        viewer:onKeyPress({ key = "Right" })
        assert.equals(1, next_spy:callCount())

        -- Key press with inactive modifiers
        viewer:onKeyPress({ key = "D", modifiers = { Ctrl = false, Shift = false } })
        assert.equals(2, next_spy:callCount())

        -- Key press with active modifier (Ctrl+D) should not trigger panel navigation
        viewer:onKeyPress({ key = "D", modifiers = { Ctrl = true } })
        assert.equals(2, next_spy:callCount())
    end)

    it("handles onKeyRepeat identically to onKeyPress", function()
        local next_spy, prev_spy = spy(), spy()
        local viewer = PanelViewer:new({
            reading_mode = "manga",
            onShowNextImage = next_spy,
            onShowPrevImage = prev_spy,
        })

        viewer:onKeyRepeat("Left")
        assert.equals(1, next_spy:callCount())

        viewer:onKeyRepeat("Right")
        assert.equals(1, prev_spy:callCount())
    end)

    it("routes onCursorPan left and right to panel navigation", function()
        local next_spy, prev_spy = spy(), spy()
        local viewer = PanelViewer:new({
            reading_mode = "comic",
            onShowNextImage = next_spy,
            onShowPrevImage = prev_spy,
        })

        viewer:onCursorPan("right")
        assert.equals(1, next_spy:callCount())
        assert.equals(0, prev_spy:callCount())

        viewer:onCursorPan("left")
        assert.equals(1, next_spy:callCount())
        assert.equals(1, prev_spy:callCount())
    end)

    it("dynamically adapts when reading_mode toggles at runtime", function()
        local next_spy, prev_spy = spy(), spy()
        local viewer = PanelViewer:new({
            reading_mode = "comic",
            onShowNextImage = next_spy,
            onShowPrevImage = prev_spy,
        })

        viewer:onKeyPress("D")
        assert.equals(1, next_spy:callCount())
        assert.equals(0, prev_spy:callCount())

        -- Switch to manga mode
        viewer.reading_mode = "manga"
        viewer:onKeyPress("D")
        assert.equals(1, next_spy:callCount())
        assert.equals(1, prev_spy:callCount())

        viewer:onKeyPress("A")
        assert.equals(2, next_spy:callCount())
        assert.equals(1, prev_spy:callCount())
    end)

    it("navigates panels while zoomed in (isImagePannable returns true)", function()
        local next_spy, prev_spy = spy(), spy()
        local viewer = PanelViewer:new({
            reading_mode = "comic",
            isImagePannable = function()
                return true
            end,
            onShowNextImage = next_spy,
            onShowPrevImage = prev_spy,
        })

        assert.is_true(viewer:isImagePannable())
        viewer:onKeyPress("Right")
        assert.equals(1, next_spy:callCount())
        viewer:onKeyPress("Left")
        assert.equals(1, prev_spy:callCount())
    end)

    it("initializes PanelNavLeft and PanelNavRight in key_events and removes PanLeft/PanRight", function()
        local viewer = PanelViewer:new({})
        viewer:init()

        assert.is_not_nil(viewer.key_events)
        assert.is_not_nil(viewer.key_events.PanelNavLeft)
        assert.is_not_nil(viewer.key_events.PanelNavRight)
        assert.is_nil(viewer.key_events.PanLeft)
        assert.is_nil(viewer.key_events.PanRight)
    end)
end)

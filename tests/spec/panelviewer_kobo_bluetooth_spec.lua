--[[
Panels+
File: tests/spec/panelviewer_kobo_bluetooth_spec.lua
Name: Kobo and Bluetooth navigation specs
Description: Verifies physical-button and remote navigation across panels and pages.
Author: KristanLaimon
Year: 2026
Copyright (c) 2026 KristanLaimon
License: MIT; see the repository LICENSE file.
SPDX-License-Identifier: MIT
]]
--- Regression prevention suite for Kobo physical buttons and Bluetooth page turners.

local framework = require("tests.PanelsPlusTestFramework")
local describe, it, assert, spy = framework.describe, framework.it, framework.assert, framework.spy

require("tests.spec.helper")
local PanelViewer = require("src._panelviewer")

local function makeSpy(ret)
    local s = spy()
    s.return_value = ret ~= nil and ret or true
    return s
end

describe("Kobo physical button and Bluetooth reader action handlers", function()
    it("routes all forward action methods to onShowNextImage and returns truthy", function()
        local next_spy, prev_spy = makeSpy(true), makeSpy(true)
        local viewer = PanelViewer:new({ onShowNextImage = next_spy, onShowPrevImage = prev_spy })

        assert.is_true(viewer:onGotoNextPage())
        assert.is_true(viewer:onPageForward())
        assert.is_true(viewer:onShowNextPage())
        assert.is_true(viewer:onPhysicalPageForward())
        assert.is_true(viewer:onNextPage())

        assert.equals(5, next_spy:callCount())
        assert.is_false(prev_spy:called())
    end)

    it("routes all backward action methods to onShowPrevImage and returns truthy", function()
        local next_spy, prev_spy = makeSpy(true), makeSpy(true)
        local viewer = PanelViewer:new({ onShowNextImage = next_spy, onShowPrevImage = prev_spy })

        assert.is_true(viewer:onGotoPrevPage())
        assert.is_true(viewer:onPageBackward())
        assert.is_true(viewer:onShowPrevPage())
        assert.is_true(viewer:onPhysicalPageBackward())
        assert.is_true(viewer:onPrevPage())

        assert.is_false(next_spy:called())
        assert.equals(5, prev_spy:callCount())
    end)

    it("routes relative page and position jump events through onGotoViewRel", function()
        local next_spy, prev_spy = makeSpy(true), makeSpy(true)
        local viewer = PanelViewer:new({ onShowNextImage = next_spy, onShowPrevImage = prev_spy })

        assert.is_true(viewer:onGotoPageRel(1))
        assert.is_true(viewer:onGotoPageRel(25))
        assert.is_true(viewer:onGotoPosRel(1))
        assert.is_true(viewer:onGotoPosRel(10))

        assert.is_true(viewer:onGotoPageRel(-1))
        assert.is_true(viewer:onGotoPageRel(-25))
        assert.is_true(viewer:onGotoPosRel(-1))
        assert.is_true(viewer:onGotoPosRel(-10))

        assert.equals(4, next_spy:callCount())
        assert.equals(4, prev_spy:callCount())
    end)

    it("handles zero and nil relative diffs safely without moving", function()
        local next_spy, prev_spy = spy(), spy()
        local viewer = PanelViewer:new({ onShowNextImage = next_spy, onShowPrevImage = prev_spy })

        assert.is_true(viewer:onGotoViewRel(0))
        assert.is_true(viewer:onGotoViewRel(nil))
        assert.is_true(viewer:onGotoPageRel(0))
        assert.is_true(viewer:onGotoPageRel(nil))
        assert.is_true(viewer:onGotoPosRel(0))
        assert.is_true(viewer:onGotoPosRel(nil))

        assert.is_false(next_spy:called())
        assert.is_false(prev_spy:called())
    end)
end)

describe("Kobo key_events table initialization and conflict prevention", function()
    it("initializes ShowNextImage, ShowPrevImage, Close, and Home in key_events", function()
        local viewer = PanelViewer:new({})
        viewer:init()

        assert.is_not_nil(viewer.key_events)
        assert.is_not_nil(viewer.key_events.ShowPrevImage)
        assert.is_not_nil(viewer.key_events.ShowNextImage)
        assert.is_not_nil(viewer.key_events.Close)
        assert.is_not_nil(viewer.key_events.Home)
    end)

    it("explicitly clears ZoomIn, ZoomOut, PanLeft, and PanRight to prevent ImageViewer key conflicts", function()
        local viewer = PanelViewer:new({})
        viewer:init()

        assert.is_nil(viewer.key_events.ZoomIn)
        assert.is_nil(viewer.key_events.ZoomOut)
        assert.is_nil(viewer.key_events.PanLeft)
        assert.is_nil(viewer.key_events.PanRight)
    end)

    it("loads custom Device.input.group physical buttons dynamically", function()
        local ok_dev, Device = pcall(require, "device")
        assert.is_true(ok_dev and Device ~= nil)

        local orig_input = Device.input
        Device.input = {
            group = {
                PgFwd = { "CustomKoboPgFwd1", "CustomKoboPgFwd2" },
                PgBack = { "CustomKoboPgBack1", "CustomKoboPgBack2" },
                Back = { "CustomBack" },
            },
        }

        local viewer = PanelViewer:new({})
        viewer:init()

        assert.is_not_nil(viewer.key_events.ShowNextImage)
        assert.is_not_nil(viewer.key_events.ShowPrevImage)
        assert.equals(Device.input.group.PgFwd, viewer.key_events.ShowNextImage[1][1])
        assert.equals(Device.input.group.PgBack, viewer.key_events.ShowPrevImage[1][1])

        -- Restore original Device.input
        Device.input = orig_input
    end)
end)

describe("Kobo physical button onKeyPress and onKeyRepeat handling", function()
    it("advances panel on LPgFwd and RPgFwd string and Key objects", function()
        local next_spy, prev_spy = spy(), spy()
        local viewer = PanelViewer:new({ onShowNextImage = next_spy, onShowPrevImage = prev_spy })

        viewer:onKeyPress("LPgFwd")
        viewer:onKeyPress("RPgFwd")
        viewer:onKeyPress({ key = "LPgFwd" })
        viewer:onKeyPress({ key = "RPgFwd" })

        assert.equals(4, next_spy:callCount())
        assert.is_false(prev_spy:called())
    end)

    it("retreats panel on LPgBack and RPgBack string and Key objects", function()
        local next_spy, prev_spy = spy(), spy()
        local viewer = PanelViewer:new({ onShowNextImage = next_spy, onShowPrevImage = prev_spy })

        viewer:onKeyPress("LPgBack")
        viewer:onKeyPress("RPgBack")
        viewer:onKeyPress({ key = "LPgBack" })
        viewer:onKeyPress({ key = "RPgBack" })

        assert.is_false(next_spy:called())
        assert.equals(4, prev_spy:callCount())
    end)

    it("repeats panel navigation on physical button onKeyRepeat", function()
        local next_spy, prev_spy = spy(), spy()
        local viewer = PanelViewer:new({ onShowNextImage = next_spy, onShowPrevImage = prev_spy })

        viewer:onKeyRepeat("LPgFwd")
        viewer:onKeyRepeat({ key = "RPgFwd" })
        viewer:onKeyRepeat("LPgBack")
        viewer:onKeyRepeat({ key = "RPgBack" })

        assert.equals(2, next_spy:callCount())
        assert.equals(2, prev_spy:callCount())
    end)

    it("dispatches custom keys from Device.input.group onKeyPress", function()
        local ok_dev, Device = pcall(require, "device")
        assert.is_true(ok_dev and Device ~= nil)

        local orig_input = Device.input
        Device.input = {
            group = {
                PgFwd = { "KoboHardwareFwd" },
                PgBack = { "KoboHardwareBack" },
            },
        }

        local next_spy, prev_spy = spy(), spy()
        local viewer = PanelViewer:new({ onShowNextImage = next_spy, onShowPrevImage = prev_spy })

        viewer:onKeyPress("KoboHardwareFwd")
        viewer:onKeyPress({ key = "KoboHardwareFwd" })
        viewer:onKeyPress("KoboHardwareBack")
        viewer:onKeyPress({ key = "KoboHardwareBack" })

        assert.equals(2, next_spy:callCount())
        assert.equals(2, prev_spy:callCount())

        Device.input = orig_input
    end)

    it("rejects physical button presses with active modifier chords", function()
        local next_spy, prev_spy = spy(), spy()
        local viewer = PanelViewer:new({ onShowNextImage = next_spy, onShowPrevImage = prev_spy })

        viewer:onKeyPress({ key = "LPgFwd", modifiers = { Ctrl = true } })
        viewer:onKeyPress({ key = "RPgFwd", modifiers = { Alt = true } })
        viewer:onKeyPress({ key = "LPgBack", modifiers = { Shift = true } })

        assert.is_false(next_spy:called())
        assert.is_false(prev_spy:called())

        -- Inactive modifiers should still navigate
        viewer:onKeyPress({ key = "LPgFwd", modifiers = { Ctrl = false, Alt = false } })
        viewer:onKeyPress({ key = "LPgBack", modifiers = { Shift = false } })

        assert.equals(1, next_spy:callCount())
        assert.equals(1, prev_spy:callCount())
    end)
end)

describe("Bluetooth device page-turners and remote clickers", function()
    it("advances panel on PageDown and Space string and Key objects", function()
        local next_spy, prev_spy = spy(), spy()
        local viewer = PanelViewer:new({ onShowNextImage = next_spy, onShowPrevImage = prev_spy })

        viewer:onKeyPress("PageDown")
        viewer:onKeyPress({ key = "PageDown" })
        viewer:onKeyPress(" ")
        viewer:onKeyPress({ key = " " })

        assert.equals(4, next_spy:callCount())
        assert.is_false(prev_spy:called())
    end)

    it("retreats panel on PageUp string and Key objects", function()
        local next_spy, prev_spy = spy(), spy()
        local viewer = PanelViewer:new({ onShowNextImage = next_spy, onShowPrevImage = prev_spy })

        viewer:onKeyPress("PageUp")
        viewer:onKeyPress({ key = "PageUp" })

        assert.is_false(next_spy:called())
        assert.equals(2, prev_spy:callCount())
    end)

    it("repeats panel navigation on Bluetooth onKeyRepeat", function()
        local next_spy, prev_spy = spy(), spy()
        local viewer = PanelViewer:new({ onShowNextImage = next_spy, onShowPrevImage = prev_spy })

        viewer:onKeyRepeat("PageDown")
        viewer:onKeyRepeat(" ")
        viewer:onKeyRepeat("PageUp")

        assert.equals(2, next_spy:callCount())
        assert.equals(1, prev_spy:callCount())
    end)

    it("integrates with kobo.koplugin Bluetooth essential actions", function()
        -- kobo.koplugin binds Bluetooth devices to 'GotoViewRel' with args 1 (next_page) and -1 (prev_page)
        local next_spy, prev_spy = makeSpy(true), makeSpy(true)
        local viewer = PanelViewer:new({ onShowNextImage = next_spy, onShowPrevImage = prev_spy })

        local next_action = { id = "next_page", event = "GotoViewRel", args = 1 }
        local prev_action = { id = "prev_page", event = "GotoViewRel", args = -1 }

        assert.is_true(viewer:onGotoViewRel(next_action.args))
        assert.is_true(viewer:onGotoViewRel(prev_action.args))

        assert.equals(1, next_spy:callCount())
        assert.equals(1, prev_spy:callCount())
    end)

    it("rejects Bluetooth keys when active modifiers are pressed", function()
        local next_spy, prev_spy = makeSpy(true), makeSpy(true)
        local viewer = PanelViewer:new({ onShowNextImage = next_spy, onShowPrevImage = prev_spy })

        viewer:onKeyPress({ key = "PageDown", modifiers = { Ctrl = true } })
        viewer:onKeyPress({ key = "PageUp", modifiers = { Alt = true } })
        viewer:onKeyPress({ key = " ", modifiers = { Shift = true } })

        assert.is_false(next_spy:called())
        assert.is_false(prev_spy:called())
    end)
end)

describe("End-to-end boundary page-crossing via Kobo and Bluetooth triggers", function()
    it("crosses to the next page when at the last panel via physical buttons and Bluetooth keys", function()
        local triggers = {
            function(v)
                return v:onPhysicalPageForward()
            end,
            function(v)
                return v:onPageForward()
            end,
            function(v)
                return v:onGotoNextPage()
            end,
            function(v)
                return v:onNextPage()
            end,
            function(v)
                return v:onShowNextPage()
            end,
            function(v)
                return v:onGotoViewRel(1)
            end,
            function(v)
                return v:onGotoPageRel(1)
            end,
            function(v)
                return v:onGotoPosRel(1)
            end,
            function(v)
                return v:onKeyPress("LPgFwd")
            end,
            function(v)
                return v:onKeyPress("RPgFwd")
            end,
            function(v)
                return v:onKeyPress("PageDown")
            end,
            function(v)
                return v:onKeyPress(" ")
            end,
        }

        for index, trigger in ipairs(triggers) do
            local boundary_spy = makeSpy(true)
            local viewer = PanelViewer:new({
                _images_list_cur = 3,
                _images_list_nb = 3,
                nav_transition_mode = "classic",
                boundary_callback = boundary_spy,
            })

            local handled = trigger(viewer)
            assert.is_true(handled, "Trigger #" .. index .. " must return truthy")
            assert.is_true(
                boundary_spy:called(),
                "Trigger #" .. index .. " must trigger boundary_callback at last panel"
            )
            local call = boundary_spy:lastCall()
            assert.equals("next", call[1], "Trigger #" .. index .. " must specify 'next' boundary direction")
            assert.equals(viewer, call[2], "Trigger #" .. index .. " must pass viewer instance to boundary_callback")
        end
    end)

    it("crosses to the previous page when at the first panel via physical buttons and Bluetooth keys", function()
        local triggers = {
            function(v)
                return v:onPhysicalPageBackward()
            end,
            function(v)
                return v:onPageBackward()
            end,
            function(v)
                return v:onGotoPrevPage()
            end,
            function(v)
                return v:onPrevPage()
            end,
            function(v)
                return v:onShowPrevPage()
            end,
            function(v)
                return v:onGotoViewRel(-1)
            end,
            function(v)
                return v:onGotoPageRel(-1)
            end,
            function(v)
                return v:onGotoPosRel(-1)
            end,
            function(v)
                return v:onKeyPress("LPgBack")
            end,
            function(v)
                return v:onKeyPress("RPgBack")
            end,
            function(v)
                return v:onKeyPress("PageUp")
            end,
        }

        for index, trigger in ipairs(triggers) do
            local boundary_spy = makeSpy(true)
            local viewer = PanelViewer:new({
                _images_list_cur = 1,
                _images_list_nb = 3,
                nav_transition_mode = "classic",
                boundary_callback = boundary_spy,
            })

            local handled = trigger(viewer)
            assert.is_true(handled, "Trigger #" .. index .. " must return truthy")
            assert.is_true(
                boundary_spy:called(),
                "Trigger #" .. index .. " must trigger boundary_callback at first panel"
            )
            local call = boundary_spy:lastCall()
            assert.equals("previous", call[1], "Trigger #" .. index .. " must specify 'previous' boundary direction")
            assert.equals(viewer, call[2], "Trigger #" .. index .. " must pass viewer instance to boundary_callback")
        end
    end)

    it("navigates within current page without boundary callback when mid-sequence", function()
        local boundary_spy = makeSpy(true)
        local viewer = PanelViewer:new({
            _images_list_cur = 2,
            _images_list_nb = 4,
            nav_transition_mode = "classic",
            boundary_callback = boundary_spy,
        })

        -- Forward mid-sequence actions must not trigger boundary
        assert.is_true(viewer:onPhysicalPageForward())
        assert.is_false(boundary_spy:called())

        assert.is_true(viewer:onPageForward())
        assert.is_false(boundary_spy:called())

        assert.is_true(viewer:onKeyPress("PageDown"))
        assert.is_false(boundary_spy:called())

        assert.is_true(viewer:onKeyPress("LPgFwd"))
        assert.is_false(boundary_spy:called())

        assert.is_true(viewer:onGotoViewRel(1))
        assert.is_false(boundary_spy:called())

        -- Backward mid-sequence actions must not trigger boundary
        assert.is_true(viewer:onPhysicalPageBackward())
        assert.is_false(boundary_spy:called())

        assert.is_true(viewer:onPageBackward())
        assert.is_false(boundary_spy:called())

        assert.is_true(viewer:onKeyPress("PageUp"))
        assert.is_false(boundary_spy:called())

        assert.is_true(viewer:onKeyPress("LPgBack"))
        assert.is_false(boundary_spy:called())

        assert.is_true(viewer:onGotoViewRel(-1))
        assert.is_false(boundary_spy:called())
    end)
end)

describe("Kobo physical buttons and Bluetooth coexistence with zoom and gestures", function()
    it("navigates panels while zoomed in (isImagePannable returns true)", function()
        local next_spy, prev_spy = spy(), spy()
        local viewer = PanelViewer:new({
            isImagePannable = function()
                return true
            end,
            onShowNextImage = next_spy,
            onShowPrevImage = prev_spy,
        })

        assert.is_true(viewer:isImagePannable())

        viewer:onPhysicalPageForward()
        viewer:onKeyPress("LPgFwd")
        viewer:onKeyPress("PageDown")
        viewer:onKeyPress(" ")
        viewer:onGotoViewRel(1)

        assert.equals(5, next_spy:callCount())

        viewer:onPhysicalPageBackward()
        viewer:onKeyPress("LPgBack")
        viewer:onKeyPress("PageUp")
        viewer:onGotoViewRel(-1)

        assert.equals(4, prev_spy:callCount())
    end)

    it("coexists with Kobo vertical edge gestures when enabled or disabled", function()
        local zoom_in_spy, zoom_out_spy = spy(), spy()
        local next_spy, prev_spy = spy(), spy()

        local viewer = PanelViewer:new({
            kobo_vertical_gesture = true,
            onZoomIn = zoom_in_spy,
            onZoomOut = zoom_out_spy,
            onShowNextImage = next_spy,
            onShowPrevImage = prev_spy,
        })

        -- Left edge swipe up zooms in
        viewer:onSwipe(nil, { direction = "north", pos = { x = 50, y = 400 } })
        assert.equals(1, zoom_in_spy:callCount())

        -- Left edge swipe down zooms out
        viewer:onSwipe(nil, { direction = "south", pos = { x = 50, y = 400 } })
        assert.equals(1, zoom_out_spy:callCount())

        -- Physical buttons still navigate panels without calling zoom
        viewer:onPhysicalPageForward()
        viewer:onKeyPress("LPgFwd")
        viewer:onKeyPress("PageDown")
        viewer:onPhysicalPageBackward()
        viewer:onKeyPress("LPgBack")
        viewer:onKeyPress("PageUp")

        assert.equals(3, next_spy:callCount())
        assert.equals(3, prev_spy:callCount())
        assert.equals(1, zoom_in_spy:callCount())
        assert.equals(1, zoom_out_spy:callCount())

        -- When disabled, left edge swipe does not zoom, and buttons still work
        viewer.kobo_vertical_gesture = false
        viewer:onSwipe(nil, { direction = "north", pos = { x = 50, y = 400 } })
        assert.equals(1, zoom_in_spy:callCount())

        viewer:onPhysicalPageForward()
        assert.equals(4, next_spy:callCount())
    end)

    it("operates across classic, smooth, and animated nav_transition_mode settings", function()
        for _, mode in ipairs({ "classic", "smooth", "animated" }) do
            local boundary_spy = spy()
            local viewer = PanelViewer:new({
                _images_list_cur = 3,
                _images_list_nb = 3,
                nav_transition_mode = mode,
                boundary_callback = boundary_spy,
            })

            viewer:onPhysicalPageForward()
            assert.is_true(boundary_spy:called(), "Mode " .. mode .. " must cross boundary on physical button")
        end
    end)
end)

--- Specs for `PanelViewer:onSwipe`'s left-edge vertical zoom gesture
--- (swipe up/down in the left 25% of the screen), driven end-to-end through
--- `onSwipe` rather than exposing the private `isLeftEdgeGesture` helper.
---
--- The mocked `device` screen is 600x800 (see `tests/spec/helper.lua`), so
--- the left-edge threshold is x <= 150.

local framework = require("tests.PanelsPlusTestFramework")
local describe, it, assert, spy = framework.describe, framework.it, framework.assert, framework.spy

local PanelViewer = require("src._panelviewer")

local function newViewer(overrides)
    local base = {
        onZoomIn = spy(),
        onZoomOut = spy(),
        onClose = spy(),
        isImagePannable = spy(),
    }
    for k, v in pairs(overrides or {}) do
        base[k] = v
    end
    return PanelViewer:new(base)
end

describe("PanelViewer:onSwipe left-edge zoom", function()
    it("zooms in on a north swipe within the left edge", function()
        local viewer = newViewer()

        viewer:onSwipe(nil, { direction = "north", pos = { x = 100, y = 400 } })

        assert.is_true(viewer.onZoomIn:called(), "onZoomIn should have been called")
        assert.is_false(viewer.onZoomOut:called())
        assert.is_false(viewer.onClose:called())
    end)

    it("zooms out on a south swipe within the left edge while pannable (zoomed in)", function()
        local pannable_spy = spy()
        pannable_spy.return_value = true
        local viewer = newViewer({ isImagePannable = pannable_spy })

        viewer:onSwipe(nil, { direction = "south", pos = { x = 50, y = 400 } })

        assert.is_true(viewer.onZoomOut:called(), "onZoomOut should have been called")
        assert.is_false(viewer.onClose:called())
    end)

    it("zooms out (does not close) on a south swipe within the left edge when not pannable (standard zoom)", function()
        local pannable_spy = spy()
        pannable_spy.return_value = false
        local viewer = newViewer({ isImagePannable = pannable_spy })

        viewer:onSwipe(nil, { direction = "south", pos = { x = 50, y = 400 } })

        assert.is_true(viewer.onZoomOut:called(), "onZoomOut should have been called")
        assert.is_false(
            viewer.onClose:called(),
            "onClose should not have been called -- this gesture is reserved for Kobo-style zoom, never for exiting"
        )
    end)

    it("does not zoom on a north swipe outside the left edge", function()
        local pannable_spy = spy()
        pannable_spy.return_value = false
        local viewer = newViewer({ isImagePannable = pannable_spy })

        viewer:onSwipe(nil, { direction = "north", pos = { x = 200, y = 400 } })

        assert.is_false(viewer.onZoomIn:called())
        assert.is_false(viewer.onZoomOut:called())
        assert.is_false(viewer.onClose:called())
    end)

    it("does not zoom on a south swipe outside the left edge", function()
        local pannable_spy = spy()
        pannable_spy.return_value = false
        local viewer = newViewer({ isImagePannable = pannable_spy })

        viewer:onSwipe(nil, { direction = "south", pos = { x = 200, y = 400 } })

        assert.is_false(viewer.onZoomIn:called())
        assert.is_false(viewer.onZoomOut:called())
        assert.is_false(viewer.onClose:called())
    end)

    it("is nil-safe when the gesture has no position", function()
        local pannable_spy = spy()
        pannable_spy.return_value = false
        local viewer = newViewer({ isImagePannable = pannable_spy })

        viewer:onSwipe(nil, { direction = "north" })

        assert.is_false(viewer.onZoomIn:called())
        assert.is_false(viewer.onZoomOut:called())
    end)

    it("treats the exact 25% boundary as still within the left edge", function()
        local viewer = newViewer()

        -- screen width 600 * 0.25 == 150, boundary is inclusive (`<=`)
        viewer:onSwipe(nil, { direction = "north", pos = { x = 150, y = 400 } })

        assert.is_true(viewer.onZoomIn:called())
    end)
end)

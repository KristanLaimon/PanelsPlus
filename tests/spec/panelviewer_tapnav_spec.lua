--- Specs for `PanelViewer:getNextTapSide` and `PanelViewer:onTap`'s
--- tap-to-navigate side zones, plus `PanelViewer:onSwipe`'s
--- `swipe_navigation` gate -- the "Tap screen sides to navigate" and "Swipe
--- to navigate" toggles added under the panel viewer's "More config..." menu.
---
--- The mocked `device` screen is 600x800 (see `tests/spec/helper.lua`), so
--- the tap zones (left/right third) are x <= 200 and x >= 400.

local framework = require("tests.PanelsPlusTestFramework")
local describe, it, assert, spy = framework.describe, framework.it, framework.assert, framework.spy

local PanelViewer = require("src._panelviewer")

local function newViewer(overrides)
    local base = {
        onShowNextImage = spy(),
        onShowPrevImage = spy(),
        onClose = spy(),
        isImagePannable = spy(),
        update = spy(),
        tap_navigation = true,
        buttons_visible = false,
    }
    for k, v in pairs(overrides or {}) do
        base[k] = v
    end
    return PanelViewer:new(base)
end

describe("PanelViewer:getNextTapSide", function()
    it("is right in comic mode", function()
        local viewer = PanelViewer:new({ reading_mode = "comic" })
        assert.equals("right", viewer:getNextTapSide())
    end)

    it("is left in manga mode", function()
        local viewer = PanelViewer:new({ reading_mode = "manga" })
        assert.equals("left", viewer:getNextTapSide())
    end)

    it("is not affected by invert_swipe (that only applies to the swipe gesture)", function()
        local viewer = PanelViewer:new({ reading_mode = "comic", invert_swipe = true })
        assert.equals("right", viewer:getNextTapSide())

        viewer = PanelViewer:new({ reading_mode = "manga", invert_swipe = true })
        assert.equals("left", viewer:getNextTapSide())
    end)
end)

describe("PanelViewer:onTap side navigation", function()
    it("advances to next panel on a right-side tap in comic mode", function()
        local viewer = newViewer({ reading_mode = "comic" })

        viewer:onTap(nil, { pos = { x = 500, y = 400 } })

        assert.is_true(viewer.onShowNextImage:called())
        assert.is_false(viewer.onShowPrevImage:called())
    end)

    it("goes to previous panel on a left-side tap in comic mode", function()
        local viewer = newViewer({ reading_mode = "comic" })

        viewer:onTap(nil, { pos = { x = 100, y = 400 } })

        assert.is_true(viewer.onShowPrevImage:called())
        assert.is_false(viewer.onShowNextImage:called())
    end)

    it("advances to next panel on a left-side tap in manga mode", function()
        local viewer = newViewer({ reading_mode = "manga" })

        viewer:onTap(nil, { pos = { x = 100, y = 400 } })

        assert.is_true(viewer.onShowNextImage:called())
        assert.is_false(viewer.onShowPrevImage:called())
    end)

    it("goes to previous panel on a right-side tap in manga mode", function()
        local viewer = newViewer({ reading_mode = "manga" })

        viewer:onTap(nil, { pos = { x = 500, y = 400 } })

        assert.is_true(viewer.onShowPrevImage:called())
        assert.is_false(viewer.onShowNextImage:called())
    end)

    it("toggles controls instead of navigating on a center tap", function()
        local viewer = newViewer({ reading_mode = "comic" })

        viewer:onTap(nil, { pos = { x = 300, y = 400 } })

        assert.is_false(viewer.onShowNextImage:called())
        assert.is_false(viewer.onShowPrevImage:called())
        assert.is_true(viewer.buttons_visible)
    end)

    it("does not navigate when tap_navigation is off", function()
        local viewer = newViewer({ reading_mode = "comic", tap_navigation = false })

        viewer:onTap(nil, { pos = { x = 500, y = 400 } })

        assert.is_false(viewer.onShowNextImage:called())
        assert.is_false(viewer.onShowPrevImage:called())
        assert.is_true(viewer.buttons_visible)
    end)

    it("does not navigate on edge taps while zoomed in (pannable)", function()
        local pannable_spy = spy()
        pannable_spy.return_value = true
        local viewer = newViewer({ reading_mode = "comic", isImagePannable = pannable_spy })

        viewer:onTap(nil, { pos = { x = 500, y = 400 } })

        assert.is_false(viewer.onShowNextImage:called())
        assert.is_false(viewer.onShowPrevImage:called())
        assert.is_true(viewer.buttons_visible)
    end)

    it("treats the exact left third boundary as still within the left zone", function()
        local viewer = newViewer({ reading_mode = "manga" })

        -- screen width 600 * (1/3) == 200, boundary is inclusive (`<=`)
        viewer:onTap(nil, { pos = { x = 200, y = 400 } })

        assert.is_true(viewer.onShowNextImage:called())
    end)
end)

describe("PanelViewer:onSwipe swipe_navigation toggle", function()
    local function newSwipeViewer(overrides)
        local base = {
            reading_mode = "comic",
            isImagePannable = spy(),
            onShowNextImage = spy(),
            onShowPrevImage = spy(),
            _images_list = { {}, {} },
        }
        for k, v in pairs(overrides or {}) do
            base[k] = v
        end
        return PanelViewer:new(base)
    end

    it("does not navigate west/east when swipe_navigation is off", function()
        local viewer = newSwipeViewer({ swipe_navigation = false })

        viewer:onSwipe(nil, { direction = "east", pos = { x = 500, y = 400 } })

        assert.is_false(viewer.onShowNextImage:called())
        assert.is_false(viewer.onShowPrevImage:called())
    end)

    it("still navigates west/east when swipe_navigation is on (default)", function()
        local viewer = newSwipeViewer()

        viewer:onSwipe(nil, { direction = "east", pos = { x = 500, y = 400 } })

        assert.is_true(viewer.onShowNextImage:called())
        assert.is_false(viewer.onShowPrevImage:called())
    end)
end)

--- Specs for `PanelViewer:onGotoViewRel`, KOReader's standard relative
--- page-turn event -- the fix for physical/Bluetooth page-turner buttons
--- silently falling through to the underlying document instead of driving
--- panel-by-panel navigation.

local framework = require("tests.PanelsPlusTestFramework")
local describe, it, assert, spy = framework.describe, framework.it, framework.assert, framework.spy

local PanelViewer = require("src._panelviewer")

describe("PanelViewer:onGotoViewRel sign dispatch", function()
    it("calls onShowNextImage on a positive diff", function()
        local next_spy, prev_spy = spy(), spy()
        local viewer = PanelViewer:new({ onShowNextImage = next_spy, onShowPrevImage = prev_spy })

        viewer:onGotoViewRel(1)

        assert.is_true(next_spy:called(), "onShowNextImage should have been called")
        assert.is_false(prev_spy:called(), "onShowPrevImage should not have been called")
    end)

    it("calls onShowPrevImage on a negative diff", function()
        local next_spy, prev_spy = spy(), spy()
        local viewer = PanelViewer:new({ onShowNextImage = next_spy, onShowPrevImage = prev_spy })

        viewer:onGotoViewRel(-1)

        assert.is_false(next_spy:called(), "onShowNextImage should not have been called")
        assert.is_true(prev_spy:called(), "onShowPrevImage should have been called")
    end)

    it("treats a large positive diff (e.g. dispatcher 'Turn pages') as a single step forward", function()
        local next_spy, prev_spy = spy(), spy()
        local viewer = PanelViewer:new({ onShowNextImage = next_spy, onShowPrevImage = prev_spy })

        viewer:onGotoViewRel(50)

        assert.equals(1, next_spy:callCount(), "onShowNextImage should be called exactly once")
        assert.is_false(prev_spy:called())
    end)

    it("treats a large negative diff as a single step backward", function()
        local next_spy, prev_spy = spy(), spy()
        local viewer = PanelViewer:new({ onShowNextImage = next_spy, onShowPrevImage = prev_spy })

        viewer:onGotoViewRel(-50)

        assert.equals(1, prev_spy:callCount())
        assert.is_false(next_spy:called())
    end)

    it("no-ops and returns true on a zero diff", function()
        local next_spy, prev_spy = spy(), spy()
        local viewer = PanelViewer:new({ onShowNextImage = next_spy, onShowPrevImage = prev_spy })

        local handled = viewer:onGotoViewRel(0)

        assert.is_false(next_spy:called())
        assert.is_false(prev_spy:called())
        assert.is_true(handled)
    end)

    it("no-ops and returns true on a nil diff", function()
        local next_spy, prev_spy = spy(), spy()
        local viewer = PanelViewer:new({ onShowNextImage = next_spy, onShowPrevImage = prev_spy })

        local handled = viewer:onGotoViewRel(nil)

        assert.is_false(next_spy:called())
        assert.is_false(prev_spy:called())
        assert.is_true(handled)
    end)
end)

describe("PanelViewer:onGotoViewRel end-to-end boundary crossing", function()
    it("crosses to the next page when at the last panel", function()
        local boundary_spy = spy()
        local viewer = PanelViewer:new({
            _images_list_cur = 3,
            _images_list_nb = 3,
            nav_transition_mode = "classic",
            boundary_callback = boundary_spy,
        })

        viewer:onGotoViewRel(1)

        assert.is_true(boundary_spy:called(), "boundary_callback should fire at the last panel")
        local call = boundary_spy:lastCall()
        assert.equals("next", call[1])
        assert.equals(viewer, call[2])
    end)

    it("crosses to the previous page when at the first panel", function()
        local boundary_spy = spy()
        local viewer = PanelViewer:new({
            _images_list_cur = 1,
            _images_list_nb = 3,
            nav_transition_mode = "classic",
            boundary_callback = boundary_spy,
        })

        viewer:onGotoViewRel(-1)

        assert.is_true(boundary_spy:called(), "boundary_callback should fire at the first panel")
        local call = boundary_spy:lastCall()
        assert.equals("previous", call[1])
        assert.equals(viewer, call[2])
    end)

    it("does not cross the boundary when navigating mid-sequence", function()
        local boundary_spy = spy()
        local viewer = PanelViewer:new({
            _images_list_cur = 2,
            _images_list_nb = 3,
            nav_transition_mode = "classic",
            boundary_callback = boundary_spy,
        })

        viewer:onGotoViewRel(1)

        assert.is_false(boundary_spy:called(), "boundary_callback should not fire mid-sequence")
    end)
end)

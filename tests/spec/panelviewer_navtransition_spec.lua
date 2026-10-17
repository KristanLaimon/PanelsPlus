--[[
Panels+
File: tests/spec/panelviewer_navtransition_spec.lua
Name: PanelViewer transition specs
Description: Verifies Classic, Smooth, and Animated transition selection and options.
Author: KristanLaimon
Year: 2026
Copyright (c) 2026 KristanLaimon
License: MIT; see the repository LICENSE file.
SPDX-License-Identifier: MIT
]]
local framework = require("tests.PanelsPlusTestFramework")
local describe, it, assert, spy = framework.describe, framework.it, framework.assert, framework.spy

local PanelViewer = require("src._panelviewer")
local UIManager = require("ui/uimanager")

describe("PanelViewer nav transition hold options", function()
    local function findNavButton(viewer)
        for _, row in ipairs(viewer.button_table.buttons or {}) do
            for _, button in ipairs(row) do
                if button.id == "nav_transition" then
                    return button
                end
            end
        end
    end

    it("labels Animated mode as long-press configurable", function()
        local viewer = PanelViewer:new({ nav_transition_mode = "animated" })
        assert.equals("Nav. Animated (Long Press)", viewer:getNavTransitionText())
    end)

    it("skips Animated when hardware swipe animation is unavailable", function()
        local viewer = PanelViewer:new({ nav_transition_mode = "classic" })
        viewer:replaceButtonTable()

        findNavButton(viewer).callback()
        assert.equals("smooth", viewer.nav_transition_mode)
        findNavButton(viewer).callback()
        assert.equals("classic", viewer.nav_transition_mode)
        findNavButton(viewer).callback()
        assert.equals("smooth", viewer.nav_transition_mode)
    end)

    it("delegates hold to nav_transition_options_callback when provided", function()
        local options_spy = spy()
        local viewer = PanelViewer:new({
            nav_transition_mode = "smooth",
            nav_transition_options_callback = options_spy,
        })
        viewer:replaceButtonTable()

        local nav_btn = findNavButton(viewer)

        assert.is_not_nil(nav_btn)
        assert.is_not_nil(nav_btn.hold_callback)
        nav_btn.hold_callback()
        assert.is_true(options_spy:called())
    end)

    it("falls back to onShowNavTransitionOptionsMenu when options callback is nil", function()
        local viewer = PanelViewer:new({
            nav_transition_mode = "smooth",
            nav_transition_options_callback = nil,
        })
        local menu_spy = spy()
        viewer.onShowNavTransitionOptionsMenu = menu_spy
        viewer:replaceButtonTable()

        local nav_btn = findNavButton(viewer)

        assert.is_not_nil(nav_btn)
        nav_btn.hold_callback()
        assert.is_true(menu_spy:called())
    end)

    it("displays the menu with options when onShowNavTransitionOptionsMenu is invoked", function()
        local cross_page_spy = spy()
        local viewer = PanelViewer:new({
            nav_transition_mode = "smooth",
            nav_transition_cross_page = false,
            nav_transition_cross_page_callback = cross_page_spy,
        })

        assert.is_true(viewer:onShowNavTransitionOptionsMenu())
        local shown_menu = UIManager._last_shown
        assert.is_not_nil(shown_menu)
        assert.is_not_nil(shown_menu.item_table)
        assert.equals(4, #shown_menu.item_table)
    end)

    it("arms Animated mode for panel switches only when its panel option is enabled", function()
        local animation_spy = spy()
        local viewer = PanelViewer:new({
            _images_list_cur = 1,
            _images_list_nb = 2,
            nav_transition_mode = "animated",
            nav_animated_panels = true,
            panel_animation_callback = animation_spy,
        })

        viewer:onShowNextImage()
        assert.equals(1, animation_spy:callCount())
        assert.equals("next", animation_spy:lastCall()[1])

        viewer.nav_animated_panels = false
        viewer:onShowNextImage()
        assert.equals(1, animation_spy:callCount())
    end)

    it("defaults Smooth to ease and cycles every CSS style plus Classic", function()
        local viewer = PanelViewer:new({ nav_transition_mode = "smooth" })
        assert.equals("ease", viewer.nav_smooth_style)
        assert.equals(24, viewer.nav_transition_frames)
        assert.equals(0.4, viewer.nav_transition_duration)
        viewer:onShowNavTransitionOptionsMenu()
        for _, choice in ipairs({
            "ease-in",
            "ease-out",
            "ease-in-out",
            "classic",
            "linear",
            "ease",
        }) do
            UIManager._last_shown.item_table[4].callback()
            assert.equals(choice, viewer.nav_smooth_style)
            assert.equals("smooth", viewer.nav_transition_mode)
            assert.equals(
                "Smooth style: " .. (choice == "classic" and "Classic" or choice),
                UIManager._last_shown.item_table[4].text
            )
        end
    end)

    it("delegates the Smooth style choice to its persistence callback", function()
        local selected
        local viewer = PanelViewer:new({
            nav_transition_mode = "smooth",
            nav_smooth_style_callback = function(current, style)
                selected = style
                current.nav_smooth_style = style
            end,
        })
        viewer:onShowNavTransitionOptionsMenu()
        UIManager._last_shown.item_table[4].callback()
        assert.equals("ease-in", selected)
        assert.equals("Smooth style: ease-in", UIManager._last_shown.item_table[4].text)
    end)
end)

describe("PanelViewer panel finding button", function()
    local function button(viewer)
        for _, row in ipairs(viewer.button_table.buttons or {}) do
            for _, item in ipairs(row) do
                if item.id == "panel_finding" then
                    return item
                end
            end
        end
    end

    it("shows the selected mode in the middle of the bottom row and cycles on tap", function()
        local viewer = PanelViewer:new({})
        viewer:replaceButtonTable()
        assert.equals("settings_profile", viewer.button_table.buttons[2][2].id)
        assert.equals("panel_finding", viewer.button_table.buttons[2][3].id)
        assert.equals("Panels Finding: Safe", button(viewer).text)
        button(viewer).callback()
        assert.equals("smart", viewer.panel_finding_mode)
        assert.equals("Panels Finding: Smart", button(viewer).text)
        button(viewer).callback()
        assert.equals("safe", viewer.panel_finding_mode)
    end)
end)

-- Exercise the real transition dispatch with bounded fake bitmap allocations.
describe("PanelViewer smooth pan and zoom navigation", function()
    local Blitbuffer = require("ffi/blitbuffer")
    local RenderImage = require("ui/renderimage")
    local Memory = require("src._memory")
    local PageRender = require("src._pagerender")

    local function withTransition(options, check)
        local old_draw = PageRender.drawPagePart
        local old_new = Blitbuffer.new
        local old_scale = RenderImage.scaleBlitBuffer
        local old_headroom = Memory.hasHeadroom
        local old_allocation = Memory.hasAllocationHeadroom
        local buffers, frames, blits = {}, {}, {}
        local source
        Blitbuffer.new = function(w, h, kind)
            local bb = old_new(w, h, kind)
            bb.getWidth = function()
                return w
            end
            bb.getHeight = function()
                return h
            end
            bb.free = function(self)
                self.frees = (self.frees or 0) + 1
            end
            bb.blitFrom = function(_, _, _, _, sx, sy, bw, bh)
                blits[#blits + 1] = { sx = sx, sy = sy, w = bw, h = bh }
            end
            bb.copy = function()
                return Blitbuffer.new(w, h, kind)
            end
            buffers[#buffers + 1] = bb
            return bb
        end
        RenderImage.scaleBlitBuffer = function(_, crop, w, h)
            if options.fail_scale then
                error("scale failed")
            end
            local frame = Blitbuffer.new(w, h, 0)
            frame.crop_w = crop.w
            return frame
        end
        Memory.hasHeadroom = function()
            return not options.low_memory
        end
        Memory.hasAllocationHeadroom = function()
            return not options.low_memory
        end
        local viewer = PanelViewer:new({
            _images_list_cur = 1,
            image_rects = options.rects or {
                { x = 0, y = 0, w = 600, h = 800 },
                { x = 650, y = 300, w = 60, h = 80 },
            },
            nav_transition_frames = options.steps or 4,
            nav_smooth_style = options.style or "linear",
            nav_transition_duration = 0.4,
            image_disposable = true,
            crop_mode = options.margin and "margin" or "tight",
            margin_ratio = 0.2,
            panel_is_full_page = options.full_page,
            image_union_renderer = function(union, zoom)
                source = Blitbuffer.new(math.ceil(union.w * zoom), math.ceil(union.h * zoom), 0)
                return source
            end,
        })
        if options.cached_source then
            local render = viewer.image_union_renderer
            viewer.image_union_renderer = nil
            PageRender.drawPagePart = function(_, _, union)
                return render(union, math.min(600 / union.w, 800 / union.h))
            end
        end
        viewer.shouldAutoRotateDoublePage = function()
            return false
        end
        viewer.isOpen = function()
            return not options.closed
        end
        viewer.releasePreviousPanelImage = function(_, image)
            if image then
                image:free()
            end
        end
        viewer.update = function(self)
            frames[#frames + 1] = { image = self.image, margin = self:getMarginShrinkFactor() }
        end
        viewer.switchToImageNum = function(self, target)
            self.switched_to = target
            self._images_list_cur = target
        end
        viewer.runNavPanAnimation = function(self, x, y, done)
            self.canvas_pan = { x = x, y = y, done = done }
        end
        local ok, err = pcall(function()
            check(viewer, buffers, frames, blits, function()
                return source
            end)
        end)
        PageRender.drawPagePart = old_draw
        Blitbuffer.new = old_new
        RenderImage.scaleBlitBuffer = old_scale
        Memory.hasHeadroom = old_headroom
        Memory.hasAllocationHeadroom = old_allocation
        if not ok then
            error(err)
        end
    end

    it("animates a tiny destination with screen-sized frames and releases its source", function()
        withTransition({}, function(viewer, buffers, frames, blits, source)
            viewer:animateSwitchToImageNum(2)
            assert.is_true(viewer._panels_plus_transition_active)
            assert.is_nil(viewer.switched_to)
            for _ = 1, 4 do
                UIManager._last_scheduled()
            end
            assert.equals(2, viewer.switched_to)
            assert.equals(5, #frames)
            assert.equals(1, source().frees)
            assert.is_nil(viewer._panels_plus_transition_cleanup)
            for _, bb in ipairs(buffers) do
                assert.is_true(bb.w <= 600 and bb.h <= 800, "all allocations stay within screen dimensions")
                assert.is_true((bb.frees or 0) <= 1)
            end
            assert.is_true(blits[1].sx ~= blits[#blits].sx, "the camera moves toward the destination")
            assert.is_true(blits[1].w > blits[#blits].w, "the camera zooms toward the small panel")
        end)
    end)

    it("copies cache-owned document pixels before scheduling frames", function()
        withTransition({ cached_source = true }, function(viewer, buffers, _, _, source)
            viewer:animateSwitchToImageNum(2)
            assert.is_true(viewer._panels_plus_transition_active)
            for _ = 1, 4 do
                UIManager._last_scheduled()
            end
            assert.equals(2, viewer.switched_to)
            assert.is_nil(source().frees, "DocCache retains ownership of the source")
            assert.equals(1, buffers[2].frees, "the private animation copy is released")
        end)
    end)

    it("fits eased frames to the open controls in portrait and landscape", function()
        local Screen = require("device").screen
        for _, layout in ipairs({
            { w = 600, h = 800, container_h = 500, panel_w = 600, panel_h = 500 - Screen:scaleBySize(64) },
            { w = 800, h = 600, container_h = 400, panel_w = 800 - Screen:scaleBySize(72), panel_h = 400 },
        }) do
            for _, margin in ipairs({ false, true }) do
                withTransition({ style = "ease", margin = margin }, function(viewer, _, frames)
                    viewer.width, viewer.height = layout.w, layout.h
                    viewer.img_container_h = layout.container_h
                    viewer.buttons_visible = true
                    viewer.quick_controls = {}
                    viewer:animateSwitchToImageNum(2)
                    for _ = 1, 4 do
                        UIManager._last_scheduled()
                    end
                    local factor = margin and 0.8 or 1
                    for _, frame in ipairs(frames) do
                        assert.equals(math.floor(layout.panel_w * factor), frame.image.w)
                        assert.equals(math.floor(layout.panel_h * factor), frame.image.h)
                    end
                    -- Both rectangles have the same aspect ratio. Matching their
                    -- fit zoom keeps the whole endpoint panel in the smaller box.
                    local source_zoom = math.min(600 / 710, 800 / 800)
                    local start_zoom = math.min(layout.panel_w / 600, layout.panel_h / 800) * factor
                    local end_zoom = math.min(layout.panel_w / 60, layout.panel_h / 80) * factor
                    assert.equals(math.ceil(frames[1].image.w * source_zoom / start_zoom), frames[1].image.crop_w)
                    assert.equals(math.ceil(frames[5].image.w * source_zoom / end_zoom), frames[5].image.crop_w)
                    assert.equals(2, viewer.switched_to)
                end)
            end
        end
    end)

    it("preserves margin framing on every bounded frame", function()
        withTransition({ margin = true }, function(viewer, _, frames)
            viewer:animateSwitchToImageNum(2)
            for _ = 1, 4 do
                UIManager._last_scheduled()
            end
            for _, frame in ipairs(frames) do
                assert.equals(480, frame.image.w)
                assert.equals(640, frame.image.h)
                assert.near(0.8, frame.margin, 0.0001)
            end
            assert.is_nil(viewer._panels_plus_transition_margin_factor)
        end)
    end)

    it("gradually zooms out from small to large panels", function()
        withTransition({
            rects = { { x = 650, y = 300, w = 60, h = 80 }, { x = 0, y = 0, w = 600, h = 800 } },
        }, function(viewer, buffers, frames, _, source)
            viewer:animateSwitchToImageNum(2)
            assert.is_nil(viewer.switched_to)
            for _ = 1, 4 do
                UIManager._last_scheduled()
            end
            assert.equals(2, viewer.switched_to)
            assert.equals(5, #frames)
            for i = 2, #frames do
                assert.is_true(frames[i].image.crop_w > frames[i - 1].image.crop_w)
            end
            for _, bb in ipairs(buffers) do
                assert.is_true(bb.w <= 600 and bb.h <= 800)
                assert.is_true((bb.frees or 0) <= 1)
            end
            assert.equals(1, source().frees)
        end)
    end)

    it("interpolates similar-sized panels in either direction at the configured frame count", function()
        local a = { x = 0, y = 0, w = 300, h = 400 }
        local b = { x = 320, y = 40, w = 270, h = 360 }
        for _, rects in ipairs({ { a, b }, { b, a } }) do
            withTransition({ rects = rects, steps = 7 }, function(viewer, _, frames)
                viewer:animateSwitchToImageNum(2)
                assert.is_nil(viewer.switched_to)
                for _ = 1, 7 do
                    UIManager._last_scheduled()
                end
                assert.equals(2, viewer.switched_to)
                assert.equals(8, #frames)
                for i = 2, #frames do
                    local previous, current = frames[i - 1].image.crop_w, frames[i].image.crop_w
                    assert.is_true(rects[1] == a and current < previous or rects[1] == b and current > previous)
                end
            end)
        end
    end)

    it("pans equal-sized panels with stable zoom", function()
        withTransition({
            rects = { { x = 0, y = 0, w = 300, h = 400 }, { x = 320, y = 0, w = 300, h = 400 } },
        }, function(viewer, _, frames, blits)
            viewer:animateSwitchToImageNum(2)
            assert.is_nil(viewer.switched_to)
            for _ = 1, 4 do
                UIManager._last_scheduled()
            end
            assert.equals(2, viewer.switched_to)
            assert.equals(5, #frames)
            for _, frame in ipairs(frames) do
                assert.equals(frames[1].image.crop_w, frame.image.crop_w)
            end
            assert.is_true(blits[1].sx ~= blits[#blits].sx)
        end)
    end)

    it("gradually changes margin framing when entering or leaving a full-page panel", function()
        for _, flags in ipairs({ { true, false }, { false, true } }) do
            withTransition({ margin = true, full_page = flags }, function(viewer, _, frames)
                viewer:animateSwitchToImageNum(2)
                for _ = 1, 4 do
                    UIManager._last_scheduled()
                end
                assert.equals(flags[1] and 600 or 480, frames[1].image.w)
                assert.equals(flags[2] and 600 or 480, frames[#frames].image.w)
                assert.equals(540, frames[3].image.w)
                assert.is_nil(viewer._panels_plus_transition_margin_factor)
            end)
        end
    end)

    it("eases both zoom directions while keeping duration, frame count, and landing framing", function()
        local a = { x = 0, y = 0, w = 300, h = 400 }
        local b = { x = 320, y = 40, w = 150, h = 200 }
        for _, rects in ipairs({ { a, b }, { b, a } }) do
            local widths = {}
            for _, style in ipairs({ "linear", "ease-in-out" }) do
                withTransition({ style = style, rects = rects }, function(viewer, _, frames)
                    viewer:animateSwitchToImageNum(2)
                    for _ = 1, 4 do
                        UIManager._last_scheduled()
                    end
                    assert.equals(2, viewer.switched_to)
                    assert.equals(5, #frames)
                    widths[style] = {}
                    for _, frame in ipairs(frames) do
                        table.insert(widths[style], frame.image.crop_w)
                    end
                end)
            end
            assert.equals(widths.linear[1], widths["ease-in-out"][1])
            assert.equals(widths.linear[5], widths["ease-in-out"][5])
            if rects[1] == a then
                assert.is_true(widths["ease-in-out"][2] > widths.linear[2])
                assert.is_true(widths["ease-in-out"][4] < widths.linear[4])
            else
                assert.is_true(widths["ease-in-out"][2] < widths.linear[2])
                assert.is_true(widths["ease-in-out"][4] > widths.linear[4])
            end
        end
    end)

    it("still switches instantly when memory is low", function()
        withTransition({ low_memory = true }, function(viewer, buffers)
            viewer:animateSwitchToImageNum(2)
            assert.equals(2, viewer.switched_to)
            assert.equals(0, #buffers)
        end)
    end)

    it("notifies preview completion once after each render path lands on its panel", function()
        for _, options in ipairs({
            {},
            { style = "classic" },
            { style = "classic", rects = { { x = 0, y = 0, w = 300, h = 400 }, { x = 320, y = 0, w = 300, h = 400 } } },
            { low_memory = true },
            { fail_scale = true },
        }) do
            withTransition(options, function(viewer)
                local completed = 0
                viewer:animateSwitchToImageNum(2, function()
                    assert.equals(2, viewer._images_list_cur)
                    completed = completed + 1
                end)
                if viewer.canvas_pan then
                    viewer._panels_plus_transition_active = nil
                    viewer.canvas_pan.done()
                elseif viewer._panels_plus_transition_active then
                    for _ = 1, 4 do
                        UIManager._last_scheduled()
                    end
                end
                assert.equals(1, completed)
            end)
        end
    end)

    it("restores the earlier shared-canvas pan in Classic for both size directions", function()
        local a = { x = 0, y = 0, w = 300, h = 400 }
        local b = { x = 320, y = 40, w = 270, h = 360 }
        for _, rects in ipairs({ { a, b }, { b, a } }) do
            withTransition({ style = "classic", rects = rects }, function(viewer, _, frames, _, source)
                viewer:animateSwitchToImageNum(2)
                assert.is_true(viewer._panels_plus_transition_active)
                assert.is_nil(viewer.switched_to)
                assert.is_not_nil(viewer.canvas_pan)
                assert.equals(0.5, viewer.canvas_pan.x)
                assert.equals(0.5, viewer.canvas_pan.y)
                assert.equals(1, #frames)
                assert.equals(1, source().frees)
                viewer.canvas_pan.done()
                assert.equals(2, viewer.switched_to)
                assert.is_nil(viewer._panels_plus_transition_margin_factor)
            end)
        end
    end)

    it("pans oversized Classic transitions at a fixed zoom with bounded allocations", function()
        for _, margin in ipairs({ false, true }) do
            withTransition({ style = "classic", margin = margin }, function(viewer, buffers, frames, blits, source)
                viewer:animateSwitchToImageNum(2)
                assert.is_nil(viewer.canvas_pan)
                assert.is_nil(viewer.switched_to)
                for _ = 1, 4 do
                    UIManager._last_scheduled()
                end
                assert.equals(5, #frames)
                assert.equals(2, viewer.switched_to)
                for _, frame in ipairs(frames) do
                    assert.equals(frames[1].image.crop_w, frame.image.crop_w)
                    assert.equals(frames[1].margin, frame.margin)
                end
                assert.is_true(blits[1].sx ~= blits[#blits].sx, "Classic still pans to the destination")
                for _, buffer in ipairs(buffers) do
                    assert.is_true(buffer.w <= 600 and buffer.h <= 800)
                    assert.is_true((buffer.frees or 0) <= 1)
                end
                assert.equals(1, source().frees)
            end)
        end
    end)

    it("releases temporary crops and the source if scaling fails", function()
        withTransition({ fail_scale = true }, function(viewer, buffers)
            viewer:animateSwitchToImageNum(2)
            assert.equals(2, viewer.switched_to)
            assert.is_nil(viewer._panels_plus_transition_active)
            for _, bb in ipairs(buffers) do
                assert.equals(1, bb.frees)
            end
        end)
    end)

    it(
        "previews an adjacent page and restores the original image and framing without committing a page turn",
        function()
            for _, direction in ipairs({ "next", "previous" }) do
                withTransition({ cached_source = true }, function(viewer)
                    local original = Blitbuffer.new(600, 800, 0)
                    viewer.image = original
                    viewer.page = 5
                    viewer._center_x_ratio, viewer._center_y_ratio, viewer.scale_factor = 0.4, 0.6, 0.7
                    viewer.auto_rotate_double_pages = false
                    viewer.nav_boundary_peek_callback = function()
                        return {
                            next_page = direction == "next" and 6 or 4,
                            target_rect = { x = 0, y = 0, w = 600, h = 800 },
                        }
                    end
                    local committed, completed = 0, 0
                    viewer.nav_boundary_commit_callback = function()
                        committed = committed + 1
                    end
                    viewer:animateBoundaryTransition(direction, function(played)
                        assert.is_true(played)
                        completed = completed + 1
                    end)
                    local outbound = viewer.canvas_pan
                    assert.is_not_nil(outbound)
                    assert.is_nil(original.frees)
                    viewer._panels_plus_transition_active = nil
                    outbound.done()
                    UIManager._last_scheduled()
                    local inbound = viewer.canvas_pan
                    assert.is_true(outbound.x ~= inbound.x)
                    viewer._panels_plus_transition_active = nil
                    inbound.done()
                    assert.equals(original, viewer.image)
                    assert.equals(0.4, viewer._center_x_ratio)
                    assert.equals(0.6, viewer._center_y_ratio)
                    assert.equals(0.7, viewer.scale_factor)
                    assert.equals(5, viewer.page)
                    assert.is_nil(original.frees)
                    assert.is_nil(viewer._panels_plus_transition_cleanup)
                    assert.equals(0, committed)
                    assert.equals(1, completed)
                end)
            end
        end
    )

    it("releases the retained source when the viewer closes during a pan", function()
        withTransition({ closed = true }, function(viewer, _, _, _, source)
            viewer:animateSwitchToImageNum(2)
            UIManager._last_scheduled()
            assert.equals(1, source().frees)
            assert.is_nil(viewer._panels_plus_transition_active)
            assert.is_nil(viewer.switched_to)
        end)
    end)
end)

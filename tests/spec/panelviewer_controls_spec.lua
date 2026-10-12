local framework = require("tests.PanelsPlusTestFramework")
local describe, it, assert = framework.describe, framework.it, framework.assert
local PanelViewer = require("src._panelviewer")
local Toolbar = require("src._quicktoolbar")
local ImageViewer = require("ui/widget/imageviewer")
local Screen = require("device").screen

describe("Panel viewer compact controls", function()
    it("places settings in two rows of three and Close across the bottom", function()
        local viewer = PanelViewer:new({ width = 600 })
        viewer:replaceButtonTable()
        local rows = viewer.button_table.buttons
        assert.equals(3, #rows)
        assert.equals(3, #rows[1])
        assert.equals("mode", rows[1][1].id)
        assert.equals("nav_transition", rows[1][2].id)
        assert.equals("crop", rows[1][3].id)
        assert.equals(3, #rows[2])
        assert.equals("more_config", rows[2][1].id)
        assert.equals("settings_profile", rows[2][2].id)
        assert.equals("panel_finding", rows[2][3].id)
        assert.equals(1, #rows[3])
        assert.equals("close", rows[3][1].id)
        for _, id in ipairs(Toolbar.order) do
            assert.is_not_nil(viewer.quick_controls[id])
            assert.is_true(viewer.quick_controls[id].icon_file:match("%.svg$") ~= nil)
        end
    end)

    it("keeps base scale/rotation relabeling compatible with icon controls", function()
        local viewer = PanelViewer:new({ width = 600, _scale_to_fit = true, progress_bar_visible = false })
        viewer:replaceButtonTable()
        local scale = viewer.button_table:getButtonById("scale")
        assert.equals("1:1", scale.text)
        scale:setText("Scale")
        assert.equals("Fit", scale.text)
        local rotate = viewer.button_table:getButtonById("rotate")
        rotate:setText("No rotation")
        assert.equals("Rotate", rotate.text)
        assert.equals("Show", viewer.quick_controls.progress_bar.text)
    end)

    it("dispatches rail actions and retains long-press settings on navigation and crop", function()
        local selected = {}
        local viewer = PanelViewer:new({
            width = 600,
            nav_transition_mode = "smooth",
            crop_mode = "margin",
            ocr_language_callback = function()
                selected.ocr = true
            end,
            progress_bar_toggle_callback = function()
                selected.progress = true
            end,
            nav_transition_options_callback = function()
                selected.nav = true
            end,
            onOpenRotationPicker = function()
                selected.rotate = true
            end,
            onSaveImageView = function()
                selected.screenshot = true
            end,
            onAdjustMarginRatio = function()
                selected.crop = true
            end,
        })
        viewer:replaceButtonTable()
        for _, id in ipairs({ "rotate", "ocr_language", "screenshot", "progress_bar" }) do
            viewer.quick_controls[id].callback()
        end
        viewer.button_table.buttons[1][2].hold_callback()
        viewer.button_table.buttons[1][3].hold_callback()
        for _, name in ipairs({ "rotate", "ocr", "screenshot", "progress", "nav", "crop" }) do
            assert.is_true(selected[name])
        end
    end)

    it("reserves rail width only while controls are visible, preserving margin and rotation", function()
        local old_new, old_build, old_scale = ImageViewer._new_image_wg, Toolbar.build, Screen.scaleBySize
        local old_group = package.loaded["ui/widget/horizontalgroup"]
        Screen.scaleBySize = function(_, value)
            return value
        end
        package.loaded["ui/widget/horizontalgroup"] = {
            new = function(_, value)
                return value
            end,
        }
        Toolbar.build = function(_, width, height)
            return { width = width, height = height }
        end
        ImageViewer._new_image_wg = function(self)
            self._image_wg = { width = self.width, height = self.img_container_h }
            self.image_container = { dimen = { w = self.width, h = self.img_container_h } }
        end
        local viewer = PanelViewer:new({
            width = 600,
            img_container_h = 420,
            buttons_visible = true,
            crop_mode = "margin",
            margin_ratio = 0.2,
            panel_is_full_page = { false },
            _images_list_cur = 1,
            rotated = 180,
        })
        viewer:replaceButtonTable()
        viewer:_new_image_wg()
        local visible_container, visible_image = viewer.image_container, viewer._image_wg
        viewer.buttons_visible = false
        viewer:_new_image_wg()
        local hidden_container, hidden_image = viewer.image_container, viewer._image_wg
        ImageViewer._new_image_wg, Toolbar.build, Screen.scaleBySize = old_new, old_build, old_scale
        package.loaded["ui/widget/horizontalgroup"] = old_group
        assert.equals(600, viewer.width)
        assert.equals(528, visible_container[1].dimen.w)
        assert.equals(72, visible_container[2].width)
        assert.equals(420, visible_container[2].height)
        assert.near(528 * 0.8, visible_image.width, 0.001)
        assert.equals(180, visible_image.rotation_angle)
        assert.equals(600, hidden_container.dimen.w)
        assert.near(600 * 0.8, hidden_image.width, 0.001)
        assert.is_nil(viewer.quick_rail)
    end)
end)

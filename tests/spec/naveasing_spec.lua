local framework = require("tests.PanelsPlusTestFramework")
local describe, it, assert = framework.describe, framework.it, framework.assert
local Easing = require("src._naveasing")
local Settings = require("src._settings")
local Profiles = require("src.profiles")
local PanelViewer = require("src._panelviewer")
local UIManager = require("ui/uimanager")

describe("CSS navigation timing", function()
    it("matches CSS Bezier timing at quarter, half, and three-quarter progress", function()
        local samples = {
            ease = { 0.408511, 0.802403, 0.960459 },
            ["ease-in"] = { 0.093465, 0.315357, 0.621862 },
            ["ease-out"] = { 0.378138, 0.684643, 0.906535 },
            ["ease-in-out"] = { 0.129162, 0.5, 0.870838 },
        }
        for style, expected in pairs(samples) do
            for index, value in ipairs(expected) do
                assert.near(value, Easing.progress(style, index / 4), 0.000002)
            end
        end
    end)

    it("keeps continuous timings monotone, bounded, and exact at endpoints", function()
        for _, style in ipairs({ "linear", "ease", "ease-in", "ease-out", "ease-in-out", "classic" }) do
            assert.equals(0, Easing.progress(style, 0))
            assert.equals(1, Easing.progress(style, 1))
            local previous = 0
            for index = 1, 100 do
                local value = Easing.progress(style, index / 100)
                assert.is_true(value >= previous and value <= 1)
                previous = value
            end
        end
        assert.equals(0.25, Easing.progress("linear", 0.25))
        assert.equals(0.25, Easing.progress("classic", 0.25))
    end)

    it("implements CSS step endpoints", function()
        for _, progress in ipairs({ 0, 0.25, 0.5, 0.75, 1 }) do
            assert.equals(1, Easing.progress("step-start", progress))
            assert.equals(progress == 1 and 1 or 0, Easing.progress("step-end", progress))
        end
    end)

    it("preserves old Modern preferences and profile snapshots as linear", function()
        assert.equals("linear", Settings.withDefaults({ nav_smooth_style = "modern" }).nav_smooth_style)
        assert.equals("linear", Profiles.options({ nav_smooth_style = "modern" }).nav_smooth_style)
        assert.equals("linear", Easing.normalize("unknown"))
        for _, style in ipairs(Easing.styles) do
            assert.equals(style, Settings.withDefaults({ nav_smooth_style = style }).nav_smooth_style)
            assert.equals(style, Profiles.options({ nav_smooth_style = style }).nav_smooth_style)
        end
    end)

    it("applies ease-in-out to shared-canvas and cross-page camera pans", function()
        local offsets = {}
        local image = {
            width = 600,
            height = 800,
            _offset_x = 0,
            _offset_y = 0,
            getSize = function() end,
            getCurrentWidth = function()
                return 1200
            end,
            getCurrentHeight = function()
                return 800
            end,
        }
        local viewer = PanelViewer:new({
            _image_wg = image,
            _panels_plus_transition_active = true,
            nav_smooth_style = "ease-in-out",
            nav_transition_frames = 4,
            isOpen = function()
                return true
            end,
            panBy = function(_, dx, dy)
                image._offset_x = image._offset_x + dx
                image._offset_y = image._offset_y + dy
                offsets[#offsets + 1] = image._offset_x
            end,
        })
        local completed = false
        viewer:runNavPanAnimation(1, 0.5, function()
            completed = true
        end)
        for _ = 1, 4 do
            UIManager._last_scheduled()
        end
        assert.near(116.246, offsets[1], 0.002)
        assert.near(450, offsets[2], 0.002)
        assert.near(783.754, offsets[3], 0.002)
        assert.equals(900, offsets[4])
        assert.is_true(completed)
    end)
end)

local framework = require("tests.PanelsPlusTestFramework")
local describe, it, assert = framework.describe, framework.it, framework.assert
local Device = require("device")
local UIManager = require("ui/uimanager")
local Capabilities = require("src._navcapabilities")
local Settings = require("src._settings")
local PanelsPlus = require("main")
local PanelViewer = require("src._panelviewer")
local ProfileMenu = require("src.profile_menu")
local Menu = require("src.menu")

local function withDevice(eink, animated, check)
    local old_eink, old_animated = Device.hasEinkScreen, Device.canDoSwipeAnimation
    Device.hasEinkScreen = function()
        return eink
    end
    Device.canDoSwipeAnimation = function()
        return animated
    end
    local ok, err = pcall(check)
    Device.hasEinkScreen, Device.canDoSwipeAnimation = old_eink, old_animated
    if not ok then
        error(err)
    end
end

local function plugin()
    return setmetatable({
        settings = Settings.withDefaults({}),
        saveSettings = function() end,
        saveDocSettings = function() end,
    }, { __index = PanelsPlus })
end

describe("Device-aware navigation", function()
    it("defaults to 24 frames on non-eink devices and 2 on e-readers without resetting saved preferences", function()
        for _, eink in ipairs({ false, true }) do
            withDevice(eink, eink, function()
                assert.equals(eink and 2 or 24, Settings.withDefaults({}).nav_transition_frames)
                assert.equals(16, Settings.withDefaults({ nav_transition_frames = 16 }).nav_transition_frames)
                assert.equals(60, Settings.withDefaults({ nav_transition_frames = 60 }).nav_transition_frames)
            end)
        end
        withDevice(true, false, function()
            assert.equals(2, Settings.withDefaults({}).nav_transition_frames)
        end)
    end)

    it("supports up to 60 frames in the setter and both settings inputs", function()
        local p = plugin()
        p:setNavTransitionFrames(60)
        assert.equals(60, p.settings.nav_transition_frames)
        p:setNavTransitionFrames(100)
        assert.equals(60, p.settings.nav_transition_frames)
        local old_tick, old_spin = UIManager.nextTick, package.loaded["ui/widget/spinwidget"]
        UIManager.nextTick = function(_, callback)
            callback()
        end
        package.loaded["ui/widget/spinwidget"] = {
            new = function(_, options)
                return options
            end,
        }
        local ok, err = pcall(function()
            Menu.animationItems(p)[5].callback()
            assert.equals(60, UIManager._last_shown.value_max)
            PanelViewer:new({}):onAdjustNavTransitionFrames()
            assert.equals(60, UIManager._last_shown.value_max)
        end)
        UIManager.nextTick, package.loaded["ui/widget/spinwidget"] = old_tick, old_spin
        if not ok then
            error(err)
        end
    end)

    it("includes Animated only when the device has hardware support", function()
        for _, supported in ipairs({ false, true }) do
            withDevice(supported, supported, function()
                assert.equals(supported and "animated" or "classic", Capabilities.nextMode("smooth"))
                assert.equals("smooth", Capabilities.nextMode("classic"))
                local p = plugin()
                p:setNavTransitionMode("animated")
                assert.equals(supported and "animated" or "classic", p.settings.nav_transition_mode)
                p:setEmbeddedNavTransitionMode("animated")
                assert.equals(supported and "animated" or "classic", p.settings.embedded_nav_transition_mode)
                local draft = { nav_transition_mode = "classic" }
                ProfileMenu.showProfileFieldPicker(p, "nav_transition_mode", draft, function() end)
                local items = UIManager._last_shown[1].item_table
                assert.equals(supported and 4 or 3, #items) -- choices plus Back
                for _, item in ipairs(items) do
                    if not supported then
                        assert.is_nil(item.text:find("Animated", 1, true))
                    end
                end
            end)
        end
    end)

    it("warns only on e-readers when Smooth is selected, for fixed and embedded images", function()
        for _, eink in ipairs({ false, true }) do
            withDevice(eink, eink, function()
                for _, setter in ipairs({ "setNavTransitionMode", "setEmbeddedNavTransitionMode" }) do
                    local p = plugin()
                    local sentinel = {}
                    UIManager._last_shown = sentinel
                    p[setter](p, "smooth")
                    if eink then
                        assert.equals(7, UIManager._last_shown.timeout)
                        assert.is_true(UIManager._last_shown.text:find("Animated mode is recommended", 1, true) ~= nil)
                    else
                        assert.equals(sentinel, UIManager._last_shown)
                    end
                    UIManager._last_shown = sentinel
                    p[setter](p, "classic")
                    assert.equals(sentinel, UIManager._last_shown)
                end
            end)
        end
    end)

    it("silently normalizes unsupported modes when loading preferences", function()
        withDevice(false, false, function()
            local sentinel = {}
            UIManager._last_shown = sentinel
            local settings =
                Settings.withDefaults({ nav_transition_mode = "animated", embedded_nav_transition_mode = "animated" })
            assert.equals("classic", settings.nav_transition_mode)
            assert.equals("classic", settings.embedded_nav_transition_mode)
            assert.equals(sentinel, UIManager._last_shown)
        end)
    end)
end)

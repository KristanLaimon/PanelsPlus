--[[
Panels+
File: tests/spec/viewer_controller_more_config_spec.lua
Name: ViewerController configuration specs
Description: Verifies grouped viewer controls and page-turn animation settings.
Author: KristanLaimon
Year: 2026
Copyright (c) 2026 KristanLaimon
License: MIT; see the repository LICENSE file.
SPDX-License-Identifier: MIT
]]
--- Shared More-config controls and native page-turn animation behavior.
local framework = require("tests.PanelsPlusTestFramework")
local describe, it, assert, spy = framework.describe, framework.it, framework.assert, framework.spy

local Device = require("device")
local Screen = Device.screen
local UIManager = require("ui/uimanager")
local PanelCollector = require("src._panelcollector")
local PanelViewer = require("src._panelviewer")
local MainMenu = require("src.menu")
local Settings = require("src._settings")
local ViewerController = require("src.viewer_controller")
local WordFinder = require("src._wordfinder")

describe("ViewerController page-turn animation settings", function()
    local function withAnimationEnvironment(callback)
        local old_can_do_swipe_animation = Device.canDoSwipeAnimation
        Device.canDoSwipeAnimation = function()
            return true
        end

        callback()

        Device.canDoSwipeAnimation = old_can_do_swipe_animation
    end

    local function makeController(settings)
        local saved = spy()
        local controller = setmetatable({
            settings = settings,
            saveSettings = saved,
        }, { __index = ViewerController })
        return controller, saved
    end

    it("animates pages only when Animated mode and its page option are enabled", function()
        withAnimationEnvironment(function()
            local controller = makeController({})
            assert.is_true(controller:isPageTurnAnimationActive({
                nav_transition_mode = "animated",
                nav_animated_pages = true,
            }))
            assert.is_false(controller:isPageTurnAnimationActive({
                nav_transition_mode = "animated",
                nav_animated_pages = false,
            }))
            assert.is_false(controller:isPageTurnAnimationActive({
                nav_transition_mode = "classic",
                nav_animated_pages = true,
            }))
        end)
    end)

    it("shows two independent boolean options for Animated mode", function()
        local controller = makeController({ nav_animated_panels = true, nav_animated_pages = true })
        controller:showNavTransitionOptionsMenu({ nav_transition_mode = "animated" })
        local items = UIManager._last_shown.item_table
        assert.equals(2, #items)
        assert.equals("Animate between panels (Actual: true)", items[1].text)
        assert.equals("Animate between pages (Actual: true)", items[2].text)
        assert.is_true(items[1].checked_func())
        assert.is_true(items[2].checked_func())
    end)

    it("defaults both Animated mode options to true", function()
        local settings = Settings.withDefaults({})
        assert.is_true(settings.nav_animated_panels)
        assert.is_true(settings.nav_animated_pages)
        assert.equals("eng", settings.ocr_bundled_language)
    end)

    it("selects a bundled language in the current viewer and saves it", function()
        local controller, saved = makeController(Settings.withDefaults({}))
        local viewer = { ocr_bundled_language = "eng" }
        controller:showMoreConfigMenu(viewer)
        local items = UIManager._last_shown.item_table
        assert.is_true(items[9].checked_func())

        items[11].callback()
        assert.equals("ita", controller.settings.ocr_bundled_language)
        assert.equals("ita", viewer.ocr_bundled_language)
        assert.equals(1, saved:callCount())
        assert.is_true(UIManager._last_shown.item_table[11].checked_func())
    end)

    it("does not offer bundled languages in the manual OCR package", function()
        local original_has_bundled = WordFinder.hasBundledData
        WordFinder.hasBundledData = function()
            return false
        end
        local controller = makeController(Settings.withDefaults({}))
        controller:showMoreConfigMenu({})
        local items = UIManager._last_shown.item_table
        WordFinder.hasBundledData = original_has_bundled
        assert.equals(8, #items)
    end)

    it("groups all More config items by their prefixed categories", function()
        withAnimationEnvironment(function()
            local controller = makeController({
                tap_navigation = false,
                swipe_navigation = true,
                invert_swipe = false,
                panel_prerender = true,
                hold_text_selection = true,
            })

            controller:showMoreConfigMenu({ nav_transition_mode = "classic" })
            local items = UIManager._last_shown.item_table
            assert.equals("[Navigation]: Tap screen sides to navigate (Actual: false)", items[1].text)
            assert.equals("[Navigation]: Swipe to navigate (Actual: true)", items[2].text)
            assert.equals("[Navigation]: Invert panel swipe direction (Actual: false)", items[3].text)
            assert.equals("[Navigation]: Invert tap screens direction (Actual: false)", items[4].text)
            assert.equals("[Navigation]: Kobo-like edge vertical gesture (Actual: true)", items[5].text)
            assert.equals("[Navigation]: Remember per-document settings (Actual: true)", items[6].text)
            assert.equals("[Performance]: Pre-render next panel (Actual: true)", items[7].text)
            assert.equals("[Text Selection]: Touch & hold (Actual: true)", items[8].text)
        end)
    end)

    it("toggles kobo-like edge vertical gesture in place", function()
        local controller = makeController({ kobo_vertical_gesture = true })
        local viewer = { kobo_vertical_gesture = true }

        controller:showMoreConfigMenu(viewer)
        local items = UIManager._last_shown.item_table
        assert.equals("[Navigation]: Kobo-like edge vertical gesture (Actual: true)", items[5].text)
        assert.is_true(items[5].checked_func())

        -- Click the option to toggle it off
        items[5].callback()
        assert.is_false(controller.settings.kobo_vertical_gesture)
        assert.is_false(viewer.kobo_vertical_gesture)

        -- Check the re-opened menu item state
        local updated_items = UIManager._last_shown.item_table
        assert.equals("[Navigation]: Kobo-like edge vertical gesture (Actual: false)", updated_items[5].text)
        assert.is_false(updated_items[5].checked_func())
    end)

    it("keeps later groups visible when page animations are unsupported", function()
        local old_can_do_swipe_animation = Device.canDoSwipeAnimation
        Device.canDoSwipeAnimation = function()
            return false
        end
        local controller = makeController({
            tap_navigation = false,
            swipe_navigation = true,
            invert_swipe = false,
            invert_taps = false,
            remember_doc_settings = true,
            panel_prerender = true,
            hold_text_selection = true,
        })

        controller:showMoreConfigMenu({ nav_transition_mode = "classic" })
        local items = UIManager._last_shown.item_table
        assert.equals(11, #items)
        assert.equals("[Performance]: Pre-render next panel (Actual: true)", items[7].text)
        assert.equals("[Text Selection]: Touch & hold (Actual: true)", items[8].text)
        assert.equals("[OCR language]: English", items[9].text)

        Device.canDoSwipeAnimation = old_can_do_swipe_animation
    end)

    it("keeps the moved settings out of the main plugin menu", function()
        local menu_items = {}
        MainMenu.addToMainMenu({
            settings = { mode = "manga" },
            getModeText = function()
                return "Panels+"
            end,
        }, menu_items)

        local moved = {
            ["Invert panel swipe direction"] = true,
            ["Pre-render next panel"] = true,
            ["Touch & hold text selection in zoom [EXPERIMENTAL]"] = true,
        }
        for _, item in ipairs(menu_items.panels_plus.sub_item_table) do
            assert.is_nil(moved[item.text])
        end
    end)
end)

describe("ViewerController native page-turn animation", function()
    it("uses Comic and Manga reading flow for panel and page animation direction", function()
        local old_can_do_swipe_animation = Device.canDoSwipeAnimation
        local old_set_animations = Screen.setSwipeAnimations
        local old_set_direction = Screen.setSwipeDirection
        local animations, directions = spy(), spy()
        Device.canDoSwipeAnimation = function()
            return true
        end
        Screen.setSwipeAnimations = function(...)
            animations(...)
        end
        Screen.setSwipeDirection = function(...)
            directions(...)
        end

        local controller = setmetatable({
            settings = {},
            ui = {},
        }, { __index = ViewerController })
        local animated_viewer = {
            nav_transition_mode = "animated",
            nav_animated_panels = true,
            nav_animated_pages = true,
            reading_mode = "comic",
        }

        assert.is_true(controller:armPageTurnAnimation("next", animated_viewer))
        assert.equals(true, animations:lastCall()[2])
        assert.equals(true, directions:lastCall()[2])

        animated_viewer.reading_mode = "manga"
        assert.is_true(controller:armPanelTransitionAnimation("next", animated_viewer))
        assert.equals(false, directions:lastCall()[2])

        assert.is_true(controller:armPanelTransitionAnimation("previous", animated_viewer))
        assert.equals(true, directions:lastCall()[2])

        local animation_count = animations:callCount()
        animated_viewer.nav_animated_pages = false
        assert.is_false(controller:armPageTurnAnimation("next", animated_viewer))
        assert.equals(animation_count, animations:callCount())

        Device.canDoSwipeAnimation = old_can_do_swipe_animation
        Screen.setSwipeAnimations = old_set_animations
        Screen.setSwipeDirection = old_set_direction
    end)

    it("arms a fixed-layout handoff after building the destination and before replacing the viewer", function()
        local old_build_images = PanelCollector.buildImages
        local old_new = PanelViewer.new
        local old_close, old_show = UIManager.close, UIManager.show
        local sequence = {}
        local source_viewer = { nav_transition_mode = "animated", nav_animated_pages = true }
        local destination_viewer = {}

        PanelCollector.buildImages = function()
            table.insert(sequence, "build")
            return { {} }, { {} }, { false }
        end
        PanelViewer.new = function()
            return destination_viewer
        end
        UIManager.close = function(_, viewer)
            assert.equals(source_viewer, viewer)
            table.insert(sequence, "close")
        end
        UIManager.show = function(_, viewer)
            assert.equals(destination_viewer, viewer)
            table.insert(sequence, "show")
        end

        local controller = setmetatable({
            settings = {
                mode = "manga",
                crop_mode = "strict",
                nav_transition_mode = "animated",
                nav_animated_panels = true,
                nav_animated_pages = true,
            },
            ui = {},
            armPageTurnAnimation = function(_, direction, viewer)
                assert.equals("next", direction)
                assert.equals(source_viewer, viewer)
                table.insert(sequence, "arm")
                return true
            end,
        }, { __index = ViewerController })

        assert.is_true(controller:showPanelViewerForPage(2, { {} }, 1, {
            replace_viewer = source_viewer,
            boundary_direction = "next",
            defer_preload = true,
        }))
        assert.equals("build,arm,close,show", table.concat(sequence, ","))

        PanelCollector.buildImages = old_build_images
        PanelViewer.new = old_new
        UIManager.close, UIManager.show = old_close, old_show
    end)
end)

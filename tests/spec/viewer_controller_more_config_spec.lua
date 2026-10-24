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
local PanelsPlus = require("main")
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
            saveDocSettings = function() end,
        }, { __index = ViewerController })
        return controller, saved
    end

    local function shownOcrMenu()
        return UIManager._last_shown[1]
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

    it("shares animation toggles with the advanced menu and updates the active viewer", function()
        local controller = makeController(Settings.withDefaults({}))
        controller.setNavAnimatedPanels = PanelsPlus.setNavAnimatedPanels
        local viewer = { nav_animated_panels = true }
        controller.active_panel_viewer = viewer
        local items = MainMenu.animationItems(controller)
        assert.equals(7, #items)
        assert.equals("Animate between panels", items[1].text)
        assert.is_true(items[1].checked_func())
        items[1].callback()
        assert.is_false(controller.settings.nav_animated_panels)
        assert.is_false(viewer.nav_animated_panels)
    end)

    it("saves animation tuning from the advanced input after the menu closes", function()
        local controller = makeController(Settings.withDefaults({}))
        controller.setNavTransitionDuration = PanelsPlus.setNavTransitionDuration
        local viewer = { nav_transition_duration = 0.4 }
        controller.active_panel_viewer = viewer
        local old_tick, old_spin = UIManager.nextTick, package.loaded["ui/widget/spinwidget"]
        local next_tick
        UIManager.nextTick = function(_, callback)
            next_tick = callback
        end
        package.loaded["ui/widget/spinwidget"] = {
            new = function(_, options)
                return options
            end,
        }
        MainMenu.animationItems(controller)[4].callback()
        assert.equals("function", type(next_tick))
        next_tick()
        local spin = UIManager._last_shown
        assert.equals(400, spin.value)
        spin.callback({ value = 650 })
        assert.equals(0.65, controller.settings.nav_transition_duration)
        assert.equals(0.65, viewer.nav_transition_duration)
        UIManager.nextTick, package.loaded["ui/widget/spinwidget"] = old_tick, old_spin
    end)

    it("cycles Smooth styles in the advanced menu and updates the active viewer", function()
        local controller, saved = makeController(Settings.withDefaults({ nav_smooth_style = "linear" }))
        controller.setNavSmoothStyle = PanelsPlus.setNavSmoothStyle
        local viewer = { nav_smooth_style = "linear", nav_transition_mode = "smooth" }
        controller.active_panel_viewer = viewer
        local item = MainMenu.animationItems(controller)[6]
        local refreshed = spy()
        assert.equals("Smooth style: linear", item.text_func())
        item.callback({ updateItems = refreshed })
        assert.equals("ease", controller.settings.nav_smooth_style)
        assert.equals("ease", viewer.nav_smooth_style)
        assert.equals("Smooth style: ease", item.text_func())
        assert.equals(1, refreshed:callCount())
        item.callback()
        assert.equals("ease-in", controller.settings.nav_smooth_style)
        assert.equals("ease-in", viewer.nav_smooth_style)
        assert.equals("smooth", viewer.nav_transition_mode)
        assert.equals(2, saved:callCount())
    end)

    it("defaults both Animated mode options to true", function()
        local settings = Settings.withDefaults({})
        assert.is_true(settings.nav_animated_panels)
        assert.is_true(settings.nav_animated_pages)
        assert.equals("eng", settings.ocr_bundled_language)
        assert.is_true(settings.prefer_native_text_layer)
    end)

    it("selects a bundled language in the current viewer and saves it", function()
        local controller, saved = makeController(Settings.withDefaults({}))
        local viewer = { ocr_bundled_language = "eng" }
        controller:setBundledOcrLanguage(viewer, "spa")
        assert.equals("spa", controller.settings.ocr_bundled_language)
        assert.equals("spa", viewer.ocr_bundled_language)
        assert.equals(1, saved:callCount())
    end)

    it("opens OCR Language from the quick-action rail", function()
        local opened
        local viewer = PanelViewer:new({
            width = 600,
            ocr_language_callback = function(current)
                opened = current
            end,
        })
        viewer:replaceButtonTable()
        assert.equals("ocr_language", viewer.quick_controls.ocr_language.id)
        viewer.quick_controls.ocr_language.callback()
        assert.equals(viewer, opened)
    end)

    it("discovers fixture models in data/tessdata and rejects path-like choices", function()
        local old_storage, old_lfs = package.loaded.datastorage, package.loaded["libs/libkoreader-lfs"]
        package.loaded.datastorage = {
            getDataDir = function()
                return "/reader"
            end,
        }
        package.loaded["libs/libkoreader-lfs"] = {
            dir = function(directory)
                assert.equals("/reader/data/tessdata", directory)
                local names =
                    { ".", "fixture_z.traineddata", "notes.txt", "fixture_a.traineddata", "../bad.traineddata" }
                local index = 0
                return function()
                    index = index + 1
                    return names[index]
                end
            end,
            attributes = function(_, attribute)
                return attribute == "mode" and "file" or nil
            end,
        }
        local languages = WordFinder.availableUserLanguages()
        assert.equals(2, #languages)
        assert.equals("fixture_a", languages[1])
        assert.equals("fixture_z", languages[2])
        local dir, code = WordFinder.selectedModel("user:fixture_z")
        assert.equals("/reader/data/tessdata", dir)
        assert.equals("fixture_z", code)
        assert.is_nil(WordFinder.selectedModel("user:../bad"))
        package.loaded.datastorage, package.loaded["libs/libkoreader-lfs"] = old_storage, old_lfs
    end)

    it("offers bundled and installed models in the in-zoom picker with one selection", function()
        local controller, saved = makeController(Settings.withDefaults({}))
        local original_installed = WordFinder.availableUserLanguages
        local original_directory = WordFinder.userModelDirectory
        WordFinder.availableUserLanguages = function()
            return { "eng", "spa" }
        end
        WordFinder.userModelDirectory = function()
            return "/reader/data/tessdata"
        end
        local viewer = { ocr_bundled_language = "eng" }
        controller:showOcrLanguageMenu(viewer)
        local choices = shownOcrMenu().item_table
        assert.equals("Select OCR Model", shownOcrMenu().title)
        assert.is_true(shownOcrMenu().width < 600)
        assert.is_true(shownOcrMenu().height < 800)
        assert.equals("Panels+ Fine-Tuned", choices[1].text)
        assert.equals("◉ English", choices[2].text)
        assert.is_true(choices[2].bold)
        assert.equals("In use", choices[2].mandatory)
        assert.equals(2, choices.current)
        assert.equals("○ Spanish", choices[3].text)
        assert.is_nil(choices[3].mandatory)
        assert.equals("KOReader User Installed", choices[4].text)
        assert.is_true(choices[5].text:match("^○ ") ~= nil)
        assert.is_nil(choices[5].mandatory)
        assert.equals("Close", choices[#choices].text)

        choices[6].callback()
        assert.equals("user:spa", controller.settings.ocr_bundled_language)
        assert.equals("user:spa", controller.settings.ocr_preferred_user_language)
        assert.equals("user:spa", viewer.ocr_bundled_language)
        assert.equals(1, saved:callCount())
        local updated = shownOcrMenu().item_table
        assert.equals("○ English", updated[2].text)
        assert.is_nil(updated[2].mandatory)
        assert.is_true(updated[5].text:match("^○ ") ~= nil)
        assert.is_true(updated[6].text:match("^◉ ") ~= nil)
        assert.equals("In use", updated[6].mandatory)
        assert.equals(6, updated.current)

        updated[3].callback()
        local switched_back = shownOcrMenu().item_table
        assert.equals("spa", controller.settings.ocr_bundled_language)
        assert.equals("spa", controller.settings.ocr_preferred_bundled_language)
        assert.is_true(switched_back[3].text:match("^◉ ") ~= nil)
        assert.equals("In use", switched_back[3].mandatory)
        assert.equals(3, switched_back.current)
        assert.is_true(switched_back[6].text:match("^○ ") ~= nil)
        assert.is_nil(switched_back[6].mandatory)
        switched_back[#switched_back].callback()
        WordFinder.availableUserLanguages = original_installed
        WordFinder.userModelDirectory = original_directory
    end)

    it("shows the full native-text preference in the main menu and persists toggles", function()
        local controller, saved = makeController(Settings.withDefaults({}))
        controller.setPreferNativeTextLayer = PanelsPlus.setPreferNativeTextLayer
        controller.active_panel_viewer = { prefer_native_text_layer = true }
        local menu_items = {}
        MainMenu.addToMainMenu(controller, menu_items)
        local preference = menu_items.panels_plus.sub_item_table[6]

        assert.equals("Prefer native-text layer in PDF files over Panels+ text recognition", preference.text)
        assert.is_true(preference.help_text:find(preference.text, 1, true) == 1)
        assert.equals("function", type(preference.font_func))
        assert.is_true(preference.checked_func())
        preference.callback()
        assert.is_false(preference.checked_func())
        assert.is_false(controller.settings.prefer_native_text_layer)
        assert.is_false(controller.active_panel_viewer.prefer_native_text_layer)
        assert.equals(1, saved:callCount())
    end)

    it("explains installation when the manual package has no OCR models", function()
        local original_available = WordFinder.availableBundledLanguages
        local original_installed = WordFinder.availableUserLanguages
        WordFinder.availableBundledLanguages = function()
            return {}
        end
        WordFinder.availableUserLanguages = function()
            return {}
        end
        local controller = makeController(Settings.withDefaults({}))
        local menu_items = {}
        MainMenu.addToMainMenu(controller, menu_items)
        assert.equals(9, #menu_items.panels_plus.sub_item_table)
        controller:showOcrLanguageMenu({})
        local choices = shownOcrMenu().item_table
        assert.equals(3, #choices)
        assert.is_true(choices[2].text:find("/koreader/data/tessdata", 1, true) ~= nil)
        assert.equals("Close", choices[3].text)
        controller:showMoreConfigMenu({})
        local items = UIManager._last_shown[1].item_table
        WordFinder.availableBundledLanguages = original_available
        WordFinder.availableUserLanguages = original_installed
        assert.equals(9, #items)
    end)

    it("allows a user model as the only available OCR choice", function()
        local original_available = WordFinder.availableBundledLanguages
        local original_installed = WordFinder.availableUserLanguages
        local original_directory = WordFinder.userModelDirectory
        WordFinder.availableBundledLanguages = function()
            return {}
        end
        WordFinder.availableUserLanguages = function()
            return { "jpn" }
        end
        WordFinder.userModelDirectory = function()
            return "/reader/data/tessdata"
        end
        local controller = makeController(Settings.withDefaults({}))
        local viewer = {}
        controller:showOcrLanguageMenu(viewer)
        local choices = shownOcrMenu().item_table
        assert.equals(3, #choices)
        assert.is_true(choices[2].text:match("^◉ ") ~= nil)
        assert.equals("In use", choices[2].mandatory)
        choices[2].callback()
        assert.equals("user:jpn", controller.settings.ocr_bundled_language)
        assert.equals("user:jpn", viewer.ocr_bundled_language)
        WordFinder.availableBundledLanguages = original_available
        WordFinder.availableUserLanguages = original_installed
        WordFinder.userModelDirectory = original_directory
    end)

    it("opens a long model list on the page containing the active radio choice", function()
        local original_available = WordFinder.availableBundledLanguages
        local original_installed = WordFinder.availableUserLanguages
        WordFinder.availableBundledLanguages = function()
            return {}
        end
        WordFinder.availableUserLanguages = function()
            return { "a", "b", "c", "d", "e", "f", "g", "h", "i", "j" }
        end
        local controller = makeController(Settings.withDefaults({ ocr_bundled_language = "user:j" }))
        controller:showOcrLanguageMenu({})
        local menu = shownOcrMenu()
        assert.equals(8, menu.items_per_page)
        assert.equals(12, #menu.item_table)
        assert.equals(11, menu.item_table.current)
        assert.equals("◉ j", menu.item_table[11].text)
        assert.equals("In use", menu.item_table[11].mandatory)
        WordFinder.availableBundledLanguages = original_available
        WordFinder.availableUserLanguages = original_installed
    end)

    it("offers a partial bundle and falls back to its available model", function()
        local original_available = WordFinder.availableBundledLanguages
        local original_installed = WordFinder.availableUserLanguages
        WordFinder.availableBundledLanguages = function()
            return { "spa" }
        end
        WordFinder.availableUserLanguages = function()
            return {}
        end
        local controller = makeController(Settings.withDefaults({}))
        controller:showOcrLanguageMenu({})
        local choices = shownOcrMenu().item_table
        assert.equals(3, #choices)
        assert.equals("◉ Spanish", choices[2].text)
        assert.equals("In use", choices[2].mandatory)
        WordFinder.availableBundledLanguages = original_available
        WordFinder.availableUserLanguages = original_installed
    end)

    it("shows eight common settings with SVG icons and a final advanced shortcut", function()
        local controller = makeController(Settings.withDefaults({ tap_navigation = false }))
        controller:showMoreConfigMenu({})
        local menu = UIManager._last_shown[1]
        local labels = {
            "Tap screen sides to navigate",
            "Swipe to navigate",
            "Invert panel swipe direction",
            "Invert tap direction",
            "Open panels with",
            "Rotate spreads",
            "Remove spread fold line",
            "Touch & hold text selection",
            "Open advanced options",
        }
        assert.equals(9, #menu.item_table)
        for index, label in ipairs(labels) do
            assert.equals(label, menu.item_table[index].text)
            local file = io.open(menu.item_table[index].icon_file, "r")
            assert.is_true(file ~= nil)
            file:close()
        end
        assert.equals("Off", menu.item_table[1].mandatory)
        assert.equals("On", menu.item_table[2].mandatory)
        assert.is_true(menu.item_table[9].separator)
        local opened
        controller.showAdvancedOptions = function(_, viewer)
            opened = viewer
        end
        local viewer = {}
        controller:showMoreConfigMenu(viewer)
        UIManager._last_shown[1].item_table[9].callback()
        assert.equals(viewer, opened)
    end)

    it("centers a 90-percent menu within the full screen in both orientations", function()
        local old_width, old_height = Screen.getWidth, Screen.getHeight
        for _, size in ipairs({ { 600, 800 }, { 1200, 800 }, { 800, 600 } }) do
            Screen.getWidth = function()
                return size[1]
            end
            Screen.getHeight = function()
                return size[2]
            end
            local controller = makeController(Settings.withDefaults({}))
            controller:showMoreConfigMenu({})
            local container = UIManager._last_shown
            local menu = container[1]
            assert.equals(size[1], container.dimen.w)
            assert.equals(size[2], container.dimen.h)
            assert.equals(math.floor(size[1] * 0.9), menu.width)
            assert.equals(math.floor(size[2] * 0.9), menu.height)
            assert.equals(container, menu.show_parent)
        end
        Screen.getWidth, Screen.getHeight = old_width, old_height
    end)

    it("closes the centered container when toggling or dismissing the menu", function()
        local old_close = UIManager.close
        local closed
        UIManager.close = function(_, widget)
            closed = widget
        end
        local controller = makeController(Settings.withDefaults({ tap_navigation = false }))
        controller.setTapNavigation = PanelsPlus.setTapNavigation
        controller:showMoreConfigMenu({})
        local first_container = UIManager._last_shown
        first_container[1].item_table[1].callback()
        assert.equals(first_container, closed)
        assert.is_nil(first_container[1].close_callback)
        local second_container = UIManager._last_shown
        assert.is_true(first_container ~= second_container)
        second_container[1].close_callback()
        assert.equals(second_container, closed)
        UIManager.close = old_close
    end)

    it("renders each SVG in the leading icon slot", function()
        local previous = package.loaded["ui/widget/iconwidget"]
        package.loaded["ui/widget/iconwidget"] = {
            new = function(_, options)
                return options
            end,
        }
        local controller = makeController(Settings.withDefaults({}))
        controller:showMoreConfigMenu({})
        local menu = UIManager._last_shown[1]
        -- Rendering initializes these fields in KOReader's Menu:init.
        menu.page, menu.perpage = 1, 9
        local dimension = { w = 28, h = 28 }
        for index, key in ipairs(menu.item_shortcuts) do
            local container = menu:getItemShortCutIcon(dimension, key)
            assert.equals(menu.item_table[index].icon_file, container[1].file)
            assert.equals(28, container[1].width)
            assert.equals(dimension, container.dimen)
        end
        package.loaded["ui/widget/iconwidget"] = previous
    end)

    it("toggles quick navigation settings in place", function()
        local controller = makeController(Settings.withDefaults({ tap_navigation = false }))
        controller.setTapNavigation = PanelsPlus.setTapNavigation
        local viewer = { tap_navigation = false }
        controller:showMoreConfigMenu(viewer)
        UIManager._last_shown[1].item_table[1].callback()
        assert.is_true(controller.settings.tap_navigation)
        assert.is_true(viewer.tap_navigation)
        assert.equals("On", UIManager._last_shown[1].item_table[1].mandatory)
    end)

    it("preserves the More Config page after toggles, viewer rebuilds, and gesture selection", function()
        local Menu = require("ui/widget/menu")
        local old_new, old_height = Menu.new, Screen.getHeight
        Screen.getHeight = function()
            return 320
        end
        Menu.new = function(_, options)
            local menu = old_new(Menu, options)
            menu.page = 1 -- KOReader's Menu:init always resets pagination.
            menu.updateItems = function(self)
                self.page = math.min(self.page, math.ceil(#self.item_table / (self.items_per_page or 4)))
                self.rendered_page = self.page
            end
            return menu
        end
        local ok, err = pcall(function()
            local controller = makeController(Settings.withDefaults({}))
            controller.setHoldTextSelection = PanelsPlus.setHoldTextSelection
            controller.setPanelGesture = PanelsPlus.setPanelGesture
            controller.applyNativePanelSetting = spy()
            controller.applyPanelGesture = spy()
            local viewer = { replaceButtonTable = function() end, update = function() end }
            local rebuilt = { replaceButtonTable = function() end, update = function() end }
            controller.cycleViewerSpreadRotationMode = function()
                return rebuilt
            end
            controller.toggleViewerJoinSpreadFold = function(_, current)
                assert.equals(rebuilt, current)
                return rebuilt
            end
            controller:showMoreConfigMenu(viewer)
            local menu = UIManager._last_shown[1]
            menu.page = 2
            menu.item_table[8].callback()
            menu = UIManager._last_shown[1]
            assert.equals(2, menu.page)
            assert.equals(2, menu.rendered_page)
            assert.equals("Off", menu.item_table[8].mandatory)
            menu.item_table[6].callback()
            menu = UIManager._last_shown[1]
            assert.equals(2, menu.page)
            menu.item_table[7].callback()
            menu = UIManager._last_shown[1]
            assert.equals(2, menu.page)
            menu.item_table[5].callback()
            local picker = UIManager._last_shown
            picker.item_table[2].callback()
            picker.close_callback()
            menu = UIManager._last_shown[1]
            assert.equals(2, menu.page)
            assert.equals("Two-finger tap", menu.item_table[5].mandatory)

            -- A fresh visit starts normally; pagination is only carried over
            -- while changing settings in the existing menu session.
            controller:showMoreConfigMenu(rebuilt)
            assert.equals(1, UIManager._last_shown[1].page)
        end)
        Menu.new, Screen.getHeight = old_new, old_height
        if not ok then
            error(err)
        end
    end)

    it("updates the OCR icon immediately when text selection is toggled", function()
        local controller = makeController(Settings.withDefaults({}))
        controller.setHoldTextSelection = PanelsPlus.setHoldTextSelection
        local updated = spy()
        local viewer = PanelViewer:new({ width = 600, update = updated })
        controller:showMoreConfigMenu(viewer)
        UIManager._last_shown[1].item_table[8].callback()
        assert.is_false(viewer.hold_text_selection)
        assert.is_true(viewer.quick_controls.ocr_language.dim)
        assert.equals("Off", UIManager._last_shown[1].item_table[8].mandatory)
        UIManager._last_shown[1].item_table[8].callback()
        assert.is_true(viewer.hold_text_selection)
        assert.is_false(viewer.quick_controls.ocr_language.dim)
        assert.equals(2, updated:callCount())
    end)

    it("toggles swipe and tap inversion immediately in the open viewer", function()
        local controller = makeController(Settings.withDefaults({}))
        controller.setInvertSwipe = PanelsPlus.setInvertSwipe
        controller.setInvertTaps = PanelsPlus.setInvertTaps
        local viewer = { invert_swipe = false, invert_taps = false }
        controller:showMoreConfigMenu(viewer)
        UIManager._last_shown[1].item_table[3].callback()
        assert.is_true(controller.settings.invert_swipe)
        assert.is_true(viewer.invert_swipe)
        assert.equals("On", UIManager._last_shown[1].item_table[3].mandatory)
        UIManager._last_shown[1].item_table[4].callback()
        assert.is_true(controller.settings.invert_taps)
        assert.is_true(viewer.invert_taps)
        assert.equals("On", UIManager._last_shown[1].item_table[4].mandatory)
        UIManager._last_shown[1].item_table[3].callback()
        assert.is_false(viewer.invert_swipe)
        assert.equals("Off", UIManager._last_shown[1].item_table[3].mandatory)
    end)

    it("changes the panel-opening gesture and returns to the quick settings", function()
        local controller = makeController(Settings.withDefaults({}))
        controller.setPanelGesture = PanelsPlus.setPanelGesture
        controller.applyNativePanelSetting = spy()
        controller.applyPanelGesture = spy()
        controller:showMoreConfigMenu({})
        assert.equals("Long press", UIManager._last_shown[1].item_table[5].mandatory)
        UIManager._last_shown[1].item_table[5].callback()
        local picker = UIManager._last_shown
        assert.equals("Long press", picker.item_table[1].text)
        assert.equals("Two-finger tap", picker.item_table[2].text)
        picker.item_table[2].callback()
        picker.close_callback()
        assert.equals("two_finger_tap", controller.settings.panel_gesture)
        assert.equals(1, controller.applyPanelGesture:callCount())
        assert.equals("Two-finger tap", UIManager._last_shown[1].item_table[5].mandatory)
    end)

    it("keeps icons on later pages and adapts the row count for short screens", function()
        local old_height = Screen.getHeight
        Screen.getHeight = function()
            return 320
        end
        local controller = makeController(Settings.withDefaults({}))
        controller:showMoreConfigMenu({})
        local menu = UIManager._last_shown[1]
        assert.equals(4, menu.items_per_page)
        local previous = package.loaded["ui/widget/iconwidget"]
        package.loaded["ui/widget/iconwidget"] = {
            new = function(_, options)
                return options
            end,
        }
        menu.page, menu.perpage = 3, 4
        local icon = menu:getItemShortCutIcon({ w = 28, h = 28 }, "Q")
        assert.equals(menu.item_table[9].icon_file, icon[1].file)
        package.loaded["ui/widget/iconwidget"] = previous
        Screen.getHeight = old_height
    end)

    it("keeps all common settings when hardware animation is unsupported", function()
        local previous = Device.canDoSwipeAnimation
        Device.canDoSwipeAnimation = function()
            return false
        end
        local controller = makeController(Settings.withDefaults({}))
        controller:showMoreConfigMenu({})
        assert.equals(9, #UIManager._last_shown[1].item_table)
        Device.canDoSwipeAnimation = previous
    end)

    it("allows text selection for embedded-image viewers", function()
        local controller = makeController(Settings.withDefaults({}))
        controller:showMoreConfigMenu({ embedded_source_image = {} })
        local item = UIManager._last_shown[1].item_table[8]
        assert.equals("On", item.mandatory)
        assert.is_nil(item.select_enabled)
    end)

    it("keeps common spread and reading-order settings out of advanced options", function()
        local menu_items = {}
        MainMenu.addToMainMenu({ settings = Settings.withDefaults({}) }, menu_items)
        local common = {
            ["Auto-rotate double-page spreads"] = true,
            ["Remove the fold line from double-page spreads"] = true,
            ["Manga mode (right to left)"] = true,
            ["Comic mode (left to right)"] = true,
        }
        local advanced = {}
        for _, item in ipairs(menu_items.panels_plus.sub_item_table) do
            assert.is_nil(common[item.text])
            advanced[item.text] = true
        end
        assert.is_nil(advanced["Invert tap direction"])
        assert.is_nil(advanced["Invert panel swipe direction"])
        assert.is_true(advanced["Open panels with"])
        assert.is_true(advanced["Pre-render next panel"])
        assert.is_true(advanced["Animation"])
    end)
end)

describe("Advanced options reader-menu navigation", function()
    local function fixture(touch)
        local plugin = {
            panels_plus_menu = true,
            text = "Translated Panels+",
            sub_item_table = {
                { text = "Animation", panels_plus_section = "animation", sub_item_table = { { text = "Option" } } },
            },
        }
        local unrelated = { text = "Unrelated" }
        local tools = { text = "Tools", sub_item_table = { unrelated, plugin } }
        local selected, states = {}, { stack = {} }
        local menu = { close_callback = spy(), item_table = { tools } }
        if touch then
            menu.tab_item_table = { { unrelated }, { tools } }
            menu.switchMenuTab = function(self, tab)
                states.tab = tab
                self.item_table = self.tab_item_table[tab]
            end
            menu.bar = {
                switchToTab = function(_, tab)
                    states.bar = tab
                    menu:switchMenuTab(tab)
                end,
            }
        end
        menu.onMenuSelect = function(self, item)
            assert.equals(item, self.item_table[item.idx])
            states.stack[#states.stack + 1] = self.item_table
            selected[#selected + 1] = item
            self.item_table = item.sub_item_table
        end
        menu.onBack = function(self)
            self.item_table = table.remove(states.stack)
        end
        local reader_menu = { menu_container = { menu } }
        reader_menu.onShowMenu = function(_, _, hidden)
            states.hidden = hidden
        end
        local controller = setmetatable({ ui = { menu = reader_menu } }, { __index = ViewerController })
        return controller, menu, selected, states, plugin
    end

    it("enters the Panels+ submenu through the current touch-menu tree", function()
        local controller, menu, selected, states, plugin = fixture(true)
        local viewer = { page = 9, _images_list_cur = 3 }
        assert.is_true(controller:showAdvancedOptions(viewer))
        assert.is_true(states.hidden)
        assert.equals(2, states.tab)
        assert.equals(2, states.bar)
        assert.equals(plugin, selected[2])
        assert.equals(plugin.sub_item_table, menu.item_table)
        assert.equals(2, plugin.idx)
        assert.equals(viewer, controller:getOpenPanelViewer())
        menu:onBack()
        assert.equals(plugin, menu.item_table[2])
        local original = menu.close_callback
        original()
        assert.is_nil(controller._panels_plus_config_viewer)
        assert.equals(9, viewer.page)
        assert.equals(3, viewer._images_list_cur)
    end)

    it("uses the keyboard menu's own submenu stack", function()
        local controller, menu, selected, _, plugin = fixture(false)
        controller:showAdvancedOptions({})
        assert.equals(2, #selected)
        assert.equals(plugin.sub_item_table, menu.item_table)
    end)

    it("opens the shared Animation section from a navigation-button hold", function()
        local controller, menu, selected, _, plugin = fixture(true)
        controller:showNavTransitionOptionsMenu({ nav_transition_mode = "smooth" })
        assert.equals(3, #selected)
        assert.equals(plugin.sub_item_table[1].sub_item_table, menu.item_table)
    end)

    it("restores the settings page after a preview in touch and keyboard menus", function()
        for _, touch in ipairs({ true, false }) do
            local controller, menu = fixture(touch)
            local refreshed = 0
            menu.updateItems = function(self)
                refreshed = refreshed + 1
                assert.equals(2, self.page)
            end
            controller:showAdvancedOptions({}, "animation", 2)
            assert.equals(2, menu.page)
            assert.equals(1, refreshed)
        end
    end)

    it("rebuilds changed spread geometry only after closing the reader menu", function()
        local controller, menu = fixture(true)
        local viewer = { page = 7, _images_list_cur = 4 }
        local rebuilt
        controller.rebuildViewerForSpreadOptions = function(_, current)
            rebuilt = current
        end
        controller:showAdvancedOptions(viewer)
        controller._panels_plus_spread_options_changed = true
        menu.close_callback()
        assert.equals(viewer, rebuilt)
        assert.is_nil(controller._panels_plus_spread_options_changed)
    end)

    it("finds embedded-image viewers and ignores closed viewers", function()
        local old_windows = UIManager._window_stack
        local controller = setmetatable({ ui = {} }, { __index = ViewerController })
        local viewer = { reader_ui = controller.ui, name = PanelViewer.name, embedded_source_image = {} }
        UIManager._window_stack = { { widget = viewer } }
        assert.equals(viewer, controller:getOpenPanelViewer())
        viewer._panels_plus_closed = true
        assert.is_nil(controller:getOpenPanelViewer())
        UIManager._window_stack = old_windows
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

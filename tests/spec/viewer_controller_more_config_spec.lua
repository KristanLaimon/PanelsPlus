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
        assert.is_true(settings.prefer_native_text_layer)
    end)

    it("selects a bundled language in the current viewer and saves it", function()
        local controller, saved = makeController(Settings.withDefaults({}))
        local viewer = { ocr_bundled_language = "eng" }
        controller:setBundledOcrLanguage(viewer, "ita")
        assert.equals("ita", controller.settings.ocr_bundled_language)
        assert.equals("ita", viewer.ocr_bundled_language)
        assert.equals(1, saved:callCount())
    end)

    it("places OCR Language between progress and navigation controls", function()
        local opened
        local viewer = PanelViewer:new({
            width = 600,
            ocr_language_callback = function(current)
                opened = current
            end,
        })
        viewer:replaceButtonTable()
        local row = viewer.button_table.buttons[2]
        assert.equals(4, #row)
        assert.equals("progress_bar", row[2].id)
        assert.equals("ocr_language", row[3].id)
        assert.equals("nav_transition", row[4].id)
        row[3].callback()
        assert.equals(viewer, opened)
    end)

    it("finds installed tessdata models and rejects path-like choices", function()
        local old_storage, old_lfs = package.loaded.datastorage, package.loaded.lfs
        package.loaded.datastorage = {
            getDataDir = function()
                return "/reader/data"
            end,
        }
        package.loaded.lfs = {
            dir = function()
                local names = { ".", "spa.traineddata", "notes.txt", "eng.traineddata", "../bad.traineddata" }
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
        assert.equals("eng", languages[1])
        assert.equals("spa", languages[2])
        local dir, code = WordFinder.selectedModel("user:spa")
        assert.equals("/reader/data/tessdata", dir)
        assert.equals("spa", code)
        assert.is_nil(WordFinder.selectedModel("user:../bad"))
        package.loaded.datastorage, package.loaded.lfs = old_storage, old_lfs
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
        assert.equals("KOReader User Installed", choices[5].text)
        assert.is_true(choices[6].text:match("^◉ ") ~= nil)
        assert.is_nil(choices[6].mandatory)
        assert.equals("Close", choices[#choices].text)

        choices[7].callback()
        assert.equals("user:spa", controller.settings.ocr_bundled_language)
        assert.equals("user:spa", controller.settings.ocr_preferred_user_language)
        assert.equals("user:spa", viewer.ocr_bundled_language)
        assert.equals(1, saved:callCount())
        local updated = shownOcrMenu().item_table
        assert.equals("◉ English", updated[2].text)
        assert.is_nil(updated[2].mandatory)
        assert.is_true(updated[6].text:match("^○ ") ~= nil)
        assert.is_true(updated[7].text:match("^◉ ") ~= nil)
        assert.equals("In use", updated[7].mandatory)
        assert.equals(7, updated.current)

        updated[4].callback()
        local switched_back = shownOcrMenu().item_table
        assert.equals("ita", controller.settings.ocr_bundled_language)
        assert.equals("ita", controller.settings.ocr_preferred_bundled_language)
        assert.is_true(switched_back[4].text:match("^◉ ") ~= nil)
        assert.equals("In use", switched_back[4].mandatory)
        assert.equals(4, switched_back.current)
        assert.is_true(switched_back[7].text:match("^◉ ") ~= nil)
        assert.is_nil(switched_back[7].mandatory)
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
        local preference = menu_items.panels_plus.sub_item_table[8]

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
        local items = UIManager._last_shown.item_table
        WordFinder.availableBundledLanguages = original_available
        WordFinder.availableUserLanguages = original_installed
        assert.equals(11, #items)
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
            assert.equals("[Rotation]: Rotate spreads (Actual: Viewer)", items[7].text)
            assert.equals("[Rotation]: Spread direction (Actual: KOReader)", items[8].text)
            assert.equals("[Rotation]: Remove spread fold line (Actual: true)", items[9].text)
            assert.equals("[Performance]: Pre-render next panel (Actual: true)", items[10].text)
            assert.equals("[Text Selection]: Touch & hold (Actual: true)", items[11].text)
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
        assert.equals("[Performance]: Pre-render next panel (Actual: true)", items[10].text)
        assert.equals("[Text Selection]: Touch & hold (Actual: true)", items[11].text)

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
        assert.equals(9, #menu_items.panels_plus.sub_item_table)
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

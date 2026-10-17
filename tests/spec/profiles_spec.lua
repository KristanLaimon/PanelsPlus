local framework = require("tests.PanelsPlusTestFramework")
local describe, it, assert = framework.describe, framework.it, framework.assert
local Profiles = require("src.profiles")
local Settings = require("src._settings")
local PanelsPlus = require("main")
local Device = require("device")
local UIManager = require("ui/uimanager")

local function plugin()
    local instance = setmetatable({
        settings = Settings.withDefaults({}),
        ui = { document = { file = "profiles.cbz" } },
        saveSettings = function(self)
            if not self._applying_profile then
                Profiles.invalidate(self.settings)
                self.saves = (self.saves or 0) + 1
            end
        end,
        getSelectedOcrModel = function(self)
            return self.settings.ocr_bundled_language
        end,
        notifyAnimatedModeUnsupported = function() end,
        collectPanels = function()
            return { { x = 0, y = 0, w = 100, h = 100 }, { x = 100, y = 0, w = 100, h = 100 } }
        end,
        showPanelViewerForPage = function(self, page, panels, index)
            self.rebuilds = (self.rebuilds or 0) + 1
            self.reopened = { page = page, panels = panels, index = index }
        end,
    }, { __index = PanelsPlus })
    return instance
end

local function viewer()
    return {
        page = 7,
        panels = { { x = 100, y = 0, w = 100, h = 100 } },
        _images_list_cur = 1,
        replaceButtonTable = function() end,
        update = function() end,
    }
end

local function lastDialog()
    return UIManager._last_shown
end

describe("Settings profiles", function()
    it("migrates all algorithm aliases globally and in document overrides", function()
        for _, mode in ipairs({ "legacy", "classic", "safe", "unknown" }) do
            assert.equals("safe", Settings.normalizePanelFindingMode(mode))
        end
        for _, mode in ipairs({ "normal", "detailed", "aggressive", "smart" }) do
            local settings = Settings.withDefaults({
                panel_finding_mode = mode,
                doc_settings = { book = { panel_finding_mode = mode } },
            })
            assert.equals("smart", settings.panel_finding_mode)
            assert.equals("smart", settings.doc_settings.book.panel_finding_mode)
        end
    end)

    it("separates Safe and Smart cache entries and normalizes old aliases", function()
        local p = plugin()
        local safe_key = p:getPanelCacheKey(7)
        p.settings.panel_finding_mode = "smart"
        local smart_key = p:getPanelCacheKey(7)
        assert.is_true(safe_key ~= smart_key)
        p.settings.panel_finding_mode = "normal"
        assert.equals(smart_key, p:getPanelCacheKey(7))
        p.settings.panel_finding_mode = "legacy"
        assert.equals(safe_key, p:getPanelCacheKey(7))
    end)

    it("seeds the recommendation once and leaves None selected", function()
        local old = Device.hasEinkScreen
        Device.hasEinkScreen = function()
            return true
        end
        local settings = Settings.withDefaults({})
        Device.hasEinkScreen = old
        local values = settings.profiles[1].values
        assert.equals("manga", values.mode)
        assert.is_false(values.progress_bar_visible)
        assert.equals("eng", values.ocr_bundled_language)
        assert.equals("none", values.crop_mode)
        assert.equals("animated", values.nav_transition_mode)
        assert.equals(3, values.rotation.value)
        assert.is_nil(settings.selected_profile_id)
        Profiles.delete(settings, "recommended")
        Settings.withDefaults(settings)
        assert.equals(0, #settings.profiles)
    end)

    it("captures device and explicit image rotation without sharing tables", function()
        local p = plugin()
        local current_mode = Device.screen:getRotationMode()
        local values = Profiles.capture(p.settings)
        assert.equals("device", values.rotation.kind)
        assert.equals(current_mode, values.rotation.value)
        p.settings.image_rotation = false
        values = Profiles.capture(p.settings)
        assert.equals("image", values.rotation.kind)
        assert.is_false(values.rotation.value)
        local profile = Profiles.create(p.settings, "  Custom  ", values)
        values.rotation.value = 90
        assert.equals("Custom", profile.name)
        assert.is_false(profile.values.rotation.value)
    end)

    it("rejects blank, reserved and duplicate names and keeps stable identities", function()
        local p = plugin()
        assert.is_nil(Profiles.create(p.settings, " ", {}))
        assert.is_nil(Profiles.create(p.settings, "none", {}))
        assert.is_nil(Profiles.create(p.settings, "RECOMMENDED", {}))
        local created = Profiles.create(p.settings, "My settings", Profiles.capture(p.settings))
        local id = created.id
        local renamed = Profiles.validateName(p.settings, "Renamed", id)
        assert.equals("Renamed", renamed)
        created.name = renamed
        assert.equals(id, created.id)
        Profiles.delete(p.settings, id)
        assert.is_nil(Profiles.find(p.settings, id))
    end)

    it("applies with one viewer rebuild and keeps the nearest panel position", function()
        local p = plugin()
        local v = viewer()
        local rotation = Device.screen:getRotationMode()
        local old_broadcast = UIManager.broadcastEvent
        UIManager.broadcastEvent = function(_, event)
            if event.name == "SetRotationMode" then
                Device.screen:setRotationMode(event.args[1])
            end
        end
        p:applySettingsProfile(v, "recommended")
        assert.equals(1, p.saves)
        assert.equals(1, p.rebuilds)
        assert.equals(7, p.reopened.page)
        assert.equals(2, p.reopened.index)
        assert.equals("recommended", p.settings.selected_profile_id)
        assert.equals("safe", p.settings.panel_finding_mode)
        assert.is_false(p.settings.progress_bar_visible)
        assert.equals(p.settings.nav_transition_mode, p.settings.embedded_nav_transition_mode)
        UIManager.broadcastEvent = old_broadcast
        Device.screen:setRotationMode(rotation)
    end)

    it("deselects on manual edits and leaves current settings when choosing None", function()
        local p = plugin()
        local values = Profiles.capture(p.settings)
        values.nav_transition_mode = "classic"
        p.settings.embedded_nav_transition_mode = "classic"
        local profile = Profiles.create(p.settings, "Match", values)
        p.settings.selected_profile_id = profile.id
        p:setProgressBarVisible(false)
        assert.is_nil(p.settings.selected_profile_id)
        p:applySettingsProfile(viewer(), nil)
        assert.is_false(p.settings.progress_bar_visible)
    end)

    it("restores None across profile switches and saves its latest manual changes", function()
        local p = plugin()
        p.settings.image_rotation = false
        p.settings.profiles[1].values.rotation = { kind = "image", value = false }
        p.settings.mode = "comic"
        p.settings.nav_transition_mode = "smooth"
        p.settings.embedded_nav_transition_mode = "classic"
        p.settings.nav_transition_duration = 0.75
        p.settings.panel_margin_ratio = 0.23
        local initial = Profiles.capture(p.settings)
        local other = Profiles.create(p.settings, "Other", initial)
        p:applySettingsProfile(viewer(), "recommended")
        p:applySettingsProfile(viewer(), other.id)
        p:applySettingsProfile(viewer(), nil)
        assert.is_nil(p.settings.selected_profile_id)
        assert.is_true(Profiles.matches(p.settings, initial))
        p:setMarginRatio(0.31)
        p:applySettingsProfile(viewer(), "recommended")
        p:applySettingsProfile(viewer(), nil)
        assert.equals(0.31, p.settings.panel_margin_ratio)
        assert.equals("classic", p.settings.embedded_nav_transition_mode)
    end)

    it("captures and restores every transition and crop suboption including false values", function()
        local p = plugin()
        p.settings.image_rotation = false
        local expected = {
            nav_animated_panels = false,
            nav_animated_pages = false,
            nav_transition_duration = 0.8,
            nav_transition_cross_page = false,
            nav_transition_frames = 17,
            panel_margin_ratio = 0.27,
            panel_bleed_ratio = 0.35,
            panel_bleed_min = 3,
        }
        for key, value in pairs(expected) do
            p.settings[key] = value
        end
        local profile = Profiles.create(p.settings, "Options", Profiles.capture(p.settings))
        p:applySettingsProfile(viewer(), "recommended")
        for key in pairs(expected) do
            assert.equals(Settings.defaults[key], p.settings[key])
        end
        p:applySettingsProfile(viewer(), profile.id)
        for key, value in pairs(expected) do
            assert.equals(value, p.settings[key])
        end
        assert.equals(profile.id, p.settings.selected_profile_id)
        p:setNavTransitionFrames(9)
        assert.is_nil(p.settings.selected_profile_id)
        assert.equals(9, p.settings.doc_settings["profiles.cbz"].nav_transition_frames)
    end)

    it("persists None and suboptions when reopening a document", function()
        local p = plugin()
        p.settings.image_rotation = false
        p.settings.profiles[1].values.rotation = { kind = "image", value = false }
        p:setNavTransitionDuration(0.7)
        p:applySettingsProfile(viewer(), "recommended")
        local saved = Profiles.copy(p.settings.doc_settings["profiles.cbz"])
        p.settings.none_profile_values = nil
        p.settings.nav_transition_duration = 0.9
        p.settings.doc_settings["profiles.cbz"] = saved
        p:loadDocSettings()
        assert.equals("recommended", p.settings.selected_profile_id)
        assert.equals(0.4, p.settings.nav_transition_duration)
        p:applySettingsProfile(viewer(), nil)
        assert.equals(0.7, p.settings.nav_transition_duration)
        assert.is_nil(p.settings.selected_profile_id)
    end)

    it("editing or deleting an active profile does not change live settings", function()
        local p = plugin()
        p.settings.selected_profile_id = "recommended"
        local before = p.settings.crop_mode
        local changed = Profiles.copy(p.settings.profiles[1].values)
        changed.crop_mode = "margin"
        Profiles.update(p.settings, "recommended", changed)
        assert.is_nil(p.settings.selected_profile_id)
        assert.equals(before, p.settings.crop_mode)
        p.settings.selected_profile_id = "recommended"
        Profiles.delete(p.settings, "recommended")
        assert.is_nil(p.settings.selected_profile_id)
        assert.equals(before, p.settings.crop_mode)
    end)

    it("transfers extracted-image ownership before the single rebuild", function()
        local p = plugin()
        local v = viewer()
        local image = {}
        v.embedded_source_image = image
        local values = Profiles.capture(p.settings, v)
        values.rotation = { kind = "image", value = false }
        local profile = Profiles.create(p.settings, "Embedded", values)
        p.showEmbeddedImagePanelsForImage = function(self, source, options)
            self.source = source
            self.position = options.start_point
            self.rebuilds = (self.rebuilds or 0) + 1
        end
        p:applySettingsProfile(v, profile.id)
        assert.equals(image, p.source)
        assert.is_nil(v.embedded_source_image)
        assert.equals(1, p.rebuilds)
        assert.equals(150, p.position.x)
        assert.is_false(p.settings.image_rotation)
    end)

    it("uses OCR fallback without modifying the stored profile", function()
        local p = plugin()
        local values = Profiles.capture(p.settings)
        values.ocr_bundled_language = "user:missing"
        values.rotation = { kind = "image", value = false }
        local profile = Profiles.create(p.settings, "Missing OCR", values)
        p.getSelectedOcrModel = function()
            return "eng"
        end
        p:applySettingsProfile(viewer(), profile.id)
        assert.is_nil(p.settings.selected_profile_id)
        assert.equals("eng", p.settings.ocr_bundled_language)
        assert.equals("user:missing", profile.values.ocr_bundled_language)
    end)

    it("keeps draft edits isolated and discards them on Cancel", function()
        local p = plugin()
        local v = viewer()
        p:showProfileEditor(v, "recommended")
        local editor = lastDialog()[1]
        editor.item_table[2].callback()
        local picker = lastDialog()[1]
        picker.item_table[2].callback() -- Comic in draft only
        assert.equals("manga", p.settings.profiles[1].values.mode)
        lastDialog()[1].item_table[8].callback() -- Cancel
        assert.equals("manga", p.settings.profiles[1].values.mode)
    end)

    it("restores matching document selection and drops deleted profile references", function()
        local p = plugin()
        local values = Profiles.capture(p.settings)
        local profile = Profiles.create(p.settings, "Document", values)
        p.settings.embedded_nav_transition_mode = values.nav_transition_mode
        p.settings.selected_profile_id = profile.id
        p:saveDocSettings(true)
        p.settings.selected_profile_id = nil
        p:loadDocSettings()
        assert.equals(profile.id, p.settings.selected_profile_id)
        Profiles.delete(p.settings, profile.id)
        p:loadDocSettings()
        assert.is_nil(p.settings.selected_profile_id)
    end)

    it("creates and renames through the dialogs without applying settings", function()
        local p, v = plugin(), viewer()
        local returned = 0
        p:promptProfileName(v, nil, function()
            returned = returned + 1
        end)
        lastDialog()._test_input = "  Reader profile  "
        lastDialog().buttons[1][2].callback()
        local created = p.settings.profiles[2]
        assert.equals("Reader profile", created.name)
        assert.is_nil(p.settings.selected_profile_id)
        assert.equals(0, p.rebuilds or 0)
        p:promptProfileName(v, created, function()
            returned = returned + 1
        end)
        lastDialog()._test_input = "Renamed reader"
        lastDialog().buttons[1][2].callback()
        assert.equals("Renamed reader", created.name)
        assert.equals(2, returned)
    end)

    it("saves draft edits without applying them and confirms destructive actions", function()
        local p, v = plugin(), viewer()
        p:showProfileEditor(v, "recommended")
        lastDialog()[1].item_table[2].callback()
        lastDialog()[1].item_table[2].callback() -- Comic
        lastDialog()[1].item_table[7].callback() -- Save
        assert.equals("comic", p.settings.profiles[1].values.mode)
        assert.equals("manga", p.settings.mode)
        local details = lastDialog()[1]
        details.item_table[10].callback() -- Replace with current
        assert.equals("comic", p.settings.profiles[1].values.mode)
        lastDialog().ok_callback()
        assert.equals("manga", p.settings.profiles[1].values.mode)
        assert.is_nil(p.settings.doc_settings["profiles.cbz"].selected_profile_id)
        lastDialog()[1].item_table[11].callback() -- Delete
        assert.equals(1, #p.settings.profiles)
        lastDialog().ok_callback()
        assert.equals(0, #p.settings.profiles)
        Profiles.initialize(p.settings)
        assert.equals(0, #p.settings.profiles)
    end)

    it("keeps image rotation when loading document settings from before profiles", function()
        local p = plugin()
        p.settings.image_rotation = 90
        p.settings.doc_settings["profiles.cbz"] = { mode = "comic" }
        p:loadDocSettings()
        assert.equals(90, p.settings.image_rotation)
        assert.is_nil(p.settings.selected_profile_id)
    end)

    it("deselects and persists a manual image or embedded-navigation change", function()
        local p = plugin()
        local values = Profiles.capture(p.settings)
        p.settings.embedded_nav_transition_mode = values.nav_transition_mode
        local created = Profiles.create(p.settings, "Manual edits", values)
        p.settings.selected_profile_id = created.id
        p:setImageRotation(90)
        assert.is_nil(p.settings.selected_profile_id)
        assert.equals(90, p.settings.doc_settings["profiles.cbz"].image_rotation)
        p:setEmbeddedNavTransitionMode("smooth")
        assert.equals("smooth", p.settings.doc_settings["profiles.cbz"].embedded_nav_transition_mode)
    end)
end)

-- Profile management and viewer integration. Draft edits never touch live settings.
local Profiles = require("src.profiles")
local NavCapabilities = require("src._navcapabilities")
local Device = require("device")
local UIManager = require("ui/uimanager")
local Event = require("ui/event")
local PanelCollector = require("src._panelcollector")
local gettext = require("gettext")
local ProfileMenu = {}

local function notice(message)
    UIManager:show(require("ui/widget/infomessage"):new({ text = message }))
end

local function menu(title, items)
    local Menu = require("ui/widget/menu")
    local CenterContainer = require("ui/widget/container/centercontainer")
    local Geom = require("ui/geometry")
    local screen = Device.screen
    local container = CenterContainer:new({ dimen = Geom:new({ w = screen:getWidth(), h = screen:getHeight() }) })
    local dialog = Menu:new({
        title = title,
        item_table = items,
        width = math.min(math.floor(screen:getWidth() * 0.9), math.floor(screen:getHeight() * 0.9)),
        height = math.floor(screen:getHeight() * 0.82),
        items_per_page = math.min(8, #items),
        show_parent = container,
        close_callback = function()
            UIManager:close(container)
        end,
    })
    container[1] = dialog
    UIManager:show(container)
    return function()
        dialog.close_callback = nil
        UIManager:close(container)
    end
end

local function refresh(viewer)
    if viewer and not viewer._panels_plus_closed then
        viewer:replaceButtonTable()
        viewer:update()
    end
end

local function confirm(message, callback)
    UIManager:show(require("ui/widget/confirmbox"):new({ text = message, ok_callback = callback }))
end

function ProfileMenu:getSettingsProfileName()
    Profiles.invalidate(self.settings)
    local profile = Profiles.find(self.settings, self.settings.selected_profile_id)
    return profile and profile.name or gettext("None")
end

function ProfileMenu:applySettingsProfile(viewer, id)
    Profiles.invalidate(self.settings)
    local profile = id and Profiles.find(self.settings, id)
    if id and not profile then
        return false
    end
    if not id and not self.settings.selected_profile_id then
        return true
    end
    if not viewer or viewer._panels_plus_closed or viewer._panels_plus_boundary_pending then
        return false
    end
    local values = profile and profile.values or self.settings.none_profile_values
    if not values then
        -- Installations already using a profile have no earlier None snapshot.
        self.settings.selected_profile_id = nil
        self:saveDocSettings(true, true)
        self:saveSettings()
        refresh(viewer)
        return true
    end
    if not self.settings.selected_profile_id then
        self.settings.none_profile_values = Profiles.capture(self.settings, viewer)
    end
    local current = viewer.panels and viewer.panels[viewer._images_list_cur or 1]
    local center = current and { x = current.x + current.w / 2, y = current.y + current.h / 2 }
    self._applying_profile = true
    self:setMode(values.mode)
    self:setCropMode(values.crop_mode)
    if values.panel_finding_mode ~= nil then
        self:setPanelFindingMode(values.panel_finding_mode)
    end
    self:setProgressBarVisible(values.progress_bar_visible)
    self:setNavTransitionMode(values.nav_transition_mode)
    self:setEmbeddedNavTransitionMode(values.embedded_nav_transition_mode or values.nav_transition_mode)
    for key, value in pairs(Profiles.options(values)) do
        self.settings[key] = value
    end
    -- Use the existing resolver when the stored model is no longer installed.
    self.settings.ocr_bundled_language = values.ocr_bundled_language
    local resolved = self:getSelectedOcrModel()
    if resolved then
        self:setBundledOcrLanguage(nil, resolved)
    end
    local unavailable = resolved ~= values.ocr_bundled_language
    if values.rotation.kind == "image" then
        self:setImageRotation(values.rotation.value)
    else
        self:setImageRotation(nil)
    end
    self.settings.profile_rotation = Profiles.copy(values.rotation)
    self.settings.selected_profile_id = id
    local image = viewer.embedded_source_image
    viewer.embedded_source_image = nil -- transfer ownership before closing/rotating
    UIManager:close(viewer)
    if values.rotation.kind == "device" and Device.screen:getRotationMode() ~= values.rotation.value then
        UIManager:broadcastEvent(Event:new("SetRotationMode", values.rotation.value))
        UIManager:onRotation()
    end
    self._applying_profile = nil
    if unavailable then
        self.settings.selected_profile_id = nil
    end
    Profiles.invalidate(self.settings)
    self:saveDocSettings(true, true)
    self:saveSettings()
    if image then
        self:showEmbeddedImagePanelsForImage(image, { start_point = center, buttons_visible = true })
    else
        local panels = self:collectPanels(viewer.page)
        self:showPanelViewerForPage(viewer.page, panels, center and PanelCollector.startIndex(panels, center) or 1, {
            buttons_visible = true,
        })
    end
    if unavailable then
        notice(
            gettext(
                "The profile's OCR model is unavailable. The available fallback is in use; profile selection is None."
            )
        )
    end
    if self.settings.nav_transition_mode == "smooth" then
        NavCapabilities.warnSmooth()
    end
    return true
end

function ProfileMenu:promptProfileName(viewer, profile, callback)
    local InputDialog = require("ui/widget/inputdialog")
    local dialog
    dialog = InputDialog:new({
        title = profile and gettext("Rename profile") or gettext("Create profile from current settings"),
        input = profile and profile.name or "",
        buttons = {
            {
                {
                    text = gettext("Cancel"),
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = gettext("Save"),
                    is_enter_default = true,
                    callback = function()
                        local name, error_message =
                            Profiles.validateName(self.settings, dialog:getInputText(), profile and profile.id)
                        if not name then
                            notice(error_message)
                            return
                        end
                        if profile then
                            profile.name = name
                        else
                            Profiles.create(self.settings, name, Profiles.capture(self.settings, viewer))
                        end
                        self:saveSettings()
                        refresh(viewer)
                        UIManager:close(dialog)
                        callback()
                    end,
                },
            },
        },
    })
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function ProfileMenu:showSettingsProfileMenu(viewer)
    Profiles.initialize(self.settings)
    Profiles.invalidate(self.settings)
    local close
    local items = {}
    local function choice(id, name)
        local active = self.settings.selected_profile_id == id
        items[#items + 1] = {
            text = (active and "◉ " or "○ ") .. name,
            bold = active,
            mandatory = active and gettext("In use") or nil,
            callback = function()
                close()
                self:applySettingsProfile(viewer, id)
            end,
        }
    end
    choice(nil, gettext("None"))
    for _, profile in ipairs(self.settings.profiles) do
        choice(profile.id, profile.name)
    end
    items[#items + 1] = {
        text = gettext("Add defaults"),
        callback = function()
            close()
            Profiles.addDefaults(self.settings)
            self:saveSettings()
            self:showSettingsProfileMenu(viewer)
        end,
    }
    items[#items + 1] = {
        text = gettext("Create from current settings..."),
        separator = true,
        callback = function()
            close()
            self:promptProfileName(viewer, nil, function()
                self:showSettingsProfileMenu(viewer)
            end)
        end,
    }
    items[#items + 1] = {
        text = gettext("Manage profiles..."),
        callback = function()
            close()
            self:showManageProfilesMenu(viewer)
        end,
    }
    items[#items + 1] = {
        text = gettext("Close"),
        callback = function()
            close()
        end,
    }
    close = menu(gettext("Settings Profiles"), items)
    return true
end

function ProfileMenu:showManageProfilesMenu(viewer)
    local close
    local items = {}
    for _, profile in ipairs(self.settings.profiles or {}) do
        items[#items + 1] = {
            text = profile.name,
            callback = function()
                close()
                self:showProfileDetails(viewer, profile.id)
            end,
        }
    end
    items[#items + 1] = {
        text = gettext("Back"),
        callback = function()
            close()
            self:showSettingsProfileMenu(viewer)
        end,
    }
    close = menu(gettext("Manage Profiles"), items)
end

local function valueLabel(key, values)
    local labels = {
        mode = { manga = gettext("Manga"), comic = gettext("Comic") },
        panel_finding_mode = { safe = gettext("Safe"), smart = gettext("Smart") },
        progress_bar_visible = { [true] = gettext("Shown"), [false] = gettext("Hidden") },
        nav_transition_mode = {
            classic = gettext("Classic"),
            smooth = gettext("Smooth"),
            animated = gettext("Animated"),
        },
        crop_mode = {
            strict = gettext("Strict crop"),
            loose = gettext("Loose crop"),
            margin = gettext("With margin"),
            none = gettext("No crop"),
        },
    }
    if key == "rotation" then
        local rotation = values.rotation
        local orientation = {
            [0] = gettext("Portrait"),
            [1] = gettext("Landscape right"),
            [2] = gettext("Inverted portrait"),
            [3] = gettext("Landscape left"),
        }
        return rotation.kind == "device" and (gettext("Device") .. " / " .. orientation[rotation.value])
            or (
                gettext("Image")
                .. " / "
                .. (
                    rotation.value == false and gettext("No rotation")
                    or rotation.value == nil and gettext("Auto")
                    or tostring(rotation.value)
                )
            )
    elseif key == "panel_finding_mode" and values[key] == nil then
        return gettext("Unchanged")
    elseif key == "ocr_bundled_language" then
        return values[key] == "eng" and gettext("English") or values[key] == "spa" and gettext("Spanish") or values[key]
    end
    return labels[key][values[key]]
end

local EDIT_FIELDS = {
    { "rotation", "Rotation" },
    { "mode", "Reading order" },
    { "progress_bar_visible", "Progress" },
    { "ocr_bundled_language", "OCR" },
    { "nav_transition_mode", "Navigation" },
    { "crop_mode", "Crop" },
    { "panel_finding_mode", "Panel finding" },
}

function ProfileMenu:showProfileDetails(viewer, id)
    local profile = Profiles.find(self.settings, id)
    if not profile then
        return
    end
    local close
    local items = {}
    for _, field in ipairs(EDIT_FIELDS) do
        items[#items + 1] =
            { text = gettext(field[2]) .. ": " .. valueLabel(field[1], profile.values), select_enabled = false }
    end
    local function back()
        self:showProfileDetails(viewer, id)
    end
    items[#items + 1] = {
        text = gettext("Apply"),
        separator = true,
        callback = function()
            close()
            self:applySettingsProfile(viewer, id)
        end,
    }
    items[#items + 1] = {
        text = gettext("Edit settings..."),
        callback = function()
            close()
            self:showProfileEditor(viewer, id)
        end,
    }
    items[#items + 1] = {
        text = gettext("Rename..."),
        callback = function()
            close()
            self:promptProfileName(viewer, profile, back)
        end,
    }
    items[#items + 1] = {
        text = gettext("Replace with current settings..."),
        callback = function()
            confirm(gettext("Replace this profile with the current reading settings?"), function()
                Profiles.update(self.settings, id, Profiles.capture(self.settings, viewer))
                self:saveSettings()
                self:saveDocSettings(true)
                refresh(viewer)
                close()
                back()
            end)
        end,
    }
    items[#items + 1] = {
        text = gettext("Delete..."),
        callback = function()
            confirm(gettext("Delete profile?") .. "\n" .. profile.name, function()
                Profiles.delete(self.settings, id)
                self:saveSettings()
                self:saveDocSettings(true)
                refresh(viewer)
                close()
                self:showManageProfilesMenu(viewer)
            end)
        end,
    }
    items[#items + 1] = {
        text = gettext("Back"),
        callback = function()
            close()
            self:showManageProfilesMenu(viewer)
        end,
    }
    close = menu(profile.name, items)
end

function ProfileMenu:showProfileEditor(viewer, id, draft)
    local profile = Profiles.find(self.settings, id)
    if not profile then
        return
    end
    draft = draft or Profiles.copy(profile.values)
    local close
    local items = {}
    local function back()
        self:showProfileEditor(viewer, id, draft)
    end
    for _, field in ipairs(EDIT_FIELDS) do
        local key = field[1]
        items[#items + 1] = {
            text = gettext(field[2]) .. ": " .. valueLabel(key, draft),
            callback = function()
                close()
                self:showProfileFieldPicker(key, draft, back)
            end,
        }
    end
    items[#items + 1] = {
        text = gettext("Save"),
        separator = true,
        callback = function()
            Profiles.update(self.settings, id, draft)
            self:saveSettings()
            self:saveDocSettings(true)
            refresh(viewer)
            close()
            self:showProfileDetails(viewer, id)
        end,
    }
    items[#items + 1] = {
        text = gettext("Cancel"),
        callback = function()
            close()
            self:showProfileDetails(viewer, id)
        end,
    }
    close = menu(gettext("Edit profile") .. ": " .. profile.name, items)
end

function ProfileMenu:showProfileFieldPicker(key, draft, back)
    if key == "rotation" then
        local direction_modes = { up = 0, right = 1, down = 2, left = 3 }
        local image_angles = { up = false, right = 90, down = 180, left = 270, auto = nil }
        UIManager:show(
            require("src._rotationpicker"):new({
                on_device_rotate = function(direction)
                    draft.rotation = { kind = "device", value = direction_modes[direction] }
                    back()
                end,
                on_image_rotate = function(direction)
                    draft.rotation = { kind = "image", value = image_angles[direction] }
                    back()
                end,
                on_close = back,
            }),
            "full"
        )
        return
    end
    local choices = {
        mode = { "manga", "comic" },
        progress_bar_visible = { true, false },
        nav_transition_mode = NavCapabilities.modes(),
        crop_mode = { "strict", "loose", "margin", "none" },
        panel_finding_mode = { "safe", "smart" },
    }
    if key == "ocr_bundled_language" then
        local WordFinder = require("src._wordfinder")
        choices[key] = {}
        for _, language in ipairs(WordFinder.availableBundledLanguages()) do
            choices[key][#choices[key] + 1] = language
        end
        for _, language in ipairs(WordFinder.availableUserLanguages()) do
            choices[key][#choices[key] + 1] = "user:" .. language
        end
        local found = false
        for _, value in ipairs(choices[key]) do
            if value == draft[key] then
                found = true
            end
        end
        if not found then
            choices[key][#choices[key] + 1] = draft[key]
        end
    end
    local close
    local items = {}
    for _, value in ipairs(choices[key]) do
        local sample = Profiles.copy(draft)
        sample[key] = value
        items[#items + 1] = {
            text = (draft[key] == value and "◉ " or "○ ") .. valueLabel(key, sample),
            callback = function()
                draft[key] = value
                close()
                back()
            end,
        }
    end
    items[#items + 1] = {
        text = gettext("Cancel"),
        callback = function()
            close()
            back()
        end,
    }
    close = menu(gettext("Profile setting"), items)
end

return ProfileMenu

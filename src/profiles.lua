-- Settings profiles include reading choices and their dependent options.
local Profiles = {}
local FIELDS = { "mode", "progress_bar_visible", "ocr_bundled_language", "nav_transition_mode", "crop_mode" }
local OPTION_FIELDS = {
    "nav_smooth_style",
    "nav_animated_panels",
    "nav_animated_pages",
    "nav_transition_duration",
    "nav_transition_cross_page",
    "nav_transition_frames",
    "panel_margin_ratio",
    "panel_bleed_ratio",
    "panel_bleed_min",
}
Profiles.option_fields = OPTION_FIELDS

-- Older profiles did not store suboptions. Use stable defaults rather than
-- inheriting whichever profile happened to be active before them.
function Profiles.options(values)
    local defaults = require("src._settings").defaults
    local options = {}
    for _, key in ipairs(OPTION_FIELDS) do
        options[key] = values[key]
        if options[key] == nil then
            options[key] = defaults[key]
        end
    end
    options.nav_smooth_style = require("src._naveasing").normalize(options.nav_smooth_style)
    return options
end

function Profiles.copy(value)
    if type(value) ~= "table" then
        return value
    end
    local result = {}
    for key, item in pairs(value) do
        result[key] = Profiles.copy(item)
    end
    return result
end

-- Build fresh values so restoring defaults never shares mutable profile tables.
local function defaultProfiles()
    local gettext = require("gettext")
    local capabilities = require("src._navcapabilities")
    local function deviceProfile(ereader)
        local transition = ereader and "animated" or "smooth"
        local values = Profiles.options({})
        values.rotation = { kind = "device", value = 3 }
        values.mode = "manga"
        values.progress_bar_visible = false
        values.ocr_bundled_language = "eng"
        values.nav_transition_mode = transition
        values.embedded_nav_transition_mode = transition
        values.nav_transition_frames = ereader and 2 or 24
        values.crop_mode = "none"
        values.panel_finding_mode = ereader and "safe" or "smart"
        return {
            id = ereader and "ereader" or "android-desktop",
            name = ereader and gettext("EReader") or gettext("Android-Desktop"),
            values = values,
        }
    end
    return {
        {
            id = "recommended",
            name = gettext("Recommended"),
            values = {
                rotation = { kind = "device", value = 3 },
                mode = "manga",
                progress_bar_visible = false,
                ocr_bundled_language = "eng",
                nav_transition_mode = capabilities.supportsAnimated() and "animated" or "smooth",
                crop_mode = "strict",
            },
        },
        deviceProfile(true),
        deviceProfile(false),
    }
end

function Profiles.initialize(settings)
    settings.profiles = settings.profiles or {}
    if not settings.profiles_initialized then
        local defaults = defaultProfiles()
        settings.profiles[#settings.profiles + 1] = defaults[1]
        settings.profiles[#settings.profiles + 1] = defaults[require("src._navcapabilities").isEreader() and 2 or 3]
        settings.profiles_initialized = true
        settings.selected_profile_id = nil
    end
end

-- Name validation skips defaults already present, even if their settings or
-- identities differ. New identities also avoid collisions with renamed defaults.
function Profiles.addDefaults(settings)
    local added = 0
    for _, profile in ipairs(defaultProfiles()) do
        if Profiles.create(settings, profile.name, profile.values) then
            added = added + 1
        end
    end
    return added
end

function Profiles.find(settings, id)
    for index, profile in ipairs(settings.profiles or {}) do
        if profile.id == id then
            return profile, index
        end
    end
end

function Profiles.capture(settings)
    local values = {}
    values.panel_finding_mode = settings.panel_finding_mode
    for _, key in ipairs(FIELDS) do
        values[key] = settings[key]
    end
    for _, key in ipairs(OPTION_FIELDS) do
        values[key] = settings[key]
    end
    values.embedded_nav_transition_mode = settings.embedded_nav_transition_mode or "classic"
    if settings.image_rotation ~= nil then
        values.rotation = { kind = "image", value = settings.image_rotation }
    else
        values.rotation = { kind = "device", value = require("device").screen:getRotationMode() }
    end
    return values
end

-- Keep document-only choices and the None snapshot, but restore a selected
-- profile as a complete package, including changes made since the last visit.
-- The saved settings remain the fallback if the profile has been deleted.
function Profiles.documentSettings(settings, saved)
    local profile = saved.selected_profile_id and Profiles.find(settings, saved.selected_profile_id)
    if not profile then
        return saved
    end
    local result = Profiles.copy(saved)
    local values = profile.values
    if values.panel_finding_mode ~= nil then
        result.panel_finding_mode = values.panel_finding_mode
    end
    for _, key in ipairs(FIELDS) do
        result[key] = values[key]
    end
    for key, value in pairs(Profiles.options(values)) do
        result[key] = value
    end
    result.embedded_nav_transition_mode = values.embedded_nav_transition_mode or values.nav_transition_mode
    result.profile_rotation = Profiles.copy(values.rotation)
    result.image_rotation = nil
    if values.rotation.kind == "image" then
        result.image_rotation = values.rotation.value
    end
    result.profile_settings_version = 1
    return result
end

function Profiles.matches(settings, values)
    if type(values) ~= "table" or type(values.rotation) ~= "table" then
        return false
    end
    if values.panel_finding_mode ~= nil and settings.panel_finding_mode ~= values.panel_finding_mode then
        return false
    end
    for _, key in ipairs(FIELDS) do
        if settings[key] ~= values[key] then
            return false
        end
    end
    for key, value in pairs(Profiles.options(values)) do
        if settings[key] ~= value then
            return false
        end
    end
    if
        (settings.embedded_nav_transition_mode or "classic")
        ~= (values.embedded_nav_transition_mode or values.nav_transition_mode)
    then
        return false
    end
    local rotation = values.rotation
    if rotation.kind == "image" then
        return settings.image_rotation == rotation.value
    end
    return settings.image_rotation == nil and require("device").screen:getRotationMode() == rotation.value
end

function Profiles.invalidate(settings)
    if not settings.selected_profile_id then
        return
    end
    local profile = Profiles.find(settings, settings.selected_profile_id)
    if not profile or not Profiles.matches(settings, profile.values) then
        settings.selected_profile_id = nil
    end
end

function Profiles.validateName(settings, name, except_id)
    name = (name or ""):match("^%s*(.-)%s*$")
    local gettext = require("gettext")
    if name == "" or name:lower() == "none" or name:lower() == gettext("None"):lower() then
        return nil, gettext("Choose a non-empty name other than None.")
    end
    for _, profile in ipairs(settings.profiles or {}) do
        if profile.id ~= except_id and profile.name:lower() == name:lower() then
            return nil, gettext("A profile with this name already exists.")
        end
    end
    return name
end

function Profiles.create(settings, name, values)
    local valid, error_message = Profiles.validateName(settings, name)
    if not valid then
        return nil, error_message
    end
    settings.profiles = settings.profiles or {}
    settings.profile_next_id = (settings.profile_next_id or 0) + 1
    local id = "profile-" .. settings.profile_next_id
    while Profiles.find(settings, id) do
        settings.profile_next_id = settings.profile_next_id + 1
        id = "profile-" .. settings.profile_next_id
    end
    local profile = { id = id, name = valid, values = Profiles.copy(values) }
    settings.profiles[#settings.profiles + 1] = profile
    return profile
end

function Profiles.update(settings, id, values)
    local profile = Profiles.find(settings, id)
    if not profile then
        return false
    end
    profile.values = Profiles.copy(values)
    if settings.selected_profile_id == id then
        settings.selected_profile_id = nil
    end
    return true
end

function Profiles.delete(settings, id)
    local profile, index = Profiles.find(settings, id)
    if not profile then
        return false
    end
    table.remove(settings.profiles, index)
    if settings.selected_profile_id == id then
        settings.selected_profile_id = nil
    end
    return true
end

return Profiles

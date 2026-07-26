--- Settings persistence and default normalization.
---
--- @class PPSettingsModule
--- @field key string Current KOReader settings key.
--- @field legacy_keys string[] Previous settings keys used for migration.
--- @field defaults PPSettings Default setting values.
local Settings = {
    key = "panels_plus",
    legacy_keys = {
        "mangacomicsmoother",
        "manga_smooth_reading",
    },
    defaults = {
        enabled = true,
        mode = "manga",
        crop_mode = "strict",
        invert_swipe = false,
        progress_bar_visible = true,
        detector = "auto",
        panel_grid_cols = 4,
        panel_grid_rows = 7,
        panel_bleed_ratio = 0.08,
        panel_bleed_min = 8,
        panel_prefetch_delay = 0.75,
        panel_cache_pages = 12,
        panel_prerender = true,
        panel_prerender_delay = 0.25,
        prerender_min_free_bytes = 40 * 1024 * 1024,
        full_page_panel_ratio = 0.92,
        segment_target_width = 480,
        segment_ink_delta = 40,
        segment_gutter_ratio = 0.005,
        segment_gutter_ink_ratio = 0.005,
        segment_min_panel_area = 0.005,
        segment_min_panel_side = 0.03,
        segment_max_depth = 6,
        segment_max_panels = 40,
        segment_coverage_min = 0.5,
        segment_page_coverage_min = 0.4,
        segment_single_panel_ratio = 0.6,
        segment_shear = true,
        segment_shear_max_depth = 4,
        segment_shear_trigger = 0.35,
        segment_shear_step = 2,
        debug_timing = false,
        performance_profile_version = 7,
    },
}

--- Fill missing settings and migrate older performance-sensitive defaults.
---
--- Existing values are preserved unless the stored performance profile predates
--- the current profile, in which case detector-grid and cache tuning values are
--- reset to the current low-cost defaults.
---
--- @param settings PPSettings|nil Stored settings table.
--- @return PPSettings settings Normalized settings table.
function Settings.withDefaults(settings)
    settings = settings or {}
    local performance_profile_version = settings.performance_profile_version or 0
    -- The precise detector was called "native" before it was surfaced in the
    -- viewer, where it reads as "Exact".
    if settings.detector == "native" then
        settings.detector = "exact"
    end
    for key, value in pairs(Settings.defaults) do
        if settings[key] == nil then
            settings[key] = value
        end
    end
    if performance_profile_version < Settings.defaults.performance_profile_version then
        settings.panel_grid_rows = Settings.defaults.panel_grid_rows
        settings.panel_grid_cols = Settings.defaults.panel_grid_cols
        settings.panel_bleed_ratio = math.min(settings.panel_bleed_ratio or Settings.defaults.panel_bleed_ratio, Settings.defaults.panel_bleed_ratio)
        settings.panel_bleed_min = math.min(settings.panel_bleed_min or Settings.defaults.panel_bleed_min, Settings.defaults.panel_bleed_min)
        settings.panel_prefetch_delay = math.max(settings.panel_prefetch_delay or Settings.defaults.panel_prefetch_delay, Settings.defaults.panel_prefetch_delay)
        settings.panel_cache_pages = Settings.defaults.panel_cache_pages
        settings.full_page_panel_ratio = Settings.defaults.full_page_panel_ratio
        -- Gutter sensitivity is tied to the map resolution it was measured at,
        -- so these two only make sense reset together.
        settings.segment_target_width = Settings.defaults.segment_target_width
        settings.segment_gutter_ratio = Settings.defaults.segment_gutter_ratio
        settings.performance_profile_version = Settings.defaults.performance_profile_version
    end
    return settings
end

--- Load settings from KOReader storage, falling back to the legacy key.
---
--- @return PPSettings settings Normalized plugin settings.
function Settings.load()
    local settings = G_reader_settings:readSetting(Settings.key)
    for _, legacy_key in ipairs(Settings.legacy_keys) do
        if settings then
            break
        end
        settings = G_reader_settings:readSetting(legacy_key)
    end
    return Settings.withDefaults(settings)
end

--- Save plugin settings to KOReader storage.
---
--- @param settings PPSettings Runtime settings table.
function Settings.save(settings)
    G_reader_settings:saveSetting(Settings.key, settings)
end

return Settings

local Settings = {
    key = "mangacomicsmoother",
    legacy_key = "manga_smooth_reading",
    defaults = {
        enabled = true,
        mode = "manga",
        crop_mode = "strict",
        invert_swipe = false,
        panel_grid_cols = 3,
        panel_grid_rows = 4,
        panel_bleed_ratio = 0.08,
        panel_bleed_min = 8,
        panel_prefetch_delay = 0.75,
        panel_cache_pages = 3,
        full_page_panel_ratio = 0.92,
        performance_profile_version = 3,
    },
}

function Settings.withDefaults(settings)
    settings = settings or {}
    local performance_profile_version = settings.performance_profile_version or 0
    for key, value in pairs(Settings.defaults) do
        if settings[key] == nil then
            settings[key] = value
        end
    end
    if performance_profile_version < Settings.defaults.performance_profile_version then
        settings.panel_grid_rows = math.min(settings.panel_grid_rows or Settings.defaults.panel_grid_rows, Settings.defaults.panel_grid_rows)
        settings.panel_grid_cols = math.min(settings.panel_grid_cols or Settings.defaults.panel_grid_cols, Settings.defaults.panel_grid_cols)
        settings.panel_bleed_ratio = math.min(settings.panel_bleed_ratio or Settings.defaults.panel_bleed_ratio, Settings.defaults.panel_bleed_ratio)
        settings.panel_bleed_min = math.min(settings.panel_bleed_min or Settings.defaults.panel_bleed_min, Settings.defaults.panel_bleed_min)
        settings.panel_prefetch_delay = math.max(settings.panel_prefetch_delay or Settings.defaults.panel_prefetch_delay, Settings.defaults.panel_prefetch_delay)
        settings.panel_cache_pages = Settings.defaults.panel_cache_pages
        settings.full_page_panel_ratio = Settings.defaults.full_page_panel_ratio
        settings.performance_profile_version = Settings.defaults.performance_profile_version
    end
    return settings
end

function Settings.load()
    local settings = G_reader_settings:readSetting(Settings.key)
    if not settings then
        settings = G_reader_settings:readSetting(Settings.legacy_key)
    end
    return Settings.withDefaults(settings)
end

function Settings.save(settings)
    G_reader_settings:saveSetting(Settings.key, settings)
end

return Settings

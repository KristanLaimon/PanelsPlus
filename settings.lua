local Settings = {
    key = "manga_smooth_reading",
    defaults = {
        enabled = true,
        mode = "manga",
        panel_grid_cols = 4,
        panel_grid_rows = 7,
    },
}

function Settings.withDefaults(settings)
    settings = settings or {}
    for key, value in pairs(Settings.defaults) do
        if settings[key] == nil then
            settings[key] = value
        end
    end
    return settings
end

function Settings.load()
    return Settings.withDefaults(G_reader_settings:readSetting(Settings.key))
end

function Settings.save(settings)
    G_reader_settings:saveSetting(Settings.key, settings)
end

return Settings

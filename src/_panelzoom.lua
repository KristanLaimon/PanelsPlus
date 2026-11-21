--- Validation and live access to globally persisted panel zoom preferences.
--- @class PPPanelZoomModule
--- @field minimum number Default slider minimum (0.3×).
--- @field maximum number Default slider maximum (3×).
local PanelZoom = { minimum = 0.3, maximum = 3 }
--- @type table<string, boolean>
local allowed = { panel_zoom_enabled = true, panel_zoom_gesture_type = true, panel_zoom_mode = true, panel_zoom_factor = true,
    panel_zoom_slider_min = true, panel_zoom_slider_max = true, panel_zoom_slider_x = true, panel_zoom_slider_y = true,
    panel_zoom_slider_width = true, panel_zoom_slider_height = true, panel_zoom_slider_opacity = true }

--- Normalize a slider range, preserving at least 0.1× between its endpoints.
--- @param settings PPPanelZoomSettings Persisted preferences or a live viewer proxy.
--- @return number minimum Lower multiplier, clamped to 0.1–7.9.
--- @return number maximum Upper multiplier, clamped to minimum + 0.1 through 8.
function PanelZoom.range(settings)
    --- @type number
    local min = tonumber(settings.panel_zoom_slider_min) or 0.3
    --- @type number
    local max = tonumber(settings.panel_zoom_slider_max) or 3
    min = math.max(0.1, math.min(7.9, min))
    max = math.max(min + 0.1, math.min(8, max))
    return min, max
end

--- Forward zoom setting reads/writes to the original table without copying it.
--- @param settings PPPanelZoomSettings
--- @return PPPanelZoomSettings proxy Rejects writes to non-zoom settings.
function PanelZoom.proxy(settings)
    return setmetatable({}, {
        __index = function(_, key)
            if allowed[key] then
                return settings[key]
            end
        end,
        __newindex = function(_, key, value)
            assert(allowed[key], "Unsupported panel zoom setting: " .. tostring(key))
            settings[key] = value
        end,
    })
end

--- Validate a multiplier; missing, nonnumeric, or NaN values fall back to 1.5×.
--- @param value unknown Untrusted saved zoom multiplier.
--- @return number factor Multiplier clamped to 0.1–8.
function PanelZoom.factor(value)
    if type(value) ~= "number" or value ~= value then
        return 1.5
    end
    return math.max(0.1, math.min(8, value))
end

return PanelZoom

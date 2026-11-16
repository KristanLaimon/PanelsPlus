-- Live, deliberately narrow access to globally persisted panel zoom preferences.
local PanelZoom = { minimum = 0.3, maximum = 3 }
local allowed = { panel_gesture_zoom = true, panel_zoom_gesture = true, panel_gesture_zoom_factor = true }

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

function PanelZoom.factor(value)
    if type(value) ~= "number" or value ~= value then
        return 1.5
    end
    return math.max(PanelZoom.minimum, math.min(PanelZoom.maximum, value))
end

return PanelZoom

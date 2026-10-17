local Device = require("device")
local Capabilities = {}

function Capabilities.supportsAnimated()
    return Device.canDoSwipeAnimation and Device:canDoSwipeAnimation() and true or false
end

function Capabilities.isEreader()
    return (Device.hasEinkScreen and Device:hasEinkScreen()) or Capabilities.supportsAnimated()
end

function Capabilities.defaultFrames()
    return Capabilities.isEreader() and 2 or 24
end

function Capabilities.normalizeMode(mode)
    if mode == "smooth" or (mode == "animated" and Capabilities.supportsAnimated()) then
        return mode
    end
    return "classic"
end

function Capabilities.modes()
    return Capabilities.supportsAnimated() and { "classic", "smooth", "animated" } or { "classic", "smooth" }
end

function Capabilities.nextMode(mode)
    local modes = Capabilities.modes()
    for index, value in ipairs(modes) do
        if value == mode then
            return modes[index % #modes + 1]
        end
    end
    return "classic"
end

function Capabilities.warnSmooth()
    if not Capabilities.isEreader() then
        return
    end
    local gettext = require("gettext")
    require("ui/uimanager"):show(require("ui/widget/infomessage"):new({
        text = gettext(
            "Smooth mode is not well adapted for e-readers. Animated mode is recommended on devices with hardware swipe animation support."
        ),
        timeout = 7,
    }))
end

return Capabilities

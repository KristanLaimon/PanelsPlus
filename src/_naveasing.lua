-- CSS timing functions for smooth navigation. Classic retains the earlier pan.
-- Curves follow https://www.w3.org/TR/css-easing-1/#cubic-bezier-easing-functions
local Easing = {}
Easing.styles = { "linear", "ease", "ease-in", "ease-out", "ease-in-out", "classic" }
local curves = {
    ease = { 0.25, 0.1, 0.25, 1 },
    ["ease-in"] = { 0.42, 0, 1, 1 },
    ["ease-out"] = { 0, 0, 0.58, 1 },
    ["ease-in-out"] = { 0.42, 0, 0.58, 1 },
}

function Easing.normalize(style)
    if style == nil then
        return "ease"
    end
    for _, value in ipairs(Easing.styles) do
        if style == value then
            return value
        end
    end
    -- Modern and removed step styles fall back to continuous linear timing.
    return "linear"
end

function Easing.next(style)
    style = Easing.normalize(style)
    for index, value in ipairs(Easing.styles) do
        if style == value then
            return Easing.styles[index % #Easing.styles + 1]
        end
    end
end

function Easing.label(style)
    style = Easing.normalize(style)
    return style == "classic" and require("gettext")("Classic") or style
end

local function coordinate(t, p1, p2)
    local inverse = 1 - t
    return 3 * inverse * inverse * t * p1 + 3 * inverse * t * t * p2 + t * t * t
end

function Easing.progress(style, progress)
    progress = math.max(0, math.min(1, progress))
    local curve = curves[style]
    if not curve or progress == 0 or progress == 1 then
        return progress
    end
    -- CSS time is the curve's x coordinate, not its Bezier parameter. Solve
    -- x(t) first, then evaluate y(t); using y(progress) changes the timing.
    local low, high = 0, 1
    for _ = 1, 24 do
        local t = (low + high) / 2
        if coordinate(t, curve[1], curve[3]) < progress then
            low = t
        else
            high = t
        end
    end
    return coordinate((low + high) / 2, curve[2], curve[4])
end

return Easing

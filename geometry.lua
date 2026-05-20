local Geometry = {}

function Geometry.rectKey(rect)
    return table.concat({
        math.floor(rect.x or 0),
        math.floor(rect.y or 0),
        math.floor(rect.w or 0),
        math.floor(rect.h or 0),
    }, ":")
end

function Geometry.rectCenter(rect)
    return (rect.x or 0) + (rect.w or 0) / 2, (rect.y or 0) + (rect.h or 0) / 2
end

function Geometry.rectContains(rect, pos)
    return pos.x >= rect.x and pos.x <= rect.x + rect.w
        and pos.y >= rect.y and pos.y <= rect.y + rect.h
end

function Geometry.sameRow(a, b)
    local ay = (a.y or 0) + (a.h or 0) / 2
    local by = (b.y or 0) + (b.h or 0) / 2
    return math.abs(ay - by) <= math.max(a.h or 0, b.h or 0) * 0.45
end

return Geometry

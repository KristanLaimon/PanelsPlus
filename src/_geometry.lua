--- Geometry helpers used by panel collection and panel-position matching.
---
--- @class PPGeometryModule
local Geometry = {}

--- Build a stable integer key for a rectangle.
---
--- @param rect PPRect Rectangle-like table.
--- @return string key Colon-delimited floored coordinates.
function Geometry.rectKey(rect)
    return table.concat({
        math.floor(rect.x or 0),
        math.floor(rect.y or 0),
        math.floor(rect.w or 0),
        math.floor(rect.h or 0),
    }, ":")
end

--- Return a rectangle's center point.
---
--- @param rect PPRect Rectangle-like table.
--- @return number x Center x coordinate.
--- @return number y Center y coordinate.
function Geometry.rectCenter(rect)
    return (rect.x or 0) + (rect.w or 0) / 2, (rect.y or 0) + (rect.h or 0) / 2
end

--- Return the smallest rectangle containing both `a` and `b`.
---
--- @param a PPRect First rectangle.
--- @param b PPRect Second rectangle.
--- @return PPRect union Bounding box of both rectangles.
function Geometry.rectUnion(a, b)
    local x = math.min(a.x or 0, b.x or 0)
    local y = math.min(a.y or 0, b.y or 0)
    local right = math.max((a.x or 0) + (a.w or 0), (b.x or 0) + (b.w or 0))
    local bottom = math.max((a.y or 0) + (a.h or 0), (b.y or 0) + (b.h or 0))
    return { x = x, y = y, w = right - x, h = bottom - y }
end

--- Test whether a point is inside a rectangle, including the edges.
---
--- @param rect PPRect Rectangle-like table.
--- @param pos PPPagePosition|{x:number,y:number} Point-like table.
--- @return boolean contains Whether the point lies inside the rectangle.
function Geometry.rectContains(rect, pos)
    return pos.x >= rect.x and pos.x <= rect.x + rect.w and pos.y >= rect.y and pos.y <= rect.y + rect.h
end

--- Return whether two rectangles are close enough vertically to count as a row.
---
--- @param a PPRect First rectangle.
--- @param b PPRect Second rectangle.
--- @return boolean same_row Whether rectangle centers belong to the same row.
function Geometry.sameRow(a, b)
    local ay = (a.y or 0) + (a.h or 0) / 2
    local by = (b.y or 0) + (b.h or 0) / 2
    return math.abs(ay - by) <= math.max(a.h or 0, b.h or 0) * 0.45
end

--- Sort panels into reading order for a reading mode.
---
--- Panels within the same row run right-to-left in manga mode and left-to-right
--- in comic mode; rows themselves always run top to bottom. Shared by every
--- detector so panel order never depends on which one produced the rectangles.
---
--- `sameRow()` is a pairwise, height-dependent threshold test, not a fixed
--- row band -- it is not guaranteed transitive (A~B and B~C does not imply
--- A~C), so it cannot be used directly as a `table.sort` comparator, which
--- requires a strict weak ordering. Instead, panels are grouped into rows by
--- transitive closure (union-find over the `sameRow` relation) first, then
--- each row is ordered internally, and rows are ordered by their mean
--- vertical center.
---
--- @param panels PPPanel[] Unordered panel rectangles.
--- @param mode PPReadingMode Reading order mode.
--- @return PPPanel[] panels The same table, sorted in place.
function Geometry.sortReadingOrder(panels, mode)
    local n = #panels
    if n <= 1 then
        return panels
    end

    local parent = {}
    for i = 1, n do
        parent[i] = i
    end
    local function find(i)
        while parent[i] ~= i do
            parent[i] = parent[parent[i]]
            i = parent[i]
        end
        return i
    end
    for i = 1, n do
        for j = i + 1, n do
            if Geometry.sameRow(panels[i], panels[j]) then
                local ri, rj = find(i), find(j)
                if ri ~= rj then
                    parent[ri] = rj
                end
            end
        end
    end

    local groups = {}
    for i = 1, n do
        local root = find(i)
        groups[root] = groups[root] or {}
        table.insert(groups[root], i)
    end

    local roots, row_y = {}, {}
    for root, idxs in pairs(groups) do
        table.insert(roots, root)
        local sum = 0
        for _, i in ipairs(idxs) do
            local rect = panels[i]
            sum = sum + (rect.y or 0) + (rect.h or 0) / 2
        end
        row_y[root] = sum / #idxs
    end
    table.sort(roots, function(a, b)
        return row_y[a] < row_y[b]
    end)

    local sorted = {}
    for _, root in ipairs(roots) do
        local idxs = groups[root]
        table.sort(idxs, function(i, j)
            if mode == "comic" then
                return (panels[i].x or 0) < (panels[j].x or 0)
            end
            return (panels[i].x or 0) > (panels[j].x or 0)
        end)
        for _, i in ipairs(idxs) do
            table.insert(sorted, panels[i])
        end
    end

    for i = 1, n do
        panels[i] = sorted[i]
    end
    return panels
end

return Geometry

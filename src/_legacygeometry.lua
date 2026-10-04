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

--- Sort panels into reading order for a reading mode.
---
--- Panels within the same row run right-to-left in manga mode and left-to-right
--- in comic mode; rows themselves always run top to bottom. Shared by every
--- detector so panel order never depends on which one produced the rectangles.
---
--- Rows are deliberately built from their *top edges*, rather than by
--- chaining together panels whose vertical centres happen to be near each
--- other. A tall panel beside two stacked panels otherwise links the upper and
--- lower tiers into one row; sorting that oversized row by x then sends the
--- lower panel before the upper one. That breaks both left-to-right comic and
--- right-to-left manga flow.
---
--- A layout can also place a tall trailing panel beside a vertical stack of
--- later panels. That panel shares a top edge with the first panel in the
--- stack, but its position on the trailing edge means the stack is read first:
--- comic flow enters the left-hand stack and manga flow enters the right-hand
--- stack, returning to the tall panel only after that stack is complete.
---
--- @param panels PPPanel[] Unordered panel rectangles.
--- @param mode PPReadingMode Reading order mode.
--- @return PPPanel[] panels The same table, sorted in place.
local function sortTopAlignedRows(panels, mode)
    local indexed = {}
    for _, rect in ipairs(panels) do
        table.insert(indexed, { rect = rect })
    end
    table.sort(indexed, function(a, b)
        local ay, by = a.rect.y or 0, b.rect.y or 0
        if ay == by then
            return (a.rect.x or 0) < (b.rect.x or 0)
        end
        return ay < by
    end)

    local rows = {}
    for _, item in ipairs(indexed) do
        local rect = item.rect
        local y = rect.y or 0
        local height = math.max(1, rect.h or 0)
        local best_row, best_distance

        for _, row in ipairs(rows) do
            -- `row.top` never changes: every member is measured against the
            -- same tier boundary, so a chain of slightly-offset panels cannot
            -- grow a row downward.
            local distance = math.abs(y - row.top)
            -- A borderless panel's first ink can start appreciably below its
            -- framed neighbour's top edge: its white upper margin is not part
            -- of the detected rectangle. Treat that small offset as one tier
            -- so comic flow still runs left-to-right across the row. Measuring
            -- every item from the fixed row top (rather than chaining) keeps a
            -- tall panel beside a stacked layout from joining lower tiers.
            local tolerance = math.min(height, row.min_height) * 0.35
            if distance <= tolerance and (not best_distance or distance < best_distance) then
                best_row, best_distance = row, distance
            end
        end

        if not best_row then
            best_row = { top = y, min_height = height, items = {} }
            table.insert(rows, best_row)
        else
            best_row.min_height = math.min(best_row.min_height, height)
        end
        table.insert(best_row.items, item)
    end

    local sorted = {}
    for _, row in ipairs(rows) do
        table.sort(row.items, function(a, b)
            local ax, bx = a.rect.x or 0, b.rect.x or 0
            if ax == bx then
                return (a.rect.y or 0) < (b.rect.y or 0)
            end
            if mode == "comic" then
                return ax < bx
            end
            return ax > bx
        end)
    end

    do
        -- A trailing panel which overlaps later panels entirely on the leading
        -- side is the closing panel of a nested stack. Hold it until the last
        -- such row, preserving 1,2,3,5,6,7,4 rather than 1,2,3,4,5,6,7.
        -- The leading side is left in comic mode and right in manga mode.
        local deferred = {}

        for row_index, row in ipairs(rows) do
            for item_index, item in ipairs(row.items) do
                local rect = item.rect
                local defer_until = row_index
                local bottom = (rect.y or 0) + math.max(1, rect.h or 0)

                if item_index > 1 then
                    for later_index = row_index + 1, #rows do
                        local later_row = rows[later_index]
                        if later_row.top >= bottom then
                            break
                        end
                        for _, later_item in ipairs(later_row.items) do
                            local later_rect = later_item.rect
                            local later_right = (later_rect.x or 0) + math.max(1, later_rect.w or 0)
                            local rect_right = (rect.x or 0) + math.max(1, rect.w or 0)
                            local is_in_leading_stack = mode == "comic" and later_right <= (rect.x or 0)
                                or mode ~= "comic" and (later_rect.x or 0) >= rect_right
                            if is_in_leading_stack then
                                defer_until = later_index
                                break
                            end
                        end
                    end
                end

                if defer_until > row_index then
                    deferred[defer_until] = deferred[defer_until] or {}
                    table.insert(deferred[defer_until], item)
                else
                    table.insert(sorted, rect)
                end
            end
            if deferred[row_index] then
                for _, item in ipairs(deferred[row_index]) do
                    table.insert(sorted, item.rect)
                end
            end
        end
    end

    for i, rect in ipairs(sorted) do
        panels[i] = rect
    end
    return panels
end

--- @param panels PPPanel[] Unordered panel rectangles.
--- @param mode PPReadingMode Reading order mode.
--- @return PPPanel[] panels The same table, sorted in place.
function Geometry.sortReadingOrder(panels, mode)
    local n = #panels
    if n <= 1 then
        return panels
    end

    return sortTopAlignedRows(panels, mode)
end

return Geometry

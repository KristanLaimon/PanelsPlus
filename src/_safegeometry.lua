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

                if item_index > 1 or mode == "manga" then
                    local stack_rows = 0
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
                            if item_index == 1 then
                                local overlap = math.min(bottom, later_rect.y + later_rect.h) - later_rect.y
                                is_in_leading_stack = is_in_leading_stack and overlap >= later_rect.h * 0.50
                            end
                            if is_in_leading_stack then
                                stack_rows = stack_rows + 1
                                defer_until = later_index
                                break
                            end
                        end
                    end
                    -- A tall trailing panel can start above a right-hand stack.
                    -- Require two later tiers if it has no leading peer on its row.
                    if item_index == 1 and stack_rows < 2 then
                        defer_until = row_index
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

local function staggeredColumns(band)
    if #band < 4 then
        return
    end
    table.sort(band, function(a, b)
        return a.x < b.x
    end)
    local columns = {}
    local column
    for _, rect in ipairs(band) do
        if not column or rect.x >= column.right then
            column = { right = rect.x + rect.w, panels = {} }
            columns[#columns + 1] = column
        end
        column.panels[#column.panels + 1] = rect
        column.right = math.max(column.right, rect.x + rect.w)
    end
    local stacks, gaps = 0, {}
    local first, last
    for _, group in ipairs(columns) do
        local items = group.panels
        table.sort(items, function(a, b)
            return a.y < b.y
        end)
        local top, bottom = items[1], items[#items]
        if first then
            if
                math.abs(top.y - first.y) > math.min(top.h, first.h) * 0.35
                or math.abs(bottom.y + bottom.h - last.y - last.h) > math.min(bottom.h, last.h) * 0.35
            then
                return
            end
        end
        first, last = top, bottom
        for i = 2, #items do
            local from, to = items[i - 1].y + items[i - 1].h, items[i].y
            if from > to then
                return
            end
            for _, gap in ipairs(gaps) do
                if gap.column ~= group and from <= gap.to and gap.from <= to then
                    return
                end
            end
            gaps[#gaps + 1] = { from = from, to = to, column = group }
        end
        if #items > 1 then
            stacks = stacks + 1
        end
    end
    if stacks >= 2 then
        return columns
    end
end

-- A shared horizontal gutter closes a tier. If the internal gutters are
-- staggered and full-height vertical gutters separate stacks, finish each stack.
local function sortStaggeredMangaBands(panels)
    local by_top = {}
    for i, panel in ipairs(panels) do
        by_top[i] = panel
    end
    table.sort(by_top, function(a, b)
        return a.y < b.y
    end)
    local band, bottom, first_index = {}, 0, 1
    for i = 1, #by_top + 1 do
        local rect = by_top[i]
        if #band > 0 and (not rect or rect.y >= bottom) then
            local columns = staggeredColumns(band)
            if columns then
                local index = first_index
                for column_index = #columns, 1, -1 do
                    for _, item in ipairs(columns[column_index].panels) do
                        panels[index] = item
                        index = index + 1
                    end
                end
            end
            first_index = first_index + #band
            band = {}
        end
        if rect then
            band[#band + 1] = rect
            bottom = math.max(bottom, rect.y + rect.h)
        end
    end
end

--- @param panels PPPanel[] Unordered panel rectangles.
--- @param mode PPReadingMode Reading order mode.
--- @return PPPanel[] panels The same table, sorted in place.
function Geometry.sortReadingOrder(panels, mode)
    local n = #panels
    if n <= 1 then
        return panels
    end

    sortTopAlignedRows(panels, mode)
    if mode == "manga" then
        sortStaggeredMangaBands(panels)
    end
    return panels
end

return Geometry

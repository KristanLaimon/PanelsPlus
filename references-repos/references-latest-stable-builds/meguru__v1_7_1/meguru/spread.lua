-- Two-page imposition; the design record is in docs/two-page-view.md.

local Spread = {}

-- `list` is ascending; the binary searches over it rely on that.
local function isWide(list, p)
    local lo, hi = 1, #list
    while lo <= hi do
        local mid = math.floor((lo + hi) / 2)
        local v = list[mid]
        if v == p then
            return true
        elseif v < p then
            lo = mid + 1
        else
            hi = mid - 1
        end
    end
    return false
end

local function lastBelow(list, n)
    local lo, hi, found = 1, #list, nil
    while lo <= hi do
        local mid = math.floor((lo + hi) / 2)
        if list[mid] < n then
            found = list[mid]
            lo = mid + 1
        else
            hi = mid - 1
        end
    end
    return found
end

function Spread.runStart(page, list)
    list = list or {}
    page = tonumber(page) or 0
    if page < 1 then
        return 0
    end
    if isWide(list, page) then
        return page
    end
    local wide = lastBelow(list, page)
    return wide and (wide + 1) or 1
end

function Spread.unitFor(n, count, list, anchor)
    n = tonumber(n)
    if not n or not count or n < 1 or n > count then
        return nil
    end
    list = list or {}

    if isWide(list, n) then
        return { a = n }
    end

    local wide = lastBelow(list, n)
    local run = wide and (wide + 1) or 1

    -- An anchor of 0 (or "0", both truthy in Lua) is off: no run starts at 0.
    local first = (Spread.runStart(anchor, list) == run) and 1 or 0
    local idx = n - run
    if idx < first then
        return { a = n }              -- the run's first page, offset on
    end

    if ((idx - first) % 2) ~= 0 then
        return { a = n - 1, b = n }
    end

    local nxt = n + 1
    if nxt > count or isWide(list, nxt) then
        return { a = n }
    end
    return { a = n, b = nxt }
end

function Spread.nextStart(n, count, list, anchor)
    local unit = Spread.unitFor(n, count, list, anchor)
    if not unit then
        return nil
    end
    local after = unit.b and (unit.b + 1) or (unit.a + 1)
    if after > count then
        return nil
    end
    local next_unit = Spread.unitFor(after, count, list, anchor)
    return next_unit and next_unit.a or nil
end

function Spread.prevStart(n, count, list, anchor)
    local unit = Spread.unitFor(n, count, list, anchor)
    if not unit or unit.a <= 1 then
        return nil
    end
    local prev_unit = Spread.unitFor(unit.a - 1, count, list, anchor)
    return prev_unit and prev_unit.a or nil
end

function Spread.gutter(content_w, content_h, inner_left, inner_right, screen_w, screen_h)
    local nothing = { left = 0, right = 0 }
    content_w, content_h = tonumber(content_w), tonumber(content_h)
    screen_w, screen_h = tonumber(screen_w), tonumber(screen_h)
    if not (content_w and content_h and screen_w and screen_h)
        or content_w <= 0 or content_h <= 0
        or screen_w <= 0 or screen_h <= 0 then
        return nothing
    end
    local max_left = math.max(0, tonumber(inner_left) or 0)
    local max_right = math.max(0, tonumber(inner_right) or 0)
    local total_max = max_left + max_right
    if total_max <= 0 then
        return nothing
    end

    local scale = math.min(screen_w / content_w, screen_h / content_h)
    local spare = math.max(0, screen_w - content_w * scale)
    local total = math.min(spare, total_max * scale)
    if total <= 0 then
        return nothing
    end

    local left = total * (max_left / total_max)
    -- Right is the remainder, so rounding cannot push the sum past the cap.
    local right = total - left
    -- Back in the pages' own units; the caller knows nothing of the scale.
    return { left = left / scale, right = right / scale }
end

function Spread.grow(lw, lh, rw, rh, screen_w, screen_h, fits_by_width)
    local nothing = { left = 1, right = 1 }
    if fits_by_width then
        return nothing
    end
    lw, lh = tonumber(lw), tonumber(lh)
    rw, rh = tonumber(rw), tonumber(rh)
    screen_w, screen_h = tonumber(screen_w), tonumber(screen_h)
    if not (lw and lh and rw and rh and screen_w and screen_h)
        or lw <= 0 or lh <= 0 or rw <= 0 or rh <= 0
        or screen_w <= 0 or screen_h <= 0 then
        return nothing
    end

    local h_max = math.max(lh, rh)
    local free = math.max(0, screen_w * h_max / screen_h - (lw + rw))
    if free <= 0 then
        return nothing
    end

    if lh < rh then
        return { left = math.min(h_max / lh, 1 + free / lw), right = 1 }
    elseif rh < lh then
        return { left = 1, right = math.min(h_max / rh, 1 + free / rw) }
    end
    return nothing
end

return Spread

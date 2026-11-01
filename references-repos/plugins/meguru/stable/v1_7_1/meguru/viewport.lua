-- The window over a page, for the panel view that does not crop.

local Viewport = {}

function Viewport.fitScale(dims, screen)
    return screen.w / dims.w
end

function Viewport.pageFitScale(dims, screen)
    return math.min(screen.w / dims.w, screen.h / dims.h)
end

local PANEL_WINDOW_TOLERANCE = 0.18

local function round(value)
    return math.floor(value + 0.5)
end

-- The detector yields floats; round once so no fraction reaches the tile key.
local function whole(panel)
    return {
        x = round(panel.x),
        y = round(panel.y),
        w = round(panel.w),
        h = round(panel.h),
    }
end

-- Clamped to the page: `Image.renderRegion` has no content past its edge.
local function windowFor(dims, screen, scale)
    return round(math.min(dims.w, screen.w / scale)),
        round(math.min(dims.h, screen.h / scale)), scale
end

local function clampAxis(position, size, lo, hi)
    if size >= hi - lo or position < lo then
        return lo
    end
    if position + size > hi then
        return hi - size
    end
    return position
end

local function centred(x, y, w, h, dims)
    return {
        x = clampAxis(round(x - w / 2), w, 0, dims.w),
        y = clampAxis(round(y - h / 2), h, 0, dims.h),
        w = w,
        h = h,
    }
end

local function positions(panel, w, h, dims, right_to_left)
    local xs = {}
    if panel.w <= w then
        xs[1] = round(panel.x + (panel.w - w) / 2)
    elseif right_to_left then
        xs[1], xs[2] = round(panel.x + panel.w - w), round(panel.x)
    else
        xs[1], xs[2] = round(panel.x), round(panel.x + panel.w - w)
    end
    local ys = {}
    if panel.h <= h then
        ys[1] = round(panel.y + (panel.h - h) / 2)
    else
        ys[1], ys[2] = round(panel.y), round(panel.y + panel.h - h)
    end
    local views = {}
    for i = 1, #ys do
        for j = 1, #xs do
            local view = {
                x = clampAxis(xs[j], w, 0, dims.w),
                y = clampAxis(ys[i], h, 0, dims.h),
                w = w,
                h = h,
            }
            -- Sub-pixel overflow can repeat a position; drop the duplicate.
            local previous = views[#views]
            if not (previous and previous.x == view.x and previous.y == view.y) then
                views[#views + 1] = view
            end
        end
    end
    return views
end

local function sameView(view, other)
    return view.x == other.x and view.y == other.y
        and view.w == other.w and view.h == other.h
end

-- Sole source of out_w/out_h; tiles key on both, so the two cannot drift.
local function frameFor(dims, screen, scale)
    local w, h = windowFor(dims, screen, scale)
    return {
        w = w,
        h = h,
        scale = scale,
        out_w = math.max(1, math.floor(w * scale + 0.5)),
        out_h = math.max(1, math.floor(h * scale + 0.5)),
    }
end

local function eases(overflow, room)
    return overflow > room and overflow <= room * (1 + PANEL_WINDOW_TOLERANCE)
end

local function frameForPanel(panel, dims, screen, scale)
    if PANEL_WINDOW_TOLERANCE <= 0 then
        return frameFor(dims, screen, scale)
    end
    local frame = frameFor(dims, screen, scale)
    local eased = scale
    if eases(panel.w, frame.w) then
        eased = math.min(eased, screen.w / panel.w)
    end
    if eases(panel.h, frame.h) then
        eased = math.min(eased, screen.h / panel.h)
    end
    if eased >= scale then
        return frame
    end
    return frameFor(dims, screen, eased)
end

-- Compares start corners so a re-open at another scale keeps the place.
function Viewport.stepNearest(steps, panel, x, y)
    local best, best_d
    for i, step in ipairs(steps or {}) do
        if step.panel == panel then
            local dx, dy = step.x - x, step.y - y
            local d = dx * dx + dy * dy
            if not best_d or d < best_d then
                best, best_d = i, d
            end
        end
    end
    return best
end

function Viewport.scaleBounds(dims, screen, content)
    return math.min(Viewport.pageFitScale(dims, screen), 1),
        math.max(Viewport.fitScale(content or dims, screen) * 4, 1)
end

function Viewport.windowAt(dims, screen, scale, cx, cy)
    if not (dims and screen and scale) then
        return nil
    end
    local frame = frameFor(dims, screen, scale)
    local view = centred(cx or dims.w / 2, cy or dims.h / 2, frame.w, frame.h, dims)
    return {
        x = view.x,
        y = view.y,
        w = frame.w,
        h = frame.h,
        out_w = frame.out_w,
        out_h = frame.out_h,
    }
end

function Viewport.steps(panels, dims, screen, entry, right_to_left, scale)
    if not (panels and #panels > 0 and dims and screen and scale) then
        return nil
    end
    local steps = {}
    local open_at = 1
    local cur

    local function push(index, view, frame)
        steps[#steps + 1] = {
            x = view.x, y = view.y, w = view.w, h = view.h,
            out_w = frame.out_w, out_h = frame.out_h,
            panel = index,
        }
    end

    for i = 1, #panels do
        local panel = whole(panels[i])
        local frame = frameForPanel(panel, dims, screen, scale)
        local views = positions(panel, frame.w, frame.h, dims, right_to_left)
        local wanted = entry and entry.panel == i
        if wanted or not (cur and #views == 1 and sameView(cur, views[1])) then
            for _, view in ipairs(views) do
                push(i, view, frame)
                cur = view
            end
            if wanted then
                open_at = entry.at_end and #steps or (#steps - #views + 1)
            end
        end
    end

    return steps, open_at
end

return Viewport

--[[
Notebook rulings (lined, grid, dots, margin, Cornell, blank) and planner pages
(handwriting, checklist, two columns, storyboard, music, daily, weekly, week
columns, monthly, meeting notes, habit tracker). Like the
rasterizer it emits horizontal spans through a `put(x, y, len)` callback, so the
page on screen and the export share the geometry; the caller's `put` picks the
colour. Every page follows the spacing `size` (the reader's line spacing), so
the planners grow and shrink with it like the plain rulings.
]]

local Template = {}

-- Horizontal rules at y = size, 2 * size, ... up to `y_end`, each `len` long from `x`.
local function rules(put, x, len, size, y_end)
    local cy = size
    while cy < y_end do
        put(x, cy, len)
        cy = cy + size
    end
end

-- A vertical rule at x from y0 to y1 (exclusive), `t` pixels thick.
local function vrule(put, x, y0, y1, t)
    for y = math.max(0, math.floor(y0)), math.floor(y1) - 1 do put(x, y, t or 1) end
end

-- A rectangle's outline, `t` pixels thick.
local function box(put, x, y, w, h, t)
    t = t or 1
    for k = 0, t - 1 do
        put(x, y + k, w)
        put(x, y + h - 1 - k, w)
    end
    vrule(put, x, y, y + h, t)
    vrule(put, x + w - t, y, y + h, t)
end

-- Rules every `size` from y0 + size up to y1, between x0 and x1.
local function rulesIn(put, x0, x1, y0, y1, size)
    local cy = y0 + size
    while cy < y1 do
        put(x0, math.floor(cy), x1 - x0)
        cy = cy + size
    end
end

-- The planner pages, keyed by style.
local PAGES = {}

-- A checkbox at the start of every line.
function PAGES.checklist(w, h, size, put)
    local m = math.floor(size * 0.6)
    local b = math.max(6, math.floor(size * 0.55))
    local cy = size
    while cy < h do
        local by = math.floor(cy - size * 0.2) - b
        if by > 0 then box(put, m, by, b, b, 1) end
        local lx = m + b + math.floor(size * 0.35)
        put(lx, cy, w - lx - m)
        cy = cy + size
    end
end

-- Two columns of lines with a gutter between them.
function PAGES.twocol(w, h, size, put)
    local m = math.floor(size * 0.5)
    local half = math.floor(w / 2)
    local g = math.floor(size * 0.5)
    local cy = size
    while cy < h do
        put(m, cy, half - g - m)
        put(half + g, cy, w - half - g - m)
        cy = cy + size
    end
end

-- A week: two columns of four boxes (seven days and notes), lined inside, under
-- a band for the dates.
function PAGES.weekly(w, h, size, put)
    local m = math.floor(size * 0.5)
    local top = m + math.floor(size * 1.5)
    local cw = math.floor((w - 2 * m) / 2)
    local ch = math.floor((h - top - m) / 4)
    for r = 0, 3 do
        for c = 0, 1 do
            local x, y = m + c * cw, top + r * ch
            box(put, x, y, cw, ch, 2)
            rulesIn(put, x + 2, x + cw - 2, y, y + ch - 2, size)
        end
    end
end

-- A month: a band for its name, seven columns by six weeks of boxes, and lines
-- for notes under it.
function PAGES.monthly(w, h, size, put)
    local m = math.floor(size * 0.5)
    local top = m + math.floor(size * 1.5)
    local gw = w - 2 * m
    local cw = math.floor(gw / 7)
    gw = cw * 7
    local gh = math.floor((h - top) * 0.62)
    local rh = math.floor(gh / 6)
    gh = rh * 6
    box(put, m, top, gw, gh, 2)
    for r = 1, 5 do put(m, top + r * rh, gw) end
    for c = 1, 6 do vrule(put, m + c * cw, top, top + gh, 1) end
    rulesIn(put, m, m + gw, top + gh, h - m, size)
end

-- Frames down the left, each with lines beside it for notes.
function PAGES.storyboard(w, h, size, put)
    local m = math.floor(size * 0.5)
    local row = size * 5
    local fh = size * 4
    local fw = math.floor((w - 2 * m) * 0.45)
    local lx = m + fw + math.floor(size * 0.5)
    local y = m
    while y + fh <= h - m do
        box(put, m, math.floor(y), fw, math.floor(fh), 2)
        rulesIn(put, lx, w - m, y - size * 0.5, y + fh, size)
        y = y + row
    end
end

-- Music staves: five lines a quarter of the spacing apart, a staff every two
-- and a half spacings.
function PAGES.music(w, h, size, put)
    local m = math.floor(w * 0.05)
    local gap = math.max(3, size / 4)
    local pitch = size * 2.5
    local y = size
    while y + 4 * gap < h - m do
        for k = 0, 4 do put(m, math.floor(y + k * gap), w - 2 * m) end
        vrule(put, m, y, y + 4 * gap + 1, 1)
        vrule(put, w - m - 1, y, y + 4 * gap + 1, 1)
        y = y + pitch
    end
end

-- A horizontal dashed rule: dashes of `dash` px with gaps as long.
local function dashed(put, x0, x1, y, dash)
    local x = x0
    while x < x1 do
        put(x, y, math.min(dash, x1 - x))
        x = x + 2 * dash
    end
end

-- Handwriting practice: a top line, a dashed midline and a baseline per line,
-- with room for descenders before the next.
function PAGES.handwriting(w, h, size, put)
    local m = math.floor(size * 0.5)
    local dash = math.max(3, math.floor(size / 6))
    local y = size
    while y + size < h do
        put(m, math.floor(y), w - 2 * m)
        dashed(put, m, w - m, math.floor(y + size / 2), dash)
        put(m, math.floor(y + size), w - 2 * m)
        y = y + size * 1.6
    end
end

-- A day: a column for the times, then a line every half hour, solid on the
-- hour and dashed between, under a band for the date.
function PAGES.daily(w, h, size, put)
    local m = math.floor(size * 0.5)
    local top = m + math.floor(size * 1.5)
    local tx = m + math.floor(w * 0.16)
    local dash = math.max(3, math.floor(size / 6))
    put(m, top, w - 2 * m)
    put(m, top + 1, w - 2 * m)
    vrule(put, tx, top, h - m, 1)
    local k, y = 1, top + size
    while y < h - m do
        if k % 2 == 0 then put(m, math.floor(y), w - 2 * m)
        else dashed(put, tx, w - m, math.floor(y), dash) end
        y = y + size
        k = k + 1
    end
end

-- A week in seven columns side by side, a band at the top of each for its
-- day, lines across.
function PAGES.weekcols(w, h, size, put)
    local m = math.floor(size * 0.5)
    local top = m + math.floor(size * 1.5)
    local cw = math.floor((w - 2 * m) / 7)
    local gw = cw * 7
    box(put, m, m, gw, h - 2 * m, 2)
    put(m, top, gw)
    put(m, top + 1, gw)
    for c = 1, 6 do vrule(put, m + c * cw, m, h - m, 1) end
    rulesIn(put, m, m + gw, top, h - m, size)
end

-- Meeting notes: a box for the title, date and who came, lines for the notes,
-- and a box of action items with checkboxes at the bottom.
function PAGES.meeting(w, h, size, put)
    local m = math.floor(size * 0.5)
    local head = math.floor(size * 3)
    box(put, m, m, w - 2 * m, head, 2)
    rulesIn(put, m + 2, w - m - 2, m, m + head - 2, size)
    vrule(put, math.floor(w * 0.62), m + size, m + head, 1)
    local act_y = math.floor(h * 0.72)
    rulesIn(put, m, w - m, m + head, act_y - size * 0.5, size)
    box(put, m, act_y, w - 2 * m, h - m - act_y, 2)
    local b = math.max(6, math.floor(size * 0.5))
    local y = act_y + size
    while y < h - m - 2 do
        box(put, m + math.floor(size * 0.4), math.floor(y - size * 0.2) - b, b, b, 1)
        local lx = m + math.floor(size * 0.4) + b + math.floor(size * 0.3)
        put(lx, math.floor(y), w - m - 2 - lx)
        y = y + size
    end
end

-- A habit tracker: a column for the habits and one narrow column a day for a
-- month, a row per habit, under a band for the dates.
function PAGES.habits(w, h, size, put)
    local m = math.floor(size * 0.5)
    local top = m + math.floor(size * 1.5)
    local label = math.floor((w - 2 * m) * 0.28)
    local dw = math.max(4, math.floor((w - 2 * m - label) / 31))
    local gw = label + dw * 31
    local rows = math.floor((h - m - top) / size)
    local gh = rows * size
    box(put, m, top, gw, gh, 2)
    vrule(put, m + label, top, top + gh, 2)
    for d = 1, 30 do vrule(put, m + label + d * dw, top, top + gh, 1) end
    for r = 1, rows - 1 do put(m, top + r * size, gw) end
end

-- Is `style` one of the planner pages (rather than a plain ruling)?
function Template.isPlanner(style)
    return PAGES[style] ~= nil
end

-- Draw `style` ruling over a w x h page with spacing `size` (px) via `put`.
function Template.render(style, w, h, size, put)
    if not style or style == "blank" then return end
    if not size or size <= 0 then return end
    if PAGES[style] then
        PAGES[style](w, h, size, put)
    elseif style == "lines" then
        rules(put, 0, w, size, h)
    elseif style == "thirds" then
        -- a drawing's rule-of-thirds guide (not a notebook paper)
        for i = 1, 2 do
            vrule(put, math.floor(w * i / 3), 0, h, 1)
            put(0, math.floor(h * i / 3), w)
        end
    elseif style == "grid" then
        rules(put, 0, w, size, h)
        local cx = size
        while cx < w do
            for y = 0, h - 1 do put(cx, y, 1) end   -- 1px vertical rule
            cx = cx + size
        end
    elseif style == "iso" then
        -- isometric: vertical rules and two families of 30-degree diagonals, so
        -- the lines meet in equilateral triangles
        local cx = size
        while cx < w do
            vrule(put, cx, 0, h, 1)
            cx = cx + size
        end
        local slope = math.tan(math.rad(30))
        local step = size / math.cos(math.rad(30))
        local reach = h * slope
        local b = -math.ceil(reach / step) * step
        while b < w + reach do
            for y = 0, h - 1 do
                local x1 = math.floor(b + y * slope)
                if x1 >= 0 and x1 < w then put(x1, y, 1) end
                local x2 = math.floor(b + reach - y * slope)
                if x2 >= 0 and x2 < w then put(x2, y, 1) end
            end
            b = b + step
        end
    elseif style == "dots" then
        -- a small filled square at each intersection, scaled with the spacing so
        -- the dots stay visible
        local r = math.max(3, math.floor(size / 12))
        local cy = size
        while cy < h do
            local cx = size
            while cx < w do
                for yy = 0, r - 1 do
                    if cy + yy < h then put(cx, cy + yy, r) end
                end
                cx = cx + size
            end
            cy = cy + size
        end
    elseif style == "margin" then
        -- ruled lines with one vertical margin rule down the left, like a legal
        -- pad
        local mx = math.floor(w * 0.12)
        rules(put, 0, w, size, h)
        for y = 0, h - 1 do put(mx, y, 1) end
    elseif style == "cornell" then
        -- Cornell notes: a left cue column, a bottom summary band and ruled lines
        -- only in the notes area
        local cue = math.floor(w * 0.28)
        local summary_y = math.floor(h * 0.80)
        rules(put, cue, w - cue, size, summary_y)
        for y = 0, summary_y - 1 do put(cue, y, 1) end      -- cue divider
        put(0, summary_y, w)                                -- summary divider
    end
end

return Template

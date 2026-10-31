--[[
The smart highlighter: which text does a highlighter stroke run over, so that it
can become the reader's own highlight of that text? Plain Lua (the book is
asked by ink/reader/book.lua), so the headless tests drive it.

The stroke is walked a few pixels at a time, and each point asks the book for
the word under it, or just above or below it (the highlighter is thick). When
enough of the stroke runs over words, it becomes the highlight of the text from
the first of them to the last, in reading order: what overflows into the margin
at either end, wobbles or crosses onto the next line still snaps to the text.
A stroke that runs over no text, or only grazes it (the space above a page, a
margin), stays ink.
]]

local Snap = {}

Snap.MIN_LEN = 12        -- px along the stroke: shorter is a dab, not a stroke
Snap.MIN_SHARE = 0.25    -- of the stroke over words, to snap
Snap.STEP = 4            -- px between the points asked about
Snap.MIN_COVER = 0.3     -- of a word's height the highlighter must cover, beside it

-- Points along the stroke's centre line every `step` px (always its ends):
-- a flat list x1, y1, x2, y2... and the line's length.
function Snap.samples(pts, step)
    step = step or Snap.STEP
    local out = { pts[1], pts[2] }
    local len = 0
    for i = 3, #pts - 1, 2 do
        local x0, y0, x1, y1 = pts[i - 2], pts[i - 1], pts[i], pts[i + 1]
        local d = math.sqrt((x1 - x0) ^ 2 + (y1 - y0) ^ 2)
        len = len + d
        local n = math.max(1, math.ceil(d / step))
        for k = 1, n do
            out[#out + 1] = x0 + (x1 - x0) * k / n
            out[#out + 1] = y0 + (y1 - y0) * k / n
        end
    end
    return out, len
end

local function inside(b, x, y, sx, sy)
    return x >= b.x - sx and x <= b.x + b.w + sx and y >= b.y - sy and y <= b.y + b.h + sy
end

-- The words a highlighter stroke `op` runs over. `wordAt(x, y)` gives the word
-- at a point as { box = { x, y, w, h }, ... } (or nil, or a word elsewhere: the
-- PDF reader gives the nearest one); a word counts when the point is in its box,
-- or within `reach` px above or below it. Words are told apart by `key(word)`.
-- Returns the words in stroke order, each once, and the share of the stroke
-- that ran over them; nil for a dab.
function Snap.hits(op, wordAt, reach, key)
    if not (op and op.pts and #op.pts >= 2) then return nil end
    local pts, len = Snap.samples(op.pts)
    if len < Snap.MIN_LEN then return nil end
    reach = reach or 0
    local words, seen, on, n = {}, {}, 0, 0
    for i = 1, #pts - 1, 2 do
        local x, y = pts[i], pts[i + 1]
        n = n + 1
        -- the word under the point, else the one just above or below that the
        -- highlighter's band [y - reach, y + reach] covers most (at least
        -- MIN_COVER of its height: a stroke drawn a little low over a line
        -- finds that line, not the next one's top)
        local w = wordAt(x, y)
        if not (w and w.box and inside(w.box, x, y, 2, 2)) then
            local best, bo
            for _j, dy in ipairs({ -reach, reach }) do
                local c = dy ~= 0 and wordAt(x, y + dy)
                if c and c.box and inside(c.box, x, y, 2, reach) then
                    local o = math.min(y + reach, c.box.y + c.box.h) - math.max(y - reach, c.box.y)
                    if o >= Snap.MIN_COVER * c.box.h and (not bo or o > bo) then best, bo = c, o end
                end
            end
            w = best
        end
        if w then
            on = on + 1
            local k = key(w)
            if not seen[k] then
                seen[k] = 0
                words[#words + 1] = w
            end
            seen[k] = seen[k] + 1
        end
    end
    return Snap.oneLine(op, words, seen, key), n > 0 and on / n or 0
end

-- A stroke that stays within a line's height is on one line: of the words it
-- found, only those on the line it ran over most (a highlighter thicker than
-- the lines, as on a zoomed PDF, also touches the lines above and below where
-- it crosses a gap between words). A stroke that goes down the page keeps all.
-- `count[key(word)]` is how many of the stroke's points found each word.
function Snap.oneLine(op, words, count, key)
    if #words < 2 then return words end
    local y0, y1 = math.huge, -math.huge
    for i = 2, #op.pts, 2 do
        local y = op.pts[i]
        if y < y0 then y0 = y end
        if y > y1 then y1 = y end
    end
    local hs = {}
    for i, w in ipairs(words) do hs[i] = w.box.h end
    table.sort(hs)
    local hm = hs[math.ceil(#hs / 2)]
    if y1 - y0 >= 0.8 * hm then return words end
    -- the words in lines (centres within half a line of each other), and the
    -- line with the most of the stroke's points
    local best, best_n
    for _i, w in ipairs(words) do
        local cy = w.box.y + w.box.h / 2
        local n = 0
        for _j, o in ipairs(words) do
            if math.abs(o.box.y + o.box.h / 2 - cy) < hm / 2 then n = n + count[key(o)] end
        end
        if not best_n or n > best_n then best, best_n = cy, n end
    end
    local out = {}
    for _i, w in ipairs(words) do
        if math.abs(w.box.y + w.box.h / 2 - best) < hm / 2 then out[#out + 1] = w end
    end
    return out
end

-- The first and last of `words` in reading order, `before(a, b)` saying a
-- comes before b.
function Snap.ends(words, before)
    local first, last = words[1], words[1]
    for i = 2, #words do
        local w = words[i]
        if before(w, first) then first = w end
        if before(last, w) then last = w end
    end
    return first, last
end

-- Reading order on a fixed page: by line, then across (words whose boxes share
-- most of their height are on one line).
function Snap.pageBefore(a, b)
    local ay, by = a.box.y + a.box.h / 2, b.box.y + b.box.h / 2
    local h = math.min(a.box.h, b.box.h) / 2
    if math.abs(ay - by) > h then return ay < by end
    return a.box.x < b.box.x
end

-- Does a stroke snap? Its words and share, from Snap.hits.
function Snap.snaps(words, share)
    return words ~= nil and #words > 0 and share >= Snap.MIN_SHARE
end

-- KOReader's highlight colours (Blitbuffer.HIGHLIGHT_COLORS), for a reader
-- that does not have them.
local NAMED = {
    red = "#FF3300", orange = "#FF8800", yellow = "#FFFF33", green = "#00AA66",
    olive = "#88FF77", cyan = "#00FFEE", blue = "#0066FF", purple = "#EE00FF",
}

-- The colours of Ink Away's pen menu, and the highlight colour each is.
local PALETTE = {
    ["208,0,0"] = "red", ["224,112,0"] = "orange", ["232,192,0"] = "yellow", ["0,144,0"] = "green",
    ["0,80,208"] = "blue", ["128,0,176"] = "purple", ["255,235,59"] = "yellow",
}

-- Hue (degrees), saturation and value of an RGB colour.
local function hsv(r, g, b)
    local hi, lo = math.max(r, g, b), math.min(r, g, b)
    local d = hi - lo
    local h = 0
    if d > 0 then
        if hi == r then h = 60 * (((g - b) / d) % 6)
        elseif hi == g then h = 60 * ((b - r) / d + 2)
        else h = 60 * ((r - g) / d + 4) end
    end
    return h, hi > 0 and d / hi or 0, hi / 255
end

-- Where each named colour sits on the colour wheel, as a reader names them
-- (KOReader's "green" is a sea green and its "olive" a light green, so plain
-- greens go to green).
local HUES = { red = 4, orange = 30, yellow = 55, green = 125, cyan = 180, blue = 218, purple = 290 }

-- The reader's highlight colour for the pen's colour: Ink Away's own colours as
-- named, any other by its hue (a pale green is olive); a grey pen (as on a grey
-- screen) gives `fallback`, the colour the reader highlights in by default.
-- `named` is the reader's list, so only colours it has are given.
function Snap.colourName(color, fallback, named)
    if type(color) ~= "table" then return fallback end
    named = named or NAMED
    local r, g, b = color[1] or 0, color[2] or 0, color[3] or 0
    local exact = PALETTE[r .. "," .. g .. "," .. b]
    if exact and named[exact] then return exact end
    local h, s, v = hsv(r, g, b)
    if s < 0.2 or v < 0.08 then return fallback end
    if h >= 80 and h <= 160 and s < 0.6 and v > 0.85 and named.olive then return "olive" end
    local best, bd
    for name, hue in pairs(HUES) do
        if named[name] then
            local d = math.abs(h - hue)
            d = math.min(d, 360 - d)
            if not bd or d < bd or (d == bd and name < best) then best, bd = name, d end
        end
    end
    return best or fallback
end

return Snap

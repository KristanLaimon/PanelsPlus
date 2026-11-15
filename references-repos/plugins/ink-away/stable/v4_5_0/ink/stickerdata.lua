--[[
The built-in stickers, as drawing recipes: a few lines of points each, so all of
them together are a few kilobytes, stay sharp at any size, take any colour and
look the same on every device (see ink/stickers.lua, which turns a recipe into
shapes on the page).

A recipe is { id, cat, w, h, palette, edge, parts = function() -> parts } drawn in
a box w by h (design units, y down). `palette` says which colours the sticker
offers ("pastel", "strong", or nil for fixed colours). A part is
{ poly = {x, y, ...}, fill, edge, closed, w, alpha, body }:
  fill   "body" (the chosen colour), "dark", "light", "white", "ink" or {r,g,b}
         (false for an outline only); for an open line, its colour
  edge   "tone" (a darker shade of the body), "ink", "none" or {r,g,b}
  closed false for an open line, drawn w units thick (a closed shape's w is its
         outline's thickness)
  alpha  0 to 255, for a shadow or tape you see through
  body   the part a pen or a text box counts as being on
Plain Lua, so the headless tests drive it.
]]

local pi, sin, cos, abs = math.pi, math.sin, math.cos, math.abs

local D = {}

------------------------------------------------------------------------------
-- Shape helpers
------------------------------------------------------------------------------

local function rect(x, y, w, h) return { x, y, x + w, y, x + w, y + h, x, y + h } end

-- Append the points of an arc (angles in radians, 0 is right, y down).
local function arc(t, cx, cy, rx, ry, a0, a1, n)
    n = n or 7
    for i = 0, n do
        local a = a0 + (a1 - a0) * i / n
        t[#t + 1] = cx + rx * cos(a)
        t[#t + 1] = cy + ry * sin(a)
    end
    return t
end

local function ellipse(cx, cy, rx, ry, n)
    local t = {}
    n = n or 32
    for i = 0, n - 1 do
        local a = i / n * 2 * pi
        t[#t + 1] = cx + rx * cos(a)
        t[#t + 1] = cy + ry * sin(a)
    end
    return t
end

-- A rounded rectangle; `tail` = { x1, x2, tipx, tipy } adds a speech tail on the
-- bottom edge (x1 < x2, both inside the straight part).
local function rrect(x, y, w, h, r, tail)
    local t = {}
    arc(t, x + r, y + r, r, r, pi, 1.5 * pi, 5)
    arc(t, x + w - r, y + r, r, r, 1.5 * pi, 2 * pi, 5)
    arc(t, x + w - r, y + h - r, r, r, 0, 0.5 * pi, 5)
    if tail then
        t[#t + 1] = tail[2]; t[#t + 1] = y + h
        t[#t + 1] = tail[3]; t[#t + 1] = tail[4]
        t[#t + 1] = tail[1]; t[#t + 1] = y + h
    end
    arc(t, x + r, y + h - r, r, r, 0.5 * pi, pi, 5)
    return t
end

-- An ellipse with a gap (angles a0 to a1) closed by a tail to (tx, ty).
local function bubble(cx, cy, rx, ry, a0, a1, tx, ty)
    local t = arc({}, cx, cy, rx, ry, a1, a0 + 2 * pi, 30)
    t[#t + 1] = tx; t[#t + 1] = ty
    return t
end

local function star(cx, cy, ro, ri, n, rot)
    local t = {}
    rot = rot or -pi / 2
    for i = 0, 2 * n - 1 do
        local r = (i % 2 == 0) and ro or ri
        local a = rot + i * pi / n
        t[#t + 1] = cx + r * cos(a)
        t[#t + 1] = cy + r * sin(a)
    end
    return t
end

local function heart(cx, cy, s)
    local t = {}
    for i = 0, 39 do
        local a = i / 40 * 2 * pi
        t[#t + 1] = cx + s * 16 * sin(a) ^ 3 / 16
        t[#t + 1] = cy - s * (13 * cos(a) - 5 * cos(2 * a) - 2 * cos(3 * a) - cos(4 * a)) / 16
    end
    return t
end

-- A scalloped outline (a cloud) of an ellipse.
local function cloud(cx, cy, rx, ry, lobes, n)
    local t = {}
    n = n or 64
    for i = 0, n - 1 do
        local a = i / n * 2 * pi
        local m = 0.86 + 0.16 * abs(sin(lobes * a / 2))
        t[#t + 1] = cx + rx * m * cos(a)
        t[#t + 1] = cy + ry * m * sin(a)
    end
    return t
end

local function bezier(p0, p1, p2, p3, n)
    local t = {}
    n = n or 16
    for i = 0, n do
        local u = i / n
        local a, b, c, d = (1 - u) ^ 3, 3 * (1 - u) ^ 2 * u, 3 * (1 - u) * u * u, u ^ 3
        t[#t + 1] = a * p0[1] + b * p1[1] + c * p2[1] + d * p3[1]
        t[#t + 1] = a * p0[2] + b * p1[2] + c * p2[2] + d * p3[2]
    end
    return t
end

local function join(...)
    local out = {}
    for _, t in ipairs({ ... }) do for i = 1, #t do out[#out + 1] = t[i] end end
    return out
end

-- A triangle with its tip at (x, y) + d * len, pointing along (dx, dy).
local function head(x, y, dx, dy, len, wid)
    local l = math.sqrt(dx * dx + dy * dy)
    dx, dy = dx / l, dy / l
    local px, py = -dy, dx
    return { x + dx * len, y + dy * len, x + px * wid, y + py * wid, x - px * wid, y - py * wid }
end

local function rotated(poly, deg, cx, cy)
    local a = deg * pi / 180
    local ca, sa = cos(a), sin(a)
    local out = {}
    for i = 1, #poly, 2 do
        local dx, dy = poly[i] - cx, poly[i + 1] - cy
        out[i] = cx + dx * ca - dy * sa
        out[i + 1] = cy + dx * sa + dy * ca
    end
    return out
end

local function wave(x0, y0, len, amp, periods, n)
    local t = {}
    n = n or 40
    for i = 0, n do
        t[#t + 1] = x0 + len * i / n
        t[#t + 1] = y0 + amp * sin(periods * 2 * pi * i / n)
    end
    return t
end

local function part(poly, o)
    o = o or {}
    o.poly = poly
    return o
end

local YELLOW, RED, GREY, BLUEWHITE = { 255, 214, 80 }, { 214, 72, 72 }, { 150, 150, 150 }, { 226, 238, 250 }
local SOFT = { 0, 0, 0 }

------------------------------------------------------------------------------
-- The catalogue
------------------------------------------------------------------------------

D.CATEGORIES = { "notes", "bubbles", "marks", "tape", "fun" }

local list = {}
local function add(id, cat, w, h, palette, edge, parts)
    list[#list + 1] = { id = id, cat = cat, w = w, h = h, palette = palette, edge = edge, parts = parts }
end

-- A sheet of paper with a soft shadow under it: the shadow, then `body`.
local function paper(body, extra)
    local out = { part(body.shadow, { fill = SOFT, alpha = 55, edge = "none" }),
        part(body.poly, { fill = "body", edge = "tone", body = true }) }
    for _, p in ipairs(extra or {}) do out[#out + 1] = p end
    return out
end

local function shifted(poly, dx, dy)
    local out = {}
    for i = 1, #poly, 2 do out[i] = poly[i] + dx; out[i + 1] = poly[i + 1] + dy end
    return out
end

-- Notes ----------------------------------------------------------------------

add("postit", "notes", 100, 100, "pastel", "tone", function()
    local b = { 0, 0, 100, 0, 100, 76, 76, 100, 0, 100 }
    return paper({ poly = b, shadow = shifted(b, 3, 4) },
        { part({ 100, 76, 76, 100, 76, 76 }, { fill = "dark", edge = "tone" }) })
end)

add("postit_tall", "notes", 80, 100, "pastel", "tone", function()
    local b = { 0, 0, 80, 0, 80, 78, 58, 100, 0, 100 }
    return paper({ poly = b, shadow = shifted(b, 3, 4) },
        { part({ 80, 78, 58, 100, 58, 78 }, { fill = "dark", edge = "tone" }) })
end)

add("postit_wide", "notes", 100, 62, "pastel", "tone", function()
    local b = { 0, 0, 100, 0, 100, 44, 82, 62, 0, 62 }
    return paper({ poly = b, shadow = shifted(b, 3, 4) },
        { part({ 100, 44, 82, 62, 82, 44 }, { fill = "dark", edge = "tone" }) })
end)

add("postit_curl", "notes", 100, 100, "pastel", "tone", function()
    local b = { 0, 0, 100, 0, 100, 68, 66, 100, 0, 100 }
    return paper({ poly = b, shadow = shifted(b, 3, 4) },
        { part(join({ 100, 68 }, bezier({ 100, 68 }, { 84, 70 }, { 68, 84 }, { 66, 100 }, 8)), { fill = "dark", edge = "tone" }) })
end)

add("postit_torn", "notes", 100, 100, "pastel", "tone", function()
    local b = {}
    for i = 0, 16 do b[#b + 1] = 100 * i / 16; b[#b + 1] = (i % 2 == 0) and 0 or 6 end
    for _, v in ipairs({ 100, 100, 0, 100 }) do b[#b + 1] = v end
    return paper({ poly = b, shadow = shifted(b, 3, 4) })
end)

add("postit_taped", "notes", 100, 108, "pastel", "tone", function()
    local b = rect(0, 10, 100, 98)
    return paper({ poly = b, shadow = shifted(b, 3, 4) },
        { part(rotated(rect(28, -2, 44, 20), -4, 50, 8), { fill = "light", edge = "tone", alpha = 215 }) })
end)

add("postit_pin", "notes", 100, 108, "pastel", "tone", function()
    local b = rect(0, 8, 100, 100)
    return paper({ poly = b, shadow = shifted(b, 3, 4) }, {
        part(ellipse(53, 18, 9, 7), { fill = SOFT, alpha = 70, edge = "none" }),
        part(ellipse(50, 14, 9, 9), { fill = RED, edge = "ink" }),
        part(ellipse(47, 11, 2.6, 2.6, 12), { fill = "white", edge = "none" }),
    })
end)

add("index_card", "notes", 100, 64, "pastel", "tone", function()
    local b = rect(0, 0, 100, 64)
    return paper({ poly = b, shadow = shifted(b, 3, 4) }, {
        part({ 0, 14, 100, 14 }, { fill = { 214, 90, 90 }, closed = false, w = 1.1 }),
        part({ 0, 28, 100, 28 }, { fill = { 120, 160, 214 }, closed = false, w = 0.9 }),
        part({ 0, 42, 100, 42 }, { fill = { 120, 160, 214 }, closed = false, w = 0.9 }),
        part({ 0, 56, 100, 56 }, { fill = { 120, 160, 214 }, closed = false, w = 0.9 }),
    })
end)

add("flag", "notes", 100, 56, "pastel", "tone", function()
    local b = { 0, 0, 76, 0, 100, 28, 76, 56, 0, 56 }
    return paper({ poly = b, shadow = shifted(b, 3, 4) })
end)

add("tag", "notes", 100, 60, "pastel", "tone", function()
    local b = join({ 26, 0, 100, 0, 100, 60, 26, 60 }, { 0, 30 })
    return paper({ poly = b, shadow = shifted(b, 3, 4) }, {
        part(ellipse(22, 30, 5, 5, 14), { fill = "white", edge = "tone" }),
    })
end)

-- Speech and thought -----------------------------------------------------------

add("speech", "bubbles", 100, 86, nil, "ink", function()
    local b = bubble(50, 36, 48, 34, 0.62 * pi, 0.80 * pi, 22, 84)
    return { part(shifted(b, 2, 3), { fill = SOFT, alpha = 40, edge = "none" }),
        part(b, { fill = "white", edge = "ink", body = true }) }
end)

add("speech_box", "bubbles", 100, 76, nil, "ink", function()
    local b = rrect(0, 0, 100, 58, 12, { 18, 36, 12, 74 })
    return { part(shifted(b, 2, 3), { fill = SOFT, alpha = 40, edge = "none" }),
        part(b, { fill = "white", edge = "ink", body = true }) }
end)

add("shout", "bubbles", 100, 86, nil, "ink", function()
    local b = star(50, 43, 50, 31, 12, -pi / 2 + 0.1)
    return { part(shifted(b, 2, 3), { fill = SOFT, alpha = 40, edge = "none" }),
        part(b, { fill = { 255, 232, 120 }, edge = "ink", body = true }) }
end)

add("thought", "bubbles", 100, 100, nil, "ink", function()
    local c = cloud(50, 34, 46, 30, 9)
    return { part(shifted(c, 2, 3), { fill = SOFT, alpha = 40, edge = "none" }),
        part(c, { fill = "white", edge = "ink", body = true }),
        part(ellipse(30, 78, 8, 7, 18), { fill = "white", edge = "ink" }),
        part(ellipse(18, 91, 5, 4.5, 14), { fill = "white", edge = "ink" }) }
end)

add("ribbon", "bubbles", 100, 44, "pastel", "tone", function()
    local b = { 0, 0, 100, 0, 90, 22, 100, 44, 0, 44, 10, 22 }
    return { part(shifted(b, 2, 3), { fill = SOFT, alpha = 45, edge = "none" }),
        part(b, { fill = "body", edge = "tone", body = true }) }
end)

-- Marks --------------------------------------------------------------------------

add("arrow", "marks", 100, 60, "strong", "ink", function()
    return { part({ 0, 22, 62, 22, 62, 3, 100, 30, 62, 57, 62, 38, 0, 38 }, { fill = "body", edge = "ink" }) }
end)

add("arrow_curved", "marks", 100, 70, "strong", "ink", function()
    local p3 = { 82, 22 }
    local curve = bezier({ 6, 62 }, { 8, 20 }, { 50, 0 }, p3, 18)
    local h = head(p3[1], p3[2], 30, 20, 17, 13)
    return { part(curve, { fill = "ink", closed = false, w = 11 }),
        part(h, { fill = "ink", edge = "ink", w = 3 }),
        part(curve, { fill = "body", closed = false, w = 6 }),
        part(h, { fill = "body", edge = "none" }) }
end)

add("tick", "marks", 100, 100, "strong", "ink", function()
    local p = { 12, 54, 38, 80, 88, 18 }
    return { part(p, { fill = "ink", closed = false, w = 17 }), part(p, { fill = "body", closed = false, w = 10 }) }
end)

add("cross", "marks", 100, 100, "strong", "ink", function()
    local a, b = { 16, 16, 84, 84 }, { 84, 16, 16, 84 }
    return { part(a, { fill = "ink", closed = false, w = 17 }), part(b, { fill = "ink", closed = false, w = 17 }),
        part(a, { fill = "body", closed = false, w = 10 }), part(b, { fill = "body", closed = false, w = 10 }) }
end)

add("star", "marks", 100, 96, "strong", "ink", function()
    return { part(star(50, 52, 48, 21, 5), { fill = "body", edge = "ink", w = 2.2 }) }
end)

add("heart", "marks", 100, 92, "strong", "ink", function()
    return { part(heart(50, 46, 46), { fill = "body", edge = "ink", w = 2.2 }) }
end)

add("exclaim", "marks", 60, 100, "strong", "ink", function()
    return { part({ 18, 4, 42, 4, 37, 62, 23, 62 }, { fill = "body", edge = "ink", w = 2.2 }),
        part(ellipse(30, 84, 9, 9, 18), { fill = "body", edge = "ink", w = 2.2 }) }
end)

add("question", "marks", 80, 100, "strong", "ink", function()
    local q = arc({}, 40, 30, 22, 22, 0.92 * pi, 2.12 * pi, 14)
    q[#q + 1] = 40; q[#q + 1] = 62; q[#q + 1] = 40; q[#q + 1] = 68
    return { part(q, { fill = "ink", closed = false, w = 17 }), part(q, { fill = "body", closed = false, w = 10 }),
        part(ellipse(40, 88, 9, 9, 18), { fill = "body", edge = "ink", w = 2.2 }) }
end)

add("ring", "marks", 100, 100, "strong", "ink", function()
    local r = ellipse(50, 50, 44, 44, 40)
    return { part(r, { fill = false, edge = "ink", w = 15 }), part(r, { fill = false, edge = "body", w = 9 }) }
end)

add("squiggle", "marks", 100, 30, "strong", "ink", function()
    local p = wave(6, 15, 88, 9, 4)
    return { part(p, { fill = "ink", closed = false, w = 10 }), part(p, { fill = "body", closed = false, w = 5.5 }) }
end)

add("bracket", "marks", 50, 100, "strong", "ink", function()
    local p = { 40, 6, 12, 6, 12, 94, 40, 94 }
    return { part(p, { fill = "ink", closed = false, w = 15 }), part(p, { fill = "body", closed = false, w = 8 }) }
end)

add("pin_marker", "marks", 76, 100, "strong", "ink", function()
    local t = join({ 38, 98 }, arc({}, 38, 36, 32, 32, 0.68 * pi, 2.32 * pi, 26))
    return { part(t, { fill = "body", edge = "ink", w = 2.2 }), part(ellipse(38, 36, 12, 12, 20), { fill = "white", edge = "ink", w = 1.8 }) }
end)

-- Tape and clips ---------------------------------------------------------------------

local function tapeStrip()
    local t = {}
    for i = 0, 4 do t[#t + 1] = (i % 2 == 0) and 0 or 5; t[#t + 1] = 28 * i / 4 end
    for i = 4, 0, -1 do t[#t + 1] = 100 - ((i % 2 == 0) and 0 or 5); t[#t + 1] = 28 * i / 4 end
    local out = {}
    -- left side top to bottom, then right side bottom to top
    for i = 1, 5 do out[#out + 1] = t[2 * i - 1]; out[#out + 1] = t[2 * i] end
    for i = 6, 10 do out[#out + 1] = t[2 * i - 1]; out[#out + 1] = t[2 * i] end
    return out
end

add("tape", "tape", 100, 28, "pastel", "none", function()
    return { part(tapeStrip(), { fill = "body", edge = "none", alpha = 205, body = true }),
        part({ 12, 8, 88, 8 }, { fill = "white", closed = false, w = 1.2, alpha = 140 }) }
end)

add("tape_slant", "tape", 100, 70, "pastel", "none", function()
    return { part(rotated(shifted(tapeStrip(), 0, 21), -24, 50, 35), { fill = "body", edge = "none", alpha = 205, body = true }) }
end)

add("tape_corner", "tape", 70, 70, "pastel", "none", function()
    return { part({ 0, 0, 70, 0, 0, 70 }, { fill = "body", edge = "none", alpha = 205, body = true }) }
end)

add("clip", "tape", 60, 100, nil, "none", function()
    local p = { 22, 14, 22, 78 }
    arc(p, 34, 78, 12, 12, pi, 0, 8)
    p[#p + 1] = 46; p[#p + 1] = 30
    arc(p, 36, 30, 10, 10, 0, -pi, 8)
    p[#p + 1] = 26; p[#p + 1] = 60
    return { part(p, { fill = { 120, 126, 136 }, closed = false, w = 5 }) }
end)

add("bookmark", "tape", 44, 100, "pastel", "tone", function()
    return { part({ 0, 0, 44, 0, 44, 100, 22, 80, 0, 100 }, { fill = "body", edge = "tone", body = true }) }
end)

add("pushpin", "tape", 60, 100, nil, "ink", function()
    return { part({ 26, 44, 34, 44, 30, 98 }, { fill = GREY, edge = "ink" }),
        part(ellipse(30, 26, 24, 24, 24), { fill = RED, edge = "ink", w = 2 }),
        part(ellipse(22, 17, 6, 6, 12), { fill = "white", edge = "none" }) }
end)

-- Fun ----------------------------------------------------------------------------------

local function face(mouth)
    return function()
        local out = { part(ellipse(50, 50, 46, 46, 40), { fill = YELLOW, edge = "ink", w = 2.2, body = true }),
            part(ellipse(34, 40, 5.5, 8, 14), { fill = "ink", edge = "none" }),
            part(ellipse(66, 40, 5.5, 8, 14), { fill = "ink", edge = "none" }) }
        out[#out + 1] = part(mouth(), { fill = "ink", closed = false, w = 5 })
        return out
    end
end

add("smile", "fun", 100, 100, nil, "ink", face(function() return arc({}, 50, 50, 26, 26, 0.18 * pi, 0.82 * pi, 12) end))
add("meh", "fun", 100, 100, nil, "ink", face(function() return { 33, 68, 67, 68 } end))
add("sad", "fun", 100, 100, nil, "ink", face(function() return arc({}, 50, 88, 24, 20, 1.18 * pi, 1.82 * pi, 12) end))

add("bulb", "fun", 80, 100, nil, "ink", function()
    return { part(ellipse(40, 36, 30, 32, 32), { fill = YELLOW, edge = "ink", w = 2.2, body = true }),
        part(rrect(26, 66, 28, 22, 5), { fill = GREY, edge = "ink", w = 2 }),
        part({ 28, 76, 52, 76 }, { fill = "ink", closed = false, w = 2 }),
        part({ 34, 90, 46, 90 }, { fill = "ink", closed = false, w = 4 }) }
end)

add("sun", "fun", 100, 100, nil, "ink", function()
    local out = {}
    for i = 0, 7 do
        local a = i * pi / 4
        out[#out + 1] = part({ 50 + 32 * cos(a), 50 + 32 * sin(a), 50 + 46 * cos(a), 50 + 46 * sin(a) },
            { fill = { 240, 150, 40 }, closed = false, w = 6 })
    end
    out[#out + 1] = part(ellipse(50, 50, 24, 24, 32), { fill = YELLOW, edge = "ink", w = 2.2, body = true })
    return out
end)

add("cloud", "fun", 100, 66, nil, "ink", function()
    return { part(cloud(50, 33, 48, 30, 7), { fill = BLUEWHITE, edge = "ink", w = 2.2, body = true }) }
end)

D.list = list

return D

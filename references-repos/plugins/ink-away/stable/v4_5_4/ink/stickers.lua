--[[
Stickers: ready-made things to put on a page, a post-it, a speech bubble, an arrow.
A built-in sticker is a few shapes drawn from a recipe (ink/stickerdata.lua), so
it is tiny, sharp at any size and takes any colour. On the page it is a group of
ordinary shape ops sharing a `group` id (and marked `stk`), so moving, resizing,
turning, copying, deleting, undo, saving and export all work as they do for any
shapes, with nothing new to draw or save.

Writing on a sticker belongs to it: a pen stroke, an erase, a text box or a shape
that begins on a sticker's body gets that sticker's group id when it is placed
(Stickers.attach), and selecting any part of a group selects all of it
(Stickers.expand), so what is written on a post-it moves, turns and resizes with
it. Plain Lua, so the headless tests drive it.
]]

local Data = require("ink/stickerdata")
local Geom = require("ink/geom")
local Shapes = require("ink/shapes")

local Stickers = {}

Stickers.CATEGORIES = Data.CATEGORIES
Stickers.list = Data.list

-- The colours a sticker can take: soft ones for notes and tape, strong ones for
-- marks that must show on the page.
Stickers.COLOURS = {
    pastel = { { 255, 236, 128 }, { 255, 186, 206 }, { 190, 232, 150 }, { 160, 210, 250 },
        { 255, 198, 132 }, { 208, 188, 244 }, { 236, 236, 236 } },
    strong = { { 214, 58, 58 }, { 240, 140, 30 }, { 52, 160, 80 }, { 50, 110, 220 },
        { 150, 80, 200 }, { 40, 40, 40 } },
}

local INK = { 38, 38, 38 }
local WHITE = { 255, 255, 255 }

local function darker(c, k) return { math.floor(c[1] * k + 0.5), math.floor(c[2] * k + 0.5), math.floor(c[3] * k + 0.5) } end
local function lighter(c, k)
    return { math.floor(c[1] + (255 - c[1]) * k + 0.5), math.floor(c[2] + (255 - c[2]) * k + 0.5),
        math.floor(c[3] + (255 - c[3]) * k + 0.5) }
end

-- The sticker with this id, or nil.
function Stickers.get(id)
    for _, s in ipairs(Data.list) do if s.id == id then return s end end
end

-- The stickers of a category, in order.
function Stickers.inCategory(cat)
    local out = {}
    for _, s in ipairs(Data.list) do if s.cat == cat then out[#out + 1] = s end end
    return out
end

-- The colour the first palette entry gives when nothing was chosen.
function Stickers.defaultColour(palette)
    return Stickers.COLOURS[palette or "pastel"][1]
end

local serial = 0
-- A group id no other group on the page has (time and a count, kept as text).
function Stickers.newGroup()
    serial = serial + 1
    return string.format("%x-%x", os.time(), serial)
end

local function colour(role, body)
    if role == "body" then return body end
    if role == "dark" then return darker(body, 0.82) end
    if role == "light" then return lighter(body, 0.55) end
    if role == "white" then return WHITE end
    if role == "ink" then return INK end
    if type(role) == "table" then return role end
    return nil
end

local function edgeColour(edge, body)
    if edge == "none" or edge == false then return nil end
    if edge == "tone" then return darker(body, 0.55) end
    if edge == "ink" or edge == nil then return INK end
    if edge == "body" then return body end
    if edge == "dark" then return darker(body, 0.82) end
    if type(edge) == "table" then return edge end
    return INK
end

-- The ops of sticker `id` in colour `body` ({r,g,b}) with its left top at (x, y)
-- and `w` wide on the page, as one group. `gid` is the group (a new one when nil).
-- Returns the list of ops (bottom first) and the sticker's height.
function Stickers.build(id, body, x, y, w, gid)
    local s = Stickers.get(id)
    if not s then return nil end
    body = body or Stickers.defaultColour(s.palette)
    gid = gid or Stickers.newGroup()
    local k = w / s.w
    local ops = {}
    for _, p in ipairs(s.parts()) do
        local pts = {}
        for i = 1, #p.poly, 2 do
            pts[i] = x + p.poly[i] * k
            pts[i + 1] = y + p.poly[i + 1] * k
        end
        local closed = p.closed ~= false
        local fill = (p.fill ~= false) and colour(p.fill or "body", body) or nil
        local op = { kind = "shape", shape = "poly", pts = pts, closed = closed or nil, group = gid, stk = id }
        local alpha = p.alpha
        if closed then
            local e = edgeColour(p.edge or s.edge, body)
            op.fill_color = fill
            op.fill_alpha = alpha
            op.color = e or fill or INK
            op.width = math.max(1, (p.w or 1.4) * k)
            op.alpha = alpha
        else
            op.color = fill or INK
            op.width = math.max(1, (p.w or 6) * k)
            op.alpha = alpha
        end
        if p.body then op.sbody = true end
        ops[#ops + 1] = op
    end
    return ops, s.h * k
end

------------------------------------------------------------------------------
-- Groups on a page
------------------------------------------------------------------------------

-- The group of the topmost sticker whose body holds the canvas point (x, y), or nil.
function Stickers.groupAt(ops, x, y)
    for i = #ops, 1, -1 do
        local op = ops[i]
        if op.sbody and not op.hidden then
            local poly = Shapes.outline(op)
            if poly and #poly >= 6 and Geom.pointInPoly(x, y, poly) then return op.group end
        end
    end
    return nil
end

-- The kinds of op that belong to the sticker they were begun on.
local JOINS = { ink = true, erase = true, text = true, shape = true, fill = true }

-- Where an op begins (a pen stroke's first point, a text box's corner), or nil.
local function anchor(op)
    if op.kind == "text" then
        return (op.x or 0) + 6, (op.y or 0) + 6   -- (a box is begun where it was tapped; it may run past the note)
    end
    if op.pts and op.pts[1] then return op.pts[1], op.pts[2] end
    if op.runs and op.runs[1] then return op.runs[1], op.runs[2] end
    return nil
end

-- Give a new op the group of the sticker it was begun on, if it was begun on one
-- (and has no group yet). Returns the group, or nil.
function Stickers.attach(ops, op)
    if op.group or op.stk or not JOINS[op.kind] then return nil end
    local x, y = anchor(op)
    if not x then return nil end
    local gid = Stickers.groupAt(ops, x, y)
    if gid then op.group = gid end
    return gid
end

-- The indices of every op in `ops` that is in a group `idxs` has a member of,
-- with `idxs` themselves (no index twice).
function Stickers.expand(ops, idxs)
    local want, seen, out = {}, {}, {}
    for _, i in ipairs(idxs) do
        seen[i] = true
        out[#out + 1] = i
        local g = ops[i] and ops[i].group
        if g then want[g] = true end
    end
    if next(want) then
        for i, op in ipairs(ops) do
            if op.group and want[op.group] and not seen[i] then
                seen[i] = true
                out[#out + 1] = i
            end
        end
    end
    return out
end

-- Give each group among `ops` (copies about to be placed) a new id, the same new
-- one for each of its members, so a duplicate or a paste moves apart from the
-- original.
function Stickers.rekey(ops)
    local map = {}
    for _, op in ipairs(ops) do
        local g = op.group
        if g then
            if not map[g] then map[g] = Stickers.newGroup() end
            op.group = map[g]
        end
    end
end

-- Is this op part of a built-in sticker (drawn by a recipe)?
function Stickers.isPart(op) return op.stk ~= nil end

return Stickers

--[[
Links between pages, and a notebook's contents page. Plain Lua, so the headless
tests drive it; ink/view/links.lua makes, shows and follows them.

A link is an op of its own, an area of the page that leads to a page:

    { kind = "link", x, y, w, h,            -- the area, canvas px
      to = { path = nil | notebook file,    -- nil: a page of the same notebook
             id = page id, page = number,   -- the page (its number if the id is gone)
             label = what it was made to } }

It draws nothing into the page or an export (it is shown with a dotted
underline on screen) and a tap with Pan or a navigating finger follows it. The
lasso selects it like a text box, so it moves, resizes and is deleted with
whatever it was made on. Pages keep their ids however they are moved, so a link
holds through page moves; a link within a notebook holds through renames too.

A contents page lists the notebook's titled pages, one line each with its page
number, each line a link to its page. It is made (or made again, with the
numbers brought up to date) from the page menu; its own lines are marked
`toc = true`, so anything else written on it stays.
]]

local Text = require("ink/text")

local Links = {}

-- A link over the box { x0, y0, x1, y1 } to target `to`.
function Links.new(box, to)
    return { kind = "link", x = box.x0, y = box.y0, w = box.x1 - box.x0, h = box.y1 - box.y0, to = to }
end

function Links.isLink(op) return type(op) == "table" and op.kind == "link" and type(op.to) == "table" end

-- The links among `ops`, in order.
function Links.list(ops)
    local out = {}
    for _, op in ipairs(ops or {}) do
        if Links.isLink(op) then out[#out + 1] = op end
    end
    return out
end

-- The topmost link whose area holds canvas point (cx, cy), or nil. `slop`
-- widens the areas a little for a fingertip.
function Links.at(ops, cx, cy, slop)
    slop = slop or 0
    for i = #ops, 1, -1 do
        local op = ops[i]
        if Links.isLink(op) and cx >= op.x - slop and cx <= op.x + op.w + slop
                and cy >= op.y - slop and cy <= op.y + op.h + slop then
            return op, i
        end
    end
    return nil
end

-- The page a link leads to in notebook `nb`: its index, by id, else by number.
function Links.pageIndex(nb, to)
    if to.id then
        for i, p in ipairs(nb.pages) do if p.id == to.id then return i end end
    end
    if to.page and nb.pages[to.page] then return to.page end
    return nil
end

------------------------------------------------------------------------------
-- The contents page
------------------------------------------------------------------------------

-- The titled pages of notebook `nb` that a contents page lists (contents pages
-- themselves left out): { { id, title }, ... } in page order.
function Links.contentsEntries(nb)
    local out = {}
    for _, p in ipairs(nb.pages) do
        if not p.contents and type(p.title) == "string" and p.title ~= "" then
            out[#out + 1] = { id = p.id, title = p.title }
        end
    end
    return out
end

-- How the lines of a contents page sit on a w x h page whose ruling is `row`
-- px apart: { row, size, margin, first = the first line's top, per = lines a
-- page holds }.
function Links.contentsGeometry(w, h, row)
    row = math.max(24, row or 40)
    local margin = math.floor(w * 0.08)
    local first = row * 3
    local per = math.max(1, math.floor((h - first - row) / row))
    return { row = row, size = math.floor(row * 0.55 + 0.5), margin = margin, first = first, per = per }
end

local function textOp(x, y, w, size, str, style, align)
    local op = Text.new{ x = x, y = y, w = w, size = size, align = align or "left" }
    Text.insert(op, { p = 1, o = 0 }, str, style)
    op.toc = true
    return op
end

-- The ops of one contents page: `heading` (on the first page only), then a
-- line per entry: the title on the left, the page number on the right, and a
-- link over both. `entries` are { id, title, page = its number }.
function Links.contentsOps(entries, geo, w, heading)
    local ops = {}
    local m, row, size = geo.margin, geo.row, geo.size
    local pad = math.floor((row - size * 1.3) / 2)
    if heading then
        ops[#ops + 1] = textOp(m, row + pad - math.floor(size * 0.3), w - 2 * m,
            math.floor(size * 1.4), heading, { b = true })
    end
    for i, e in ipairs(entries) do
        local top = geo.first + (i - 1) * row
        local num_w = math.floor(w * 0.16)
        ops[#ops + 1] = textOp(m, top + pad, w - 2 * m - num_w, size, e.title)
        ops[#ops + 1] = textOp(w - m - num_w, top + pad, num_w, size, tostring(e.page), nil, "right")
        local link = Links.new({ x0 = m, y0 = top, x1 = w - m, y1 = top + row },
            { id = e.id, page = e.page, label = e.title })
        link.toc = true
        ops[#ops + 1] = link
    end
    return ops
end

------------------------------------------------------------------------------
-- In an exported PDF
------------------------------------------------------------------------------

-- The PDF link annotations of a page whose ops are `ops`, on a page box h
-- points tall (1 canvas px = 1 point): { x0, y0, x1, y1 (PDF, y up), page = the
-- exported page it leads to }, for the links whose target index_of(to) finds
-- among the exported pages.
function Links.pdfAnnots(ops, h, index_of)
    local out = {}
    for _, op in ipairs(Links.list(ops)) do
        local k = index_of(op.to)
        if k then
            out[#out + 1] = { x0 = op.x, y0 = h - (op.y + op.h), x1 = op.x + op.w, y1 = h - op.y, page = k }
        end
    end
    return out
end

return Links

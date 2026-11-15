--[[
A notebook's cover for Bookshelf (ink/bookshelf.lua), in one of six styles:

  page         the first page fills the cover, a spiral down the left edge,
               the name on a coloured band at the bottom
  hardcover    a coloured board with an elastic strap and a cream name label
  composition  a marbled board with a coloured spine tape and a name box
  reporter     a spiral along the top, the name on a coloured header and the
               first page below it
  kraft        a card cover with a spiral, a window onto the first page, the
               name stamped under it and a coloured band at the bottom
  legal        yellow ruled sheets under a coloured binding with the name

Each style has one coloured part (the band, board, tape, header or binding):
the notebook's own colour when the reader gave it one, else its tab colour,
else one picked from its path. The styles that show the first page draw it on
its own paper colour and ruling (white ink on a dark paper, as Ink Away shows
it). The name wraps onto two lines, then shrinks, and only as a last resort is
cut short, always inside its own area.

The page is never drawn here from the notebook's strokes, which costs seconds
on a reader for a page with a smudge. It comes from the snapshot of the first
page Ink Away keeps as it shows that page (see Shelf.takeSnapshot): text,
pictures and an imported PDF's page included. Until a notebook has one, its
cover shows its paper and ruling. A cover is written once to a PNG in the
cache, and again only when the snapshot or the look changes.
]]

local Canvas = require("ink/canvas")
local Export = require("ink/export")
local Library = require("ink/library")
local Notebook = require("ink/notebook")
local Palette = require("ink/palette")
local Project = require("ink/project")
local Storage = require("ink/storage")
local _ = require("ink/l10n")

local Cover = {}

-- The cover's size in pixels, a book's proportions. Bookshelf scales it to
-- the shelf, so one size does for every screen.
Cover.W, Cover.H = 480, 672
local W, H = Cover.W, Cover.H

-- The styles, in the order they are offered, and the one a notebook has
-- until the reader picks another.
Cover.STYLES = { "page", "hardcover", "composition", "reporter", "kraft", "legal" }
Cover.DEFAULT = "page"

-- The styles that show the notebook's first page.
Cover.SHOWS_PAGE = { page = true, reporter = true, kraft = true }

-- The styles' names, as the reader sees them.
function Cover.names()
    return { page = _("Front page"), hardcover = _("Hardcover"), composition = _("Composition book"),
        reporter = _("Reporter pad"), kraft = _("Kraft with window"), legal = _("Legal pad") }
end

-- `s` when it is a style, else the default.
function Cover.styleOf(s)
    for _, k in ipairs(Cover.STYLES) do if k == s then return s end end
    return Cover.DEFAULT
end

-- Colours for a notebook's coloured part when it has none of its own, one per
-- notebook by its path, so neighbours on the shelf usually differ. Dark
-- enough that the white name stands out on grey screens too.
Cover.BOARDS = {
    { 0x2E, 0x4A, 0x7A },   -- navy
    { 0x2F, 0x6B, 0x4F },   -- green
    { 0x8A, 0x2F, 0x3A },   -- red
    { 0x3C, 0x3C, 0x44 },   -- charcoal
    { 0x5B, 0x3F, 0x7A },   -- plum
    { 0x1F, 0x6E, 0x78 },   -- teal
}

-- The colour picked for the notebook at `path` when it has none of its own.
function Cover.boardOf(path)
    local n = tonumber(Library.pathCode(path), 16) or 0
    return Cover.BOARDS[n % #Cover.BOARDS + 1]
end

-- Is `rgb` light enough that a name on it should be black, not white?
function Cover.isLight(rgb)
    return 0.299 * rgb[1] + 0.587 * rgb[2] + 0.114 * rgb[3] > 150
end

-- Where each style's parts go, in cover pixels; `name` is the area the name
-- stays inside.
Cover.LAYOUT = {
    page = { page = { x = 0, y = 0, w = W, h = H - 104 }, band = { x = 0, y = H - 104, w = W, h = 104 },
        name = { x = 44, y = H - 98, w = W - 60, h = 92 } },
    hardcover = { spine = { x = 0, y = 0, w = 30, h = H }, strap = { x = W - 80, y = 0, w = 24, h = H },
        label = { x = 70, y = 200, w = W - 80 - 70 - 26, h = 180 },
        name = { x = 88, y = 214, w = W - 80 - 70 - 26 - 36, h = 152 } },
    composition = { spine = { x = 0, y = 0, w = 58, h = H }, label = { x = 100, y = 196, w = W - 136, h = 184 },
        name = { x = 118, y = 206, w = W - 172, h = 108 } },
    reporter = { header = { x = 0, y = 44, w = W, h = 112 }, name = { x = 20, y = 50, w = W - 40, h = 100 },
        page = { x = 0, y = 156, w = W, h = H - 156 } },
    kraft = { window = { x = 70, y = 52, w = W - 110, h = 330 }, name = { x = 70, y = 400, w = W - 110, h = 150 },
        band = { x = 0, y = H - 76, w = W, h = 76 } },
    legal = { binding = { x = 0, y = 0, w = W, h = 128 }, name = { x = 20, y = 12, w = W - 40, h = 104 } },
}

-- Render page `pageno` of the PDF at `pdf_path` to fit `w` x `h`, as the
-- notebook view does. Returns a BlitBuffer or nil.
local function pdfPage(pdf_path, pageno, w, h)
    local img
    pcall(function()
        local doc = require("document/documentregistry"):openDocument(pdf_path)
        if not doc then return end
        pcall(function()
            local Document = require("document/document")
            local Geom = require("ui/geometry")
            local native = Document.getNativePageDimensions(doc, pageno)
            if not (native and native.w and native.h) then return end
            local zoom = math.min(w / native.w, h / native.h)
            local rect = Geom:new{ x = 0, y = 0,
                w = math.floor(native.w * zoom + 0.5), h = math.floor(native.h * zoom + 0.5) }
            local tile = Document.renderPage(doc, pageno, rect, zoom, 0, 1.0, 1.0, false)
            if tile and tile.bb then img = tile.bb:copy() end
        end)
        doc:close()
    end)
    return img
end

-- The export template of the notebook's first page, dressed as an export
-- dresses it: its paper colour, its ruling in the paper's shade and its text
-- black, or white on a dark paper.
local function pageTemplate(nb)
    local Paint = require("ink/paint")
    local t = {}
    for k, v in pairs(nb.template) do t[k] = v end
    t.style = nb:pageTemplate(1).style
    local paper = Palette.paperRGB(nb.template.paper)
    t.paper = paper or { 255, 255, 255 }
    t.gray = Paint.strengthToLevel(t.strength)
    t.rule = Paint.rulingRGB(paper, t.strength)
    t.dark = Paint.darkPaper(paper)
    local ink = t.dark and 255 or 0
    t.ink = { ink, ink, ink }
    return t
end

-- The notebook's first page `w` wide (at most its own width), of which `h`
-- rows show, through the export engine: its paper, ruling and ink (over the
-- PDF page, for an imported PDF), but not its text and pictures. Drawn at that
-- size, not drawn whole and scaled: its strokes are scaled down first (see
-- Transform.scale), so it costs about what the cover's pixels cost. Only for a
-- notebook with no snapshot yet, once (see Shelf's draft pages). Returns an
-- RGB32 BlitBuffer.
function Cover.pageImage(nb, w, h)
    local BB = require("ffi/blitbuffer")
    local Transform = require("ink/transform")
    local page = nb.pages[1]
    local template = pageTemplate(nb)
    local k = math.min(1, w / nb.w)
    local sw, sh = math.max(1, math.floor(nb.w * k + 0.5)), math.max(1, math.floor(nb.h * k + 0.5))
    local canvas = Canvas.new(sw, sh)
    local ops = {}
    for i, op in ipairs(page.ops) do ops[i] = Transform.scale(canvas:cloneOp(op), 0, 0, k) end
    canvas:setOps(ops)
    -- (whole pixels: a ruling at a fractional row lands its colour channels on
    -- different rows, tinting the lines)
    if template.size then template.size = math.max(2, math.floor(template.size * k + 0.5)) end
    local pdf = template.pdf_path and page.src and Storage.exists(template.pdf_path)
    -- see-through over a PDF page, else on the page's paper
    local buf, ow, oh = Export.buildPNGRGBA(canvas, { template = template, white = not pdf })
    local ink = BB.new(ow, oh, BB.TYPE_BBRGB32, buf)
    local out = BB.new(w, math.max(h, sh), BB.TYPE_BBRGB32)
    local paper = template.paper
    out:paintRectRGB32(0, 0, w, out:getHeight(), BB.ColorRGB32(paper[1], paper[2], paper[3], 0xFF))
    if pdf then
        local bg = pdfPage(template.pdf_path, page.src, sw, sh)
        if bg then
            out:blitFrom(bg, math.floor((sw - bg:getWidth()) / 2), math.floor((sh - bg:getHeight()) / 2),
                0, 0, bg:getWidth(), bg:getHeight())
            bg:free()
        end
        out:alphablitFrom(ink, 0, 0, 0, 0, ow, oh)
    else
        out:blitFrom(ink, 0, 0, 0, 0, ow, oh)
    end
    ink = nil   -- luacheck: ignore 311
    buf = nil   -- luacheck: ignore 311
    return out
end

-- Snapshot PNG `file` (a first page, see Shelf.takeSnapshot) `w` wide, on a
-- white page at least `h` high. Returns an RGB32 BlitBuffer or nil.
function Cover.snapshotImage(file, w, h)
    local BB = require("ffi/blitbuffer")
    local RenderImage = require("ui/renderimage")
    local ok, img = pcall(function() return RenderImage:renderImageFile(file, false) end)
    if not (ok and img) then return nil end
    local sw, sh = img:getWidth(), img:getHeight()
    local th = math.max(1, math.floor(w * sh / sw + 0.5))
    local scaled = RenderImage:scaleBlitBuffer(img, w, th)
    local out = BB.new(w, math.max(h, th), BB.TYPE_BBRGB32)
    out:paintRectRGB32(0, 0, w, out:getHeight(), BB.ColorRGB32(0xFF, 0xFF, 0xFF, 0xFF))
    out:blitFrom(scaled, 0, 0, 0, 0, w, th)
    scaled:free()
    if scaled ~= img then pcall(function() img:free() end) end
    return out
end

-- The notebook's first page `w` x `h` as blank paper: its paper colour and its
-- ruling at the cover's scale, no ink. What a cover shows until Ink Away has
-- taken a snapshot of the page. Returns an RGB32 BlitBuffer.
function Cover.paperImage(nb, w, h)
    local BB = require("ffi/blitbuffer")
    local Template = require("ink/template")
    local t = pageTemplate(nb)
    local out = BB.new(w, h, BB.TYPE_BBRGB32)
    out:paintRectRGB32(0, 0, w, h, BB.ColorRGB32(t.paper[1], t.paper[2], t.paper[3], 0xFF))
    local k = w / (nb.w or w)
    local rule = BB.ColorRGB32(t.rule[1], t.rule[2], t.rule[3], 0xFF)
    local size = (t.size or 40) * k
    if not t.pdf_path and size >= 3 then
        pcall(Template.render, t.style, w, h, size, function(x, y, len)
            x, y = math.floor(x), math.floor(y)
            if y >= 0 and y < h then out:paintRectRGB32(x, y, math.max(1, math.floor(len)), 1, rule) end
        end)
    end
    return out
end

------------------------------------------------------------------------------
-- Drawing helpers
------------------------------------------------------------------------------

-- An RGB32 colour from {r,g,b}, made darker by `k` (0..1) when given.
local function rgb32(c, k)
    local BB = require("ffi/blitbuffer")
    k = k or 1
    return BB.ColorRGB32(math.floor(c[1] * k), math.floor(c[2] * k), math.floor(c[3] * k), 0xFF)
end

-- Fill rect `r` with {r,g,b} `c`.
local function fill(bb, r, c, k)
    bb:paintRectRGB32(r.x, r.y, r.w, r.h, rgb32(c, k))
end

-- A wire ring of the spiral, an oval w x h at (x, y). A ring partly off the
-- cover is drawn whole on a scrap holding what is under it, and only its part
-- on the cover goes back, so the wire runs off the edge.
local function paintRing(bb, x, y, w, h)
    local BB = require("ffi/blitbuffer")
    local cx, cy = math.max(0, -x), math.max(0, -y)
    local t = BB.new(w, h, BB.TYPE_BBRGB32)
    t:blitFrom(bb, cx, cy, x + cx, y + cy, w - cx, h - cy)
    local r = math.floor(math.min(w, h) / 2)
    t:paintBorderRGB32(0, 0, w, h, 7, BB.ColorRGB32(0x60, 0x60, 0x68, 0xFF), r)
    t:paintBorderRGB32(1, 1, w - 2, h - 2, 5, BB.ColorRGB32(0xD8, 0xD8, 0xDC, 0xFF), r - 1)
    bb:blitFrom(t, x + cx, y + cy, cx, cy, w - cx, h - cy)
    t:free()
end

-- A punched hole of the spiral at (x, y).
local function paintHole(bb, x, y)
    local BB = require("ffi/blitbuffer")
    bb:paintRoundedRectRGB32(x - 6, y - 6, 12, 12, BB.ColorRGB32(0x3A, 0x3A, 0x3A, 0xFF), 6)
end

-- A spiral down the left edge: a hole near the edge and a wire ring from it
-- round the edge, every few millimetres.
local function spiralLeft(bb)
    for y = 18, H - 12, 30 do
        paintHole(bb, 22, y)
        paintRing(bb, -17, y - 10, 46, 20)
    end
end

-- A spiral along the top edge, the same turned a quarter.
local function spiralTop(bb)
    for x = 22, W - 12, 30 do
        paintHole(bb, x, 22)
        paintRing(bb, x - 10, -17, 20, 46)
    end
end

-- A small random number source, seeded by the notebook's path so its marbling
-- and fibres are the same on every cover drawn for it.
local function randomFor(path)
    local s = (tonumber(Library.pathCode(path), 16) or 1) % 2147483646 + 1
    return function()
        s = (s * 16807) % 2147483647
        return s / 2147483647
    end
end

-- The words of `text` as lines: one, or the two that split it most evenly.
local function splitTwo(words, measure)
    local best, bw
    for k = 1, #words - 1 do
        local a = table.concat(words, " ", 1, k)
        local b = table.concat(words, " ", k + 1)
        local w = math.max(measure(a), measure(b))
        if not bw or w < bw then best, bw = { a, b }, w end
    end
    return best, bw
end

-- Write `name` in `rgb` inside rect `r`: on one line at the largest size from
-- `max_px` down that fits, else on two lines split where they come out most
-- even, else at `min_px` on two lines cut short with an ellipsis. Nothing is
-- drawn outside `r`.
function Cover.paintName(bb, r, name, rgb, max_px, min_px)
    local BB = require("ffi/blitbuffer")
    local Font = require("ui/font")
    local RenderText = require("ui/rendertext")
    local Screen = require("device").screen
    name = (name or ""):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
    if name == "" then return end
    -- Font sizes scale with the screen; the cover is in plain pixels.
    local per = Screen:scaleBySize(1000) / 1000
    -- near black on a light ground, white on a dark one
    local fg = Cover.isLight(rgb) and BB.Color8(0x1A) or BB.COLOR_WHITE
    local words = {}
    for w in name:gmatch("%S+") do words[#words + 1] = w end
    local function draw(face, lines)
        local lh = math.ceil(face.size * 1.25)
        local top = r.y + math.floor((r.h - #lines * lh) / 2)
        for i, line in ipairs(lines) do
            local w = RenderText:sizeUtf8Text(0, r.w * 4, face, line, true, true).x
            local x = r.x + math.floor((r.w - w) / 2)
            local base = top + (i - 1) * lh + math.ceil(face.size * 0.95)
            RenderText:renderUtf8Text(bb, x, base, face, line, true, true, fg)
        end
    end
    local face
    for px = max_px, min_px, -2 do
        face = Font:getFace("cfont", px / per)
        local lh = math.ceil(face.size * 1.25)
        local function measure(t) return RenderText:sizeUtf8Text(0, r.w * 4, face, t, true, true).x end
        if lh <= r.h and measure(name) <= r.w then return draw(face, { name }) end
        if #words > 1 and 2 * lh <= r.h then
            local lines, w = splitTwo(words, measure)
            if w <= r.w then return draw(face, lines) end
        end
    end
    -- still too long at the smallest size: cut short
    local function cut(t) return RenderText:truncateTextByWidth(t, face, r.w, true, true) end
    local lh = math.ceil(face.size * 1.25)
    if #words > 1 and 2 * lh <= r.h then
        local lines = splitTwo(words, function(t) return RenderText:sizeUtf8Text(0, r.w * 4, face, t, true, true).x end)
        return draw(face, { cut(lines[1]), cut(lines[2]) })
    end
    draw(face, { cut(name) })
end

------------------------------------------------------------------------------
-- The styles
------------------------------------------------------------------------------

-- Each draws the whole cover on `bb` from `c`: name, colour (the coloured
-- part), path, and page(w, h) giving the first page `w` wide, cropped to `h`.
local DRAW = {}

-- The first page edge to edge, the name on a band below.
function DRAW.page(bb, c)
    local L = Cover.LAYOUT.page
    local p = c.page(L.page.w, L.page.h)
    bb:blitFrom(p, L.page.x, L.page.y, 0, 0, L.page.w, L.page.h)
    fill(bb, L.band, c.colour)
    spiralLeft(bb)
    Cover.paintName(bb, L.name, c.name, c.colour, 40, 22)
end

-- A coloured board, a darker spine, an elastic strap and a cream label.
function DRAW.hardcover(bb, c)
    local BB = require("ffi/blitbuffer")
    local L = Cover.LAYOUT.hardcover
    fill(bb, { x = 0, y = 0, w = W, h = H }, c.colour)
    fill(bb, L.spine, c.colour, 0.75)
    bb:paintRectRGB32(L.spine.w, 0, 2, H, rgb32(c.colour, 0.6))
    fill(bb, L.strap, { 0x16, 0x16, 0x16 })
    bb:paintRectRGB32(L.strap.x + 4, 0, 2, H, BB.ColorRGB32(0x3A, 0x3A, 0x3A, 0xFF))
    local l = L.label
    bb:paintRoundedRectRGB32(l.x, l.y, l.w, l.h, BB.ColorRGB32(0xF4, 0xEB, 0xD0, 0xFF), 10)
    bb:paintBorderRGB32(l.x, l.y, l.w, l.h, 3, BB.ColorRGB32(0xB9, 0xA7, 0x7A, 0xFF), 10)
    Cover.paintName(bb, L.name, c.name, { 0xF4, 0xEB, 0xD0 }, 48, 24)
end

-- A black and white marbled board, a coloured spine tape and a name box with
-- two ruled lines under the name.
function DRAW.composition(bb, c)
    local BB = require("ffi/blitbuffer")
    local L = Cover.LAYOUT.composition
    fill(bb, { x = 0, y = 0, w = W, h = H }, { 0x14, 0x14, 0x14 })
    local rnd = randomFor(c.path)
    for i = 1, 520 do
        local w = math.floor(3 + rnd() * 28)
        local h = math.floor(2 + rnd() * 9)
        local x = math.floor(L.spine.w + rnd() * (W - L.spine.w - w))
        local y = math.floor(rnd() * (H - h))
        local shade = (i % 5 == 0) and 0x9A or 0xEC
        bb:paintRoundedRectRGB32(x, y, w, h, BB.ColorRGB32(shade, shade, shade, 0xFF), math.floor(math.min(w, h) / 2))
    end
    fill(bb, L.spine, c.colour)
    local l = L.label
    bb:paintRoundedRectRGB32(l.x - 4, l.y - 4, l.w + 8, l.h + 8, BB.ColorRGB32(0x14, 0x14, 0x14, 0xFF), 14)
    bb:paintRoundedRectRGB32(l.x, l.y, l.w, l.h, BB.ColorRGB32(0xFF, 0xFF, 0xFF, 0xFF), 12)
    for _, y in ipairs({ l.y + l.h - 52, l.y + l.h - 26 }) do
        bb:paintRectRGB32(l.x + 18, y, l.w - 36, 2, BB.ColorRGB32(0x99, 0x99, 0x99, 0xFF))
    end
    Cover.paintName(bb, L.name, c.name, { 0xFF, 0xFF, 0xFF }, 44, 22)
end

-- A spiral along the top, the name on a coloured header and the first page
-- below it.
function DRAW.reporter(bb, c)
    local L = Cover.LAYOUT.reporter
    local p = c.page(L.page.w, L.page.h)
    fill(bb, { x = 0, y = 0, w = W, h = L.page.y }, { 0xFF, 0xFF, 0xFF })
    bb:blitFrom(p, L.page.x, L.page.y, 0, 0, L.page.w, L.page.h)
    fill(bb, L.header, c.colour)
    spiralTop(bb)
    Cover.paintName(bb, L.name, c.name, c.colour, 44, 22)
end

-- A kraft card cover with fibres, a spiral, a window onto the first page, the
-- name stamped under it and a coloured band at the bottom.
function DRAW.kraft(bb, c)
    local BB = require("ffi/blitbuffer")
    local L = Cover.LAYOUT.kraft
    local kraft = { 0xC9, 0xA5, 0x7B }
    fill(bb, { x = 0, y = 0, w = W, h = H }, kraft)
    local rnd = randomFor(c.path)
    for _ = 1, 260 do
        local x, y = math.floor(rnd() * (W - 3)), math.floor(rnd() * (H - 2))
        bb:paintRectRGB32(x, y, 2 + math.floor(rnd() * 3), 1, BB.ColorRGB32(0xAE, 0x8A, 0x60, 0xFF))
    end
    local win = L.window
    local p = c.page(win.w, win.h)
    bb:blitFrom(p, win.x, win.y, 0, 0, win.w, win.h)
    bb:paintBorderRGB32(win.x - 5, win.y - 5, win.w + 10, win.h + 10, 5, BB.ColorRGB32(0x8A, 0x6A, 0x45, 0xFF), 6)
    fill(bb, L.band, c.colour)
    spiralLeft(bb)
    Cover.paintName(bb, L.name, c.name, kraft, 44, 22)
end

-- Yellow ruled sheets with a red margin under a coloured binding.
function DRAW.legal(bb, c)
    local BB = require("ffi/blitbuffer")
    local L = Cover.LAYOUT.legal
    fill(bb, { x = 0, y = 0, w = W, h = H }, { 0xFB, 0xEB, 0x94 })
    for y = L.binding.h + 30, H - 6, 28 do
        bb:paintRectRGB32(0, y, W, 2, BB.ColorRGB32(0x9F, 0xB8, 0xD8, 0xFF))
    end
    bb:paintRectRGB32(84, L.binding.h, 2, H - L.binding.h, BB.ColorRGB32(0xD9, 0x53, 0x4F, 0xFF))
    bb:paintRectRGB32(90, L.binding.h, 2, H - L.binding.h, BB.ColorRGB32(0xD9, 0x53, 0x4F, 0xFF))
    fill(bb, L.binding, c.colour)
    bb:paintRectRGB32(0, L.binding.h - 6, W, 6, rgb32(c.colour, 0.7))
    Cover.paintName(bb, L.name, c.name, c.colour, 44, 22)
end

------------------------------------------------------------------------------
-- The cover
------------------------------------------------------------------------------

-- The notebook at `path`, or nil when it is not one or can't be read.
function Cover.load(path)
    local data = Project.load(path)
    if not (data and Project.isNotebook(data)) then return nil end
    local nb = Notebook.fromData(data)
    if #nb.pages == 0 then return nil end
    return nb
end

-- Free the first pages kept in `pages` (see Cover.render).
function Cover.freePages(pages)
    for k, p in pairs(pages or {}) do
        if type(k) == "number" then p:free() end
        pages[k] = nil
    end
end

-- The cover of the notebook at `path` as an RGB32 BlitBuffer, or nil when it
-- can't be read. `look` (all optional): style, colour ({r,g,b}), name (else
-- the file's), snapshot (the first page's snapshot PNG), nb (the notebook,
-- already loaded: only needed for its paper when there is no snapshot) and
-- pages (a table to keep the first page in at each width, so several styles
-- of one notebook draw it once; Cover.freePages frees them).
function Cover.render(path, look)
    look = look or {}
    if not (look.nb or Library.isNotebookFile(path)) then return nil end
    local BB = require("ffi/blitbuffer")
    local pages = look.pages or {}
    local c = {
        path = path,
        name = look.name or Storage.stem(path),
        colour = look.colour or Cover.boardOf(path),
    }
    -- the first page `w` wide, of which the top `h` rows show
    function c.page(w, h)
        if not pages[w] then
            local img = look.snapshot and Storage.exists(look.snapshot) and Cover.snapshotImage(look.snapshot, w, h)
            if not img then
                if pages.nb == nil then pages.nb = look.nb or Cover.load(path) or false end
                local nb = pages.nb
                if nb then
                    img = Cover.paperImage(nb, w, math.max(h, math.floor(w * nb.h / nb.w + 0.5)))
                else
                    img = BB.new(w, h, BB.TYPE_BBRGB32)
                    img:paintRectRGB32(0, 0, w, h, BB.ColorRGB32(0xFF, 0xFF, 0xFF, 0xFF))
                end
            end
            pages[w] = img
        end
        return pages[w]
    end
    local bb = BB.new(W, H, BB.TYPE_BBRGB32)
    local ok, err = pcall(DRAW[Cover.styleOf(look.style)], bb, c)
    if not look.pages then Cover.freePages(pages) end
    if not ok then bb:free(); error(err) end
    return bb
end

-- Draw the first page of the notebook at `path` to PNG `file`, the cover's
-- width wide (see Cover.pageImage). Returns whether it was written.
function Cover.writePage(path, file)
    local ok, img = pcall(function()
        local nb = Cover.load(path)
        if not nb then return nil end
        return Cover.pageImage(nb, W, math.floor(W * nb.h / nb.w + 0.5))
    end)
    if not (ok and img) then return false end
    local tmp = file .. ".tmp"
    local wrote = pcall(function() img:writePNG(tmp) end)
    img:free()
    if not (wrote and Storage.exists(tmp)) then os.remove(tmp); return false end
    return os.rename(tmp, file) == true
end

-- Draw the cover of the notebook at `path` (see Cover.render for `look`) to
-- PNG `file`. Returns whether it was written.
function Cover.write(path, file, look)
    local ok, bb = pcall(Cover.render, path, look)
    if not (ok and bb) then return false end
    local tmp = file .. ".tmp"
    local wrote = pcall(function() bb:writePNG(tmp) end)
    bb:free()
    if not (wrote and Storage.exists(tmp)) then os.remove(tmp); return false end
    return os.rename(tmp, file) == true
end

return Cover

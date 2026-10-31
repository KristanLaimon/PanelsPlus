--[[
What a book gives an export: which of its pages there are, which of them have
ink or highlights, and each page's ink (and the reader's highlights, as ops) in
the units an export draws in. A PDF book's ink is anchored to its page in the
page's own units (see ink/reader/place.lua), so it lands on the same spot of
the page at any size; a reflowing book's ink is placed by the reader for the
page shown, so it is read after going to that page (see InkAwayView:bookPage).

`book` is the Book of ink/reader/book.lua. Nothing here keeps a copy: each
call reads what the book holds now, so a long export builds nothing up.
]]

local Place = require("ink/reader/place")

local BookExport = {}

-- The fixed pages of a PDF book are PDF pages; a reflowing book has the pages
-- the reader makes of it with its font and margins as they are now.
function BookExport.paged(book)
    return book.ui.paging ~= nil
end

-- The book's PDF file, or nil (a reflowing book, a comic, a DjVu).
function BookExport.pdfPath(book)
    local d = book.ui.document
    if book.ui.paging and d and d.is_pdf and d.file then return d.file end
    return nil
end

function BookExport.count(book)
    local ok, n = pcall(book.ui.document.getPageCount, book.ui.document)
    return ok and n or 0
end

-- The page a highlight is on (nil when the reader cannot say).
local function pageOfHighlight(book, h)
    if book.ui.paging then return type(h.page) == "number" and h.page or nil end
    return book:doc():pageOf(h.page)
end

-- The reader's highlights, underlines and strikeouts (not bookmarks): its
-- annotation items.
function BookExport.highlights(book)
    local out = {}
    for _i, a in ipairs(book.ui.annotation and book.ui.annotation.annotations or {}) do
        if a.drawer and a.pos0 then out[#out + 1] = a end
    end
    return out
end

-- Which pages have ink or a highlight: a set page -> true.
function BookExport.inkSet(book)
    local set = {}
    local data = book:data()
    for p, _l in pairs(Place.index(data.items, book:doc())) do set[p] = true end
    for _i, h in ipairs(BookExport.highlights(book)) do
        local p = pageOfHighlight(book, h)
        if p then set[p] = true end
    end
    return set
end

-- Does the book have anything to export: ink, or a highlight?
function BookExport.hasContent(book)
    return book:hasInk() or #BookExport.highlights(book) > 0
end

-- The pages an export covers, as page numbers: `scope` is "page" (the one shown),
-- "all", "ink" (those with ink or a highlight) or "range" ({ from, to }).
-- `stride` is how many pages the reader shows at once (two side by side).
function BookExport.pages(book, scope, range, stride)
    local n = BookExport.count(book)
    local out = {}
    if scope == "page" then
        local p = book:currentPage()
        if p then out[1] = p end
    elseif scope == "ink" then
        local set = BookExport.inkSet(book)
        for p = 1, n do if set[p] then out[#out + 1] = p end end
    elseif scope == "range" and range then
        local a = math.max(1, math.min(n, range.from or 1))
        local b = math.max(a, math.min(n, range.to or n))
        for p = a, b, stride or 1 do out[#out + 1] = p end
    else
        for p = 1, n, stride or 1 do out[#out + 1] = p end
    end
    return out
end

-- A highlight's colour from the reader's own colour names: { r, g, b }, and
-- "#RRGGBB".
local function highlightColour(name)
    local B = require("ffi/blitbuffer")
    local hex = name and B.HIGHLIGHT_COLORS and B.HIGHLIGHT_COLORS[name]
    local r, g, b = tostring(hex or "#FFFF00"):match("^#(%x%x)(%x%x)(%x%x)")
    if not r then return { 255, 255, 0 }, "#FFFF00" end
    return { tonumber(r, 16), tonumber(g, 16), tonumber(b, 16) }, hex
end
BookExport.colour = highlightColour

-- A PDF page's ink and highlights as ops in the page's units times `s` (the
-- size the page is drawn at; 1 for the page's own units). `items` are the book's
-- ink items on the page (see inkByPage), `marks` the page's highlights, and
-- `picture(path)` gives a placed picture's file (the book keeps its pictures
-- beside its ink, see ink/reader/bookink.lua).
function BookExport.pageOps(items, marks, s, picture)
    local ops = {}
    for _i, item in ipairs(items or {}) do
        local a = item.a
        local op = Place.moved(item.op, a.x * s, a.y * s, s)
        if op.kind == "image" and picture then op.path = picture(op.path) end
        ops[#ops + 1] = op
    end
    for _i, h in ipairs(marks or {}) do
        local c = highlightColour(h.color)
        for _j, b in ipairs(h.pboxes or {}) do
            -- a highlight is a highlighter line along the box's middle; an underline
            -- a thin line along its foot; a strikeout one through its middle
            local y = h.drawer == "underscore" and b.y + b.h or b.y + b.h / 2
            local plain = h.drawer == "underscore" or h.drawer == "strikeout"
            ops[#ops + 1] = { kind = "ink", style = plain and "solid" or "highlighter", alpha = 255, color = c,
                width = plain and math.max(1, 1.5 * s) or b.h * s,
                pts = { b.x * s, y * s, (b.x + b.w) * s, y * s } }
        end
    end
    return ops
end

-- The book's ink items by page: page -> list (see Place.index).
function BookExport.inkByPage(book)
    return Place.index(book:data().items, book:doc())
end

-- The reader's highlights by page: page -> list, for a PDF book.
function BookExport.marksByPage(book)
    local by = {}
    for _i, h in ipairs(BookExport.highlights(book)) do
        local p = pageOfHighlight(book, h)
        if p and h.pboxes then
            local l = by[p]
            if not l then l = {}; by[p] = l end
            l[#l + 1] = h
        end
    end
    return by
end

return BookExport

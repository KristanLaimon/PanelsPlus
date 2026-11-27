--[[
Two pages side by side, for a fixed-page book (PDF, CBZ...) in KOReader's page
view: pages are shown in pairs, as a printed book falls open, also for a PDF whose
pages are all single ones.

KOReader's view is taught, on this book's own objects and only while this is on,
to treat the pair as one page: its size for the zoom and the view's area, its
drawing, and which page a place on the screen is on. The document is left alone,
so everything else that asks it about a page (thumbnails, text, exports, another
plugin's viewer) still gets that one page. With this off nothing is installed.

The view's answers are the same ones KOReader's highlights use, and the book's ink
(ink/reader/book.lua) goes by them as well.
]]

local Event = require("ui/event")
local Geom = require("ui/geometry")
local Screen = require("device").screen

local TwoPage = {}
TwoPage.__index = TwoPage

TwoPage.OFF, TwoPage.LANDSCAPE, TwoPage.ALWAYS = "off", "landscape", "always"
TwoPage.MODE = "inkaway_twopage"             -- this book's choice; globally, the one for every PDF
TwoPage.FIRST_ALONE = "inkaway_twopage_first"   -- this book: its first page on its own

TwoPage.GUTTER = 0.03    -- of a page's width, each side of the middle at most

local function isMode(m) return m == TwoPage.LANDSCAPE or m == TwoPage.ALWAYS or m == TwoPage.OFF end

-- Which pages share the screen with page `n` of `count`: { a = first, b = second },
-- b nil for a page shown alone. Pairs count from page 1, or from page 2 with
-- `first_alone` (a cover); `wide(p)` says a page is wider than tall, a spread of its
-- own, which is never paired (the page that would have been its partner is alone too,
-- and the next pair is as it would have been).
function TwoPage.unit(n, count, first_alone, wide)
    if not (n and count and n >= 1 and n <= count) then return nil end
    local skip = first_alone and 1 or 0
    if n <= skip then return { a = n } end
    local first = n - (n - 1 - skip) % 2
    local second = first + 1
    if second > count or (wide and (wide(first) or wide(second))) then return { a = n } end
    return { a = first, b = second }
end

-- Can this book be shown in two pages by Ink Away? (Not when another plugin already
-- does it, which the ink follows just the same.)
function TwoPage.available(ui)
    local doc = ui and ui.document
    return ui and ui.paging and ui.view and ui.zooming and doc and doc.provider == "mupdf"
        and doc.is_reflowable ~= true and doc.info and doc.info.has_pages
        and not doc._mupdftwopage_installed and true or false
end

-- The mode saved for this book; else the one for every PDF, for a PDF.
function TwoPage.savedMode(ui)
    local m = ui.doc_settings and ui.doc_settings:readSetting(TwoPage.MODE)
    if isMode(m) then return m end
    local file = ui.document and ui.document.file
    if type(file) == "string" and file:lower():match("%.pdf$") then
        m = G_reader_settings:readSetting(TwoPage.MODE)
        if isMode(m) then return m end
    end
    return TwoPage.OFF
end

function TwoPage.new(ui)
    local self = setmetatable({ ui = ui, doc = ui.document, view = ui.view, paging = ui.paging, zooming = ui.zooming }, TwoPage)
    self.mode = TwoPage.savedMode(ui)
    self.first_alone = ui.doc_settings and ui.doc_settings:isTrue(TwoPage.FIRST_ALONE) or false
    return self
end

-- Are two pages wanted now? (Not in continuous view or with reflow.)
function TwoPage:active()
    if self.mode == TwoPage.OFF or self.view.page_scroll then return false end
    local c = self.doc.configurable
    if c and (tonumber(c.text_wrap) == 1 or tonumber(c.page_scroll) == 1) then return false end
    if self.mode == TwoPage.ALWAYS then return true end
    return Screen:getWidth() > Screen:getHeight()   -- (its shape: a tablet can be landscape unturned)
end

local function nativeSize(self, page)
    local doc = self.doc
    self._sizes = self._sizes or {}
    local s = self._sizes[page]
    if not s then
        local g = doc.getNativePageDimensions(doc, page)
        s = { w = g and g.w or 1, h = g and g.h or 1 }
        self._sizes[page] = s
    end
    return s
end

-- The pair shown with page `page`: { a, b }, or nil when one page is.
function TwoPage:pair(page)
    if not self:active() then return nil end
    local count = self.doc.info and self.doc.info.number_of_pages
    local unit = TwoPage.unit(page, count, self.first_alone, function(p)
        local s = nativeSize(self, p)
        return s.w > s.h
    end)
    return unit and unit.b and unit or nil
end

-- The part of a page shown: all of it, or with a page crop what the crop leaves.
local function pageBox(self, page)
    local size = nativeSize(self, page)
    local full = { x = 0, y = 0, w = size.w, h = size.h }
    local doc = self.doc
    local c = doc.configurable
    if c and tonumber(c.trim_page) == 3 then return full end   -- (no crop)
    local ok, bbox = pcall(doc.getPageBBox, doc, page)
    if not (ok and bbox and bbox.x1 and bbox.y1) then return full end
    local x0, y0 = math.max(0, tonumber(bbox.x0) or 0), math.max(0, tonumber(bbox.y0) or 0)
    local x1, y1 = math.min(size.w, tonumber(bbox.x1) or size.w), math.min(size.h, tonumber(bbox.y1) or size.h)
    if x1 <= x0 or y1 <= y0 then return full end
    return { x = x0, y = y0, w = x1 - x0, h = y1 - y0 }
end

-- A pair's layout: which page is on which side (the reading order says), each page's
-- box, the seam between them and the size of the whole, at zoom 1.
function TwoPage:layout(pair)
    local lp, rp = pair.a, pair.b
    if self.view.inverse_reading_order then lp, rp = rp, lp end
    local l, r = pageBox(self, lp), pageBox(self, rp)
    -- a crop would butt the text of the two together: some of their own inner margins back
    local ls, rs = nativeSize(self, lp), nativeSize(self, rp)
    local lg = math.min(ls.w * TwoPage.GUTTER, ls.w - (l.x + l.w))
    local rg = math.min(rs.w * TwoPage.GUTTER, r.x)
    l.w, r.x, r.w = l.w + lg, r.x - rg, r.w + rg
    return { left = { page = lp, box = l }, right = { page = rp, box = r },
        seam = l.w, w = l.w + r.w, h = math.max(l.h, r.h) }
end

-- Draw the pair at the view's zoom: the part of each page under `rect` (in the
-- pair's own zoomed coordinates) at (x, y) of `bb`.
function TwoPage:draw(bb, x, y, rect, layout, zoom, rotation, gamma, saturation)
    local doc = self.doc
    bb:paintRect(x, y, rect.w, rect.h, self.view.page_bgcolor)
    local seam = layout.seam * zoom
    local x0, x1 = rect.x, rect.x + rect.w
    local function half(side, origin, from, to)
        if to <= from then return end
        local bottom = math.min(rect.y + rect.h, side.box.h * zoom)
        if bottom <= rect.y then return end
        doc:drawPage(bb, x + (from - x0), y,
            Geom:new{ x = from - origin + side.box.x * zoom, y = rect.y + side.box.y * zoom,
                w = to - from, h = bottom - rect.y },
            side.page, zoom, rotation, gamma, saturation)
    end
    half(layout.left, 0, x0, math.min(x1, seam))
    half(layout.right, seam, math.max(x0, seam), x1)
end

-- Keep what an object has of its own, and put `fn` in the method's place.
local function patch(self, obj, name, fn)
    self._saved[#self._saved + 1] = { obj, name, rawget(obj, name) }
    obj[name] = fn
end

-- Teach the view the pairs. Once; undone by uninstall.
function TwoPage:install()
    if self._saved then return end
    self._saved = {}
    local tp, view, paging, doc = self, self.view, self.paging, self.doc

    -- the zoom fits the pair: only while it is worked out, the document's page is the pair
    local get_zoom = self.zooming.getZoom
    patch(self, self.zooming, "getZoom", function(z, pageno)
        local pair = tp:pair(pageno)
        if not pair then return get_zoom(z, pageno) end
        local layout = tp:layout(pair)
        local native, used = rawget(doc, "getNativePageDimensions"), rawget(doc, "getUsedBBoxDimensions")
        local orig_native = doc.getNativePageDimensions
        local function mine(d, p) return p == pageno and Geom:new{ w = layout.w, h = layout.h } or orig_native(d, p) end
        doc.getNativePageDimensions = mine
        doc.getUsedBBoxDimensions = function(d, _p, zoom, rotation)
            return d:transformRect(Geom:new{ x = 0, y = 0, w = layout.w, h = layout.h }, zoom or 1, rotation or 0)
        end
        local ok, a, b, c = pcall(get_zoom, z, pageno)
        doc.getNativePageDimensions, doc.getUsedBBoxDimensions = native, used
        if not ok then error(a, 0) end
        return a, b, c
    end)

    local get_area = view.getPageArea
    patch(self, view, "getPageArea", function(vw, page, zoom, rotation)
        local pair = tp:pair(page)
        if not pair then return get_area(vw, page, zoom, rotation) end
        local layout = tp:layout(pair)
        return doc:transformRect(Geom:new{ x = 0, y = 0, w = layout.w, h = layout.h }, zoom, rotation)
    end)

    local draw_single = view.drawSinglePage
    patch(self, view, "drawSinglePage", function(vw, bb, x, y)
        local st = vw.state
        local pair = tp:pair(st.page)
        if not pair then return draw_single(vw, bb, x, y) end
        tp:draw(bb, x + st.offset.x, y + st.offset.y, vw.visible_area, tp:layout(pair),
            st.zoom, st.rotation, st.gamma, st.saturation)
    end)

    local position = view.getSinglePagePosition
    patch(self, view, "getSinglePagePosition", function(vw, pos)
        local p = position(vw, pos)
        local pair = p and tp:pair(p.page)
        if not pair then return p end
        local layout = tp:layout(pair)
        local side, x = layout.left, p.x
        if x >= layout.seam then side, x = layout.right, x - layout.seam end
        p.page, p.x, p.y = side.page, x + side.box.x, p.y + side.box.y
        return p
    end)

    local to_screen = view.pageToScreenTransform
    patch(self, view, "pageToScreenTransform", function(vw, page, rect)
        local pair = not vw.page_scroll and tp:pair(vw.state.page)
        if not pair then return to_screen(vw, page, rect) end
        if page ~= pair.a and page ~= pair.b then return nil end
        local layout = tp:layout(pair)
        local zoom = vw.state.zoom
        local side, origin = layout.left, 0
        if page == layout.right.page then side, origin = layout.right, layout.seam * zoom end
        local trans = Geom:new{ x = origin + (rect.x - side.box.x) * zoom, y = (rect.y - side.box.y) * zoom,
            w = rect.w * zoom, h = rect.h * zoom }
        if not vw.visible_area:intersectWith(trans) then return nil end
        return Geom:new{ x = vw.state.offset.x + trans.x - vw.visible_area.x,
            y = vw.state.offset.y + trans.y - vw.visible_area.y, w = trans.w, h = trans.h }
    end)

    local screen_area = view.getScreenPageArea
    patch(self, view, "getScreenPageArea", function(vw, page)
        local pair = not vw.page_scroll and tp:pair(vw.state.page)
        if not pair or (page ~= pair.a and page ~= pair.b) then return screen_area(vw, page) end
        local layout = tp:layout(pair)
        local zoom = vw.state.zoom
        local side, origin = layout.left, 0
        if page == layout.right.page then side, origin = layout.right, layout.seam * zoom end
        return Geom:new{ x = vw.state.offset.x + origin - vw.visible_area.x, y = vw.state.offset.y - vw.visible_area.y,
            w = side.box.w * zoom, h = side.box.h * zoom }
    end)

    local page_list = view.getCurrentPageList
    patch(self, view, "getCurrentPageList", function(vw)
        local pair = not vw.page_scroll and tp:pair(vw.state.page)
        if pair then return { pair.a, pair.b } end
        return page_list(vw)
    end)

    -- turning goes by pairs; landing on a page shows its pair
    local function turning(name)
        local orig = paging[name]
        if type(orig) ~= "function" then return end
        patch(self, paging, name, function(pg, ...)
            tp._turn = true
            local ok, a, b = pcall(orig, pg, ...)
            tp._turn = nil
            if not ok then error(a, 0) end
            return a, b
        end)
    end
    turning("onGotoPageRel")
    turning("pageFlipping")
    turning("onGotoRelativePage")
    local goto_page = paging._gotoPage
    patch(self, paging, "_gotoPage", function(pg, number, orig_mode)
        local turn = tp._turn
        tp._turn = nil
        if number == nil or not tp:active() then return goto_page(pg, number, orig_mode) end
        local count = doc.info and doc.info.number_of_pages or number
        local n = math.max(1, math.min(count, math.floor(number)))
        local here, there = tp:pair(pg.current_page), tp:pair(n)
        local here_end = here and here.b or pg.current_page
        local here_start = here and here.a or pg.current_page
        if turn and n ~= pg.current_page and n >= here_start and n <= here_end then
            -- a turn inside the pair: on to the next pair, or the one before it
            if number >= pg.current_page then
                n = here_end + 1
                if n > count then tp.ui:handleEvent(Event:new("EndOfBook")); return true end
            else
                n = here_start - 1
                if n < 1 then return true end
            end
            there = tp:pair(n)
        end
        return goto_page(pg, there and there.a or n, orig_mode)
    end)
end

-- Back to KOReader's own methods.
function TwoPage:uninstall()
    if not self._saved then return end
    for i = #self._saved, 1, -1 do
        local s = self._saved[i]
        s[1][s[2]] = s[3]
    end
    self._saved = nil
end

-- Follow the mode: installed while it isn't off, the view laid out again when `redo`.
function TwoPage:apply(redo)
    self._sizes = nil
    if self.mode == TwoPage.OFF then
        self:uninstall()
    else
        self:install()
        -- two pages need the page view: from a continuous one, this is what was asked for
        if self.view.page_scroll or tonumber(self.doc.configurable and self.doc.configurable.page_scroll) == 1 then
            if self.doc.configurable then self.doc.configurable.page_scroll = 0 end
            self.ui:handleEvent(Event:new("SetScrollMode", false))
        end
        local page = self.paging.current_page
        local pair = page and self:pair(page)
        if pair and pair.a ~= page then self.paging:_gotoPage(pair.a) end
    end
    if redo then self.ui:handleEvent(Event:new("ReZoom")) end
end

-- The reader chose: kept with this book.
function TwoPage:setMode(mode)
    local was_off = self.mode == TwoPage.OFF
    self.mode = mode
    if self.ui.doc_settings then self.ui.doc_settings:saveSetting(TwoPage.MODE, mode) end
    self:apply(true)
    -- turned on from a zoom that fits the width, the pair would run off the screen and
    -- a turn would pan down it first: both pages whole (the zoom can still be changed)
    local zm = self.zooming.zoom_mode
    if was_off and mode ~= TwoPage.OFF and type(zm) == "string" and zm:match("width$") then
        self.ui:handleEvent(Event:new("SetZoomMode", "page"))
    end
end

function TwoPage:setFirstAlone(on)
    self.first_alone = on and true or false
    if self.ui.doc_settings then self.ui.doc_settings:saveSetting(TwoPage.FIRST_ALONE, self.first_alone) end
    self:apply(true)
end

return TwoPage

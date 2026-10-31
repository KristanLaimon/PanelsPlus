--[[
Notebook mode: pages, navigation, imported PDF pages as page backgrounds, and the
page menus.
Part of InkAwayView (see ink/view.lua).
]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local GeomUI = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local RenderImage = require("ui/renderimage")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local _ = require("ink/l10n")
local Clipboard = require("ink/clipboard")
local ImageProc = require("ink/imageproc")
local Notebook = require("ink/notebook")
local Storage = require("ink/storage")
local Templates = require("ink/templates")

local Screen = Device.screen
local WHITE = Blitbuffer.COLOR_WHITE
local FRAME = Blitbuffer.COLOR_GRAY
local fitIntoCanvasBB = ImageProc.fitIntoCanvasBB

local function vspan(px) return VerticalSpan:new{ width = Screen:scaleBySize(px) } end

local InkAwayView = {}

-- Where a digit's ink sits inside a TextWidget's box. The box includes empty
-- ascent and descent, so centring it makes digits look high next to an icon.
-- Renders the digits once per size and scans for the first and last inked rows,
-- caching {mid, h} (ink centre from the box top, ink height) so the page counter
-- can centre and size itself to the icons. Falls back to box metrics when the
-- scan is unavailable (in tests).
function InkAwayView:digitInkMetric(face, isz, box_h)
    if self._digit_ink and self._digit_ink.key == isz then return self._digit_ink end
    local res
    pcall(function()
        local probe = TextWidget:new{ text = "0123456789", face = face,
            fgcolor = Blitbuffer.COLOR_BLACK }
        local pw, ph = probe:getSize().w, probe:getSize().h
        if not (pw and ph and pw > 0 and ph > 0) then probe:free(); return end
        local sb = Blitbuffer.new(pw, ph, Blitbuffer.TYPE_BB8)
        sb:fill(Blitbuffer.COLOR_WHITE)
        probe:paintTo(sb, 0, 0); probe:free()
        local top, bot
        for row = 0, ph - 1 do
            local inked = false
            for col = 0, pw - 1 do
                local c = sb:getPixel(col, row)
                local v = (c and c.getColor8 and c:getColor8().a) or 255
                if v < 128 then inked = true; break end
            end
            if inked then top = top or row; bot = row end
        end
        sb:free()
        if top and bot then res = { key = isz, mid = (top + bot + 1) / 2, h = (bot - top + 1) } end
    end)
    res = res or { key = isz, mid = box_h / 2, h = math.floor(isz * 0.66) }
    self._digit_ink = res
    return res
end

-- Render one PDF page to a canvas-sized BlitBuffer, on demand, the way KOReader
-- renders cover thumbnails (cached in its DocCache). Returns a BlitBuffer or nil.
function InkAwayView:renderPdfPage(doc, pageno, tw, th)
    if not doc then return nil end
    local Document = require("document/document")
    local W, H = tw or self.view.canvas_w, th or self.view.canvas_h
    local img
    pcall(function()
        local native = Document.getNativePageDimensions(doc, pageno)
        if not (native and native.w and native.h) then return end
        local zoom = math.min(W / native.w, H / native.h)
        -- an explicit full-page rect: without one, a page too large for
        -- KOReader's tile cache (an A4 page at fit zoom) is refused and comes back
        -- blank, while a rect renders it uncached
        local rect = GeomUI:new{ x = 0, y = 0,
            w = math.floor(native.w * zoom + 0.5), h = math.floor(native.h * zoom + 0.5) }
        local tile = Document.renderPage(doc, pageno, rect, zoom, 0, 1.0, 1.0, false)
        if tile and tile.bb then img = fitIntoCanvasBB(tile.bb:copy(), W, H) end
    end)
    return img
end

-- A bottom-bar icon from ink/icons on an opaque white tile, cached by name and
-- size. Returns nil if unavailable.
function InkAwayView:navImage(name, sz)
    self._nav_img = self._nav_img or {}
    local key = name .. "@" .. sz
    local c = self._nav_img[key]
    if c == nil then
        local ok, raw, straight = pcall(function()
            return RenderImage:renderSVGImageFile(self:pluginDir() .. "ink/icons/" .. name .. ".svg", sz, sz)
        end)
        if ok and raw then
            local w, h = raw:getWidth(), raw:getHeight()
            local tile = Blitbuffer.new(w, h, Blitbuffer.TYPE_BBRGB32)
            tile:fill(Blitbuffer.COLOR_WHITE)
            if straight then tile:alphablitFrom(raw, 0, 0, 0, 0, w, h)
            else tile:pmulalphablitFrom(raw, 0, 0, 0, 0, w, h) end
            raw:free()
            c = tile
        else
            c = false
        end
        self._nav_img[key] = c
    end
    return c or nil
end

------------------------------------------------------------------------------
-- Notebook mode: a multi-page canvas. Each page is an op list like a drawing, so
-- every tool works unchanged. The current page lives in self.canvas; turning a
-- page syncs it back to the Notebook model and loads the next, so only one page
-- is composed at a time.
------------------------------------------------------------------------------

-- Height of the notebook bottom bar.
function InkAwayView:nbBarHeight()
    if self._nb_collapsed then return 0 end   -- hidden via the bottom-bar toggle
    -- as tall as the toolbar, so both bars hold the same icons the same way
    if self._vb_side then return self:vbarRoomBelow() end
    if self.toolbar then return self.toolbar:getSize().h end
    local isz = self._icon_sz or math.max(20, Screen:scaleBySize(26))
    return isz + 2 * Screen:scaleBySize(4)
end

-- Save the on-screen canvas back into the current notebook page. A page whose
-- ops changed since it was loaded or last synced is stamped and dropped from the
-- save cache, so the next save writes it out again.
function InkAwayView:nbSyncOut()
    local nb = self.notebook
    if not nb then return end
    nb:setCurrentOps(self.canvas.ops)
    if self.canvas.rev ~= self._page_rev then
        self._page_rev = self.canvas.rev
        if nb.index == 1 then self._p1_changed = true end   -- its shelf cover follows
        nb:touch()
        if self._page_cache then self._page_cache[nb.pages[nb.index]] = nil end
        self:dropPageThumb(nb.pages[nb.index])
        self.dirty = true
    end
end

-- Load the current notebook page into the canvas and repaint.
function InkAwayView:nbLoad()
    if not self.notebook then return end
    -- leaving the first page: its Bookshelf cover keeps a snapshot of it, from
    -- the canvas, which still shows it (see shelfSnapshot)
    self:shelfSnapshot(self._shown_page ~= nil and self._shown_page == self.notebook.pages[1])
    -- drop the previous page's image decodes so memory stays flat over many
    -- pages; composeCanvas decodes what this page uses (the bar icon cache stays)
    self:freeImageCache()
    self:loadNotebookPageBackground()   -- swap in this page's PDF image (if any)
    self.canvas:setOps(self.notebook:currentOps())
    self._page_rev = self.canvas.rev
    self:resetLasso()
    self:composeCanvas(); self:renderView()
    self._shown_page = self.notebook.pages[self.notebook.index]   -- the page the canvas shows
    -- Like KOReader's reader, turn pages with a non-flashing refresh ("partial" on
    -- grey, "ui" on colour, where a flash takes a second or two) and flash only
    -- every few turns to clear ghosting.
    self._turns_since_full = (self._turns_since_full or 0) + 1
    local every = (self.ghost_clean and self.ghost_clean > 0) and self.ghost_clean or 6
    if self._turns_since_full >= every then
        self._turns_since_full = 0
        UIManager:setDirty(self, "full")
    elseif self:colourPanel() then
        self:refreshPageTurn("ui")
    else
        self:refreshPageTurn("partial")
    end
end

-- Keep one open handle to the source PDF for the session, so a page turn does not
-- pay the cost of opening it again.
function InkAwayView:ensureNotebookPDF()
    local t = self.notebook and self.notebook.template
    if not (t and t.pdf_path) then return end
    if self._nb_pdf_doc and self._nb_pdf_path == t.pdf_path then return end
    self:closeNotebookPDF()
    local ok, doc = pcall(function() return require("document/documentregistry"):openDocument(t.pdf_path) end)
    self._nb_pdf_doc = ok and doc or nil
    self._nb_pdf_path = t.pdf_path
end

function InkAwayView:closeNotebookPDF()
    self:freePdfCache()
    self._bg_src = nil
    if self._nb_pdf_doc then pcall(function() self._nb_pdf_doc:close() end) end
    self._nb_pdf_doc, self._nb_pdf_path = nil, nil
end

-- For a PDF-backed notebook, put the current page's rendered PDF image behind
-- the ink. Only the visible page and its neighbours are kept, so a long PDF opens
-- and turns as fast as a short one.
function InkAwayView:loadNotebookPageBackground()
    local nb = self.notebook
    local t = nb and nb.template
    if not (t and t.pdf_path) then return end
    self:ensureNotebookPDF()
    local src = nb:currentSrc()      -- which source page this notebook page shows
    -- Rendering is the slow part of a page turn, so the page just left is kept
    -- (turning back is instant) and the next is rendered ahead during a pause (see
    -- prefetchPdfPage). A buffer is either the background or in the cache, never
    -- both.
    local cache = self._pdf_cache or {}
    self._pdf_cache = cache
    if self.bg_bb and self._bg_src and self._bg_src ~= src and not cache[self._bg_src] then
        cache[self._bg_src] = self.bg_bb             -- keep the page we are leaving
    elseif self.bg_bb then
        self.bg_bb:free()
    end
    self.bg_bb = nil
    local img = src and cache[src]
    if img then cache[src] = nil
    elseif src then img = self:renderPdfPage(self._nb_pdf_doc, src) end
    self.bg_bb = img            -- canvas-sized already; nil if the render failed
    self._bg_src = img and src or nil
    self.bg_rgba = nil          -- built on demand at export, never per page turn
    self.bg_path = t.pdf_path
    self:trimPdfCache()
    UIManager:unschedule(self._pdf_prefetch_cb)
    UIManager:scheduleIn(1.0, self._pdf_prefetch_cb)
end

-- The source pages of the notebook pages either side of the current one.
function InkAwayView:pdfNeighbourSrcs()
    local nb = self.notebook
    local out = {}
    if not nb then return out end
    for _, d in ipairs({ 1, -1 }) do
        local pg = nb.pages[nb.index + d]
        if pg and pg.src then out[#out + 1] = pg.src end
    end
    return out
end

-- Keep only the neighbours of the current page (at most two pages) in the cache.
function InkAwayView:trimPdfCache()
    local cache = self._pdf_cache
    if not cache then return end
    local keep = {}
    for _, s in ipairs(self:pdfNeighbourSrcs()) do keep[s] = true end
    for s, bb in pairs(cache) do
        if not keep[s] then bb:free(); cache[s] = nil end
    end
end

-- Render the next page (then the previous) ahead of time, after a short pause
-- following a page turn. Any touch or pen-down cancels a pending prefetch, so it
-- never gets in the way of writing.
function InkAwayView:prefetchPdfPage()
    local nb = self.notebook
    if self.closing or not (nb and nb.template and nb.template.pdf_path and self._nb_pdf_doc) then return end
    if self.capturing or self.editing_text or (self._pen_state and self._pen_state.down)
            or self._export_job then
        return
    end
    local cache = self._pdf_cache or {}
    self._pdf_cache = cache
    for _, s in ipairs(self:pdfNeighbourSrcs()) do
        if not cache[s] and s ~= self._bg_src then
            local img = self:renderPdfPage(self._nb_pdf_doc, s)
            if img then cache[s] = img end
            -- one page per idle slot: if there is another to do, come back later
            UIManager:scheduleIn(0.5, self._pdf_prefetch_cb)
            return
        end
    end
end

function InkAwayView:freePdfCache()
    UIManager:unschedule(self._pdf_prefetch_cb)
    if self._pdf_cache then
        for _, bb in pairs(self._pdf_cache) do bb:free() end
        self._pdf_cache = nil
    end
end

-- Step to the previous (-1) or next (+1) page.
function InkAwayView:nbGo(delta)
    if self.notebook then self:nbGoTo(self.notebook.index + delta) end
end

-- Jump to an absolute page number (1-based).
function InkAwayView:nbGoTo(target)
    if not self.notebook or type(target) ~= "number" then return end
    self:resetLasso()   -- a selection belongs to this page
    target = math.floor(target)
    local nb = self.notebook
    if target < 1 or target > nb:count() or target == nb.index then return end
    self:nbSyncOut()
    nb:gotoPage(target)
    self:nbLoad()
end

-- Go to a page: a sheet with First and Last jumps and a button that opens the
-- number keypad.
function InkAwayView:nbJumpPrompt()
    local nb = self.notebook
    if not nb then return end
    self:closeSheet("_goto_dialog")
    local content_w, gap = self:sheetWidth()
    local halfW = math.floor((content_w - gap) / 2)
    local closeSelf = function() self:closeSheet("_goto_dialog") end
    local build = function()
        local content = VerticalGroup:new{ align = "left" }
        local function add(w) table.insert(content, w) end
        add(self:sheetTitle(_("Go to page"), content_w, _("Close"), closeSelf))
        add(vspan(6))
        add(self:sheetLabel(string.format(_("Page %d of %d"), nb.index, nb:count())))
        add(vspan(12))
        add(HorizontalGroup:new{ align = "center",
            self:actionButton(_("First page"), halfW, function() closeSelf(); self:nbGoTo(1) end),
            HorizontalSpan:new{ width = gap },
            self:actionButton(_("Last page"), halfW, function() closeSelf(); self:nbGoTo(nb:count()) end),
        })
        add(vspan(8))
        add(self:actionButton(_("Type a page number\u{2026}"), content_w,
            function() closeSelf(); self:promptGotoNumber() end, true))
        return content
    end
    local v = self.view
    self:showSheet("_goto_dialog", build, { bottom_y = v.area_y + v.area_h })
end

-- The page-number entry, reached from the Go-to-page sheet: a stock InputDialog
-- with the number keypad, which types reliably on every device.
function InkAwayView:promptGotoNumber()
    local nb = self.notebook
    if not nb then return end
    self:promptText{
        title = string.format(_("Go to page (1\u{2013}%d)"), nb:count()),
        input = tostring(nb.index), input_type = "number", ok_text = _("Go"),
        on_ok = function(text)
            local n = tonumber(text)
            if n then self:nbGoTo(n) end
        end,
    }
end

-- Duplicate the current page.
function InkAwayView:nbDuplicatePage()
    if not self.notebook then return end
    self:nbSyncOut()
    self.notebook:duplicatePage()
    self:nbLoad()
    self:markDirty()
end

-- Note a change to a page's own fields (title, star, paper): drop it from the
-- save cache and mark the document changed.
function InkAwayView:nbPageChanged(page)
    if self._page_cache then self._page_cache[page] = nil end
    self:markDirty()
end

-- The page menu, opened by tapping the page counter in the bottom bar: go to a
-- page, rename, star, insert, duplicate, move, its paper, templates, paste and
-- delete.
function InkAwayView:openPageMenu()
    local nb = self.notebook
    if not nb then return end
    local page = nb.pages[nb.index]
    self:closeSheet("_page_dialog")
    local content_w, gap = self:sheetWidth()
    local halfW = math.floor((content_w - gap) / 2)
    local closeSelf = function() self:closeSheet("_page_dialog") end
    local function act(label, w, cb, icon)
        return self:actionButton(label, w, function() closeSelf(); cb() end, nil, nil, icon)
    end
    local function row2(a, b)
        return HorizontalGroup:new{ align = "center", a, HorizontalSpan:new{ width = gap }, b }
    end
    local build = function()
        local content = VerticalGroup:new{ align = "left" }
        local function add(w) table.insert(content, w) end
        add(self:sheetTitle(page.title or string.format(_("Page %d"), nb.index), content_w, _("Close"), closeSelf))
        add(vspan(6))
        add(self:sheetLabel(string.format(_("Page %d of %d"), nb.index, nb:count())
            .. (page.star and "  \u{2605}" or "")))
        add(vspan(12))
        add(act(_("Go to page\u{2026}"), content_w, function() self:nbJumpPrompt() end, "hash"))
        add(vspan(8))
        add(row2(act(_("Rename\u{2026}"), halfW, function() self:nbRenamePage() end, "rename"),
                 act(page.star and _("Unstar") or _("Star"), halfW, function() self:nbToggleStar() end, "star")))
        add(vspan(8))
        add(row2(act(_("Insert before"), halfW, function() self:nbInsertPageBefore() end, "newpage"),
                 act(_("Duplicate"), halfW, function() self:nbDuplicatePage() end, "duplicate")))
        add(vspan(8))
        add(row2(act(_("Move\u{2026}"), halfW, function() self:nbMovePrompt() end, "move"),
                 act(_("Paper\u{2026}"), halfW, function() self:nbPagePaper() end, "page")))
        add(vspan(8))
        add(row2(act(_("Save as template\u{2026}"), halfW, function() self:nbSaveTemplate() end, "template"),
                 act(_("From template\u{2026}"), halfW, function() self:nbFromTemplate() end, "template")))
        add(vspan(8))
        if self:nbHasContents() and not page.contents then
            add(act(_("Go to the contents page"), content_w, function() self:goToContents() end, "contents"))
            add(vspan(8))
        end
        add(act(self:nbHasContents() and _("Update the contents page") or _("Make a contents page"), content_w,
            function() self:nbMakeContents() end, "contents"))
        add(vspan(8))
        if Clipboard.count() > 0 then
            add(row2(act(_("Paste"), halfW, function() self:pasteAt(nil) end, "clipboard"),
                     act(_("Delete page"), halfW, function() self:nbDeletePage() end, "trash")))
        else
            add(act(_("Delete page"), content_w, function() self:nbDeletePage() end, "trash"))
        end
        return content
    end
    -- the sheet's bottom sits on the top of the notebook bottom bar
    local v = self.view
    self:showSheet("_page_dialog", build, { bottom_y = v.area_y + v.area_h })
end

-- Give the current page a title (an empty one removes it).
function InkAwayView:nbRenamePage()
    local nb = self.notebook
    local page = nb and nb.pages[nb.index]
    if not page then return end
    self:promptText{ title = _("Page title"), input = page.title or "", hint = _("Untitled"),
        ok_text = _("Rename"),
        on_ok = function(text)
            local title = (text or ""):match("^%s*(.-)%s*$")
            page.title = (title ~= "") and title or nil
            self:nbPageChanged(page)
        end }
end

function InkAwayView:nbToggleStar()
    local nb = self.notebook
    local page = nb and nb.pages[nb.index]
    if not page then return end
    page.star = (not page.star) or nil
    self:nbPageChanged(page)
    self:showNotice(page.star and _("Page starred") or _("Star removed"))
end

-- Insert a blank page before the current one and move to it.
function InkAwayView:nbInsertPageBefore()
    if not self.notebook then return end
    self:nbSyncOut()
    self.notebook:insertPageBefore()
    self:nbLoad()
    self:markDirty()
end

-- Ask for the position to move the current page to.
function InkAwayView:nbMovePrompt()
    local nb = self.notebook
    if not nb or nb:count() < 2 then return end
    self:promptText{
        title = string.format(_("Move this page to (1\u{2013}%d)"), nb:count()),
        input = tostring(nb.index), input_type = "number", ok_text = _("Move"),
        on_ok = function(text)
            local n = tonumber(text)
            if not n then return end
            self:nbSyncOut()
            nb:movePageTo(n)
            self:markDirty()
            self:refreshArea()   -- the counter shows the new position
            self:showNotice(string.format(_("Now page %d"), nb.index))
        end }
end

-- Choose the paper of the current page: the notebook's, or one of its own.
function InkAwayView:nbPagePaper()
    local nb = self.notebook
    local page = nb and nb.pages[nb.index]
    if not page then return end
    self:openPaperSheet{ title = _("Paper for this page"), current = page.paper or "same",
        same = _("Same as the notebook"),
        onpick = function(v)
            page.paper = (v ~= "same") and v or nil
            self:nbPageChanged(page)
            self:composeCanvas(); self:renderView(); self:refreshArea()
        end }
end

-- Save the current page as a template, under a name asked for (its title by
-- default), asking before replacing one of the same name.
function InkAwayView:nbSaveTemplate()
    local nb = self.notebook
    if not nb then return end
    self:nbSyncOut()
    local page = nb.pages[nb.index]
    local root = self:libraryDir()
    self:promptText{ title = _("Template name"), input = page.title or "", hint = _("Planner"),
        ok_text = _("Save"),
        on_ok = function(text)
            local name = (text or ""):gsub("[/\\]", "_"):match("^%s*(.-)%s*$")
            if name == "" then return end
            self:confirmReplace(Templates.path(root, name), function()
                local ok, err = Templates.save(root, name, page, nb:pageTemplate(), nb.w, nb.h)
                if ok then
                    self:showNotice(string.format(_("Saved the template \u{201C}%s\u{201D}"), name))
                else
                    self:tell(_("Could not save the template.\n") .. tostring(err))
                end
            end)
        end }
end

-- Choose a template and add a page made from it after the current one. The
-- last row switches to deleting templates instead.
function InkAwayView:nbFromTemplate(deleting)
    local nb = self.notebook
    if not nb then return end
    local root = self:libraryDir()
    local names = Templates.list(root)
    if #names == 0 then
        self:showNotice(_("No templates yet. Save a page as one from this menu: Save as template."), 4)
        return
    end
    local items = {}
    for i = 1, #names do
        local name = names[i]
        items[#items + 1] = { label = name, icon = deleting and "trash" or "template", cb = function()
            if not deleting then return self:nbAddFromTemplate(name) end
            self:ask{ title = string.format(_("Delete the template \u{201C}%s\u{201D}?"), name),
                ok_text = _("Delete"), ok_icon = "trash", on_ok = function() Templates.remove(root, name) end }
        end }
    end
    self:chooseFromList{ title = deleting and _("Delete which template?") or _("New page from template"),
        items = items, close_text = _("Cancel"),
        footer = { { label = deleting and _("Back") or _("Delete a template\u{2026}"),
            icon = not deleting and "trash" or nil, cb = function() self:nbFromTemplate(not deleting) end } } }
end

-- Add a page made from template `name` after the current one, and go to it.
function InkAwayView:nbAddFromTemplate(name)
    local nb = self.notebook
    local page, style = Templates.load(self:libraryDir(), name)
    if not (nb and page) then
        self:tell(_("Could not open that template."))
        return
    end
    self:nbSyncOut()
    nb.index = nb:putPage(page, false, style, nb.index + 1)
    self:nbLoad()
    self:markDirty()
end

-- Render one notebook page to a thumbnail fitting maxw x maxh, through the shared
-- compositor so it matches the page. A full-size scratch is composed, scaled down
-- and freed, so memory stays flat.
function InkAwayView:renderPageThumb(index, maxw, maxh)
    local nb = self.notebook
    if not nb or not nb.pages[index] then return nil end
    local W, H = self.view.canvas_w, self.view.canvas_h
    local bbtype = self.canvas_bb and self.canvas_bb:getType() or Screen.bb:getType()
    local scratch = Blitbuffer.new(W, H, bbtype)
    local page = nb.pages[index]
    local bg
    if nb.template.pdf_path and page.src then
        self:ensureNotebookPDF()
        bg = self:renderPdfPage(self._nb_pdf_doc, page.src)
    end
    self:trueColours(function() self:composeInto(scratch, page.ops, bg, nb:pageTemplate(index)) end)
    if bg then bg:free() end
    local scale = math.min(maxw / W, maxh / H)
    local tw = math.max(1, math.floor(W * scale))
    local th = math.max(1, math.floor(H * scale))
    local thumb = RenderImage:scaleBlitBuffer(scratch, tw, th, false)
    scratch:free()
    return thumb
end

-- Insert a blank page after the current one and move to it.
function InkAwayView:nbAddPage()
    if not self.notebook then return end
    self:nbSyncOut()
    self.notebook:addPage()
    self:nbLoad()
    self:markDirty()
end

-- Remove the current page (with a confirm; never drops below one page).
function InkAwayView:nbDeletePage()
    if not self.notebook then return end
    if self.notebook:count() <= 1 then
        self:showNotice(_("A notebook keeps at least one page."), 2)
        return
    end
    self:askDelete(nil, false, function()
        local nb = self.notebook
        if not nb then return end
        self:nbSyncOut()
        if not self:trashPage(self.doc_path, nb, nb.index) then return end
        nb:deletePage()
        self:nbLoad()
        self:markDirty()
    end)
end

-- Make `nb` the open notebook and show its current page.
function InkAwayView:enterNotebook(nb)
    self.notebook = nb
    self.nb_bar_h = self:nbBarHeight()
    self:recomputeArea()
    self:nbLoad()
    self:resetTransientMemory()     -- reclaim the previous work's memory now
end

-- Enter notebook mode with a fresh notebook using `template`
-- ({ style = "lines"|"grid"|"dots"|"blank", size = px }).
function InkAwayView:startNotebook(template)
    self:clearBackground()
    self.save_area = nil
    self:enterNotebook(Notebook.new(self.screen_w, self.screen_h, template))
end

-- Rebuild notebook mode from a loaded v2 project.
function InkAwayView:openNotebookData(data)
    self:closeNotebookPDF()
    self:clearBackground()
    self.save_area = nil
    local nb = Notebook.fromData(data)
    -- pages were drawn at their own screen size; treat them at this screen size
    nb.w, nb.h = self.screen_w, self.screen_h
    self:enterNotebook(nb)
    -- warn if the source PDF of a PDF-backed notebook is gone (the ink is safe;
    -- only the page images are missing until it is back)
    if self.notebook.template.pdf_path and not self._nb_pdf_doc then
        self:tell(string.format(
            _("The source PDF could not be opened:\n%s\n\nYour notes are intact, but the page images will be blank until the PDF is back in that location."),
            self.notebook.template.pdf_path))
    end
end

-- Leave notebook mode and return to the single-canvas layout.
function InkAwayView:exitNotebook()
    if not self.notebook then return end
    self:closeNotebookPDF()
    self.notebook = nil
    self.nb_bar_h = 0
    self:recomputeArea()
end

-- Open an entire PDF as a new notebook in folder `dir`: one page per PDF page,
-- each with the PDF page as its background to write on. Pages are rendered
-- lazily on demand. It is saved at once, named after the PDF, so it is in the
-- library straight away.
function InkAwayView:startPdfNotebook(path, dir)
    local ok, doc = pcall(function() return require("document/documentregistry"):openDocument(path) end)
    if not ok or not doc then
        self:tell(_("Could not open that PDF."))
        return
    end
    local pages = 1
    pcall(function() pages = doc:getPageCount() or 1 end)
    if not pages or pages < 1 then pages = 1 end
    self:beginDocument("notebook", Storage.stem(path), function()
        self:closeNotebookPDF()
        self._nb_pdf_doc, self._nb_pdf_path = doc, path
        self:clearBackground()
        self:enterNotebook(Notebook.forPdf(self.screen_w, self.screen_h, {
            style = "blank", size = self.grid_size or 40, strength = self.grid_strength or 45, pdf_path = path,
        }, pages))
    end, dir)
    self:saveDocument(true)
end

-- Pick a PDF (from KOReader's home folder) and open it as a new notebook in
-- folder `dir`.
function InkAwayView:openPdfAsNotebook(dir)
    self:pickFile(self:homeDir(), function(path) self:startPdfNotebook(path, dir) end,
        function(name) return name:lower():match("%.pdf$") ~= nil end, "pdfpen", _("No PDFs or folders here."),
        _("From a PDF\u{2026}"))
end

-- A sheet of paper tiles, each a small page drawn with its ruling, six to a
-- page in rows of three, with arrows to the other pages. `o` holds title,
-- current (the style shown selected, whose page opens first), onpick(style),
-- field (the sheet's slot), same (a label for a "same as the notebook" choice
-- above the papers, picked as "same") and footer(add, content_w, gap, close),
-- which adds more choices under them.
local PAPERS_PER_PAGE = 6
function InkAwayView:openPaperSheet(o)
    local field = o.field or "_chooser_dialog"
    self:closeSheet(field)
    local content_w, gap = self:sheetWidth()
    local styles = self:notebookStyles()
    local pages = math.ceil(#styles / PAPERS_PER_PAGE)
    local page = 0
    for i, s in ipairs(styles) do
        if s[1] == o.current then page = math.floor((i - 1) / PAPERS_PER_PAGE) end
    end
    local rows = PAPERS_PER_PAGE / 3
    local tileW = math.floor((content_w - 2 * gap) / 3)
    -- page-shaped tiles, made shorter when the screen (or landscape) has no room
    -- for them with the title, the optional rows and the sheet's frame
    local S = function(px) return Screen:scaleBySize(px) end
    local fixed = S(34) + S(16) + (o.same and S(48) + gap or 0) + (o.footer and S(16) + S(48) or 0)
        + (pages > 1 and gap + S(48) or 0) + (rows - 1) * gap + 2 * S(18) + S(40)
    local tileH = math.max(S(90), math.min(math.floor(tileW * 1.25),
        math.floor((Screen:getHeight() - fixed) / rows)))
    local closeSelf = function() self:closeSheet(field) end
    local build = function()
        local content = VerticalGroup:new{ align = "left" }
        local function add(w) table.insert(content, w) end
        add(self:sheetTitle(o.title, content_w, _("Cancel"), closeSelf))
        add(vspan(16))
        if o.same then
            add(self:actionButton(o.same, content_w, function() closeSelf(); o.onpick("same") end,
                o.current == "same"))
            add(VerticalSpan:new{ width = gap })
        end
        local first = page * PAPERS_PER_PAGE
        for r = 0, rows - 1 do
            local row = HorizontalGroup:new{ align = "center" }
            for c = 1, 3 do
                local s = styles[first + r * 3 + c]
                if s then
                    if c > 1 then table.insert(row, HorizontalSpan:new{ width = gap }) end
                    table.insert(row, self:paperTile(s[1], s[2], tileW, tileH, s[1] == o.current,
                        function() closeSelf(); o.onpick(s[1]) end))
                end
            end
            if r > 0 then add(VerticalSpan:new{ width = gap }) end
            add(row)
        end
        -- the other pages of papers: arrows either side of "1 / 2", turned in place
        if pages > 1 then
            add(VerticalSpan:new{ width = gap })
            add(self:pagerRow(page, pages, content_w, gap, function(d)
                page = (page + d) % pages
                self:rebuildSheet(field)
            end))
        end
        if o.footer then o.footer(add, content_w, gap, closeSelf) end
        return content
    end
    self:showSheet(field, build)
end

-- New notebook: pick its paper (the last one used is marked), or start it from
-- a PDF or a saved page template, in folder `dir` (the open document's by
-- default). The library or overview under it closes once a choice is made.
function InkAwayView:openNotebookPaper(dir)
    local function closeUnder()
        if self._library then self._library:close() end
        if self._overview then self._overview:close() end
    end
    local templates = #Templates.list(self:libraryDir()) > 0
    self:openPaperSheet{ title = _("New notebook"), field = "_new_dialog", current = self.nb_style,
        onpick = function(style) closeUnder(); self:newNotebook(style, dir) end,
        footer = function(add, content_w, gap, closeSelf)
            add(vspan(16))
            local pdf = self:actionButton(_("From a PDF\u{2026}"), templates and math.floor((content_w - gap) / 2)
                or content_w, function() closeSelf(); closeUnder(); self:openPdfAsNotebook(dir) end)
            if templates then
                add(HorizontalGroup:new{ align = "center", pdf, HorizontalSpan:new{ width = gap },
                    self:actionButton(_("From a template\u{2026}"), math.floor((content_w - gap) / 2),
                        function() closeSelf(); self:chooseNotebookTemplate(dir, closeUnder) end) })
            else
                add(pdf)
            end
        end }
end

-- Pick a saved page template and start a notebook with it as the first page.
function InkAwayView:chooseNotebookTemplate(dir, before)
    local items = {}
    local names = Templates.list(self:libraryDir())
    for i = 1, #names do
        local name = names[i]
        items[#items + 1] = { label = name, icon = "template", cb = function()
            if before then before() end
            self:newNotebookFromTemplate(name, dir)
        end }
    end
    self:chooseFromList{ title = _("New notebook from template"), items = items, close_text = _("Cancel") }
end

-- Start a notebook in folder `dir` whose first page is template `name`, on its
-- paper; it is named after the template and saved at once.
function InkAwayView:newNotebookFromTemplate(name, dir)
    local page, style = Templates.load(self:libraryDir(), name)
    if not page then
        self:tell(_("Could not open that template."))
        return
    end
    self:beginDocument("notebook", name, function()
        local nb = Notebook.new(self.screen_w, self.screen_h, { style = style or "lines",
            size = self.nb_size or self.grid_size or 40, strength = self.nb_strength or self.grid_strength or 45 })
        nb.pages[1].ops, nb.pages[1].title = Notebook.deepcopy(page.ops or {}), page.title
        self:clearBackground()
        self.save_area = nil
        self:enterNotebook(nb)
    end, dir)
    self:saveDocument(true)
end

-- The notebook paper styles, as { style, label } pairs for the choosers, six to
-- a page of the picker: blank and the rulings, then layouts for notes, then the
-- planners (see ink/template.lua).
function InkAwayView:notebookStyles()
    return {
        { "blank", _("Blank") }, { "lines", _("Lined") }, { "grid", _("Grid") },
        { "dots", _("Dotted") }, { "iso", _("Isometric") }, { "margin", _("Margin ruled") },
        { "cornell", _("Cornell") }, { "handwriting", _("Handwriting") }, { "checklist", _("Checklist") },
        { "twocol", _("2 columns") }, { "storyboard", _("Storyboard") }, { "music", _("Music") },
        { "daily", _("Daily") }, { "weekly", _("Weekly") }, { "weekcols", _("Week columns") },
        { "monthly", _("Monthly") }, { "meeting", _("Meeting notes") }, { "habits", _("Habit tracker") },
    }
end

-- The notebook's bottom bar: the toolbar's height, icons and columns.
function InkAwayView:paintNotebookBar(bb, x, y)
    local v = self.view
    local nb = self.notebook
    local h = self.nb_bar_h
    local w = self.screen_w
    local sy0 = y + v.area_y + v.area_h
    local cy = sy0 + math.floor(h / 2)
    local BLACKC = Blitbuffer.COLOR_BLACK
    bb:paintRect(x, sy0, w, h, WHITE)
    bb:paintRect(x, sy0, w, 1, FRAME)   -- divider above the strip
    local isz = self._icon_sz or math.max(20, math.floor(h * 0.66))
    -- one icon centred at cx, the toolbar's size unless given
    local function icon(name, cx, size)
        local im = self:navImage(name, size or isz)
        if not im then return end
        local iw, ih = im:getWidth(), im:getHeight()
        bb:blitFrom(im, math.floor(cx - iw / 2), math.floor(cy - ih / 2), 0, 0, iw, ih)
    end
    -- every button sits in a toolbar column and takes taps across its width, like
    -- a toolbar button: Prev under the first tool, Next under Exit. Those two are
    -- the most used, so they are drawn larger and take taps half a column further
    -- in, where the bar is empty.
    local zone = self._btn_w or (isz * 2)
    local prev_cx = x + math.floor(zone / 2)
    local next_cx = x + (self._last_btn_center or (w - math.floor(zone / 2)))
    local nav = math.floor(isz * 1.35)
    icon("nav_prev", prev_cx, nav)
    icon("nav_next", next_cx, nav)
    self._nb_prev = { x = x, y = sy0, w = math.floor(prev_cx + zone) - x, h = h }
    self._nb_next = { x = math.floor(next_cx - zone), y = sy0, w = x + w - math.floor(next_cx - zone), h = h }
    -- the page counter "index / count", centred; the slash is drawn (the font's
    -- is taller than the digits) and the digits are centred on their measured ink
    local face = self:faceAt("cfont", math.max(10, math.floor(isz * 0.95)))
    local idxw = TextWidget:new{ text = tostring(nb.index), face = face, fgcolor = BLACKC }
    local cntw = TextWidget:new{ text = tostring(nb:count()), face = face, fgcolor = BLACKC }
    local iw, ih = idxw:getSize().w, idxw:getSize().h
    local ink = self:digitInkMetric(face, isz, ih)
    local ty = math.floor(cy - ink.mid)                -- centre the digits' ink on cy
    local slh = ink.h                                  -- slash spans the digit ink height
    local cw = cntw:getSize().w
    local slw = math.max(2, math.floor(slh * 0.42))    -- slash horizontal span
    local stk = math.max(2, math.floor(isz * 0.09))    -- slash thickness
    local g = math.floor(isz * 0.30)
    local counter_w = iw + g + slw + g + cw
    local x0 = math.floor(x + w / 2 - counter_w / 2)
    idxw:paintTo(bb, x0, ty); idxw:free()
    local sx = x0 + iw + g
    do  -- diagonal slash, bottom-left to top-right, centred on cy
        local steps = math.max(slw, slh)
        for i = 0, steps do
            local t = i / steps
            bb:paintRect(math.floor(sx + t * slw) - math.floor(stk / 2),
                math.floor(cy + slh / 2 - t * slh) - math.floor(stk / 2), stk, stk, BLACKC)
        end
    end
    cntw:paintTo(bb, sx + slw + g, ty); cntw:free()
    -- the overview and add-page icons a column and a half either side of the
    -- middle, which puts them in toolbar columns too (further out when a long count
    -- needs the room), clear of Prev and Next
    local mid = x + w / 2
    local off = math.max(math.floor(zone * 1.5), math.floor(counter_w / 2 + isz * 0.6 + isz / 2))
    local ocx = math.max(math.floor(mid - off), prev_cx + zone)
    local icx = math.min(math.floor(mid + off), next_cx - zone)
    icon("overview", ocx)
    icon("newpage", icx)
    self._nb_overview = { x = math.floor(ocx - zone / 2), y = sy0, w = zone, h = h }
    self._nb_plus = { x = math.floor(icx - zone / 2), y = sy0, w = zone, h = h }
    -- the counter opens the page menu; its tap zone spans the room between them
    local count_x = self._nb_overview.x + self._nb_overview.w
    self._nb_count = { x = count_x, y = sy0, w = math.max(1, self._nb_plus.x - count_x), h = h }
end

return InkAwayView

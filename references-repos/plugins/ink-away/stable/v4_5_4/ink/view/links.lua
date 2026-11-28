--[[
Links between pages and the contents page, in the view (the model is
ink/links.lua):
  * making one: "Link to page..." in the selection's menu covers the selection
    with a link to a page chosen from this notebook or any other
  * showing them: a dotted line under each link's area (on screen only)
  * following one: a tap with Pan, or with a navigating finger; a Back pill
    then leads back to where it was followed from
  * the contents page: made, or brought up to date, from the page menu
Part of InkAwayView (see ink/view.lua).
]]

local Blitbuffer = require("ffi/blitbuffer")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Device = require("device")
local _ = require("ink/l10n")
local InkGeom = require("ink/geom")
local Library = require("ink/library")
local Links = require("ink/links")
local Storage = require("ink/storage")

local Screen = Device.screen
local MARK = Blitbuffer.Color8(0x55)

local InkAwayView = {}

local function S(px) return Screen:scaleBySize(px) end

------------------------------------------------------------------------------
-- The links on the page
------------------------------------------------------------------------------

-- The links of the page shown (kept until the page's ops change).
function InkAwayView:pageLinks()
    local ops = self.canvas.ops
    if self._links_of ~= ops or self._links_rev ~= self.canvas.rev or self._links_n ~= #ops then
        self._links, self._links_of, self._links_rev, self._links_n = Links.list(ops), ops, self.canvas.rev, #ops
    end
    return self._links
end

-- The link under a screen point, if any, and its index.
function InkAwayView:linkAtScreen(sx, sy)
    if #self:pageLinks() == 0 then return nil end
    local cx, cy = InkGeom.toCanvas(self.view, sx, sy)
    return Links.at(self.canvas.ops, cx, cy, S(6) / self.view.zoom)
end

-- A dotted line under each link's area, over the page; with `br` (a repaint of
-- just that part of the area, area-relative) only the links that reach it.
function InkAwayView:paintLinks(bb, x, y, br)
    local links = self:pageLinks()
    if #links == 0 then return end
    local v = self.view
    local ax0, ay0 = x + v.area_x, y + v.area_y
    local ax1, ay1 = ax0 + v.area_w, ay0 + v.area_h
    if br then   -- only the repainted part
        ax0, ay0 = math.max(ax0, x + v.area_x + br.x0), math.max(ay0, y + v.area_y + br.y0)
        ax1, ay1 = math.min(ax1, x + v.area_x + br.x1), math.min(ay1, y + v.area_y + br.y1)
        if ax1 <= ax0 or ay1 <= ay0 then return end
    end
    local dot, step, t = S(6), S(10), math.max(1, S(2))
    local lifted = self._lifted
    for _, op in ipairs(links) do
        if not (lifted and lifted[op]) then
            local sx0, sy0 = InkGeom.toScreen(v, op.x, op.y + op.h)
            local sx1 = InkGeom.toScreen(v, op.x + op.w, op.y)
            local ly = math.floor(sy0 + y) - t
            if ly >= ay0 and ly + t <= ay1 and sx1 + x > ax0 and sx0 + x < ax1 then
                for px = math.floor(math.max(ax0, sx0 + x)), math.floor(math.min(ax1, sx1 + x)) - dot, step do
                    bb:paintRect(px, ly, dot, t, MARK)
                end
            end
        end
    end
end

------------------------------------------------------------------------------
-- Following them
------------------------------------------------------------------------------

-- Where the reader is: the document, and its page when it is a notebook.
function InkAwayView:linkPlace()
    local nb = self.notebook
    local page = nb and nb.pages[nb.index]
    return { path = self.doc_path, id = page and page.id, page = nb and nb.index }
end

-- Go to the page `to` names (in this notebook when it names no file). Says so
-- when the page or its notebook is gone. Returns whether it got there.
function InkAwayView:goToPage(to)
    if to.path and to.path ~= self.doc_path then
        if not Storage.exists(to.path) then
            self:showNotice(_("The notebook this leads to is no longer there."), 3)
            return false
        end
        if not self:openDocument(to.path) then return false end
    end
    local nb = self.notebook
    if not nb then return true end
    local i = Links.pageIndex(nb, to)
    if not i then
        self:showNotice(_("The page this leads to is no longer there."), 3)
        return false
    end
    if i ~= nb.index then self:nbGoTo(i) end
    return true
end

-- Follow link op `op`, keeping the way back.
function InkAwayView:followLink(op)
    local back = self:linkPlace()
    self:dropSelection()
    if self:goToPage(op.to) then
        self._link_back = back
        self:refreshFabRegion(self:fabRect("back"))
    end
end

-- Go to the notebook's contents page, keeping the way back as a link does
-- (#40: a quick way to it, from the page menu or a gesture). Without one, says
-- where it is made. Returns whether it went.
function InkAwayView:goToContents()
    local nb = self.notebook
    if not nb then return false end
    for i, p in ipairs(nb.pages) do
        if p.contents then
            if i ~= nb.index then
                local back = self:linkPlace()
                self:dropSelection()
                self:nbGoTo(i)
                self._link_back = back
                self:refreshFabRegion(self:fabRect("back"))
            end
            return true
        end
    end
    self:showNotice(_("This notebook has no contents page yet: the page menu makes one."), 3)
    return false
end

-- Back to where the last link was followed from.
function InkAwayView:linkBack()
    local b = self._link_back
    local r = self:fabRect("back")
    self._link_back = nil
    self:refreshFabRegion(r)
    if b then self:goToPage(b) end
end

------------------------------------------------------------------------------
-- Making them
------------------------------------------------------------------------------

-- The selection's links' indices.
function InkAwayView:selectionLinks()
    local out = {}
    if not self.selection then return out end
    for _, idx in ipairs(self.selection.idxs) do
        if Links.isLink(self.canvas.ops[idx]) then out[#out + 1] = idx end
    end
    return out
end

-- Link the selection to a page: its link takes the new page, or a new link
-- covers it.
function InkAwayView:selLink()
    if not (self.selection and self.selection.bbox) then return end
    self:closeSelectionMenu()
    self:chooseLinkTarget(function(to)
        local sel = self.selection
        if not (sel and sel.bbox) then return end
        self.canvas:pushHistory()
        local have = self:selectionLinks()
        if #have > 0 then
            for _, idx in ipairs(have) do
                local c = self.canvas:cloneOp(self.canvas.ops[idx])
                c.to = to
                self.canvas:replaceOp(idx, c)
            end
        else
            local b = sel.bbox
            local _op, at = self.canvas:placeOp(Links.new(b, to))
            sel.idxs[#sel.idxs + 1] = at
        end
        self:markDirty()
        self:recomputeSelectionBBox()
        self:redraw()
        self:openSelectionMenu()
        self:showNotice(string.format(_("Linked to %s"), to.label or "?"))
    end, function() self:openSelectionMenu() end)
end

-- Remove the selection's links (what they were made on stays).
function InkAwayView:selUnlink()
    local have = self:selectionLinks()
    if #have == 0 then return end
    self.canvas:pushHistory()
    table.sort(have, function(a, b) return a > b end)
    local gone = {}
    for _, idx in ipairs(have) do self.canvas:removeOp(idx); gone[idx] = true end
    local keep = {}
    for _, idx in ipairs(self.selection.idxs) do
        if not gone[idx] then
            local shift = 0
            for _, g in ipairs(have) do if g < idx then shift = shift + 1 end end
            keep[#keep + 1] = idx - shift
        end
    end
    self:markDirty()
    if #keep == 0 then self:dropSelection(); self:redraw(); return end
    self.selection.idxs = keep
    self:recomputeSelectionBBox()
    self:redraw()
    self:openSelectionMenu()
end

-- A page's name in the lists: its title, or its number.
local function pageName(p, i) return p.title or string.format(_("Page %d"), i) end

-- Choose the page a link leads to: a page of this notebook, or of any other
-- one found from the library's folders. on_pick(to) gets it; on_cancel() runs
-- when the sheet is closed without a choice.
function InkAwayView:chooseLinkTarget(on_pick, on_cancel)
    local field = "_link_sheet"
    local root = self:libraryDir()
    if self.notebook then self:nbSyncOut() end
    -- what the sheet shows: a notebook's pages, or a folder's notebooks
    local st = { page = 0 }
    if self.notebook and self.doc_path then
        st.mode, st.path, st.nb = "pages", self.doc_path, self.notebook
    else
        st.mode, st.dir = "folder", self:docDir()
    end
    local picked = false
    local function close() self:closeSheet(field) end
    local function show()
        close()
        local per, pages
        local build = function()
            local content_w = self:sheetWidth()
            local gap = S(10)
            local rows = {}
            local title, note
            if st.mode == "pages" then
                title = _("Link to a page")
                note = Storage.stem(st.path)
                for i, p in ipairs(st.nb.pages) do
                    local here = st.nb == self.notebook and i == st.nb.index
                    rows[#rows + 1] = { "file", pageName(p, i),
                        { string.format(_("Page %d"), i) .. (here and _(" \u{00B7} this page") or "") },
                        function()
                            picked = true
                            close()
                            local same = st.path == self.doc_path
                            on_pick({ path = (not same) and st.path or nil, id = p.id, page = i,
                                label = same and pageName(p, i) or (Storage.stem(st.path) .. " \u{203A} " .. pageName(p, i)) })
                        end }
                end
            else
                title = _("Choose a notebook")
                note = self:searchPlace(st.dir)
                if st.dir ~= root and Storage.within(st.dir, root) then
                    rows[#rows + 1] = { "folder", "\u{2039} " .. _("Up"), { self:searchPlace(Storage.dirName(st.dir)) },
                        function() st.dir = Storage.dirName(st.dir); st.page = 0; show() end }
                end
                local folders, docs = Library.list(st.dir, root, "name")
                for _i, f in ipairs(folders) do
                    rows[#rows + 1] = { "folder", f.name, { _("Folder") },
                        function() st.dir = f.path; st.page = 0; show() end }
                end
                for _i, d in ipairs(docs) do
                    if Library.isNotebookFile(d.path) then
                        rows[#rows + 1] = { "notebook", Storage.stem(d.path), { _("Notebook") }, function()
                            local doc = (d.path == self.doc_path and self.notebook) and { nb = self.notebook }
                                or self:notebookFileDoc(d.path)
                            if not doc.nb then return end
                            st.mode, st.path, st.nb, st.page = "pages", d.path, doc.nb, 0
                            show()
                        end }
                    end
                end
            end
            per = per or self:listRowsFit(content_w, gap)
            pages = math.max(1, math.ceil(#rows / per))
            st.page = math.min(st.page, pages - 1)
            local content = VerticalGroup:new{ align = "left" }
            local function add(w) table.insert(content, w) end
            add(self:sheetTitle(title, content_w, _("Cancel"), function()
                close()
                if on_cancel then on_cancel() end
            end))
            add(VerticalSpan:new{ width = S(6) })
            add(self:sheetLabel(note))
            for k = st.page * per + 1, math.min(#rows, (st.page + 1) * per) do
                local r = rows[k]
                add(VerticalSpan:new{ width = gap })
                add(self:listRow(r[1], r[2], r[3], content_w, r[4]))
            end
            if #rows == 0 then
                add(VerticalSpan:new{ width = gap })
                add(self:sheetHint(_("No notebooks here."), content_w))
            end
            if pages > 1 then
                add(VerticalSpan:new{ width = gap })
                add(self:pagerRow(st.page, pages, content_w, gap, function(d)
                    st.page = (st.page + d) % pages
                    self:rebuildSheet(field)
                end))
            end
            add(VerticalSpan:new{ width = S(14) })
            if st.mode == "pages" then
                add(self:actionButton(_("Another notebook\u{2026}"), content_w, function()
                    st.mode, st.dir, st.page = "folder", Storage.dirName(st.path), 0
                    show()
                end))
            end
            return content
        end
        self:showSheet(field, build, { on_close = function()
            if not picked and on_cancel then on_cancel() end
        end })
    end
    show()
end

------------------------------------------------------------------------------
-- The contents page
------------------------------------------------------------------------------

-- Is there a contents page in the open notebook?
function InkAwayView:nbHasContents()
    for _, p in ipairs(self.notebook and self.notebook.pages or {}) do
        if p.contents then return true end
    end
    return false
end

-- Make the notebook's contents page, or bring it up to date: a line for each
-- titled page, each a link to it, on as many pages as they need, where the
-- contents were (at the front the first time). What else was written on the
-- contents page stays on it. Shows the contents afterwards.
function InkAwayView:nbMakeContents()
    local nb = self.notebook
    if not nb then return end
    self:nbSyncOut()
    self:resetLasso()
    local entries = Links.contentsEntries(nb)
    if #entries == 0 then
        self:tell(_("The contents lists the pages that have a title. "
            .. "Give pages a title first: tap the page number, then Rename."), { timeout = 5 })
        return
    end
    local t = nb.template or {}
    local row = (t.style and t.style ~= "blank" and t.size) or 40
    local geo = Links.contentsGeometry(nb.w, nb.h, row)
    local count = math.ceil(#entries / geo.per)
    -- the old contents pages go; what the reader wrote on them is kept
    local at, kept = nil, {}
    for i = #nb.pages, 1, -1 do
        local p = nb.pages[i]
        if p.contents then
            at = i
            for k = #(p.ops or {}), 1, -1 do
                if not p.ops[k].toc then table.insert(kept, 1, p.ops[k]) end
            end
            table.remove(nb.pages, i)
        end
    end
    at = math.min(at or 1, #nb.pages + 1)
    local made = {}
    for k = 1, count do
        local p = nb:newPage()
        p.contents = true
        if k == 1 then p.title = _("Contents") end
        table.insert(nb.pages, at + k - 1, p)
        made[k] = p
    end
    -- each entry with its page's number now
    local number = {}
    for i, p in ipairs(nb.pages) do if p.id then number[p.id] = i end end
    for k, p in ipairs(made) do
        local chunk = {}
        for e = (k - 1) * geo.per + 1, math.min(#entries, k * geo.per) do
            local en = entries[e]
            chunk[#chunk + 1] = { id = en.id, title = en.title, page = number[en.id] }
        end
        local ops = {}
        if k == 1 then for _i, op in ipairs(kept) do ops[#ops + 1] = op end end
        local heading = k == 1 and _("Contents") or nil
        for _i, op in ipairs(Links.contentsOps(chunk, geo, nb.w, heading)) do
            ops[#ops + 1] = op
        end
        p.ops = ops
    end
    nb.index = at
    self:nbLoad()
    self:markDirty()
    self:saveDocument()
    self:showNotice(string.format(_("Contents: %d page(s) listed"), #entries))
end

return InkAwayView

--[[
Search, from the magnifier in the library's and the overview's header. It asks
for words and whether to look inside pages too, then lists what matches:
folders, drawings and notebooks by name, pages by title, and with "inside
pages" the typed text on them (text boxes, handwriting turned into text). A tap
on a result opens it.

The search runs only when asked, a little at a time (ink/view/jobs.lua): a
progress bar shows once it takes a moment, and a tap on it stops the search.
Any error ends it with a message. The finding itself is ink/search.lua.
Part of InkAwayView (see ink/view.lua).
]]

local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Device = require("device")
local _ = require("ink/l10n")
local Library = require("ink/library")
local Search = require("ink/search")
local Storage = require("ink/storage")

local Screen = Device.screen

local InkAwayView = {}

-- Case folding for any script (KOReader's), or plain lower case without it.
local function lowerFn()
    local ok, util = pcall(require, "util")
    if ok and type(util) == "table" and util.stringLower then
        return function(s)
            local ok2, low = pcall(util.stringLower, s)
            return ok2 and low or s:lower()
        end
    end
    return string.lower
end

-- Ask what to search for. `from` is "library" or "overview": where a result
-- that is a folder opens.
function InkAwayView:openSearch(from)
    if self._search_job then return end
    self:promptText{
        title = _("Search"),
        input = self._search_query or "",
        hint = _("Folder, notebook or page name"),
        ok_text = _("Search"),
        toggle = { label = _("Also look inside pages (slower)"),
            is_on = self:getSetting("inkaway_search_inside") and true or false },
        on_ok = function(query, inside) self:runSearch(query or "", inside, from) end,
    }
end

-- Search the library for `query`, inside pages too with `inside`, then list
-- the results.
function InkAwayView:runSearch(query, inside, from)
    query = (query or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if query == "" or self._search_job then return end
    self._search_query = query
    self:setSetting("inkaway_search_inside", inside)
    -- the open document's latest changes go to its file first
    pcall(self.leaveDocument, self)
    local root = self:libraryDir()
    local lower = lowerFn()
    local entries, docs, index, results
    local i = 0
    local spec
    spec = {
        title = inside and _("Searching inside pages") or _("Searching"),
        quiet = 0.4,      -- a quick search shows no progress bar at all
        first = 0, pause = 0.01,
        step = function()
            if not entries then
                entries = Search.walk(root, Library.INTERNAL)
                docs = {}
                for _, e in ipairs(entries) do if e.kind == "doc" then docs[#docs + 1] = e end end
                local ok, cache = pcall(Search.loadCache, root)
                index = Search.newIndex(ok and cache or nil)
                spec.max = #docs
                return 0
            end
            -- a few documents per step, then let taps and the screen through
            local t0 = os.clock()
            while i < #docs and os.clock() - t0 < 0.06 do
                i = i + 1
                index:document(docs[i], inside)
            end
            if i < #docs then return i end
            results = Search.find(entries, index.docs, query, lower, inside)
            if index.changed then pcall(Search.saveCache, root, index) end
            return "done"
        end,
        on_done = function()
            self._search_job = nil
            self:showSearchResults(results, query, inside, from)
        end,
        on_cancel = function()
            self._search_job = nil
            self:showNotice(_("Search stopped."), 2)
        end,
        on_error = function()
            self._search_job = nil
            self:showNotice(_("The search could not finish."), 3)
        end,
    }
    self._search_job = self:runSteps(spec)
end

-- Where a result is: its folder, from the library's top ("Library" there).
function InkAwayView:searchPlace(dir)
    local root = self:libraryDir()
    if not dir or dir == root or not Storage.within(dir, root) then return _("Library") end
    return (dir:sub(#root + 2):gsub("/", " \u{203A} "))
end

-- The icon, title and grey lines a result is listed with.
function InkAwayView:searchRow(hit)
    local place = self:searchPlace(hit.dir)
    if hit.kind == "folder" then
        return "folder", hit.name, { string.format(_("Folder in %s"), place) }
    elseif hit.kind == "doc" then
        return hit.nb and "notebook" or "pen", hit.name,
            { string.format(hit.nb and _("Notebook in %s") or _("Drawing in %s"), place) }
    end
    -- a page: its title over where it is, or where it is over the words found
    local where = hit.nb and string.format(_("%s \u{00B7} page %d"), hit.name, hit.page) or hit.name
    local notes = {}
    if hit.title then notes[1] = where end
    if hit.text then notes[#notes + 1] = hit.text end
    return "file", hit.title or where, notes
end

-- The results of a search in a sheet, as many to a page as the screen holds.
function InkAwayView:showSearchResults(results, query, inside, from)
    local field = "_search_sheet"
    local page, per, pages = 0, nil, 1
    local closeSelf = function() self:closeSheet(field) end
    local build = function()
        local S = function(px) return Screen:scaleBySize(px) end
        local content_w = self:sheetWidth()
        local gap = S(10)
        if not per then
            per = self:listRowsFit(content_w, gap)
            pages = math.max(1, math.ceil(#results / per))
        end
        local content = VerticalGroup:new{ align = "left" }
        local function add(w) table.insert(content, w) end
        add(self:sheetTitle("\u{201C}" .. query .. "\u{201D}", content_w, _("Close"), closeSelf))
        add(VerticalSpan:new{ width = S(6) })
        local count = #results == 0 and _("Nothing found.")
            or (#results == 1 and _("1 result") or string.format(_("%d results"), #results))
        add(self:sheetLabel(count .. (inside and _(" \u{00B7} names and text inside pages")
            or _(" \u{00B7} names only"))))
        local first = page * per
        for k = first + 1, math.min(#results, first + per) do
            local hit = results[k]
            local icon, title, notes = self:searchRow(hit)
            add(VerticalSpan:new{ width = gap })
            add(self:listRow(icon, title, notes, content_w, function()
                closeSelf()
                self:openSearchResult(hit, from)
            end))
        end
        if pages > 1 then
            add(VerticalSpan:new{ width = gap })
            add(self:pagerRow(page, pages, content_w, gap, function(d)
                page = (page + d) % pages
                self:rebuildSheet(field)
            end))
        end
        add(VerticalSpan:new{ width = S(14) })
        local buttons = {}
        if not inside then
            buttons[#buttons + 1] = { _("Look inside pages too"), function()
                closeSelf(); self:runSearch(query, true, from) end }
        end
        buttons[#buttons + 1] = { _("New search"), function() closeSelf(); self:openSearch(from) end }
        if #buttons == 1 then
            add(self:actionButton(buttons[1][1], content_w, buttons[1][2]))
        else
            local half = math.floor((content_w - gap) / 2)
            add(HorizontalGroup:new{ align = "center",
                self:actionButton(buttons[1][1], half, buttons[1][2]),
                HorizontalSpan:new{ width = gap },
                self:actionButton(buttons[2][1], half, buttons[2][2]) })
        end
        return content
    end
    self:showSheet(field, build)
end

-- Open a result: a folder in the library (or the overview it was searched
-- from), a document, or a notebook at the page found.
function InkAwayView:openSearchResult(hit, from)
    if hit.kind == "folder" then
        if from == "overview" and self._overview then return self:overviewGo(hit.path) end
        if self._library then return self:libraryGo(hit.path) end
        return self:openLibrary(hit.path)
    end
    if not Storage.exists(hit.path) then
        self:showNotice(_("That document is no longer there."), 3)
        return
    end
    if self._overview then self._overview:close() end
    if self._library then self._library:close() end
    if hit.path ~= self.doc_path or not self.doc_written then
        if not self:openDocument(hit.path) then return end
    end
    if hit.kind == "page" and self.notebook then
        local at = hit.page
        if hit.id then
            for i, p in ipairs(self.notebook.pages) do
                if p.id == hit.id then at = i; break end
            end
        end
        self:nbGoTo(math.max(1, math.min(self.notebook:count(), at or 1)))
    end
end

return InkAwayView

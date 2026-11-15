--[[
Ink Away's notebooks on a shelf of the Bookshelf plugin (AndyHazz's
bookshelf.koplugin), through the shelf source interface it offers other plugins
(its SOURCE_API.md, version 1). The reader adds a shelf, picks "Ink Away
notebooks" as its source, and every notebook in the library stands on it face
out, on a cover in one of six styles (ink/notebookcover.lua). A tap opens the
notebook in Ink Away; a long press lets the reader pick its cover style and
colour (ink/coverpicker.lua). Those choices are kept in the folder's binder
file (ink/folder.lua), so they follow the notebook when it is renamed or moved.

Nothing here runs without Bookshelf: register() looks for it and gives up
quietly. The listing, the records and the cover queue are plain Lua with the
KOReader parts handed in, so the headless tests drive them.
]]

local Cover = require("ink/notebookcover")
local Folder = require("ink/folder")
local Library = require("ink/library")
local Storage = require("ink/storage")

local Shelf = {}

-- The source id a Bookshelf shelf stores. Never change it: shelves readers made
-- would stop finding their notebooks.
Shelf.ID = "inkaway_notebooks"

-- How deep the library walk goes into folders.
Shelf.MAX_DEPTH = 8

-- What a notebook's path starts with on the shelf. Bookshelf takes a record
-- under a prefix of its own for one that is not a book file: it then never
-- rebuilds it from the file (KOReader can't read a notebook, so the preview
-- panel would lose the cover and title) and offers no book file actions for it.
Shelf.PREFIX = "inkaway://"

-- The shelf path of the notebook at `path`, and back (nil for one not ours).
function Shelf.shelfPath(path) return Shelf.PREFIX .. path end
function Shelf.notebookPath(filepath)
    if type(filepath) ~= "string" or filepath:sub(1, #Shelf.PREFIX) ~= Shelf.PREFIX then return nil end
    return filepath:sub(#Shelf.PREFIX + 1)
end

-- The cover cache folder's name, under Ink Away's cache folder.
Shelf.COVER_DIR = "covers"

-- How long a cover a notebook no longer uses stays on disk, in seconds:
-- Bookshelf may still be holding a record that points at it, and a cover that
-- went missing under it would be drawn as a blank and stay blank.
Shelf.STALE_AFTER = 60

-- The setting holding the cover style notebooks get unless given their own.
Shelf.DEFAULT_KEY = "inkaway_shelf_cover"

-- KOReader's settings, or nil outside KOReader.
local function settings() return rawget(_G, "G_reader_settings") end

-- The cover style notebooks get unless given their own.
function Shelf.defaultStyle()
    local G = settings()
    return Cover.styleOf(G and G:readSetting(Shelf.DEFAULT_KEY))
end

-- Make `style` the one notebooks get unless given their own.
function Shelf.setDefaultStyle(style)
    local G = settings()
    if G then G:saveSetting(Shelf.DEFAULT_KEY, Cover.styleOf(style)) end
end

-- A colour {r,g,b} from a kept value, or nil when it is not one.
local function rgbOf(v)
    if type(v) ~= "table" then return nil end
    local r, g, b = tonumber(v[1]), tonumber(v[2]), tonumber(v[3])
    if not (r and g and b) then return nil end
    return { math.floor(r), math.floor(g), math.floor(b) }
end

-- The look of the notebook at `path`: { style, colour, own_style, own_colour,
-- tab }. Its own style, else the default; its own colour, else its tab colour,
-- else one picked from its path. `binders` caches folders' binder data by
-- folder for a run of notebooks.
function Shelf.lookOf(path, binders)
    local dir, name = Storage.dirName(path), Storage.baseName(path)
    local data = binders and binders[dir]
    if not data then
        data = Folder.load(dir)
        if binders then binders[dir] = data end
    end
    local mine = type(data.covers[name]) == "table" and data.covers[name] or {}
    local tab = rgbOf(data.colors[name])
    local own = rgbOf(mine.color)
    local style = mine.style and Cover.styleOf(mine.style)
    return {
        style = style or Shelf.defaultStyle(),
        colour = own or tab or Cover.boardOf(path),
        own_style = style ~= nil,
        own_colour = own ~= nil,
        tab = tab,
    }
end

-- Give the notebook at `path` its own cover style and colour: `style` (false
-- to take the default again) and `color` ({r,g,b}, or false to follow its tab
-- colour again); either left nil stays as it is.
function Shelf.setLook(path, style, color)
    local name = Storage.baseName(path)
    return Folder.update(Storage.dirName(path), function(d)
        local c = type(d.covers[name]) == "table" and d.covers[name] or {}
        if style == false then c.style = nil elseif style then c.style = Cover.styleOf(style) end
        if color == false then c.color = nil elseif color then c.color = rgbOf(color) end
        d.covers[name] = (c.style or c.color) and c or nil
    end)
end

-- The setting saying the notebooks were given mixed cover styles (see
-- mixStyles), once.
Shelf.MIXED_KEY = "inkaway_shelf_mixed"

-- The first time the shelf has notebooks, give each without a style of its
-- own one of the six, in a shuffled round so neighbours differ (the newest six
-- get all six), so the reader sees what covers there are and that a long
-- press changes them. `nbs` as from Shelf.notebooks; `random(n)` picks 1..n.
-- Returns whether it ran.
function Shelf.mixStyles(nbs, random)
    local G = settings()
    if #nbs == 0 or (G and G:readSetting(Shelf.MIXED_KEY)) then return false end
    if G then G:saveSetting(Shelf.MIXED_KEY, true) end
    random = random or math.random
    local round = {}
    local function nextStyle()
        if #round == 0 then
            for i, st in ipairs(Cover.STYLES) do round[i] = st end
            for i = #round, 2, -1 do
                local j = random(i)
                round[i], round[j] = round[j], round[i]
            end
        end
        return table.remove(round)
    end
    local byDir, dirs = {}, {}
    for _, nb in ipairs(nbs) do
        local dir = Storage.dirName(nb.path)
        if not byDir[dir] then byDir[dir] = {}; dirs[#dirs + 1] = dir end
        local list = byDir[dir]
        list[#list + 1] = { name = Storage.baseName(nb.path), style = nextStyle() }
    end
    for _, dir in ipairs(dirs) do
        Folder.update(dir, function(d)
            for _, it in ipairs(byDir[dir]) do
                local c = type(d.covers[it.name]) == "table" and d.covers[it.name] or {}
                if not c.style then c.style = it.style end
                d.covers[it.name] = c
            end
        end)
    end
    return true
end

-- A short code for a look, so a cover drawn in another style or colour has
-- another file name.
function Shelf.lookKey(look)
    local c = look.colour or { 0, 0, 0 }
    return Library.pathCode(string.format("%s:%d,%d,%d", look.style or "", c[1], c[2], c[3]))
end

-- Whether each document is a notebook, by path, kept while its file is
-- unchanged: { mtime, notebook }. Asked on every redraw of the shelf, so a
-- document's start is read once, not each time.
local kinds = {}

-- Is the document at `path` (changed at `mtime`) a notebook? Cached by mtime.
local function isNotebook(path, mtime)
    local k = kinds[path]
    if k and k.mtime == mtime then return k.notebook end
    local nb = Library.isNotebookFile(path)
    kinds[path] = { mtime = mtime, notebook = nb }
    return nb
end

-- Every notebook (or, `drawings` true, every drawing) in library folder
-- `root` and its folders, as { path, name, mtime }, newest first. Hidden
-- entries and Ink Away's own folders (exports, downloaded pictures) are left
-- out, as the library leaves them out. What is known of documents no longer
-- there is dropped, so it never piles up (both shelves walk every document,
-- so neither drops what the other asked).
function Shelf.documents(root, drawings)
    local out = {}
    local known = kinds
    kinds = {}
    local function isNotebookNow(path, mtime)
        kinds[path] = known[path]
        return isNotebook(path, mtime)
    end
    local function walk(dir, depth)
        local folders, docs = Library.list(dir, root)
        for _, e in ipairs(docs) do
            if isNotebookNow(e.path, e.mtime) ~= (drawings == true) then
                out[#out + 1] = { path = e.path, name = Storage.stem(e.path), mtime = e.mtime }
            end
        end
        if depth < Shelf.MAX_DEPTH then
            for _, f in ipairs(folders) do walk(f.path, depth + 1) end
        end
    end
    if root and Storage.isDir(root) then walk(root, 1) end
    table.sort(out, function(a, b)
        if a.mtime ~= b.mtime then return a.mtime > b.mtime end
        return a.path < b.path
    end)
    return out
end

-- Every notebook in library folder `root`, as for Shelf.documents.
function Shelf.notebooks(root) return Shelf.documents(root, false) end

-- Forget what is known about the document at `path` (all of them when nil).
function Shelf.forget(path)
    if path then kinds[path] = nil else kinds = {} end
end

-- The cover file name for a notebook: its path code, its first page's
-- snapshot (when that was taken, 0 for a style that does not show the page)
-- and its look's code. Writing on any other page leaves the cover as it is; a
-- new snapshot, look or name gives a new one, so the shelf never shows a stale
-- cover.
function Shelf.coverName(path, stamp, key)
    return string.format("%s-%d-%s.png", Library.pathCode(path), stamp or 0, key or "0")
end

-- The file of the snapshot of the notebook at `path`'s first page, in cover
-- folder `dir` (see Shelf.takeSnapshot).
function Shelf.snapshotName(path) return Library.pathCode(path) .. "-page.png" end
function Shelf.snapshotFile(dir, path) return dir and Storage.join(dir, Shelf.snapshotName(path)) end

-- The file of a notebook's draft page: its first page drawn once in the
-- background for a notebook Ink Away has no snapshot of yet (without its text
-- and pictures, which the export engine leaves out), until the first snapshot
-- replaces it.
function Shelf.draftName(path) return Library.pathCode(path) .. "-draft.png" end
function Shelf.draftFile(dir, path) return dir and Storage.join(dir, Shelf.draftName(path)) end

-- The picture of the notebook at `path`'s first page a cover shows: its
-- snapshot, else its draft, else nil.
function Shelf.pageFile(dir, path)
    if not dir then return nil end
    local snap = Shelf.snapshotFile(dir, path)
    if Storage.exists(snap) then return snap end
    local draft = Shelf.draftFile(dir, path)
    if Storage.exists(draft) then return draft end
    return nil
end

-- What a notebook's cover in `look` depends on besides the look: its page
-- picture's time for a style that shows the first page, else 0.
function Shelf.stampOf(dir, path, look)
    if not (dir and Cover.SHOWS_PAGE[look.style]) then return 0 end
    local file = Shelf.pageFile(dir, path)
    return file and Storage.mtime(file) or 0
end

-- Seconds between two draft pages, so the shelf answers between them.
Shelf.DRAFT_GAP = 1

-- The record Bookshelf shows for notebook `nb` ({ path, name, mtime }), with
-- `cover` (a PNG path) when one is drawn. Its path (under Shelf.PREFIX) is the
-- notebook's identity; its name is the title on the spine and under the cover.
function Shelf.record(nb, cover)
    return {
        filepath = Shelf.shelfPath(nb.path),
        title = nb.name,
        display_title = nb.name,
        cover_image_path = cover,
        -- said outright: Bookshelf fills in a record without it from the file,
        -- and keeps what it found then, so a notebook first listed before its
        -- cover was drawn would stay coverless
        has_cover = cover ~= nil,
        format = "INKAWAY",
        added_time = nb.mtime,
        last_opened = nb.mtime,
        last_read_time = nb.mtime,
        inkaway_notebook = true,
    }
end

-- The cover queue. `opts` gives the KOReader parts: cacheDir() (made if
-- missing), render(path, file, look, snapshot) drawing a notebook's cover in
-- `look` to PNG `file`, its first page from PNG `snapshot` when there is one
-- (returns ok), schedule(seconds, fn), unschedule(fn) and changed() (the
-- shelf redraws); and, for draft pages, draft(path, file) drawing a
-- notebook's first page to PNG `file` (returns ok) and busy() (true while a
-- notebook or a book is open, when drafts wait). Covers are drawn one at a
-- time between redraws, newest notebook first. None draws the notebook's
-- strokes (see Cover.render), so each takes moments. Draft pages, which do,
-- come after them, one every Shelf.DRAFT_GAP seconds, once per notebook. A
-- notebook here carries { path, mtime, look, key, stamp }. A cover a notebook
-- no longer uses is left for prune() to remove once it has gone stale, never
-- deleted at once. For another shelf (ink/drawingshelf.lua), `opts` may also
-- give subdir (its own cover folder), and lookOf(path), lookKey(look) and
-- stampOf(dir, path, look) in place of the notebooks' own.
function Shelf.newCovers(opts)
    local C = { queue = {}, queued = {}, failed = {}, drafts = {}, drafting = {}, draft_failed = {}, last = {} }

    -- The cover folder, or nil when it can't be made.
    function C.dir()
        local base = opts.cacheDir()
        if not base then return nil end
        local dir = Storage.join(base, opts.subdir or Shelf.COVER_DIR)
        return Storage.ensureDir(dir) and dir or nil
    end

    -- The redraw after covers land, once for a run of them.
    local function changed() opts.changed() end
    C.changed = changed

    -- Draw the next queued cover, then come back for the one after.
    local function step()
        local nb = table.remove(C.queue, 1)
        if not nb then return end
        C.queued[nb.path] = nil
        local dir = C.dir()
        if dir then
            local file = Storage.join(dir, Shelf.coverName(nb.path, nb.stamp, nb.key))
            if opts.render(nb.path, file, nb.look, Shelf.pageFile(dir, nb.path)) then
                -- shown until a newer one lands (a draft page, say, gives
                -- the notebook a new stamp before its next cover is drawn)
                C.last[nb.path] = file
                opts.unschedule(changed)
                opts.schedule(#C.queue > 0 and 1 or 0.1, changed)
            else
                -- not again until the notebook or its look changes
                C.failed[nb.path] = (nb.stamp or 0) .. ":" .. tostring(nb.key)
            end
        end
        if #C.queue > 0 then opts.schedule(0.05, step) end
    end
    C.step = step

    -- Draw the next draft page: after the covers, not while a notebook or a
    -- book is open, then come back for the one after.
    local function draftStep()
        if opts.busy and opts.busy() then opts.schedule(5, draftStep) return end
        if #C.queue > 0 then opts.schedule(Shelf.DRAFT_GAP, draftStep) return end
        local nb = table.remove(C.drafts, 1)
        if not nb then return end
        C.drafting[nb.path] = nil
        local dir = C.dir()
        if dir and not Shelf.pageFile(dir, nb.path) then
            if opts.draft(nb.path, Shelf.draftFile(dir, nb.path)) then
                opts.unschedule(changed)
                opts.schedule(0.1, changed)
            else
                C.draft_failed[nb.path] = true
            end
        end
        if #C.drafts > 0 then opts.schedule(Shelf.DRAFT_GAP, draftStep) end
    end
    C.draftStep = draftStep

    -- Queue a draft page for `nb` if it has no page picture yet (and none
    -- failed): one shown on its cover first (`first`), else after those.
    function C.wantDraft(nb, dir, first)
        if not (opts.draft and dir) or C.drafting[nb.path] or C.draft_failed[nb.path] then return end
        if Shelf.pageFile(dir, nb.path) then return end
        C.drafting[nb.path] = true
        local at = #C.drafts + 1
        if first then
            at = 1
            while C.drafts[at] and C.drafts[at].first do at = at + 1 end
        end
        table.insert(C.drafts, at, { path = nb.path, first = first })
        if #C.drafts == 1 then opts.schedule(Shelf.DRAFT_GAP, draftStep) end
    end

    -- Has the cover of `nb` failed to draw (and it has not changed since)?
    function C.hasFailed(nb)
        return C.failed[nb.path] == (nb.stamp or 0) .. ":" .. tostring(nb.key)
    end

    -- The cover file for `nb` if it is drawn, else nil, and `nb` queued. While
    -- a new one waits (a new page picture or look), the one it had before is
    -- given, so the notebook never drops off the shelf meanwhile.
    function C.get(nb, dir)
        local file = dir and Storage.join(dir, Shelf.coverName(nb.path, nb.stamp, nb.key))
        if file and Storage.exists(file) then
            C.last[nb.path] = file
            return file
        end
        if dir and not C.queued[nb.path] and C.failed[nb.path] ~= (nb.stamp or 0) .. ":" .. tostring(nb.key) then
            C.queued[nb.path] = true
            C.queue[#C.queue + 1] = nb
            if #C.queue == 1 then opts.schedule(0.2, step) end
        end
        local before = C.last[nb.path]
        if before and Storage.exists(before) then return before end
        return nil
    end

    -- Draw the cover of the notebook at `path` now (after a new look was
    -- picked, or a new snapshot taken), unless it is drawn already, then
    -- redraw the shelf.
    function C.redraw(path)
        local dir = C.dir()
        if dir and Storage.exists(path) then
            local look = (opts.lookOf or Shelf.lookOf)(path)
            local key = (opts.lookKey or Shelf.lookKey)(look)
            local file = Storage.join(dir, Shelf.coverName(path, (opts.stampOf or Shelf.stampOf)(dir, path, look), key))
            if Storage.exists(file) or opts.render(path, file, look, Shelf.pageFile(dir, path)) then
                C.failed[path] = nil
            end
        end
        changed()
    end

    -- Delete the covers and snapshots no notebook in `nbs` uses (each carries
    -- its current stamp and key): those of notebooks given a new snapshot,
    -- restyled, renamed, moved or deleted, and half-written ones, once they
    -- are older than Shelf.STALE_AFTER at time `now`.
    function C.prune(nbs, dir, now)
        if not dir then return end
        local current = {}
        for _, nb in ipairs(nbs) do
            current[Shelf.coverName(nb.path, nb.stamp, nb.key)] = true
            current[Shelf.snapshotName(nb.path)] = true
            current[Shelf.draftName(nb.path)] = true
        end
        for _, e in ipairs(Storage.list(dir)) do
            if e.mode == "file" and not current[e.name] and (e.name:match("%.png$") or e.name:match("%.tmp$"))
                    and (now or os.time()) - (e.mtime or 0) >= Shelf.STALE_AFTER then
                os.remove(e.path)
            end
        end
    end

    -- Forget the failed covers of notebooks no longer in `nbs`, so the list
    -- of them never outgrows the library.
    function C.forgetGone(nbs)
        local live = {}
        for _, nb in ipairs(nbs) do live[nb.path] = true end
        for path in pairs(C.failed) do if not live[path] then C.failed[path] = nil end end
        for path in pairs(C.draft_failed) do if not live[path] then C.draft_failed[path] = nil end end
        for path in pairs(C.last) do if not live[path] then C.last[path] = nil end end
    end

    return C
end

-- The source spec Bookshelf is given. `opts`: root() (the library folder),
-- covers (from newCovers), open(path) (opens the notebook in Ink Away),
-- choose(path) (the cover sheet, on a long press) and `_` (gettext).
function Shelf.spec(opts)
    local _ = opts._ or function(s) return s end
    local now = opts.now or os.time
    local pruned_at = nil
    return {
        api = 1,
        remote_prefix = Shelf.PREFIX,
        label = function() return _("Ink Away notebooks") end,
        available = function() return true end,
        sort_default = { { key = "last_opened", reverse = true } },
        -- every notebook in the library, with its cover once drawn
        list = function()
            local nbs = Shelf.notebooks(opts.root())
            Shelf.mixStyles(nbs)
            local dir = opts.covers.dir()
            opts.covers.forgetGone(nbs)
            local binders, out = {}, {}
            for _, nb in ipairs(nbs) do
                nb.look = Shelf.lookOf(nb.path, binders)
                nb.key = Shelf.lookKey(nb.look)
                nb.stamp = Shelf.stampOf(dir, nb.path, nb.look)
                -- A notebook joins the shelf with its cover: Bookshelf keeps
                -- what it first drew for a book, so one listed before its
                -- cover would stay blank. Covers are drawn in moments, each
                -- redrawing the shelf; one that can't be drawn still shows.
                local cover = opts.covers.get(nb, dir)
                -- a notebook not opened since: its first page drawn once, later
                if opts.covers.wantDraft then opts.covers.wantDraft(nb, dir, Cover.SHOWS_PAGE[nb.look.style]) end
                if cover or opts.covers.hasFailed(nb) then out[#out + 1] = Shelf.record(nb, cover) end
            end
            -- covers no longer used, cleared away now and then
            local t = now()
            if not pruned_at or t - pruned_at >= Shelf.STALE_AFTER then
                pruned_at = t
                opts.covers.prune(nbs, dir, t)
            end
            return out
        end,
        -- A new shelf of notebooks shows their covers, front facing (a spine
        -- only has room for the name; switched to spines, they all stand face
        -- out). Only what the reader has not chosen, as this also runs when a
        -- shelf's source is changed to ours.
        new_shelf = function(draft)
            if draft.view_mode == nil then draft.view_mode = "covers" end
            if draft.spine_face_out == nil then draft.spine_face_out = "all" end
            -- no text below the covers: a cover shows its name already, and
            -- Bookshelf's default line (an author) has nothing to show here
            if draft.cover_text == nil then draft.cover_text = "none" end
            if draft.label == nil or draft.label == "New shelf" or draft.label == _("New shelf") then
                draft.label = _("Notebooks")
            end
        end,
        owns = function(book)
            return type(book) == "table" and Shelf.notebookPath(book.filepath) ~= nil
        end,
        open = function(book)
            local path = Shelf.notebookPath(book.filepath)
            if path then opts.open(path) end
            return true
        end,
        -- a long press: the notebook's cover style and colour
        info = function(book)
            local path = Shelf.notebookPath(book.filepath)
            if path and opts.choose then opts.choose(path) end
        end,
        -- a book changed (any book, or all of them when nil); only ours matter
        invalidate = function(filepath)
            if filepath == nil then Shelf.forget() return end
            local path = Shelf.notebookPath(filepath)
            if path then Shelf.forget(path) end
        end,
    }
end

-- Put the notebooks on Bookshelf, when it is there and new enough. `plugin` is
-- Ink Away's plugin (its openCanvas opens a notebook). Returns whether the
-- source was registered; false, quietly, without Bookshelf.
function Shelf.register(ui, plugin)
    local bs = ui and ui.bookshelf
    if not (type(bs) == "table" and type(bs.registerSource) == "function"
            and (tonumber(bs.SOURCE_API) or 0) >= 1) then
        return false
    end
    local UIManager = require("ui/uimanager")
    local _ = require("ink/l10n")
    local covers = Shelf.covers
    if not covers then
        covers = Shelf.newCovers{
            cacheDir = Storage.cacheDir,
            -- each cover's buffers (several MB for a big page) go at once,
            -- not whenever the collector gets round to them
            render = function(path, file, look, snapshot)
                local done = Cover.write(path, file, { style = look and look.style,
                    colour = look and look.colour, snapshot = snapshot })
                collectgarbage()
                return done
            end,
            schedule = function(s, fn) UIManager:scheduleIn(s, fn) end,
            unschedule = function(fn) UIManager:unschedule(fn) end,
            changed = function() Shelf.redrawShelf(bs) end,
            draft = function(path, file)
                local done = Cover.writePage(path, file)
                collectgarbage()
                return done
            end,
            busy = Shelf.busy,
        }
        Shelf.covers = covers
    end
    local ok = pcall(function()
        local done = bs:registerSource(Shelf.ID, Shelf.spec{
            _ = _,
            root = function()
                local G = rawget(_G, "G_reader_settings")
                return Library.root(G and G:readSetting("inkaway_library_dir"))
            end,
            covers = covers,
            open = function(path) Shelf.open(plugin, path) end,
            choose = function(path)
                require("ink/coverpicker").show{ path = path, open = function() Shelf.open(plugin, path) end }
            end,
        })
        if not done then error("refused") end
    end)
    Shelf.registered = Shelf.registered or ok
    return ok
end

-- Is a notebook (an Ink Away view) or a book open? Draft pages wait then,
-- so their drawing never holds up the pen or a page turn.
function Shelf.busy()
    local ok, busy = pcall(function()
        if require("apps/reader/readerui").instance then return true end
        for _, w in ipairs(require("ui/uimanager")._window_stack or {}) do
            if w.widget and w.widget.name == "inkaway_view" then return true end
        end
        return false
    end)
    return ok and busy
end

-- Redraw the shelf from a fresh listing. A Spines shelf keeps its whole list
-- for half a minute and sourceChanged does not drop it (Bookshelf 5.4.4), so
-- a notebook just covered would stay off the shelf and a new cover would wait
-- that long; the shelf's kept list is cleared first. Only that one field, and
-- nothing at all if a later Bookshelf has no such field.
function Shelf.redrawShelf(bs)
    pcall(function()
        local w = bs._widget
        if type(w) == "table" and type(w._spine_fetch_cache) == "table" then w._spine_fetch_cache = nil end
        bs:sourceChanged(Shelf.ID)
    end)
end

-- Open the notebook (or drawing) at `path` in Ink Away, from the shelf. As the
-- view closes it has taken a new snapshot of the first page if that changed
-- (see takeSnapshot), and the cover follows (in `covers`, the notebooks' by
-- default); nothing of the view is kept.
function Shelf.open(plugin, path, covers)
    local view = plugin:openCanvas(nil, path)
    if not view then return end
    local doc = view.doc_path or path
    view.after_close = function()
        view.after_close = nil
        covers = covers or Shelf.covers
        if covers then covers.redraw(doc) end
    end
end

-- The notebook at `path` got a new look: draw its cover now and redraw the
-- shelf.
function Shelf.lookChanged(path)
    if Shelf.covers then Shelf.covers.redraw(path) end
end

-- What the paper of notebook `nb` looks like, as a short string, so a snapshot
-- is taken again when it changes.
local function paperKey(nb)
    local t = nb.template or {}
    local p = t.paper
    return table.concat({ tostring(t.style), tostring(t.size), tostring(t.strength),
        type(p) == "table" and table.concat(p, ",") or tostring(p), tostring(t.pdf_path) }, "|")
end

-- A snapshot's width in pixels: the widest a cover shows the page.
Shelf.SNAPSHOT_W = Cover.W

-- Keep a snapshot of the first page of Ink Away view `view`'s notebook for
-- its cover, from the page the view has drawn already (text, pictures and an
-- imported PDF's page included; no stroke is drawn again). Called as the view
-- leaves its first page or closes: only when Bookshelf has the notebooks, the
-- canvas shows the first page (the current page, unless `shows_first` says),
-- the notebook is saved, it is not in night colours, and either there is no
-- snapshot, the file changed since it was taken (written elsewhere) or the
-- page changed since. Returns whether one was written.
function Shelf.takeSnapshot(view, shows_first)
    if not (Shelf.registered and Shelf.covers) then return false end
    local nb = view.notebook
    local bb = view.canvas_bb
    if shows_first == nil then shows_first = nb ~= nil and nb.index == 1 end
    if not (nb and shows_first and bb and view.doc_written and view.doc_path) then return false end
    if view.nightInk and view:nightInk() then return false end
    local dir = Shelf.covers.dir()
    if not dir then return false end
    local file = Shelf.snapshotFile(dir, view.doc_path)
    local seen, key = view._shelf_snap, paperKey(nb)
    local need
    if not Storage.exists(file) then
        need = true
    elseif not (seen and seen.path == view.doc_path) then
        need = (Storage.mtime(file) or 0) < (Storage.mtime(view.doc_path) or 0)
    else
        need = view._p1_changed or seen.page ~= nb.pages[1] or seen.paper ~= key
    end
    view._shelf_snap = { path = view.doc_path, page = nb.pages[1], paper = key }
    view._p1_changed = nil
    if not need then return false end
    local ok = Shelf.writeSnapshot(bb, file, Shelf.SNAPSHOT_W)
    if ok then os.remove(Shelf.draftFile(dir, view.doc_path)) end   -- the real page replaces it
    return ok
end

-- Write `bb` (what the view shows) at most `w` wide to PNG `file`, by way of
-- a temporary file so a cover never reads half of one. Returns whether it was
-- written.
function Shelf.writeSnapshot(bb, file, w)
    return (pcall(function()
        local RenderImage = require("ui/renderimage")
        local bw, bh = bb:getWidth(), bb:getHeight()
        local s = math.min(1, w / bw)
        local small = RenderImage:scaleBlitBuffer(bb, math.max(1, math.floor(bw * s)), math.max(1, math.floor(bh * s)), false)
        local tmp = file .. ".tmp"
        local wrote = pcall(function() small:writePNG(tmp) end)
        if small ~= bb then small:free() end
        if not (wrote and os.rename(tmp, file)) then os.remove(tmp); error("not written") end
    end))
end

-- The default style changed: every notebook without its own is drawn again
-- as the shelf asks for it.
function Shelf.defaultChanged()
    if Shelf.covers then pcall(Shelf.covers.changed) end
end

return Shelf

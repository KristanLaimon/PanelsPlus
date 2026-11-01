--[[
Ink Away's drawings on a shelf of the Bookshelf plugin, beside the notebooks'
(ink/bookshelf.lua), through the same shelf source interface. The reader adds
a shelf, picks "Ink Away drawings" as its source, and every drawing in the
library hangs on it face out, in a frame (ink/framecover.lua). A drawing the
shelf sees for the first time gets a frame and a finish at random, the twelve
frames dealt in shuffled rounds so neighbours differ; a long press picks
another (ink/framepicker.lua). The choice is kept in the folder's binder file
(ink/folder.lua), so it follows the drawing when it is renamed or moved.

It is as quick as the notebooks' shelf and works the same way: a cover is the
snapshot Ink Away keeps of the drawing as it closes it (no stroke is drawn for
the shelf) in its frame's pieces, written once to a PNG in the cache, and again
only when the snapshot or the frame changes. A drawing never opened since has
its picture drawn once in the background, small, while nothing is open. Covers
no drawing uses are cleared away after a minute. The frames have a cache folder
of their own, so neither shelf ever clears the other's covers.
]]

local FrameCover = require("ink/framecover")
local Folder = require("ink/folder")
local Library = require("ink/library")
local Shelf = require("ink/bookshelf")
local Storage = require("ink/storage")

local DShelf = {}

-- The source id a Bookshelf shelf stores. Never change it.
DShelf.ID = "inkaway_drawings"

-- What a drawing's path starts with on the shelf: a prefix of its own, so
-- each source owns only its own records.
DShelf.PREFIX = "inkaway-drawing://"

function DShelf.shelfPath(path) return DShelf.PREFIX .. path end
function DShelf.drawingPath(filepath)
    if type(filepath) ~= "string" or filepath:sub(1, #DShelf.PREFIX) ~= DShelf.PREFIX then return nil end
    return filepath:sub(#DShelf.PREFIX + 1)
end

-- The cover cache folder's name, under Ink Away's cache folder.
DShelf.COVER_DIR = "frames"

-- A snapshot's width: the widest a cover shows the drawing.
DShelf.SNAPSHOT_W = FrameCover.W

-- The shape covers take: "true" when Bookshelf's "True cover aspect" is on
-- (it then shows each cover in its own shape, so the frame hugs the drawing),
-- else "fill" (2:3, the shape it gives every cover). Read from Bookshelf's own
-- settings, already loaded by then; "fill" when they can't be read.
function DShelf.shape()
    local ok, on = pcall(function()
        local pkg = rawget(_G, "package")
        local Store = pkg and pkg.loaded["lib/bookshelf_settings_store"]
        return Store and Store.isTrue("true_cover_aspect")
    end)
    return (ok and on) and "true" or "fill"
end

-- The frame of the drawing at `path`: { frame, option, shape }, frame and
-- option nil when it has none yet. `binders` caches folders' binder data for
-- a run of drawings.
function DShelf.lookOf(path, binders)
    local dir, name = Storage.dirName(path), Storage.baseName(path)
    local data = binders and binders[dir]
    if not data then
        data = Folder.load(dir)
        if binders then binders[dir] = data end
    end
    local mine = type(data.covers[name]) == "table" and data.covers[name] or {}
    local frame, option = FrameCover.lookOf(mine.frame, mine.frame_option)
    return { frame = frame, option = option, shape = DShelf.shape() }
end

-- Give the drawing at `path` frame `frame` in finish `option` (its first
-- when nil).
function DShelf.setLook(path, frame, option)
    frame, option = FrameCover.lookOf(frame, option)
    if not frame then return false end
    local name = Storage.baseName(path)
    return Folder.update(Storage.dirName(path), function(d)
        local c = type(d.covers[name]) == "table" and d.covers[name] or {}
        c.frame, c.frame_option = frame, option
        d.covers[name] = c
    end)
end

-- A short code for a look, so a cover in another frame or shape has another
-- file name.
function DShelf.lookKey(look)
    return Library.pathCode(string.format("%s:%s:%s", look.frame or "", look.option or "", look.shape or "fill"))
end

-- A PNG's size as Bookshelf's size tag "WxH", from its header (24 bytes),
-- or nil. Kept by file: a cover's file name changes whenever it is drawn anew.
local sizes, nsizes = {}, 0
function DShelf.sizeTag(file)
    if not file then return nil end
    local tag = sizes[file]
    if tag ~= nil then return tag or nil end
    local f = io.open(file, "rb")
    local head = f and f:read(24)
    if f then f:close() end
    tag = false
    if head and #head == 24 and head:sub(2, 4) == "PNG" then
        local function u32(i)
            local a, b, c, d = head:byte(i, i + 3)
            return ((a * 256 + b) * 256 + c) * 256 + d
        end
        tag = string.format("%dx%d", u32(17), u32(21))
    end
    if nsizes > 1000 then sizes, nsizes = {}, 0 end
    sizes[file], nsizes = tag, nsizes + 1
    return tag or nil
end

-- What a drawing's cover depends on besides its frame: its picture's time.
function DShelf.stampOf(dir, path)
    local file = dir and Shelf.pageFile(dir, path)
    return file and Storage.mtime(file) or 0
end

-- Give each drawing in `drawings` that has no frame yet a frame and a finish
-- at random, the frames dealt in shuffled rounds so neighbours differ, one
-- binder write per folder. `binders` as for lookOf (kept up to date);
-- `random(n)` picks 1..n. Returns how many were given one.
function DShelf.dealFrames(drawings, binders, random)
    random = random or math.random
    local frames = FrameCover.frames()
    if #frames == 0 then return 0 end
    local round = {}
    local function nextFrame()
        if #round == 0 then
            for i, f in ipairs(frames) do round[i] = f end
            for i = #round, 2, -1 do
                local j = random(i)
                round[i], round[j] = round[j], round[i]
            end
        end
        return table.remove(round)
    end
    local byDir, dirs, n = {}, {}, 0
    for _, d in ipairs(drawings) do
        if not DShelf.lookOf(d.path, binders).frame then
            local dir = Storage.dirName(d.path)
            if not byDir[dir] then byDir[dir] = {}; dirs[#dirs + 1] = dir end
            local f = nextFrame()
            local opts = FrameCover.options(f)
            local list = byDir[dir]
            list[#list + 1] = { name = Storage.baseName(d.path), frame = f, option = opts[random(#opts)] }
            n = n + 1
        end
    end
    for _, dir in ipairs(dirs) do
        Folder.update(dir, function(data)
            for _, it in ipairs(byDir[dir]) do
                local c = type(data.covers[it.name]) == "table" and data.covers[it.name] or {}
                if not c.frame then c.frame, c.frame_option = it.frame, it.option end
                data.covers[it.name] = c
            end
            if binders then binders[dir] = data end
        end)
    end
    return n
end

-- The record Bookshelf shows for drawing `d` ({ path, name, mtime }), with
-- `cover` (a PNG path) when one is drawn.
-- With covers in their own shapes, the record says each cover's size, so
-- Bookshelf gives it its shape.
function DShelf.record(d, cover)
    local r = Shelf.record(d, cover)
    r.filepath = DShelf.shelfPath(d.path)
    r.inkaway_notebook = nil
    r.inkaway_drawing = true
    if cover and d.look and d.look.shape == "true" then r.cover_sizetag = DShelf.sizeTag(cover) end
    return r
end

------------------------------------------------------------------------------
-- Pictures
------------------------------------------------------------------------------

-- The drawing at `path` drawn `w` wide, from its file, as an RGB32
-- BlitBuffer, or nil when it is not a drawing. Only for a drawing Ink Away
-- has no snapshot of yet, once: its strokes are scaled down first (as a
-- notebook's draft page is), so it costs about what the picture's pixels
-- cost; its background picture under them, its text and pictures left out as
-- the export engine leaves them.
function DShelf.drawingImage(path, w)
    local Project = require("ink/project")
    local data = Project.load(path)
    if not (data and not Project.isNotebook(data) and type(data.ops) == "table") then return nil end
    local BB = require("ffi/blitbuffer")
    local Canvas = require("ink/canvas")
    local Export = require("ink/export")
    local Layers = require("ink/layers")
    local Palette = require("ink/palette")
    local Transform = require("ink/transform")
    local dw = tonumber(data.w) or 600
    local dh = tonumber(data.h) or 800
    local k = math.min(1, w / dw)
    local sw, sh = math.max(1, math.floor(dw * k + 0.5)), math.max(1, math.floor(dh * k + 0.5))
    local canvas = Canvas.new(sw, sh)
    local ops = {}
    for i, op in ipairs(Layers.drawnOfFile(data.ops, data.layers) or {}) do
        ops[i] = Transform.scale(canvas:cloneOp(op), 0, 0, k)
    end
    canvas:setOps(ops)
    local paper = Palette.paperRGB(data.paper) or { 255, 255, 255 }
    local out = BB.new(sw, sh, BB.TYPE_BBRGB32)
    out:paintRectRGB32(0, 0, sw, sh, BB.ColorRGB32(paper[1], paper[2], paper[3], 0xFF))
    if type(data.bg) == "string" and Storage.exists(data.bg) then
        pcall(function()
            local RenderImage = require("ui/renderimage")
            local img = RenderImage:renderImageFile(data.bg, false)
            if not img then return end
            local s = math.min(sw / img:getWidth(), sh / img:getHeight())
            local iw, ih = math.max(1, math.floor(img:getWidth() * s)), math.max(1, math.floor(img:getHeight() * s))
            local small = RenderImage:scaleBlitBuffer(img, iw, ih, false)
            out:blitFrom(small, math.floor((sw - iw) / 2), math.floor((sh - ih) / 2), 0, 0, iw, ih)
            if small ~= img then small:free() end
            img:free()
        end)
    end
    local buf, ow, oh = Export.buildPNGRGBA(canvas, { template = { style = "blank", paper = paper } })
    local ink = BB.new(ow, oh, BB.TYPE_BBRGB32, buf)
    out:alphablitFrom(ink, 0, 0, 0, 0, ow, oh)
    ink = nil   -- luacheck: ignore 311
    buf = nil   -- luacheck: ignore 311
    return out
end

-- Draw the drawing at `path` to PNG `file` (see drawingImage). Returns whether
-- it was written.
function DShelf.writeDraft(path, file)
    local ok, img = pcall(DShelf.drawingImage, path, DShelf.SNAPSHOT_W)
    if not (ok and img) then return false end
    local tmp = file .. ".tmp"
    local wrote = pcall(function() img:writePNG(tmp) end)
    img:free()
    if not (wrote and Storage.exists(tmp)) then os.remove(tmp); return false end
    return os.rename(tmp, file) == true
end

------------------------------------------------------------------------------
-- The source
------------------------------------------------------------------------------

-- The covers queue for drawings: the notebooks' queue (see Shelf.newCovers)
-- with the frames' folder, looks and stamps. `opts` as for Shelf.newCovers,
-- without render and draft, which are the frames'.
function DShelf.newCovers(opts)
    local o = {}
    for k, v in pairs(opts) do o[k] = v end
    o.subdir = DShelf.COVER_DIR
    o.lookOf = function(path) return DShelf.lookOf(path) end
    o.lookKey = DShelf.lookKey
    o.stampOf = function(dir, path) return DShelf.stampOf(dir, path) end
    o.render = o.render or function(path, file, look, picture)
        return FrameCover.write(file, { frame = look.frame, option = look.option, shape = look.shape,
            file = picture, name = Storage.stem(path) })
    end
    o.draft = o.draft or DShelf.writeDraft
    return Shelf.newCovers(o)
end

-- The source spec Bookshelf is given. `opts`: root(), covers (from
-- DShelf.newCovers), open(path), choose(path) (the frame sheet, on a long
-- press), `_` (gettext), and random(n) and now() for the tests.
function DShelf.spec(opts)
    local _ = opts._ or function(s) return s end
    local now = opts.now or os.time
    local pruned_at = nil
    return {
        api = 1,
        remote_prefix = DShelf.PREFIX,
        label = function() return _("Ink Away drawings") end,
        available = function() return true end,
        sort_default = { { key = "last_opened", reverse = true } },
        -- every drawing in the library, with its cover once drawn
        list = function()
            local ds = Shelf.documents(opts.root(), true)
            local binders = {}
            DShelf.dealFrames(ds, binders, opts.random)
            local dir = opts.covers.dir()
            opts.covers.forgetGone(ds)
            local out = {}
            for _i, d in ipairs(ds) do
                d.look = DShelf.lookOf(d.path, binders)
                d.key = DShelf.lookKey(d.look)
                d.stamp = DShelf.stampOf(dir, d.path)
                -- as for notebooks: a drawing joins the shelf with its cover
                local cover = opts.covers.get(d, dir)
                if opts.covers.wantDraft then opts.covers.wantDraft(d, dir, true) end
                if cover or opts.covers.hasFailed(d) then out[#out + 1] = DShelf.record(d, cover) end
            end
            local t = now()
            if not pruned_at or t - pruned_at >= Shelf.STALE_AFTER then
                pruned_at = t
                opts.covers.prune(ds, dir, t)
            end
            return out
        end,
        -- A new shelf of drawings shows them face out, as framed pictures
        -- (a spine only has room for the name). Only what the reader has not
        -- chosen, as this also runs when a shelf's source is changed to ours.
        new_shelf = function(draft)
            if draft.view_mode == nil then draft.view_mode = "covers" end
            if draft.spine_face_out == nil then draft.spine_face_out = "all" end
            -- no text below the covers: a cover shows its name already, and
            -- Bookshelf's default line (an author) has nothing to show here
            if draft.cover_text == nil then draft.cover_text = "none" end
            if draft.label == nil or draft.label == "New shelf" or draft.label == _("New shelf") then
                draft.label = _("Drawings")
            end
        end,
        owns = function(book)
            return type(book) == "table" and DShelf.drawingPath(book.filepath) ~= nil
        end,
        open = function(book)
            local path = DShelf.drawingPath(book.filepath)
            if path then opts.open(path) end
            return true
        end,
        -- a long press: the drawing's frame
        info = function(book)
            local path = DShelf.drawingPath(book.filepath)
            if path and opts.choose then opts.choose(path) end
        end,
        invalidate = function(filepath)
            if filepath == nil then Shelf.forget() return end
            local path = DShelf.drawingPath(filepath)
            if path then Shelf.forget(path) end
        end,
    }
end

-- Put the drawings on Bookshelf, when it is there and new enough (see
-- Shelf.register). Returns whether the source was registered.
function DShelf.register(ui, plugin)
    local bs = ui and ui.bookshelf
    if not (type(bs) == "table" and type(bs.registerSource) == "function"
            and (tonumber(bs.SOURCE_API) or 0) >= 1) then
        return false
    end
    local UIManager = require("ui/uimanager")
    local _ = require("ink/l10n")
    local covers = DShelf.covers
    if not covers then
        covers = DShelf.newCovers{
            cacheDir = Storage.cacheDir,
            -- each cover's buffers go at once, not when the collector gets to them
            render = function(path, file, look, picture)
                local done = FrameCover.write(file, { frame = look.frame, option = look.option,
                    shape = look.shape, file = picture, name = Storage.stem(path) })
                collectgarbage()
                return done
            end,
            draft = function(path, file)
                local done = DShelf.writeDraft(path, file)
                collectgarbage()
                return done
            end,
            schedule = function(s, fn) UIManager:scheduleIn(s, fn) end,
            unschedule = function(fn) UIManager:unschedule(fn) end,
            changed = function() DShelf.redrawShelf(bs) end,
            busy = Shelf.busy,
        }
        DShelf.covers = covers
    end
    local ok = pcall(function()
        local done = bs:registerSource(DShelf.ID, DShelf.spec{
            _ = _,
            root = function()
                local G = rawget(_G, "G_reader_settings")
                return Library.root(G and G:readSetting("inkaway_library_dir"))
            end,
            covers = covers,
            open = function(path) Shelf.open(plugin, path, DShelf.covers) end,
            choose = function(path)
                require("ink/framepicker").show{ path = path, open = function() Shelf.open(plugin, path, DShelf.covers) end }
            end,
        })
        if not done then error("refused") end
    end)
    DShelf.registered = DShelf.registered or ok
    return ok
end

-- Redraw the drawings' shelf from a fresh listing (see Shelf.redrawShelf).
function DShelf.redrawShelf(bs)
    pcall(function()
        local w = bs._widget
        if type(w) == "table" and type(w._spine_fetch_cache) == "table" then w._spine_fetch_cache = nil end
        bs:sourceChanged(DShelf.ID)
    end)
end

-- The drawing at `path` got a new frame: draw its cover now, redraw the shelf.
function DShelf.lookChanged(path)
    if DShelf.covers then DShelf.covers.redraw(path) end
end

-- Keep a snapshot of the drawing Ink Away view `view` shows for its cover,
-- from what the view has drawn already (no stroke is drawn again). Called as
-- the view leaves the drawing or closes: only when Bookshelf has the
-- drawings, the drawing is saved, not in night colours, and the snapshot is
-- missing or older than the drawing's file. Returns whether one was written.
function DShelf.takeSnapshot(view)
    if not (DShelf.registered and DShelf.covers) then return false end
    local bb = view.canvas_bb
    if view.notebook or not (bb and view.doc_written and view.doc_path) then return false end
    if view.nightInk and view:nightInk() then return false end
    local dir = DShelf.covers.dir()
    if not dir then return false end
    local file = Shelf.snapshotFile(dir, view.doc_path)
    if Storage.exists(file) and (Storage.mtime(file) or 0) >= (Storage.mtime(view.doc_path) or 0) then
        return false
    end
    local ok = Shelf.writeSnapshot(bb, file, DShelf.SNAPSHOT_W)
    if ok then os.remove(Shelf.draftFile(dir, view.doc_path)) end
    return ok
end

return DShelf

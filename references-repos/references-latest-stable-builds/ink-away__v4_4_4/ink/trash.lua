--[[
The trash: what is deleted from the library waits here for Trash.KEEP_DAYS
days and can be put back where it was. Plain Lua, so the headless tests drive
it; ink/view/trash.lua is its sheet.

It is a hidden folder in the library (Trash.DIR), so the library, its search
and the overview never see it. A deleted drawing or notebook file and a deleted
folder (with everything in it) are moved in whole, by renaming, so nothing is
copied or rewritten and a notebook comes back with every page in its order. A
deleted page is written out on its own, with what is needed to put it back:
its notebook and the pages it sat between.

Each item remembers where it came from: its path, and its place and tab colour
in the folder's binder order. Putting it back uses the same name unless that is
taken since (then "Name (2)"), makes its folder again if that is gone, and puts
the tab back in its place.

  * Trash.list(root)                          the items, newest first
  * Trash.putDocument(root, path) / putFolder(root, path)
  * Trash.putPage(root, nb_path, nb, i)       page i of notebook nb (the caller removes it)
  * Trash.putBookInk(root, sidecar, info)     a book's annotations (its ink file and pictures)
  * Trash.restore(root, id, insert_page)      put an item back
  * Trash.forget(root, id), Trash.empty(root), Trash.purge(root)
]]

local Folder = require("ink/folder")
local Project = require("ink/project")
local Storage = require("ink/storage")

local Trash = {}

Trash.DIR = ".trash"
Trash.INDEX = "index"
Trash.KEEP_DAYS = 30
Trash.now = os.time   -- (replaced in the tests)

local function dirOf(root) return Storage.join(root, Trash.DIR) end

-- The trash's index: { v = 1, items = { item, ... } }, oldest first.
local function load(root)
    local f = io.open(Storage.join(dirOf(root), Trash.INDEX), "rb")
    local data
    if f then
        data = Project.decode(f:read("*a"))
        f:close()
    end
    if type(data) ~= "table" or type(data.items) ~= "table" then data = { v = 1, items = {} } end
    return data
end

local function save(root, data)
    return Storage.writeAtomic(Storage.join(dirOf(root), Trash.INDEX), Project.encode(data))
end

-- Make folder `p` and any missing folders above it, up to `root`. Returns
-- whether it exists now.
local function ensureDirs(p, root)
    if Storage.isDir(p) then return true end
    if p == root or #p <= #root then return Storage.ensureDir(p) end
    ensureDirs(Storage.dirName(p), root)
    return Storage.ensureDir(p)
end

-- A fresh item id (also the name of its file in the trash).
local function newId(root, data)
    local base = tostring(Trash.now())
    local n = 1
    while true do
        local id = base .. "-" .. n
        local taken = Storage.exists(Storage.join(dirOf(root), id))
            or Storage.exists(Storage.join(dirOf(root), id .. "." .. Project.EXT))
            or Storage.exists(Storage.join(dirOf(root), id .. ".page"))
        for _, it in ipairs(data.items) do if it.id == id then taken = true end end
        if not taken then return id end
        n = n + 1
    end
end

-- Where `name` sits in folder `dir`'s binder: the names before and after it,
-- its index, its tab colour and its Bookshelf cover.
local function binderPlace(dir, name)
    local data = Folder.load(dir)
    local place = { color = data.colors[name], cover = data.covers[name] }
    for i, n in ipairs(data.order) do
        if n == name then
            place.i, place.prev, place.next = i, data.order[i - 1], data.order[i + 1]
            break
        end
    end
    return place
end

-- Put `name` back in folder `dir`'s binder at `place` (from binderPlace).
local function rebind(dir, name, place)
    Folder.update(dir, function(d)
        Folder.forget(d, name)
        local at
        if place and place.prev then
            for i, n in ipairs(d.order) do if n == place.prev then at = i + 1 end end
        end
        if not at and place and place.next then
            for i, n in ipairs(d.order) do if n == place.next then at = i end end
        end
        if not at and place and place.i then at = math.min(place.i, #d.order + 1) end
        table.insert(d.order, at or #d.order + 1, name)
        if place and place.color ~= nil then d.colors[name] = place.color end
        if place and place.cover ~= nil then d.covers[name] = place.cover end
    end)
end

-- The items in the trash of library `root`, newest first.
function Trash.list(root)
    local items = {}
    local data = load(root)
    for i = #data.items, 1, -1 do items[#items + 1] = data.items[i] end
    return items
end

-- What an item's stored name ends in: a document's extension, a picture's own
-- (".jpg"), nothing for a folder.
local function suffix(item)
    if item.kind == "doc" then return "." .. Project.EXT end
    if item.kind == "picture" then return "." .. (item.ext or "jpg") end
    return ""
end

-- Move a file or folder at `path` into the trash as `item`. Returns the item,
-- or nil, err.
local function putPath(root, path, item)
    if not Storage.exists(path) then return nil, "not there" end
    if not Storage.ensureDir(dirOf(root)) then return nil, "no trash folder" end
    local data = load(root)
    item.id = newId(root, data)
    item.from = path
    item.when = Trash.now()
    item.place = binderPlace(Storage.dirName(path), Storage.baseName(path))
    local stored = Storage.join(dirOf(root), item.id .. suffix(item))
    local ok, err = os.rename(path, stored)
    if not ok then return nil, err end
    Folder.update(Storage.dirName(path), function(d) Folder.forget(d, Storage.baseName(path)) end)
    data.items[#data.items + 1] = item
    if not save(root, data) then
        os.rename(stored, path)   -- keep it where it was rather than lose track of it
        rebind(Storage.dirName(path), Storage.baseName(path), item.place)
        return nil, "the trash could not be written"
    end
    return item
end

-- Move the drawing or notebook file at `path` to the trash. `nb` says whether
-- it is a notebook (for how it is listed). Returns the item, or nil, err.
function Trash.putDocument(root, path, nb)
    return putPath(root, path, { kind = "doc", name = Storage.stem(path), nb = nb and true or false })
end

-- Move the picture (a JPEG or PNG) at `path` to the trash.
function Trash.putPicture(root, path)
    local ext = (Storage.baseName(path):match("%.([^.]+)$") or "jpg"):lower()
    return putPath(root, path, { kind = "picture", name = Storage.stem(path), ext = ext })
end

-- Move the folder at `path`, with everything in it, to the trash.
function Trash.putFolder(root, path)
    return putPath(root, path, { kind = "folder", name = Storage.baseName(path) })
end

-- Move a book's annotations, Ink Away's file and pictures in the book's
-- KOReader folder `sidecar` (see ink/reader/bookink.lua), to the trash, in a
-- folder of their own. `info` is { name = the book's title, book = its file },
-- so they go back to the book wherever it is by then; `info.gone` says the book
-- itself was deleted. KOReader's own files stay.
-- Returns the item, or nil, err.
function Trash.putBookInk(root, sidecar, info)
    local BookInk = require("ink/reader/bookink")
    if not BookInk.exists(sidecar) then return nil, "not there" end
    if not Storage.ensureDir(dirOf(root)) then return nil, "no trash folder" end
    local data = load(root)
    local id = newId(root, data)
    local stored = Storage.join(dirOf(root), id)
    if not BookInk.transfer(sidecar, stored, false) then return nil, "it could not be moved" end
    local item = { id = id, kind = "bookink", from = sidecar, book = info and info.book,
        name = info and info.name or Storage.baseName(sidecar), when = Trash.now(),
        gone = info and info.gone or nil }   -- the book itself was deleted
    data.items[#data.items + 1] = item
    if not save(root, data) then
        BookInk.transfer(stored, sidecar, false)   -- back where it was rather than lose track of it
        return nil, "the trash could not be written"
    end
    return item
end

-- Keep page i of notebook `nb` (whose file is `nb_path`) in the trash, with the
-- pages either side of it, so it can go back between them. The caller then
-- removes it from the notebook. Returns the item, or nil, err.
function Trash.putPage(root, nb_path, nb, i)
    local page = nb.pages[i]
    if not page then return nil, "no such page" end
    if not Storage.ensureDir(dirOf(root)) then return nil, "no trash folder" end
    local data = load(root)
    local id = newId(root, data)
    local style = nb.pageTemplate and nb:pageTemplate(i).style or nil
    local ok, err = Storage.writeAtomic(Storage.join(dirOf(root), id .. ".page"), Project.encode({
        page = page, style = style, w = nb.w, h = nb.h, template = nb.template }))
    if not ok then return nil, err end
    local prev, nxt = nb.pages[i - 1], nb.pages[i + 1]
    local item = { id = id, kind = "page", from = nb_path, when = Trash.now(),
        name = page.title or "", notebook = Storage.stem(nb_path), page = i,
        prev = prev and prev.id, next = nxt and nxt.id, page_id = page.id }
    data.items[#data.items + 1] = item
    if not save(root, data) then
        os.remove(Storage.join(dirOf(root), id .. ".page"))
        return nil, "the trash could not be written"
    end
    return item
end

-- Where a page goes back in `nb`: after the page it followed, else before the
-- one it preceded, else at its old number.
function Trash.pageSlot(nb, item)
    for k, p in ipairs(nb.pages) do
        if item.prev and p.id == item.prev then return k + 1 end
    end
    for k, p in ipairs(nb.pages) do
        if item.next and p.id == item.next then return k end
    end
    return math.max(1, math.min(#nb.pages + 1, item.page or #nb.pages + 1))
end

-- The saved page of a page item: { page, style, w, h, template }, or nil.
function Trash.readPage(root, item)
    local f = io.open(Storage.join(dirOf(root), item.id .. ".page"), "rb")
    if not f then return nil end
    local data = Project.decode(f:read("*a"))
    f:close()
    return type(data) == "table" and type(data.page) == "table" and data or nil
end

local function drop(root, data, id)
    for k, it in ipairs(data.items) do
        if it.id == id then table.remove(data.items, k); break end
    end
    return save(root, data)
end

local function find(data, id)
    for _, it in ipairs(data.items) do if it.id == id then return it end end
end

-- Put item `id` back. A book's annotations go back to the book's folder (where
-- the book is now, when it is still there), joined with any made since. A file
-- or folder goes back to its path (a free name
-- next to it when that is taken), in its place in the binder. A page goes back
-- into its notebook through insert_page(nb_path, saved, item), which returns
-- whether it worked (the view does it, as the notebook may be open); a
-- notebook that is itself in the trash comes back first. Returns the path put
-- back (the notebook's for a page), or nil, err.
function Trash.restore(root, id, insert_page)
    local data = load(root)
    local item = find(data, id)
    if not item then return nil, "not in the trash" end
    if item.kind == "bookink" then
        local BookInk = require("ink/reader/bookink")
        local target = item.from
        if item.book and Storage.exists(item.book) then
            local ok, where = pcall(BookInk.locate, item.book)
            if ok and where and where.dir then target = where.dir end
        end
        if not BookInk.transfer(Storage.join(dirOf(root), item.id), target, false) then
            return nil, "the book's folder could not be written"
        end
        drop(root, data, id)
        return target
    end
    if item.kind == "page" then
        local saved = Trash.readPage(root, item)
        if not saved then return nil, "the page could not be read" end
        local nb_path = item.from
        if not Storage.exists(nb_path) then
            -- its notebook was deleted too: bring that back first
            for k = #data.items, 1, -1 do
                local it = data.items[k]
                if it.kind == "doc" and it.from == nb_path then
                    local back, err = Trash.restore(root, it.id)
                    if not back then return nil, err end
                    nb_path = back
                    break
                end
            end
        end
        if not insert_page(nb_path, saved, item) then return nil, "the page could not be put back" end
        os.remove(Storage.join(dirOf(root), item.id .. ".page"))
        drop(root, load(root), id)
        return nb_path
    end
    local dir = Storage.dirName(item.from)
    if not ensureDirs(dir, root) then return nil, "its folder could not be made" end
    local target = item.from
    if Storage.exists(target) then
        if item.kind == "doc" or item.kind == "picture" then
            target = Storage.uniquePath(dir, Storage.stem(item.from), item.kind == "doc" and Project.EXT or item.ext or "jpg")
        else
            local n = 2
            repeat
                target = Storage.join(dir, string.format("%s (%d)", Storage.baseName(item.from), n))
                n = n + 1
            until not Storage.exists(target)
        end
    end
    local stored = Storage.join(dirOf(root), item.id .. suffix(item))
    local ok, err = os.rename(stored, target)
    if not ok then return nil, err end
    rebind(dir, Storage.baseName(target), item.place)
    drop(root, data, id)
    return target
end

-- The PDF a notebook file at `path` is written over, when it is one sent to
-- the reader (see ink/view/receive.lua): read from the start of the file,
-- where its template is.
local function sentPdfOf(path)
    local app = Storage.appRootPath()
    if not app then return nil end
    local f = io.open(path, "rb")
    if not f then return nil end
    local head = f:read(256 * 1024) or ""
    f:close()
    local pdf = head:match('%["pdf_path"%]=("[^"\n]*")')
    pdf = pdf and pdf:sub(2, -2)
    local dir = Storage.join(app, "imported pdfs") .. "/"
    return pdf and pdf:sub(1, #dir) == dir and pdf or nil
end

-- The documents under `p` (a file or a folder, its hidden ones too), not
-- following links (a link to a folder above would never end) and at most a
-- dozen folders deep.
local function isLink(p)
    local ok, lfs = pcall(require, "libs/libkoreader-lfs")
    return ok and lfs and lfs.symlinkattributes and lfs.symlinkattributes(p, "mode") == "link"
end
local function eachDoc(p, fn, depth)
    depth = depth or 0
    if depth > 12 or isLink(p) then return end
    if Storage.isDir(p) then
        for _, e in ipairs(Storage.list(p)) do eachDoc(e.path, fn, depth + 1) end
    elseif p:match("%." .. Project.EXT .. "$") then
        fn(p)
    end
end

-- Delete the PDFs in `pdfs` (sent to the reader) that no document in the
-- library or the trash still uses.
local function releasePdfs(root, pdfs)
    if not next(pdfs) then return end
    eachDoc(root, function(doc)
        local pdf = sentPdfOf(doc)
        if pdf then pdfs[pdf] = nil end
    end)
    for pdf in pairs(pdfs) do os.remove(pdf) end
end

-- Delete item `id` for good. A PDF sent to the reader goes with the last
-- notebook written over it.
function Trash.forget(root, id)
    local data = load(root)
    local item = find(data, id)
    if not item then return false end
    local base = Storage.join(dirOf(root), item.id)
    local pdfs = {}
    local function note(doc) local pdf = sentPdfOf(doc); if pdf then pdfs[pdf] = true end end
    if item.kind == "doc" then
        note(base .. "." .. Project.EXT)
        os.remove(base .. "." .. Project.EXT)
    elseif item.kind == "page" then
        os.remove(base .. ".page")
    elseif item.kind == "picture" then
        os.remove(base .. suffix(item))
    else
        eachDoc(base, note)
        Storage.removeTree(base)
    end
    local done = drop(root, data, id)
    pcall(releasePdfs, root, pdfs)
    return done
end

-- Delete everything in the trash for good.
function Trash.empty(root)
    for _, it in ipairs(Trash.list(root)) do Trash.forget(root, it.id) end
end

-- Delete for good what has been in the trash longer than KEEP_DAYS. Returns
-- how many went.
function Trash.purge(root)
    local limit = Trash.now() - Trash.KEEP_DAYS * 86400
    local n = 0
    for _, it in ipairs(Trash.list(root)) do
        if (tonumber(it.when) or 0) < limit then
            Trash.forget(root, it.id)
            n = n + 1
        end
    end
    return n
end

return Trash

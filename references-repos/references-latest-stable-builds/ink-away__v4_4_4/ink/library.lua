--[[
The library: the folder drawings and notebooks are kept in, the names new ones
get, and bringing the single "last session" file of older versions into it.
Plain Lua, so the headless tests drive it.
]]

local Folder = require("ink/folder")
local Project = require("ink/project")
local Storage = require("ink/storage")

local Library = {}

-- The clock new names are dated with (replaced in the tests).
Library.now = os.time

-- The library folder: `chosen` when it still exists, else "ink away" in
-- KOReader's data folder, else KOReader's settings folder.
function Library.root(chosen)
    if chosen and Storage.isDir(chosen) then return chosen end
    return Storage.appRoot() or Storage.settingsDir()
end

-- Folders in the "ink away" folder that hold Ink Away's own files (exports and
-- downloaded pictures) rather than documents. The library leaves them out.
Library.INTERNAL = { drawings = true, notebooks = true, exports = true,
    ["online images"] = true, ["processed images"] = true,
    ["imported pdfs"] = true, ["imported images"] = true }   -- (sent from a phone, see ink/view/receive.lua)

-- Is `name` a document file?
function Library.isDocument(name)
    return name:lower():match("%." .. Project.EXT .. "$") ~= nil
end

-- Is the document at `path` a notebook? Only the start of the file is read: a
-- notebook lists its pages before any ink, a drawing starts its ops early, and
-- neither key can hide in a string (their quotes would be escaped).
function Library.isNotebookFile(path)
    local f = io.open(path, "rb") or io.open(path .. ".tmp", "rb")
    if not f then return false end
    local seen = ""
    while true do
        local chunk = f:read(4096)
        if not chunk then break end
        seen = seen:sub(-12) .. chunk
        local p, o = seen:find('["pages"]={', 1, true), seen:find('["ops"]={', 1, true)
        if p or o then
            f:close()
            return p ~= nil and (o == nil or p < o)
        end
    end
    f:close()
    return false
end

-- Is `name` a picture the library shows (a JPEG or PNG)?
function Library.isPicture(name)
    local ext = tostring(name):match("%.([^.]+)$")
    ext = ext and ext:lower()
    return ext == "jpg" or ext == "jpeg" or ext == "png"
end

-- What is in library folder `dir`: its subfolders, documents and pictures,
-- without hidden entries (and, at `root`, without the internal folders).
-- Folders come by name, documents and pictures by `sort`: "name", or most
-- recently changed first. Returns folders, documents, pictures; each entry is
-- { name, path, mtime }.
function Library.list(dir, root, sort)
    local folders, docs, pics = {}, {}, {}
    for _, e in ipairs(Storage.list(dir)) do
        if e.name:sub(1, 1) ~= "." then
            if e.mode == "directory" then
                if not (dir == root and Library.INTERNAL[e.name]) then folders[#folders + 1] = e end
            elseif e.mode == "file" and Library.isDocument(e.name) then
                docs[#docs + 1] = e
            elseif e.mode == "file" and Library.isPicture(e.name) then
                pics[#pics + 1] = e
            end
        end
    end
    local function byName(a, b) return a.name:lower() < b.name:lower() end
    local function byDate(a, b)
        if a.mtime ~= b.mtime then return (a.mtime or 0) > (b.mtime or 0) end
        return byName(a, b)
    end
    table.sort(folders, byName)
    table.sort(docs, sort == "name" and byName or byDate)
    table.sort(pics, sort == "name" and byName or byDate)
    return folders, docs, pics
end

-- Move the file or folder at `path` into folder `dir`, under a free name.
-- Returns the new path, or nil, err.
function Library.move(path, dir)
    if Storage.dirName(path) == dir then return path end
    if Storage.within(dir, path) then return nil, "a folder cannot go inside itself" end
    local base = Storage.baseName(path)
    local target
    if Storage.isDir(path) then
        target = Storage.join(dir, base)
        local n = 2
        while Storage.exists(target) do target = Storage.join(dir, string.format("%s (%d)", base, n)); n = n + 1 end
    else
        -- a file keeps its own kind: a picture stays a .jpg or .png
        local ext = Storage.baseName(path):match("%.([^.]+)$") or Project.EXT
        target = Storage.uniquePath(dir, Storage.stem(path), ext)
    end
    local ok, err = os.rename(path, target)
    if not ok then return nil, err end
    return target
end

-- Copy the document at `path` next to it under a free name. Returns the new
-- path, or nil, err.
function Library.duplicate(path, dir)
    local target = Storage.uniquePath(dir or Storage.dirName(path), Storage.stem(path), Project.EXT)
    local ok, err = Storage.copyFile(path, target)
    if not ok then return nil, err end
    return target
end

-- A short, stable code for a path (FNV-1a), used to name its cached thumbnail.
function Library.pathCode(path)
    local h = bit.tobit(2166136261)
    for i = 1, #path do
        h = bit.bxor(h, path:byte(i))
        h = bit.tobit(bit.lshift(h, 24) + h * 403)   -- h * 16777619, kept to 32 bits
    end
    return bit.tohex(h)
end

-- The cached thumbnail file name for a document: its path code, when it last
-- changed and the thumbnail size, so any change to the file makes a new one.
function Library.thumbName(path, mtime, w, h)
    return string.format("%s-%d-%dx%d.png", Library.pathCode(path), mtime or 0, w, h)
end

-- The name a new document gets: its kind and when it was started, e.g.
-- "Notebook 2026-10-03 14.22" (no colon, which some readers' file systems refuse).
function Library.defaultName(label)
    return label .. " " .. os.date("%Y-%m-%d %H.%M", Library.now())
end

-- Is the parsed project worth keeping: any ink, more than one page, or pages
-- over an imported PDF?
function Library.hasContent(data)
    if type(data) ~= "table" then return false end
    if type(data.ops) == "table" then return #data.ops > 0 or data.bg ~= nil end
    if type(data.pages) ~= "table" then return false end
    if #data.pages > 1 or (data.template and data.template.pdf_path) then return true end
    local p = data.pages[1]
    local ops = type(p) == "table" and (p.ops or (p.src == nil and p.id == nil and p)) or nil
    return type(ops) == "table" and #ops > 0
end

-- The folders earlier versions kept editable drawings and notebooks in, apart,
-- in the "ink away" folder.
Library.LEGACY = { "drawing projects", "notebook projects" }

-- Bring what the earlier versions' project folders hold into the library folder
-- `root`, which sits beside them, so drawings and notebooks are no longer kept
-- apart. Files and folders are only renamed, never copied or rewritten, and
-- never replace anything: a name already taken gets a number. Tab order and
-- colours come along. A project folder is removed once nothing is left in it
-- but the hidden binder file; one that still holds something else stays, as an
-- ordinary folder. Returns the moves as { old = path, new = path } entries.
function Library.mergeLegacy(root)
    local moves = {}
    for _, name in ipairs(Library.LEGACY) do
        local dir = Storage.join(root, name)
        if Storage.isDir(dir) then
            local data = Folder.load(dir)
            local folders, docs = Library.list(dir, nil, "name")
            local renamed = {}
            for _, e in ipairs(folders) do
                local new = Library.move(e.path, root)
                if new then moves[#moves + 1] = { old = e.path, new = new } end
            end
            for _, d in ipairs(Folder.arrange(data, docs)) do
                local new = Library.move(d.path, root)
                if new then
                    moves[#moves + 1] = { old = d.path, new = new }
                    renamed[#renamed + 1] = { old = d.name, new = Storage.baseName(new) }
                end
            end
            if #renamed > 0 then
                Folder.update(root, function(top)
                    for _, r in ipairs(renamed) do
                        Folder.add(top, r.new)
                        if data.colors[r.old] ~= nil then top.colors[r.new] = data.colors[r.old] end
                    end
                end)
            end
            local left = Storage.list(dir)
            if #left == 1 and left[1].name == Folder.FILE then os.remove(left[1].path); left = {} end
            if #left == 0 then Storage.removeTree(dir) end
        end
    end
    return moves
end

-- Move an old session file into `dir` as a document named `name`. Returns the
-- new path, or nil when there was nothing worth keeping. The old file is
-- removed once its content is safe in the library.
function Library.adoptSession(session_path, dir, name)
    local f = io.open(session_path, "rb")
    if not f then return nil end
    local raw = f:read("*a")
    f:close()
    if not Library.hasContent(Project.deserialize(raw)) then
        os.remove(session_path)
        return nil
    end
    local path = Storage.uniquePath(dir, name, Project.EXT)
    if not Storage.writeAtomic(path, raw) then return nil end
    os.remove(session_path)
    return path
end

return Library

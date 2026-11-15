--[[
What the cloud sync can carry, in parts the person turns on and off one by one
(see ink/sync/). Each part is an "area": a set of files on this reader and the
place they have in the cloud.

    notebooks   the library, except book notes        the cloud's top level
    booknotes   the library's "Book notes" folder     the cloud's top level (the
                                                      same place: turning it off
                                                      moves nothing)
    bookink     what is drawn on book pages           .areas/books/<book>/
    imports     imported PDFs and pictures            .areas/imports/...
    settings    pens, colours and preferences         .areas/settings/
    exports     what was exported                     .areas/exports/
    clips       screen clips                          .areas/clips/, .areas/clipped/

The files the notebooks use outside the library are kept in ".attachments" and
follow the notebooks and book notes. A part that is off is left alone on both
sides: nothing is sent, fetched or deleted for it, and turning it on again picks
up from where things stood.

Plain Lua (the settings and the folders are passed in), so the headless tests
drive it.
]]

local _ = require("ink/l10n")
local Storage = require("ink/storage")
local BookIndex = require("ink/sync/bookindex")

local Areas = {}

Areas.SETTING = "inkaway_sync_area_"
Areas.PREFIX = ".areas"
Areas.BOOKNOTES_SETTING = "inkaway_booknotes_folder"
Areas.BOOKNOTES_FOLDER = "Book notes"

-- The parts, in the order they are shown.
Areas.DEFS = {
    { id = "notebooks", label = _("Notebooks and drawings"), default = true,
      hint = _("Everything in your library except the notes kept for books.") },
    { id = "booknotes", label = _("Book notes"), default = true,
      hint = _("The notebook kept for each book you read.") },
    { id = "bookink", label = _("Ink on book pages"), default = false,
      hint = _("What you draw or write on the pages of a book. KOReader's own highlights are not included.") },
    { id = "imports", label = _("Imported PDFs and pictures"), default = false,
      hint = _("The PDFs and pictures you brought into Ink Away.") },
    { id = "exports", label = _("Exports"), default = false,
      hint = _("PDFs and pictures made from your notebooks.") },
    { id = "clips", label = _("Screen clips"), default = false,
      hint = _("Pictures taken of part of a page.") },
    { id = "settings", label = _("Pens, colours and preferences"), default = false,
      hint = _("Your pens, colours, paper, text and snapping choices. Not the folders, screen or pen settings that belong to one reader.") },
}

local BY_ID = {}
for _i, d in ipairs(Areas.DEFS) do BY_ID[d.id] = d end

-- Is part `id` on? `get(key)` reads a setting.
function Areas.enabled(id, get)
    local d = BY_ID[id]
    if not d then return false end
    local v = get and get(Areas.SETTING .. id)
    if v == nil then return d.default end
    return v == true
end

-- Turn part `id` on or off. `set(key, value)` writes a setting.
function Areas.setEnabled(id, on, set)
    if BY_ID[id] then set(Areas.SETTING .. id, on and true or false) end
end

-- A relative path under a folder of the cloud's "areas", or nil.
local function under(rel, prefix)
    if rel == prefix then return "" end
    if rel:sub(1, #prefix + 1) == prefix .. "/" then return rel:sub(#prefix + 2) end
end

-- The sidecar files of a book that belong to its ink (and nothing else of KOReader's).
local function bookFile(rest)
    if rest == "inkaway.lua" then return true end
    if rest:match("^inkaway%-book%-[^/]+%.txt$") then return true end   -- the book's name (see BookIndex.mark)
    local pic = rest:match("^inkaway%-pictures/([^/]+)$")
    return pic ~= nil and pic ~= "." and pic ~= ".."
end

-- Combine two versions of a file of a book. Only the ink file is really merged; any
-- other (a picture, the book's name) is kept as this reader has it, which is what
-- the other reader's copy is or becomes.
local function mergeBookFile(merge)
    return function(first, second)
        if first:match("inkaway%.lua$") then return merge(first, second) end
        local f = io.open(first, "rb")
        if not f then return nil end
        local text = f:read("*a")
        f:close()
        return text
    end
end

-- Build the areas for a run. `env`: get (settings), root (the library folder),
-- appPath(name) (a folder of Ink Away's, as a path, made or not), books() (the books
-- the sync knows: { [md5] = { dir } }), merge(local_path, remote_path) (for book
-- ink). Returns the list the engine takes (see ink/sync/engine.lua, `ctx.areas`).
function Areas.build(env)
    local get = env.get
    local function on(id) return Areas.enabled(id, get) end
    local root = env.root:gsub("/+$", "")
    local function lib(rel) return Storage.join(root, rel) end

    local bn = get and get(Areas.BOOKNOTES_SETTING)
    if type(bn) ~= "string" or bn == "" then bn = Areas.BOOKNOTES_FOLDER end
    local function inBookNotes(rel) return under(rel, bn) ~= nil end
    local function isArea(rel) return under(rel, Areas.PREFIX) ~= nil end

    local list = {}

    -- a part that is a folder (or two) of Ink Away's own, as they are
    local function folders(id, dirs)
        local a = { id = id, prefix = Areas.PREFIX }
        function a.enabled() return on(id) end
        function a.owns(rel)
            for _i, d in ipairs(dirs) do if under(rel, d.prefix) then return true end end
            return false
        end
        function a.locate(rel)
            for _i, d in ipairs(dirs) do
                local rest = under(rel, d.prefix)
                if rest and rest ~= "" then return Storage.join(env.appPath(d.dir), rest) end
            end
        end
        -- every file in the folders: { [lower key] = rel }
        function a.walk(add)
            for _i, d in ipairs(dirs) do
                local base = env.appPath(d.dir)
                local function go(dir, prefix, depth)
                    if depth > 8 then return end
                    for _j, e in ipairs(Storage.list(dir)) do
                        if e.mode == "directory" then
                            if e.name:sub(1, 1) ~= "." then go(e.path, prefix .. e.name .. "/", depth + 1) end
                        elseif e.mode == "file" and e.name:sub(1, 1) ~= "." then
                            add(d.prefix .. "/" .. prefix .. e.name, e.path, e.mtime)
                        end
                    end
                end
                go(base, "", 0)
            end
        end
        list[#list + 1] = a
    end

    folders("exports", { { prefix = Areas.PREFIX .. "/exports", dir = "exports" } })
    folders("imports", {
        { prefix = Areas.PREFIX .. "/imports/pdfs", dir = "imported pdfs" },
        { prefix = Areas.PREFIX .. "/imports/processed", dir = "processed images" },
        { prefix = Areas.PREFIX .. "/imports/online", dir = "online images" },
    })
    folders("clips", {
        { prefix = Areas.PREFIX .. "/clips", dir = "screen clips" },
        { prefix = Areas.PREFIX .. "/clipped", dir = "clipped images" },
    })

    -- what is drawn on book pages: one folder per book, named by its checksum
    do
        local books = Areas.PREFIX .. "/books"
        local a = { id = "bookink", prefix = Areas.PREFIX, merge = env.merge and mergeBookFile(env.merge) }
        function a.enabled() return on("bookink") end
        function a.owns(rel) return under(rel, books) ~= nil end
        function a.locate(rel)
            local rest = under(rel, books)
            local md5, file = (rest or ""):match("^(%x+)/(.+)$")
            local book = md5 and env.books and env.books()[md5]
            if book and book.dir and bookFile(file) then return Storage.join(book.dir, file) end
        end
        function a.walk(add)
            for md5, book in pairs(env.books and env.books() or {}) do
                if book.dir then
                    local ink = Storage.join(book.dir, "inkaway.lua")
                    if Storage.exists(ink) then
                        add(books .. "/" .. md5 .. "/inkaway.lua", ink, Storage.mtime(ink) or 0)
                        BookIndex.mark(book.dir, book.file)
                        for _i, e in ipairs(Storage.list(book.dir)) do
                            if e.mode == "file" and bookFile(e.name) and e.name ~= "inkaway.lua" then
                                add(books .. "/" .. md5 .. "/" .. e.name, e.path, e.mtime)
                            end
                        end
                    end
                    for _i, e in ipairs(Storage.list(Storage.join(book.dir, "inkaway-pictures"))) do
                        if e.mode == "file" then add(books .. "/" .. md5 .. "/inkaway-pictures/" .. e.name, e.path, e.mtime) end
                    end
                end
            end
        end
        list[#list + 1] = a
    end

    -- the preferences: one small file, made from the settings before a run
    do
        local rel = Areas.PREFIX .. "/settings/preferences.json"
        local a = { id = "settings", prefix = Areas.PREFIX, merge = env.mergePrefs }
        function a.enabled() return on("settings") and env.prefsPath ~= nil end
        function a.owns(r) return under(r, Areas.PREFIX .. "/settings") ~= nil end
        function a.locate(r) if r == rel then return env.prefsPath end end
        function a.walk(add)
            if env.prefsPath and Storage.exists(env.prefsPath) then add(rel, env.prefsPath, Storage.mtime(env.prefsPath) or 0) end
        end
        list[#list + 1] = a
    end

    -- the files notebooks use outside the library follow the notebooks
    list[#list + 1] = { id = "attach", enabled = function() return on("notebooks") or on("booknotes") end,
        owns = function(rel) return under(rel, ".attachments") ~= nil end, locate = lib }
    list[#list + 1] = { id = "booknotes", enabled = function() return on("booknotes") end, library = true,
        owns = function(rel) return inBookNotes(rel) and not isArea(rel) end, locate = lib }
    -- everything else in the library
    list[#list + 1] = { id = "notebooks", enabled = function() return on("notebooks") end, library = true,
        owns = function() return true end, locate = lib }
    return list
end

return Areas

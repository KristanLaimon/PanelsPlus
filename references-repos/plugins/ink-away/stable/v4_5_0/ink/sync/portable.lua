--[[
Finding a notebook's pictures and PDF on a reader other than the one that made
it. A notebook keeps full paths ("/mnt/us/koreader/ink away/Images/a.png"); on
another reader the same file lives under another root, or was brought along by
the cloud sync into the folder ".attachments" of the library (see
ink/sync/engine.lua). A path that exists is always used as it is. Only a path
that does not exist is looked for again: by its end under the library folder
("Images/a.png"), longest ending first, and then among the attachments. If
nothing is found the path is left as it was, so nothing changes where it
already worked. The notebook's file is never rewritten.

Plain Lua (the library folder and the existence check are passed in).
]]

local Hash = nil

local Portable = {}

Portable.ATTACH = ".attachments"
Portable.root = nil   -- set by Ink Away at start: function() return the library folder end

local function exists(path)
    local f = io.open(path, "rb")
    if f then f:close(); return true end
    return false
end

local function parts(path)
    local t = {}
    for p in path:gmatch("[^/]+") do t[#t + 1] = p end
    return t
end

-- The folder name a file outside the library gets among the attachments, from
-- the path it had: the same path always gives the same name, on every reader.
function Portable.attachId(path)
    Hash = Hash or require("ink/sync/hash")
    return Hash.sha256(path):sub(1, 20)
end

-- Where the sync keeps the copy of the file `path` (relative to the library folder).
function Portable.attachRel(path)
    local name = path:match("([^/]+)$") or "file"
    return Portable.ATTACH .. "/" .. Portable.attachId(path) .. "/" .. name
end

-- The path to use on this reader for the stored `path`: itself if it exists,
-- else the same file under `root` or among its attachments, else itself.
-- `has(path)` says whether a file exists (the default reads the disk).
function Portable.resolve(path, root, has)
    if type(path) ~= "string" or path == "" or not root then return path end
    has = has or exists
    if has(path) then return path end
    local p = parts(path)
    for i = 2, #p do
        local tail = table.concat(p, "/", i)
        if i == #p then break end        -- the bare name alone is too loose a match
        local cand = root .. "/" .. tail
        if has(cand) then return cand end
    end
    local cand = root .. "/" .. Portable.attachRel(path)
    if has(cand) then return cand end
    return path
end

local ONE = { "bg" }

-- Point the pictures, background and PDF of a notebook just read (`data`, as
-- Project.deserialize gives it) at the files of this reader. Only paths that do
-- not exist change, in the table in memory.
function Portable.apply(data, root, has)
    if type(data) ~= "table" or not root then return data end
    local cache = {}
    local function fix(path)
        if type(path) ~= "string" then return path end
        local r = cache[path]
        if r == nil then r = Portable.resolve(path, root, has); cache[path] = r end
        return r
    end
    local function ops(list)
        if type(list) ~= "table" then return end
        for _i, op in ipairs(list) do
            if type(op) == "table" and op.kind == "image" then
                op.path = fix(op.path)
                if op.src_path then op.src_path = fix(op.src_path) end
            end
        end
    end
    ops(data.ops)
    if type(data.pages) == "table" then
        for _i, page in ipairs(data.pages) do
            if type(page) == "table" then ops(page.ops) end
        end
    end
    for _i, k in ipairs(ONE) do if data[k] then data[k] = fix(data[k]) end end
    if type(data.template) == "table" and data.template.pdf_path then
        data.template.pdf_path = fix(data.template.pdf_path)
    end
    return data
end

return Portable

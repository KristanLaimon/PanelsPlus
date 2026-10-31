--[[
A library folder seen as a binder: its documents in the order the reader gave
them, each with a tab colour (and, for a notebook on a Bookshelf shelf, the
cover it was given there). Kept in a small hidden file in the folder, read in
a sandbox like a project. A new document joins the end when it is first saved;
documents the file does not know (copied in from a computer) come after the
known ones, oldest first, and are remembered from then on.
Plain Lua, so the headless tests drive it.
]]

local Project = require("ink/project")
local Storage = require("ink/storage")

local Folder = {}

Folder.FILE = ".inkaway-folder"

-- The folder's binder data: { order = { file names }, colors = { name = {r,g,b} },
-- covers = { name = { style, color = {r,g,b} } }, folders = { subfolder name =
-- { color = key, icon = id } } } (a subfolder's look in the library, see
-- ink/folderlook.lua).
function Folder.load(dir)
    local f = io.open(Storage.join(dir, Folder.FILE), "rb")
    local data
    if f then
        data = Project.decode(f:read("*a"))
        f:close()
    end
    if type(data) ~= "table" then data = {} end
    if type(data.order) ~= "table" then data.order = {} end
    if type(data.colors) ~= "table" then data.colors = {} end
    if type(data.covers) ~= "table" then data.covers = {} end
    if type(data.folders) ~= "table" then data.folders = {} end
    return data
end

function Folder.save(dir, data)
    return Storage.writeAtomic(Storage.join(dir, Folder.FILE), Project.encode(data))
end

-- The documents `docs` (entries with name and mtime) in binder order: the known
-- ones as ordered, then the rest oldest first.
function Folder.arrange(data, docs)
    local by_name, rank = {}, {}
    for _, d in ipairs(docs) do by_name[d.name] = d end
    local out = {}
    for _, name in ipairs(data.order) do
        if by_name[name] and not rank[name] then
            out[#out + 1] = by_name[name]
            rank[name] = #out
        end
    end
    local rest = {}
    for _, d in ipairs(docs) do if not rank[d.name] then rest[#rest + 1] = d end end
    table.sort(rest, function(a, b)
        if a.mtime ~= b.mtime then return a.mtime < b.mtime end
        return a.name:lower() < b.name:lower()
    end)
    for _, d in ipairs(rest) do out[#out + 1] = d end
    return out
end

-- Remember `arranged` (entries in their shown order) as the binder order.
function Folder.setOrder(data, arranged)
    local order = {}
    for i, d in ipairs(arranged) do order[i] = d.name end
    data.order = order
end

-- Move the document `name` one place up (-1) or down (+1) among `arranged`,
-- trading places with the next one for which counts(d) is true (any, when not
-- given): the tabs skip the drawings in between, which keep their places.
-- Returns whether it moved.
function Folder.move(data, arranged, name, delta, counts)
    local i
    for k, d in ipairs(arranged) do if d.name == name then i = k end end
    local j = i and i + delta
    while j and arranged[j] and counts and not counts(arranged[j]) do j = j + delta end
    if not j or j < 1 or j > #arranged then return false end
    arranged[i], arranged[j] = arranged[j], arranged[i]
    Folder.setOrder(data, arranged)
    return true
end

-- Add the document `name` at the end, unless it is already there.
function Folder.add(data, name)
    for _, n in ipairs(data.order) do if n == name then return end end
    data.order[#data.order + 1] = name
end

-- A document or subfolder was renamed from `old` to `new`: keep its place,
-- colour, cover and look.
function Folder.rename(data, old, new)
    for i, name in ipairs(data.order) do if name == old then data.order[i] = new end end
    local c = data.colors[old]
    if c ~= nil then data.colors[new], data.colors[old] = c, nil end
    local cv = data.covers and data.covers[old]
    if cv ~= nil then data.covers[new], data.covers[old] = cv, nil end
    local lk = data.folders and data.folders[old]
    if lk ~= nil then data.folders[new], data.folders[old] = lk, nil end
end

-- Does `data` know every document in `arranged`, and nothing else?
function Folder.knows(data, arranged)
    if #data.order ~= #arranged then return false end
    for i, d in ipairs(arranged) do if data.order[i] ~= d.name then return false end end
    return true
end

-- Load folder `dir`'s binder data, let fn change it, and save it.
function Folder.update(dir, fn)
    local data = Folder.load(dir)
    fn(data)
    return Folder.save(dir, data)
end

-- A document left the folder: forget it.
function Folder.forget(data, name)
    for i = #data.order, 1, -1 do if data.order[i] == name then table.remove(data.order, i) end end
    data.colors[name] = nil
    if data.covers then data.covers[name] = nil end
    if data.folders then data.folders[name] = nil end
end

return Folder

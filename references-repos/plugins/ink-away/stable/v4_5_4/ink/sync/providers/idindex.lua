--[[
The map of a cloud folder by ids, for the services that name files by id and not
by path (Google Drive, OneDrive): each item's name and parent, so a path such as
"Notebooks/Maths.inkaway" and an id can be turned into each other. It is kept in
a file between runs, together with the cursor of the changes it is up to date
with, so a change that only says "this id was removed" can still be turned into
the path it had. Plain Lua (the file's place is passed in), so the headless
tests drive it.
]]

local Json = require("ink/sync/json")

local Index = {}
Index.__index = Index

-- The index kept in `path` (empty if missing or damaged), for the folder `root`.
function Index.load(path, root)
    local self = setmetatable({ path = path, root = root, map = {}, cursor = nil }, Index)
    local f = path and io.open(path, "rb")
    if f then
        local t = Json.decode(f:read("*a") or "")
        f:close()
        if type(t) == "table" and t.root == root and type(t.map) == "table" then
            self.map, self.cursor = t.map, t.cursor
        end
    end
    return self
end

-- Keep it.
function Index:save()
    if not self.path then return true end
    local tmp = self.path .. ".tmp"
    local f = io.open(tmp, "wb")
    if not f then return false end
    f:write(Json.encode({ root = self.root, map = self.map, cursor = self.cursor }))
    f:close()
    return os.rename(tmp, self.path) and true or false
end

-- Forget everything (before a full listing).
function Index:clear()
    self.map, self.cursor = {}, nil
end

-- Note an item: name, parent id, whether it is a folder.
function Index:put(id, name, parent, folder)
    self.map[id] = { name = name, parent = parent, folder = folder and true or nil }
end

function Index:remove(id) self.map[id] = nil end
function Index:get(id) return self.map[id] end

-- The path of `id` below the root folder, or nil if it is not in it (or the chain
-- is not known).
function Index:relOf(id)
    local parts, seen = {}, {}
    local cur = id
    while cur and cur ~= self.root do
        local e = self.map[cur]
        if not e or seen[cur] then return nil end
        seen[cur] = true
        table.insert(parts, 1, e.name)
        cur = e.parent
    end
    if cur ~= self.root or #parts == 0 then return nil end
    return table.concat(parts, "/")
end

-- The id at path `rel` (a file or a folder), or nil. Of two with one name (the
-- service allows that) the one that sorts first by id, so every run picks the same.
function Index:idOf(rel)
    local want = {}
    for part in rel:gmatch("[^/]+") do want[#want + 1] = part end
    local parent = self.root
    for i, name in ipairs(want) do
        local found
        for id, e in pairs(self.map) do
            if e.parent == parent and e.name == name and (i < #want and e.folder or i == #want) then
                if not found or id < found then found = id end
            end
        end
        if not found then return nil end
        parent = found
    end
    return parent ~= self.root and parent or nil
end

return Index

--[[
Files and folders: small helpers for the paths Ink Away saves to.
]]

local Storage = {}

local function getLfs()
    local ok, m = pcall(require, "libs/libkoreader-lfs")
    return ok and m or nil
end

local function getDataStorage()
    local ok, m = pcall(require, "datastorage")
    return ok and m or nil
end

-- Return `p` if it is an existing directory, else nil. Without lfs (outside
-- KOReader) any path is taken as it is.
function Storage.existingDir(p)
    if not p then return nil end
    local fs = getLfs()
    if not fs or fs.attributes(p, "mode") == "directory" then return p end
    return nil
end

-- Is `p` an existing directory?
function Storage.isDir(p)
    local fs = getLfs()
    return fs ~= nil and p ~= nil and fs.attributes(p, "mode") == "directory"
end

-- Is there a file or folder at `p`? Without lfs, only files are seen.
function Storage.exists(p)
    if not p then return false end
    local fs = getLfs()
    if fs then return fs.attributes(p, "mode") ~= nil end
    local f = io.open(p, "rb")
    if f then f:close(); return true end
    return false
end

-- Make the directory `p` if it is missing. Returns whether it exists now.
function Storage.ensureDir(p)
    local fs = getLfs()
    if not fs then return false end
    if fs.attributes(p, "mode") ~= "directory" then pcall(fs.mkdir, p) end
    return fs.attributes(p, "mode") == "directory"
end

-- KOReader's data folder, or nil outside KOReader.
function Storage.dataDir()
    local ds = getDataStorage()
    return ds and ds:getDataDir() or nil
end

-- KOReader's settings folder, or /tmp outside KOReader.
function Storage.settingsDir()
    local ds = getDataStorage()
    return (ds and ds:getSettingsDir()) or "/tmp"
end

-- Where the "ink away" folder is in KOReader's data folder (it may not exist
-- yet), or nil outside KOReader.
function Storage.appRootPath()
    local data = Storage.dataDir()
    return data and data .. "/ink away" or nil
end

-- The "ink away" folder in KOReader's data folder, made if missing, or nil when
-- it can't be made.
function Storage.appRoot()
    local dir = Storage.appRootPath()
    if not dir then return nil end
    return Storage.ensureDir(dir) and dir or nil
end

-- A folder under "ink away", made if missing, or nil when it can't be made.
function Storage.appDir(name)
    local root = Storage.appRoot()
    if not root then return nil end
    local dir = root .. "/" .. name
    return Storage.ensureDir(dir) and dir or nil
end

-- KOReader's cache folder for Ink Away (made if missing), or the settings
-- folder outside KOReader.
function Storage.cacheDir()
    local data = Storage.dataDir()
    if not data then
        -- (outside KOReader, the tests: a folder of its own, never all of /tmp)
        local dir = Storage.settingsDir() .. "/inkaway-cache"
        return Storage.ensureDir(dir) and dir or Storage.settingsDir()
    end
    local dir = data .. "/cache/inkaway"
    Storage.ensureDir(data .. "/cache")
    return Storage.ensureDir(dir) and dir or Storage.settingsDir()
end

-- The entries of folder `dir`, without "." and "..": a list of { name, path,
-- mode = "file"|"directory", mtime }. Empty when it cannot be read.
function Storage.list(dir)
    local fs = getLfs()
    local out = {}
    if not fs then return out end
    local ok, iter, state = pcall(fs.dir, dir)
    if not ok then return out end
    for name in iter, state do
        if name ~= "." and name ~= ".." then
            local path = Storage.join(dir, name)
            local attr = fs.attributes(path)
            if attr then
                out[#out + 1] = { name = name, path = path, mode = attr.mode, mtime = attr.modification or 0,
                    size = attr.size or 0 }
            end
        end
    end
    return out
end

-- The size of the file at `p` in bytes, or nil.
function Storage.size(p)
    local fs = getLfs()
    if fs then return fs.attributes(p, "size") end
    local f = io.open(p, "rb")
    if not f then return nil end
    local n = f:seek("end")
    f:close()
    return n
end

-- When the file or folder at `p` last changed, or nil.
function Storage.mtime(p)
    local fs = getLfs()
    return fs and p and fs.attributes(p, "modification") or nil
end

-- Copy the file `src` to `dst` (written safely). Returns ok, err.
function Storage.copyFile(src, dst)
    local f, err = io.open(src, "rb")
    if not f then return false, err end
    local data = f:read("*a")
    f:close()
    return Storage.writeAtomic(dst, data)
end

-- Delete the file or folder at `p`, a folder with everything in it. Returns
-- whether it is gone.
function Storage.removeTree(p)
    local fs = getLfs()
    if fs and fs.attributes(p, "mode") == "directory" then
        for _, e in ipairs(Storage.list(p)) do Storage.removeTree(e.path) end
        pcall(fs.rmdir, p)
    else
        os.remove(p)
    end
    return not Storage.exists(p)
end

-- A path as the reader sees it: relative to KOReader's data folder when it is
-- inside it ("ink away/exports"), else as it is.
function Storage.shortPath(path)
    local data = Storage.dataDir()
    if data and Storage.within(path, data) and path ~= data then return path:sub(#data:gsub("/+$", "") + 2) end
    return path
end

-- Is `path` the folder `dir` or inside it?
function Storage.within(path, dir)
    if not (path and dir) then return false end
    dir = dir:gsub("/+$", "")
    return path == dir or path:sub(1, #dir + 1) == dir .. "/"
end

-- `dir` and `name` joined with a single slash.
function Storage.join(dir, name)
    return dir .. ((dir:sub(-1) == "/") and "" or "/") .. name
end

-- The folder part of a path, without the trailing slash.
function Storage.dirName(path)
    return path:match("^(.*)/[^/]*$") or "."
end

-- The last part of a path.
function Storage.baseName(path)
    return path:match("([^/]+)/*$") or path
end

-- The file name without its extension.
function Storage.stem(path)
    local base = Storage.baseName(path)
    return base:match("^(.+)%.[^.]+$") or base
end

-- A file name from what was typed: path separators replaced, and ".ext" added
-- unless it is already there.
function Storage.fileName(name, ext)
    name = name:gsub("[/\\]", "_")
    if not name:lower():match("%." .. ext .. "$") then name = name .. "." .. ext end
    return name
end

-- A path in `dir` for `base`.`ext` that nothing uses yet: "base.ext", else
-- "base (2).ext", "base (3).ext" and so on.
function Storage.uniquePath(dir, base, ext)
    base = base:gsub("[/\\]", "_")
    local path = Storage.join(dir, base .. "." .. ext)
    local n = 2
    while Storage.exists(path) do
        path = Storage.join(dir, string.format("%s (%d).%s", base, n, ext))
        n = n + 1
    end
    return path
end

-- Write `s` to `path` without ever leaving a half-written file: it goes to a
-- temporary file first, which is synced and then renamed over the old one.
-- Returns ok, err.
function Storage.writeAtomic(path, s)
    local tmp = path .. ".tmp"
    local f, err = io.open(tmp, "wb")
    if not f then return false, err end
    local wrote, werr = f:write(s)
    if wrote then
        local uok, util = pcall(require, "ffi/util")
        if uok and util and util.fsyncOpenedFile then pcall(util.fsyncOpenedFile, f) end
    end
    f:close()
    if not wrote then os.remove(tmp); return false, werr end
    local ok, rerr = os.rename(tmp, path)
    if not ok then
        -- some file systems refuse to rename over an existing file
        os.remove(path)
        ok, rerr = os.rename(tmp, path)
    end
    if not ok then os.remove(tmp); return false, rerr end
    return true
end

return Storage

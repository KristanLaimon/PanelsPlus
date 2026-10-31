local lfs = require("libs/libkoreader-lfs")
local util = require("util")

local FS = {}

function FS.isDir(path)
    return lfs.attributes(path, "mode") == "directory"
end

function FS.exists(path)
    return lfs.attributes(path, "mode") ~= nil
end

-- util.makePath answers truthy, not a path; nil means a parent failed.
function FS.ensureDir(dir)
    if FS.isDir(dir) then
        return dir
    end
    return util.makePath(dir) and dir or nil
end

function FS.mtime(path)
    return lfs.attributes(path, "modification")
end

-- Verbatim bytes: meguru/seriescover is the only caller, for series artwork.
-- "w" translates newlines and corrupts an image; "wb" writes bytes as given.
-- The caller must have made the folder: this creates the file, not the dir.
-- A full disk fails at write, not open; a failed close loses buffered data.
function FS.writeFile(path, data)
    if type(path) ~= "string" or path == "" then
        return nil, "no path"
    end
    if type(data) ~= "string" then
        return nil, "no data"
    end
    local handle, open_err = io.open(path, "wb")
    if not handle then
        return nil, tostring(open_err)
    end
    local ok, write_err = handle:write(data)
    local closed, close_err = handle:close()
    if not ok then
        return nil, tostring(write_err)
    end
    if not closed then
        return nil, tostring(close_err)
    end
    return path
end

return FS

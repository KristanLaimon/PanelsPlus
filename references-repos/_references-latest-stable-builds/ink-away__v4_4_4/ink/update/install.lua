--[[
Updates, installing: the downloaded zip is checked against the size and the
SHA-256 digest GitHub lists for it, unpacked into a staging folder beside the
plugin (only paths inside "ink-away.koplugin/", plain files and folders, within
size limits, each file written by Ink Away itself; every Lua file must load),
and must hold the version it was
offered as. Then the plugin folder is moved aside and the staged one put in its
place, and moved back if that fails. The old folder is kept until the new
version has started, which removes it (Install.cleanup).

Ink Away keeps nothing of the reader's in its plugin folder (drawings,
notebooks and settings live in KOReader's data folder), so nothing is lost.
]]

local Policy = require("ink/update/policy")

local Install = {}

local function lfs() return require("libs/libkoreader-lfs") end

-- Remove a file or a folder and everything in it. Returns true, or nil and why.
function Install.removeTree(path)
    local mode = lfs().symlinkattributes(path, "mode")
    if not mode then return true end
    if mode ~= "directory" then return os.remove(path) end
    for name in lfs().dir(path) do
        if name ~= "." and name ~= ".." then
            local ok, err = Install.removeTree(path .. "/" .. name)
            if not ok then return nil, err end
        end
    end
    return lfs().rmdir(path)
end

local function mkdir(path)
    if lfs().symlinkattributes(path, "mode") == "directory" then return true end
    return lfs().mkdir(path)
end

-- The staging and backup folders for the plugin folder `plugin`.
function Install.paths(plugin)
    local parent = plugin and plugin:gsub("/+$", ""):match("^(.+)/[^/]+$")
    if not parent then return nil end
    return parent .. "/.ink-away-update", parent .. "/.ink-away-previous"
end

-- The SHA-256 of a file (hex) and its size.
function Install.digest(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local hash = require("ffi/sha2").sha256()
    local size = 0
    while true do
        local chunk = f:read(65536)
        if not chunk then break end
        size = size + #chunk
        hash(chunk)
    end
    f:close()
    return hash(), size
end

-- Check the zip at `zip` against `release` and unpack it into `stage`.
-- Returns true, or nil and why not (nothing is left in `stage` then).
function Install.prepare(zip, stage, release)
    local sum, size = Install.digest(zip)
    if not sum then return nil, "the download could not be read" end
    if size ~= release.size or sum:lower() ~= release.digest then
        return nil, "the download does not match the one GitHub lists"
    end
    if lfs().symlinkattributes(stage) then
        local ok, err = Install.removeTree(stage)
        if not ok then return nil, err end
    end
    if not mkdir(stage) then return nil, "no staging folder" end
    local reader = require("ffi/archiver").Reader:new()
    if not reader:open(zip) then Install.removeTree(stage); return nil, "the zip could not be opened" end
    local ok, failure = pcall(function()
        local seen, bytes, count, code = {}, 0, 0, false
        for entry in reader:iterate() do
            local rel = Policy.entry(entry.path, entry.mode)
            assert(rel ~= nil, "an unsafe entry in the zip: " .. tostring(entry.path))
            assert(not seen[rel], "a repeated entry in the zip")
            seen[rel] = entry.mode
            if rel:match("^ink/.") then code = true end
            count = count + 1
            assert(count <= Policy.MAX_ENTRIES, "too many entries in the zip")
            local n = tonumber(entry.size) or 0
            bytes = bytes + n
            assert(bytes <= Policy.MAX_UNPACKED, "the zip unpacks too large")
            if rel ~= "" then
                local dir = stage
                for part in rel:gmatch("([^/]+)/") do
                    dir = dir .. "/" .. part
                    assert(mkdir(dir), "a folder could not be made")
                end
                if entry.mode == "directory" then
                    assert(mkdir(stage .. "/" .. rel), "a folder could not be made")
                else
                    -- read into memory and written by Ink Away itself, to the
                    -- path checked above, with ordinary permissions: nothing
                    -- in the zip decides where a file goes or who may run it
                    local data = reader:extractToMemory(entry.path)
                    assert(data and #data == n, "a file could not be unpacked")
                    local out = assert(io.open(stage .. "/" .. rel, "wb"), "a file could not be written")
                    local wrote = out:write(data)
                    out:close()
                    assert(wrote, "a file could not be written")
                    if rel:match("%.lua$") then
                        assert(loadfile(stage .. "/" .. rel), "a broken file in the zip: " .. rel)
                    end
                end
            end
        end
        assert(not reader.err, "the zip is damaged")
        assert(seen["main.lua"] == "file" and seen["_meta.lua"] == "file" and code,
            "the zip is not a whole Ink Away")
        local f = assert(io.open(stage .. "/_meta.lua", "rb"))
        local meta = f:read("*a")
        f:close()
        local v = meta:match('version%s*=%s*"([^"]+)"')
        assert(v and Policy.compare(v, release.version) == 0,
            "the zip holds version " .. tostring(v) .. ", not " .. release.version)
    end)
    reader:close()
    if not ok then
        Install.removeTree(stage)
        return nil, tostring(failure):gsub("^.-:%d+: ", "")
    end
    return true
end

-- Put the staged folder in place of `plugin`, keeping the old one as `backup`.
-- Returns true, or nil and why (the plugin folder is as it was then).
function Install.swap(plugin, stage, backup)
    local L = lfs()
    if L.symlinkattributes(plugin, "mode") ~= "directory" or L.symlinkattributes(stage, "mode") ~= "directory" then
        return nil, "the plugin folder is not where it should be"
    end
    if L.symlinkattributes(plugin .. "/.git") then
        return nil, "this Ink Away is a development copy (it has .git); update it with git"
    end
    if L.symlinkattributes(backup) then
        local ok, err = Install.removeTree(backup)
        if not ok then return nil, err end
    end
    local ok, err = os.rename(plugin, backup)
    if not ok then return nil, err end
    ok, err = os.rename(stage, plugin)
    if not ok then
        local back, berr = os.rename(backup, plugin)
        if not back then return nil, "could not put the old version back (" .. tostring(berr) .. "); it is in " .. backup end
        return nil, err
    end
    return true
end

-- At start: remove the previous version's folder and anything staged, once the
-- version running is the one installed (`installed`, from the settings).
-- Returns true when it cleaned up.
function Install.cleanup(plugin, running, installed)
    local stage, backup = Install.paths(plugin)
    if not stage then return false end
    Install.removeTree(stage)
    if installed and Policy.compare(running, installed) == 0 and lfs().symlinkattributes(backup) then
        Install.removeTree(backup)
        return true
    end
    return false
end

return Install

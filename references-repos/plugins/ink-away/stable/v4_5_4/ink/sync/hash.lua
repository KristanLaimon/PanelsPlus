--[[
Hashes for the cloud sync (see ink/sync/). A file is known by its SHA-256, and
Dropbox by its "content hash": the SHA-256 of the SHA-256s of the file's 4 MB
blocks. Both are read from the file a piece at a time, so a big notebook does not
fill the reader's memory. KOReader's own SHA-2 code is used (pure Lua, so a
large file takes a moment; the sync does it in the background).
]]

local Hash = {}

Hash.BLOCK = 4 * 1024 * 1024
Hash.CHUNK = 256 * 1024

local function sha() return require("ffi/sha2") end

-- Hex text as the bytes it stands for.
local function unhex(h)
    return (h:gsub("%x%x", function(x) return string.char(tonumber(x, 16)) end))
end
Hash.unhex = unhex

-- The SHA-256 of a string, as hex.
function Hash.sha256(s)
    return sha().sha256(s)
end

-- The SHA-256 of a string, as 32 raw bytes.
function Hash.sha256bin(s)
    return unhex(sha().sha256(s))
end

-- Read `path` in blocks of `size` bytes, calling fn(block) for each. Returns
-- the byte count, or nil and why not.
local function eachBlock(path, size, fn)
    local f, err = io.open(path, "rb")
    if not f then return nil, err end
    local total = 0
    while true do
        local block = f:read(size)
        if not block or block == "" then break end
        total = total + #block
        fn(block)
    end
    f:close()
    return total
end

-- The SHA-256 of the file at `path`, as hex, and its size. Or nil and why not.
function Hash.file(path)
    local s = sha()
    local ok, feed = pcall(s.sha256)   -- (a hasher that takes pieces: call it with the text, then with nil)
    if not ok or type(feed) ~= "function" then
        local f, err = io.open(path, "rb")
        if not f then return nil, err end
        local data = f:read("*a")
        f:close()
        return s.sha256(data), #data
    end
    local total, err = eachBlock(path, Hash.CHUNK, function(b) feed(b) end)
    if not total then return nil, err end
    return feed(), total
end

-- Dropbox's content hash of the file at `path`, as hex. Or nil and why not.
function Hash.dropbox(path)
    local parts = {}
    local total, err = eachBlock(path, Hash.BLOCK, function(b) parts[#parts + 1] = Hash.sha256bin(b) end)
    if not total then return nil, err end
    return Hash.sha256(table.concat(parts)), total
end

-- The same for a string held in memory (the tests, and small files).
function Hash.dropboxOfString(data)
    local parts = {}
    for i = 1, math.max(#data, 1), Hash.BLOCK do
        if #data == 0 and i > 1 then break end
        parts[#parts + 1] = Hash.sha256bin(data:sub(i, i + Hash.BLOCK - 1))
    end
    if #data == 0 then parts = {} end
    return Hash.sha256(table.concat(parts))
end

-- The hex digest of the file at `path` by a feeder from ffi/sha2 ("md5", "sha1"),
-- read in pieces. Or nil and why not.
local function feedFile(path, name)
    local feed = sha()[name]()
    local total, err = eachBlock(path, Hash.CHUNK, function(b) feed(b) end)
    if not total then return nil, err end
    return feed(), total
end

-- The MD5 of the file at `path`, as hex (Google Drive's checksum).
function Hash.md5(path) return feedFile(path, "md5") end

-- The SHA-1 of the file at `path`, as hex (OneDrive's, where it gives one).
function Hash.sha1(path) return feedFile(path, "sha1") end

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

-- Bytes as standard base64 with padding.
function Hash.base64(s)
    local out = {}
    for i = 1, #s, 3 do
        local a, b, c = s:byte(i, i + 2)
        local n = a * 65536 + (b or 0) * 256 + (c or 0)
        local c1, c2, c3, c4 = math.floor(n / 262144) % 64, math.floor(n / 4096) % 64, math.floor(n / 64) % 64, n % 64
        out[#out + 1] = B64:sub(c1 + 1, c1 + 1) .. B64:sub(c2 + 1, c2 + 1)
            .. (b and B64:sub(c3 + 1, c3 + 1) or "=") .. (c and B64:sub(c4 + 1, c4 + 1) or "=")
    end
    return table.concat(out)
end

-- OneDrive's quickXorHash of a string, as base64: every byte is XORed into a
-- 160-bit value at a position 11 bits further on each time (wrapping round),
-- then the length goes into the last 8 bytes.
function Hash.quickXorOfString(data)
    local state = {}
    Hash.quickXorFeed(state, data)
    return Hash.quickXorDone(state)
end

-- Feed `data` into a quickXorHash `state` ({ cell, pos, n }; start with {}).
function Hash.quickXorFeed(state, data)
    local bit = require("bit")
    local cell = state.cell
    if not cell then
        cell = {}
        for i = 0, 19 do cell[i] = 0 end
        state.cell, state.pos, state.n = cell, 0, 0
    end
    local pos = state.pos
    for i = 1, #data do
        local v = bit.lshift(data:byte(i), pos % 8)
        local at = math.floor(pos / 8)
        cell[at] = bit.bxor(cell[at], bit.band(v, 255))
        local hi = bit.rshift(v, 8)
        if hi ~= 0 then
            local nx = (at + 1) % 20
            cell[nx] = bit.bxor(cell[nx], hi)
        end
        pos = pos + 11
        if pos >= 160 then pos = pos - 160 end
    end
    state.pos = pos
    state.n = state.n + #data
end

-- The finished quickXorHash of a state, as base64.
function Hash.quickXorDone(state)
    local bit = require("bit")
    local cell = state.cell
    if not cell then
        cell = {}
        for i = 0, 19 do cell[i] = 0 end
        state.n = 0
    end
    local len = state.n
    for k = 0, 7 do
        cell[12 + k] = bit.bxor(cell[12 + k], len % 256)
        len = math.floor(len / 256)
    end
    local out = {}
    for i = 0, 19 do out[#out + 1] = string.char(cell[i]) end
    return Hash.base64(table.concat(out))
end

-- OneDrive's quickXorHash of the file at `path`. Or nil and why not.
function Hash.quickXor(path)
    local state = {}
    local total, err = eachBlock(path, Hash.CHUNK, function(b) Hash.quickXorFeed(state, b) end)
    if not total then return nil, err end
    return Hash.quickXorDone(state), total
end

-- A short, cheap identity for a big file that is only needed to tell two files
-- apart (a PDF or picture a notebook uses): its size and a hash of its first and
-- last 64 KB. Or nil and why not.
function Hash.quick(path)
    local f, err = io.open(path, "rb")
    if not f then return nil, err end
    local size = f:seek("end")
    f:seek("set", 0)
    local head = f:read(65536) or ""
    local tail = ""
    if size > 131072 then
        f:seek("set", size - 65536)
        tail = f:read(65536) or ""
    end
    f:close()
    return string.format("%d-%s", size, Hash.sha256(head .. "|" .. tail):sub(1, 24)), size
end

return Hash

-- Random access to a .cbz: the central directory once, then entries by offset.
-- libarchive seeks to every local header to enumerate; this reads one index.

local ffi = require("ffi")

local Zip = {}

local TAIL_BYTES = 128 * 1024
-- Larger than any book's index; refuse it and let libarchive try instead.
local MAX_CENTRAL_BYTES = 4 * 1024 * 1024

local EOCD_SIG = "PK\005\006"
local CENTRAL_SIG = "PK\001\002"
local LOCAL_SIG = "PK\003\004"

local function u16(s, i)
    local a, b = s:byte(i, i + 1)
    return a + b * 256
end

local function u32(s, i)
    local a, b, c, d = s:byte(i, i + 3)
    return a + b * 256 + c * 65536 + d * 16777216
end

local function readAt(file, pos, len)
    if not file:seek("set", pos) then
        return nil
    end
    local data = file:read(len)
    if not data or #data ~= len then
        return nil
    end
    return data
end

-- Backwards from the end: a comment can carry the signature, so the record
-- that fits its own comment length is the one taken.
local function findEocd(tail)
    for i = #tail - 21, 1, -1 do
        if tail:sub(i, i + 3) == EOCD_SIG
            and i + 21 + u16(tail, i + 20) <= #tail then
            return i
        end
    end
    return nil
end

local function parse(cd, count)
    local entries, by_name, off = {}, {}, 1
    while #entries < count do
        if off + 45 > #cd or cd:sub(off, off + 3) ~= CENTRAL_SIG then
            return nil
        end
        local method = u16(cd, off + 10)
        local csize = u32(cd, off + 20)
        local usize = u32(cd, off + 24)
        local nlen = u16(cd, off + 28)
        local elen = u16(cd, off + 30)
        local clen = u16(cd, off + 32)
        local loff = u32(cd, off + 42)
        local name_end = off + 45 + nlen
        if name_end > #cd then
            return nil
        end
        -- ZIP64 parks sentinels here; libarchive knows that format.
        if csize == 0xFFFFFFFF or usize == 0xFFFFFFFF
            or loff == 0xFFFFFFFF then
            return nil
        end
        local entry = {
            name = cd:sub(off + 46, name_end),
            method = method,
            flags = u16(cd, off + 8),
            csize = csize,
            usize = usize,
            offset = loff,
        }
        entries[#entries + 1] = entry
        by_name[entry.name] = entry
        off = name_end + 1 + elen + clen
    end
    -- A count below the real number would silently hide entries; refuse it.
    if off + 45 <= #cd and cd:sub(off, off + 3) == CENTRAL_SIG then
        return nil
    end
    return { entries = entries, by_name = by_name }
end

local zlib
local zlib_checked = false

-- Raw deflate is what ZIP method 8 holds; ffi/zlib exposes only the wrapped
-- form, so the stream itself is declared here. Absent zlib leaves the entry
-- to libarchive rather than failing the read.
local function loadZlib()
    if zlib_checked then
        return zlib
    end
    zlib_checked = true
    local ok, lib = pcall(function()
        ffi.cdef[[
            typedef struct meguru_z_stream {
                const unsigned char *next_in;
                unsigned int avail_in;
                unsigned long total_in;
                unsigned char *next_out;
                unsigned int avail_out;
                unsigned long total_out;
                const char *msg;
                void *state;
                void *zalloc;
                void *zfree;
                void *opaque;
                int data_type;
                unsigned long adler;
                unsigned long reserved;
            } meguru_z_stream;
            const char *zlibVersion(void);
            int inflateInit2_(meguru_z_stream *, int, const char *, int);
            int inflate(meguru_z_stream *, int);
            int inflateEnd(meguru_z_stream *);
        ]]
        return ffi.loadlib("z", 1)
    end)
    if ok then
        zlib = lib
    end
    return zlib
end

local function inflateRaw(data, usize)
    local lib = loadZlib()
    if not lib then
        return nil
    end
    local strm = ffi.new("meguru_z_stream[1]")
    if lib.inflateInit2_(strm, -15, lib.zlibVersion(),
        ffi.sizeof("meguru_z_stream")) ~= 0 then
        return nil
    end
    local buf = ffi.new("unsigned char[?]", usize)
    strm[0].next_in = ffi.cast("const unsigned char *", data)
    strm[0].avail_in = #data
    strm[0].next_out = buf
    strm[0].avail_out = usize
    local res = lib.inflate(strm, 4) -- Z_FINISH
    local out_len = tonumber(strm[0].total_out)
    lib.inflateEnd(strm)
    if res ~= 1 or out_len ~= usize then
        return nil
    end
    return ffi.string(buf, usize)
end

local Reader = {}
Reader.__index = Reader

function Reader:entry(name)
    return self.by_name[name]
end

-- Nil for anything the index cannot answer: absent, encrypted, a method
-- other than store/deflate, or shorter data than the directory promised.
function Reader:read(name, max_bytes)
    local entry = self.by_name[name]
    if not entry or entry.flags % 2 == 1 then
        return nil
    end
    if max_bytes and entry.usize and entry.usize > max_bytes then
        return nil
    end
    local ok, file = pcall(io.open, self.path, "rb")
    if not ok or not file then
        return nil
    end
    local ok_read, data = pcall(function()
        local header = readAt(file, entry.offset, 30)
        if not header or header:sub(1, 4) ~= LOCAL_SIG then
            return nil
        end
        local data_off = entry.offset + 30 + u16(header, 27) + u16(header, 29)
        return readAt(file, data_off, entry.csize)
    end)
    file:close()
    if not ok_read or not data then
        return nil
    end
    if entry.usize == 0 then
        return ""
    end
    if entry.method == 0 then
        return #data == entry.usize and data or nil
    end
    if entry.method == 8 then
        return inflateRaw(data, entry.usize)
    end
    return nil
end

-- The entry's first max_bytes, for a header rather than a whole page. Deflate
-- is fed in chunks so a large entry is never held whole to read its first line.
function Reader:readPrefix(name, max_bytes)
    local entry = self.by_name[name]
    if not entry or entry.flags % 2 == 1 or not max_bytes or max_bytes < 1 then
        return nil
    end
    local ok, file = pcall(io.open, self.path, "rb")
    if not ok or not file then
        return nil
    end
    -- A header is optional: a malformed entry must leave its page to MuPDF.
    local ok_read, result = pcall(function()
        local header = readAt(file, entry.offset, 30)
        if not header or header:sub(1, 4) ~= LOCAL_SIG then
            return nil
        end
        local data_off = entry.offset + 30 + u16(header, 27) + u16(header, 29)
        if entry.method == 0 then
            local len = math.min(max_bytes, entry.usize or 0)
            return len > 0 and readAt(file, data_off, len) or ""
        end
        if entry.method ~= 8 then
            return nil
        end
        local lib = loadZlib()
        if not lib then
            return nil
        end
        local strm = ffi.new("meguru_z_stream[1]")
        if lib.inflateInit2_(strm, -15, lib.zlibVersion(),
            ffi.sizeof("meguru_z_stream")) ~= 0 then
            return nil
        end
        local buf = ffi.new("unsigned char[?]", max_bytes)
        strm[0].next_out = buf
        strm[0].avail_out = max_bytes
        local remaining = entry.csize or 0
        local pos = data_off
        while remaining > 0 and strm[0].avail_out > 0 do
            local chunk = readAt(file, pos, math.min(64 * 1024, remaining))
            if not chunk or #chunk == 0 then
                break
            end
            pos = pos + #chunk
            remaining = remaining - #chunk
            strm[0].next_in = ffi.cast("const unsigned char *", chunk)
            strm[0].avail_in = #chunk
            local res = lib.inflate(strm, 0) -- Z_NO_FLUSH
            if res ~= 0 then
                break
            end
        end
        local out_len = tonumber(strm[0].total_out) or 0
        lib.inflateEnd(strm)
        if out_len < 1 then
            return nil
        end
        return ffi.string(buf, out_len)
    end)
    file:close()
    if not ok_read then
        return nil
    end
    return result
end

-- Nil whenever this reader cannot answer for the whole file; every caller
-- then keeps libarchive, so this is an index in front of it, not a replacement.
function Zip.open(path)
    if type(path) ~= "string" or path == "" then
        return nil
    end
    local ok, file = pcall(io.open, path, "rb")
    if not ok or not file then
        return nil
    end
    local ok_read, index = pcall(function()
        local size = file:seek("end")
        if not size or size < 22 then
            return nil
        end
        local tail_len = math.min(size, TAIL_BYTES)
        local tail = readAt(file, size - tail_len, tail_len)
        local eocd = tail and findEocd(tail)
        if not eocd then
            return nil
        end
        local count = u16(tail, eocd + 10)
        local cd_size = u32(tail, eocd + 12)
        local cd_off = u32(tail, eocd + 16)
        if count == 0xFFFF or cd_size == 0xFFFFFFFF or cd_off == 0xFFFFFFFF then
            return nil
        end
        if cd_size == 0 or cd_size > MAX_CENTRAL_BYTES
            or cd_off + cd_size > size then
            return nil
        end
        local in_tail = cd_off - (size - tail_len)
        local cd
        if in_tail >= 0 and in_tail + cd_size <= tail_len then
            cd = tail:sub(in_tail + 1, in_tail + cd_size)
        else
            cd = readAt(file, cd_off, cd_size)
        end
        if not cd then
            return nil
        end
        local parsed = parse(cd, count)
        if not parsed then
            return nil
        end
        parsed.path = path
        parsed.size = size
        setmetatable(parsed, Reader)
        return parsed
    end)
    file:close()
    if not ok_read then
        return nil
    end
    return index
end

return Zip

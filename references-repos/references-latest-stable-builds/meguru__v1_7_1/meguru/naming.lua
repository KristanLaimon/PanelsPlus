-- Byte-string module: only filesystem-hostile ASCII bytes are ever replaced.

local Paths = require("meguru/paths")

local Naming = {}

-- Kavita's "Continue Reading from:" alias duplicates a volume.
-- The prefix is dropped so the two name to one book.
Naming.ALIAS_PREFIX = "Continue Reading from: "

-- 220-byte cap keeps every component under the 255-byte name limit.
-- The marker's extension and a "-" plus 8 hex digits fit in the remainder.
Naming.MAX_COMPONENT_BYTES = 220

function Naming.stripAliasPrefix(title)
    title = title or ""
    local prefix = Naming.ALIAS_PREFIX
    if title:sub(1, #prefix) == prefix then
        return title:sub(#prefix + 1)
    end
    return title
end

-- Codepoint and byte length of the first UTF-8 char; nil if empty or malformed.
local function utf8Head(s)
    local b1 = s:byte(1)
    if not b1 then
        return nil, nil
    end
    if b1 < 0x80 then
        return b1, 1
    elseif b1 >= 0xC0 and b1 < 0xE0 then
        local b2 = s:byte(2)
        if not b2 then return nil, nil end
        return (b1 - 0xC0) * 0x40 + (b2 - 0x80), 2
    elseif b1 >= 0xE0 and b1 < 0xF0 then
        local b2, b3 = s:byte(2), s:byte(3)
        if not (b2 and b3) then return nil, nil end
        return (b1 - 0xE0) * 0x1000 + (b2 - 0x80) * 0x40 + (b3 - 0x80), 3
    elseif b1 >= 0xF0 and b1 < 0xF8 then
        local b2, b3, b4 = s:byte(2), s:byte(3), s:byte(4)
        if not (b2 and b3 and b4) then return nil, nil end
        return (b1 - 0xF0) * 0x40000 + (b2 - 0x80) * 0x1000
            + (b3 - 0x80) * 0x40 + (b4 - 0x80), 4
    end
    return nil, nil
end

-- Servers bake a progress glyph into titles; ranges cover a new icon too.
-- A new status icon is then stripped without a code change.
local GLYPH_RANGES = {
    { 0x2190, 0x21FF },   -- Arrows
    { 0x2300, 0x23FF },   -- Misc Technical (hourglass, stopwatch)
    { 0x25A0, 0x25FF },   -- Geometric Shapes (filled/partial circles)
    { 0x2600, 0x27BF },   -- Misc Symbols + Dingbats (check marks, stars)
    { 0x2B00, 0x2BFF },   -- Misc Symbols and Arrows
    { 0x1F300, 0x1FAFF }, -- Emoji planes
}

local function isGlyphCodepoint(cp)
    if not cp then
        return false
    end
    for _, range in ipairs(GLYPH_RANGES) do
        if cp >= range[1] and cp <= range[2] then
            return true
        end
    end
    return false
end

-- Emoji presentation is two codepoints: strip the base, then swallow U+FE0F.
local function stripLeadingGlyph(title)
    local t = title
    while true do
        local cp, len = utf8Head(t)
        if not isGlyphCodepoint(cp) then
            break
        end
        t = t:sub(len + 1)
        while t:byte(1) == 0xEF and t:byte(2) == 0xB8
            and t:byte(3) and t:byte(3) >= 0x80 and t:byte(3) <= 0x8F do
            t = t:sub(4)
        end
    end
    return (t:gsub("^%s+", ""))
end

-- Display-time only: prefix and leading glyph gone, never stored in a value.
function Naming.cleanTitle(title)
    return stripLeadingGlyph(Naming.stripAliasPrefix(title))
end

-- Placeholder authors are stamped when there is no creator; never show them.
local AUTHOR_PLACEHOLDERS = { "unknown", "unknown author" }

-- A real author name, or nil when there is none worth showing.
function Naming.cleanAuthor(author)
    local s
    if type(author) == "string" then
        s = author
    elseif type(author) == "table" and type(author.name) == "string" then
        s = author.name
    else
        return nil
    end
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    local lowered = s:lower()
    for _, placeholder in ipairs(AUTHOR_PLACEHOLDERS) do
        if lowered == placeholder then
            return nil
        end
    end
    return s
end

-- Feeds label titles "Series: <Manga>"; only a leading label is stripped.
local SERIES_NAME_LABELS = { "series", "manga" }

function Naming.stripSeriesLabel(s)
    if type(s) ~= "string" then
        return s
    end
    local t = s:gsub("^%s+", "")
    local head = t:lower()
    for _, label in ipairs(SERIES_NAME_LABELS) do
        local prefix = label .. ":"
        if head:sub(1, #prefix) == prefix then
            local rest = t:sub(#prefix + 1):gsub("^%s+", "")
            if rest ~= "" then
                return rest
            end
            return s
        end
    end
    return s
end

-- En/em dashes to ASCII "-", so " – Volume 3" peels like " - Volume 3".
local function normalizeDashes(s)
    return (s:gsub("\u{2013}", "-"):gsub("\u{2014}", "-"))
end

-- Safe single filesystem component: hostile bytes to spaces, runs collapsed.
-- Capped on a UTF-8 boundary so it never ends in a dangling lead byte.
function Naming.sanitizeComponent(name, cap_bytes)
    cap_bytes = cap_bytes or Naming.MAX_COMPONENT_BYTES
    local out = {}
    for i = 1, #name do
        local b = name:byte(i)
        if b < 32 or b == 127 or b == 47 or b == 92 or b == 58
            or b == 42 or b == 63 or b == 34 or b == 60 or b == 62 or b == 124 then
            out[#out + 1] = " "
        else
            out[#out + 1] = name:sub(i, i)
        end
    end
    name = table.concat(out)
    -- Trailing dots/spaces are trimmed: FAT does it behind our back.
    -- The name we record would otherwise disagree with the disk.
    name = name:gsub("%s+", " "):gsub("^%s+", ""):gsub("[%s.]+$", "")
    if name == "" or name == "." or name == ".." then
        return "stream"
    end
    -- Reserved device names on Windows. Fatal only there, but free to guard.
    if name:lower():match("^(con|prn|aux|nul|com[1-9]|lpt[1-9])$") then
        name = name .. "-stream"
    end
    -- Never double the extension if the title itself ends with it.
    if name:lower():sub(-(#Paths.MARKER_EXT + 1)) == "." .. Paths.MARKER_EXT then
        name = name:sub(1, #name - (#Paths.MARKER_EXT + 1))
    end
    if #name > cap_bytes then
        -- Walk back past continuation bytes to the lead byte and cut there.
        local cut = cap_bytes
        while cut > 0 do
            local b = name:byte(cut)
            if b < 0x80 or b >= 0xC0 then
                break
            end
            cut = cut - 1
        end
        name = name:sub(1, cut):gsub("[%s.]+$", "")
    end
    if name == "" then
        return "stream"
    end
    return name
end

-- The marker's base name, kept verbatim so it reads cleanly in the browser.
-- It then does not change when the server advances its progress glyph.
function Naming.markerBaseName(title)
    title = stripLeadingGlyph(Naming.stripAliasPrefix(title))
    return Naming.sanitizeComponent(title, Naming.MAX_COMPONENT_BYTES)
end

-- Volume/chapter tokens tried, in order, when deriving a series name.
local VOLUME_TOKENS = { "Volume", "Vol", "Chapter", "Ch", "Part", "v" }

-- Strip trailing "(...)"/"[...]" tags so the volume token before them is last.
-- Komga titles every volume "<Series> v<NN> (<group>)".
local function stripTrailingReleaseGroups(t)
    while true do
        local prev = t
        t = t:gsub("%s*[%(%[][^%)%]]*[%)%]]%s*$", "")
        if t == prev or t == "" then
            return t
        end
    end
end

-- Returns series, volume label, index, or nothing when none is confident.
-- A hyphenated range indexes from its first number; a decimal is kept whole.
function Naming.deriveSeries(raw_title)
    local t = Naming.stripAliasPrefix(raw_title)
    t = stripLeadingGlyph(t):gsub("^%s+", ""):gsub("%s+$", "")
    if t == "" then
        return nil
    end
    t = Naming.stripSeriesLabel(t)
    t = normalizeDashes(t)
    -- A token is trailing only once the release groups are gone.
    -- Komga's token sits before its "(...)" groups, never at the end.
    t = stripTrailingReleaseGroups(t)

    for _, token in ipairs(VOLUME_TOKENS) do
        -- Minimal prefix so the trailing token peels.
        -- A fraction and range after the number index from the integer.
        local pattern = "^(.-)%s*[%-:]*%s*" .. token .. "%.?%s*(%d+%.?%d*)%s*%-?%s*%d*%s*$"
        local prefix, num = t:match(pattern)
        -- Empty prefix is a title, not a failure: Suwayomi has no series name.
        -- It returns an empty series, which every caller already rejects.
        if prefix then
            local label = t:sub(#prefix + 1):gsub("^[%s%-:]+", ""):gsub("%s+$", "")
            local series = prefix:gsub("%s+$", ""):gsub("[%-:%s]+$", "")
            if label == "" then
                label = token .. " " .. num
            end
            return series, label, tonumber(num)
        end
    end
    return nil
end

-- djb2: not a security hash, only stable across restarts and spreading inputs.
function Naming.hash32(str)
    local h = 5381
    for i = 1, #str do
        h = (h * 33 + str:byte(i)) % 4294967296
    end
    return h
end

-- Two lanes: Lua 5.1 doubles stay exact, and a collision collapses two books.
function Naming.digest64(str)
    str = str or ""
    local h1, h2 = 5381, 0
    for i = 1, #str do
        local b = str:byte(i)
        h1 = (h1 * 33 + b) % 4294967296       -- djb2
        h2 = (h2 * 65599 + b) % 4294967296    -- sdbm
    end
    return string.format("%08x%08x", h2, h1)
end

-- From identity, not the URL: a URL-derived suffix would rename the file.
-- A key rotation would then orphan its reading progress.
function Naming.keySuffix(natural_key)
    return string.format("%08x", Naming.hash32(natural_key or ""))
end

-- `name` with a natural-key suffix, when the plain component is taken.
function Naming.disambiguated(name, natural_key)
    return name .. "-" .. Naming.keySuffix(natural_key)
end

return Naming

--[[
Capital and small letters the way each language writes them. Lua's upper() and lower()
only change A to Z, so a translated word starting with an accented capital, or Turkish
I and İ, would come out wrong. `lang` is KOReader's language code ("tr", "el", "pt_BR"),
or nil for none in particular. Plain Lua with no dependencies, so the translation tools
and tests can use it too.
]]

local TextCase = {}

-- The next UTF-8 character of s at i: its code point and byte length.
local function decode(s, i)
    local b = s:byte(i)
    if b < 0x80 then return b, 1 end
    if b >= 0xF0 then
        local b2, b3, b4 = s:byte(i + 1, i + 3)
        return ((b % 8) * 262144) + ((b2 % 64) * 4096) + ((b3 % 64) * 64) + (b4 % 64), 4
    elseif b >= 0xE0 then
        local b2, b3 = s:byte(i + 1, i + 2)
        return ((b % 16) * 4096) + ((b2 % 64) * 64) + (b3 % 64), 3
    elseif b >= 0xC0 then
        return ((b % 32) * 64) + (s:byte(i + 1) % 64), 2
    end
    return b, 1   -- a stray continuation byte
end

-- A code point as UTF-8.
local function encode(cp)
    if cp < 0x80 then return string.char(cp) end
    if cp < 0x800 then return string.char(0xC0 + math.floor(cp / 64), 0x80 + cp % 64) end
    if cp < 0x10000 then
        return string.char(0xE0 + math.floor(cp / 4096), 0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64)
    end
    return string.char(0xF0 + math.floor(cp / 262144), 0x80 + math.floor(cp / 4096) % 64, 0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64)
end

-- Greek letters with an accent mark, and the capital that carries none.
local GREEK_STRIP = {
    [0x386] = 0x391, [0x388] = 0x395, [0x389] = 0x397, [0x38A] = 0x399, [0x38C] = 0x39F, [0x38E] = 0x3A5, [0x38F] = 0x3A9,
    [0x3AC] = 0x391, [0x3AD] = 0x395, [0x3AE] = 0x397, [0x3AF] = 0x399, [0x3CC] = 0x39F, [0x3CD] = 0x3A5, [0x3CE] = 0x3A9,
    [0x390] = 0x3AA, [0x3B0] = 0x3AB,
}

-- Capital Greek letters with an accent mark, and their small forms.
local GREEK_SMALL = {
    [0x386] = 0x3AC, [0x388] = 0x3AD, [0x389] = 0x3AE, [0x38A] = 0x3AF, [0x38C] = 0x3CC, [0x38E] = 0x3CD, [0x38F] = 0x3CE,
}

-- Latin Extended-A pairs the other way round: the capital is the odd one.
local function oddCapital(cp)
    return (cp >= 0x139 and cp <= 0x148) or (cp >= 0x179 and cp <= 0x17E)
end

-- The capital of a code point (a code point, or a string for the German sharp s).
local function upperOf(cp, lang)
    if cp >= 0x61 and cp <= 0x7A then
        if cp == 0x69 and lang == "tr" then return 0x130 end
        return cp - 32
    end
    if cp < 0x80 then return cp end
    if cp == 0xDF then return "SS" end
    if cp >= 0xE0 and cp <= 0xFE and cp ~= 0xF7 then return cp - 32 end
    if cp == 0xFF then return 0x178 end
    if cp == 0x131 then return 0x49 end
    if cp >= 0x100 and cp <= 0x17F then
        if cp == 0x130 or cp == 0x138 or cp == 0x149 or cp == 0x178 then return cp end
        if cp == 0x17F then return 0x53 end
        if oddCapital(cp) then return cp % 2 == 0 and cp - 1 or cp end
        return cp % 2 == 1 and cp - 1 or cp
    end
    if cp >= 0x370 and cp <= 0x3FF then
        if GREEK_STRIP[cp] then return GREEK_STRIP[cp] end
        if cp == 0x3C2 then return 0x3A3 end
        if (cp >= 0x3B1 and cp <= 0x3C9) or cp == 0x3CA or cp == 0x3CB then return cp - 32 end
        return cp
    end
    if cp >= 0x430 and cp <= 0x44F then return cp - 32 end
    if cp >= 0x450 and cp <= 0x45F then return cp - 80 end
    if cp >= 0x460 and cp <= 0x4FF and cp % 2 == 1 and cp ~= 0x482 then return cp - 1 end
    return cp
end

-- The small form of a code point.
local function lowerOf(cp, lang)
    if cp >= 0x41 and cp <= 0x5A then
        if cp == 0x49 and lang == "tr" then return 0x131 end
        return cp + 32
    end
    if cp < 0x80 then return cp end
    if cp >= 0xC0 and cp <= 0xDE and cp ~= 0xD7 then return cp + 32 end
    if cp == 0x178 then return 0xFF end
    if cp == 0x130 then return 0x69 end
    if cp >= 0x100 and cp <= 0x17F then
        if cp == 0x131 or cp == 0x138 or cp == 0x149 or cp == 0x17F then return cp end
        if oddCapital(cp) then return cp % 2 == 1 and cp + 1 or cp end
        return cp % 2 == 0 and cp + 1 or cp
    end
    if cp >= 0x370 and cp <= 0x3FF then
        if GREEK_SMALL[cp] then return GREEK_SMALL[cp] end
        if (cp >= 0x391 and cp <= 0x3A9 and cp ~= 0x3A2) or cp == 0x3AA or cp == 0x3AB then return cp + 32 end
        return cp
    end
    if cp >= 0x410 and cp <= 0x42F then return cp + 32 end
    if cp >= 0x400 and cp <= 0x40F then return cp + 80 end
    if cp >= 0x460 and cp <= 0x4FF and cp % 2 == 0 and cp ~= 0x482 then return cp + 1 end
    return cp
end

-- `s` with every letter mapped by `fn`, one character at a time.
local function map(s, fn, lang)
    local out, i = {}, 1
    while i <= #s do
        local cp, len = decode(s, i)
        local to = fn(cp, lang)
        out[#out + 1] = type(to) == "string" and to or encode(to)
        i = i + len
    end
    return table.concat(out)
end

-- `s` in capitals for the language.
function TextCase.upper(s, lang)
    lang = lang and lang:match("^%a+")
    if not s:find("[\128-\255]") and lang ~= "tr" then return s:upper() end
    return map(s, upperOf, lang)
end

-- `s` in small letters for the language (Turkish I becomes ı, İ becomes i).
function TextCase.lower(s, lang)
    lang = lang and lang:match("^%a+")
    if not s:find("[\128-\255]") and lang ~= "tr" then return s:lower() end
    return map(s, lowerOf, lang)
end

-- Is `s` already in capitals (every letter that has a capital is one)?
function TextCase.isUpper(s, lang)
    return TextCase.upper(s, lang) == s
end

return TextCase

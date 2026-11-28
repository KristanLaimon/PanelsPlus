--[[
Reading a written word: the English word list and the decoder that picks the
likeliest word from each character's class scores. Pure Lua, so the headless
tests drive it; the training project's hwr/words.py is the same decoder.

The list (ink/data/hwr_words_en.txt) comes from SCOWL by Kevin Atkinson (see
NOTICE.md). It is grouped by how common the words are: a line "#10" starts the
most common, then "#20", "#35" and "#40" add rarer ones. A rarer word pays a
little (LEVEL_COST), so between two equally likely readings the common word
wins.

A dictionary word of the right length scores the sum of its letters' log
probabilities, less its level cost. Reading every position as a digit gives a
number, which wins over the best word when it scores higher. The characters
read on their own (a name, a code) are kept when they score better than that
by more than KEEP_RAW, or KEEP_RAW_MIXED when they mix letters and digits,
which is far more often a misread word ("e33s") than a code ("B52").
]]

local Words = {}
Words.__index = Words

Words.LEVEL_COST = { [10] = 0.0, [20] = 0.4, [35] = 0.8, [40] = 1.2, [50] = 1.6 }
Words.KEEP_RAW = 5.0
Words.KEEP_RAW_MIXED = 8.0

-- Letters whose small form shares the capital's class.
local MERGED = "cijklmopsuvwxyz"

-- A decoder over the word list at `path`, for a model whose classes are
-- `classes` (a list of one-character strings). Returns it, or nil, err.
function Words.load(path, classes)
    local f, err = io.open(path, "r")
    if not f then return nil, err end
    local by_len = {}
    local cost = 0
    for line in f:lines() do
        line = line:gsub("%s+$", "")
        local lv = line:match("^#(%d+)$")
        if lv then
            cost = Words.LEVEL_COST[tonumber(lv)] or 2.0
        elseif line ~= "" then
            local n = #line
            local e = by_len[n]
            if not e then e = { words = {}, cost = {} }; by_len[n] = e end
            e.words[#e.words + 1] = line
            e.cost[#e.cost + 1] = cost
        end
    end
    f:close()
    return Words.new(by_len, classes)
end

-- A decoder over `by_len` ({ [length] = { words = {...}, cost = {...} } }).
function Words.new(by_len, classes)
    local self = setmetatable({ by_len = by_len, classes = classes }, Words)
    -- byte -> class index, for the letters a word can hold
    local of = {}
    for i, ch in ipairs(classes) do of[ch:byte()] = i end
    for c in MERGED:gmatch(".") do
        local up = of[c:upper():byte()]
        if up then of[c:byte()] = up end
    end
    self.class_of = of
    self.digits = {}
    for d = 0, 9 do self.digits[d + 1] = of[tostring(d):byte()] end
    return self
end

-- Each position's best class, its index, and the sum of their log probabilities.
local function rawReading(lps, classes)
    local idx, score, chars = {}, 0, {}
    for p, lp in ipairs(lps) do
        local bi, best = 1, -math.huge
        for i = 1, #lp do if lp[i] > best then best, bi = lp[i], i end end
        idx[p] = bi
        score = score + best
        chars[p] = classes[bi]
    end
    return table.concat(chars), idx, score
end

-- Decode a word from its characters' log probabilities (a list, one list of
-- class log probabilities per character). Returns the text (lower case for a
-- dictionary word, digits for a number, the classes as read otherwise), whether
-- it is a dictionary word, each position's best class index, and the reading's
-- score (log probability, less the word's level cost, or less KEEP_RAW for
-- characters kept as read), so different splits of a line can be compared.
function Words:decode(lps)
    local raw, idx, raw_score = rawReading(lps, self.classes)
    local n = #lps
    local text, score, used = nil, -math.huge, false
    local e = self.by_len[n]
    if e then
        local of = self.class_of
        local best_i, best = nil, -math.huge
        for k, w in ipairs(e.words) do
            local s = -e.cost[k]
            for p = 1, n do
                local c = of[w:byte(p)]
                s = s + (c and lps[p][c] or -1e9)
                if s < best then break end   -- scores only fall from here
            end
            if s > best then best, best_i = s, k end
        end
        if best_i then text, score, used = e.words[best_i], best, true end
    end
    -- every position as a digit: a number
    local digits = self.digits
    local num, num_score = {}, 0
    for p = 1, n do
        local bd, bv = 1, -math.huge
        for d = 1, #digits do
            local v = lps[p][digits[d]]
            if v > bv then bd, bv = d, v end
        end
        num[p] = tostring(bd - 1)
        num_score = num_score + bv
    end
    if num_score > score then text, score, used = table.concat(num), num_score, false end
    local keep = (raw:find("%d") and raw:find("%a")) and Words.KEEP_RAW_MIXED or Words.KEEP_RAW
    if not text or raw_score > score + keep then return raw, false, idx, raw_score - keep end
    return text, used, idx, score
end

return Words

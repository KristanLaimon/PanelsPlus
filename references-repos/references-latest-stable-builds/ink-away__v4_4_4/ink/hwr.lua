--[[
Turning printed handwriting into text: splitting a selection of strokes into
lines, words and characters, choosing capitals, and reading it all with the
character model (ink/hwrnet.lua) and the word list (ink/hwrwords.lua). Pure
Lua, so the headless tests drive it.

  * Hwr.segment(strokes)   lines of letters, with each gap's chance of a space
  * Hwr.read(strokes, net, words)   the text, lines joined by new lines
  * Hwr.lineMetrics(chars, classes, best)   a line's x-height and baseline
  * Hwr.cased(text, ...)   a word's text with its capitals

`strokes` is a list of flat {x, y, x, y, ...} lists in the order they were
written, y down.

Lines. Strokes with some height that overlap from top to bottom share a line,
so a tall capital, a descender or a slanting line stays together. Flat strokes
(the bars of an E), dots and commas then go to the line of the stroke nearest
them.

Characters. A line's strokes are taken in writing order, and each joins the
character it touches, or the one it overlaps most from side to side when that
overlap is a good part of the narrower of the two; otherwise it starts a new
one. Two characters that a later stroke makes overlap become one (the crossbar
of an H). A thin stroke counts as about a third of the line's height wide.
Small marks low on the line are commas and full stops; other dots (an i's dot)
join the nearest character, or are dropped.

Words. How wide a gap is, against the line's own letter spacing, gives its
chance of being a space. Clear gaps decide alone; for the doubtful ones every
way of grouping the letters is read and the word list picks ("are a", not
"a re a"). Two letters that almost touch are also tried as one (an m written
in two strokes).
]]

local Hwr = {}

local function median(t)
    if #t == 0 then return nil end
    local s = {}
    for i, v in ipairs(t) do s[i] = v end
    table.sort(s)
    return s[math.ceil(#s / 2)]
end

local function bbox(pts)
    local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
    for i = 1, #pts - 1, 2 do
        local x, y = pts[i], pts[i + 1]
        if x < x0 then x0 = x end
        if x > x1 then x1 = x end
        if y < y0 then y0 = y end
        if y > y1 then y1 = y end
    end
    return x0, y0, x1, y1
end

-- How much of the narrower of two boxes their side-to-side overlap covers, each
-- box counted at least `minw` wide (around its centre).
local function overlapRatio(a, b, minw)
    local function span(o)
        local w = o.x1 - o.x0
        if w >= minw then return o.x0, o.x1, w end
        local c = (o.x0 + o.x1) / 2
        return c - minw / 2, c + minw / 2, minw
    end
    local a0, a1, aw = span(a)
    local b0, b1, bw = span(b)
    local ov = math.min(a1, b1) - math.max(a0, b0)
    if ov <= 0 then return 0 end
    return ov / math.min(aw, bw)
end

-- Does stroke `s` come within sqrt(d2) of character `c`? Boxes first, then the
-- points (sampled on long strokes).
local function touches(s, c, d2)
    local d = math.sqrt(d2)
    if s.x0 > c.x1 + d or c.x0 > s.x1 + d or s.y0 > c.y1 + d or c.y0 > s.y1 + d then return false end
    local function step(n) return math.max(1, math.floor(n / 80)) * 2 end
    local pa = s.pts
    local sa = step(#pa)
    for _, pb in ipairs(c.strokes) do
        local sb = step(#pb)
        for i = 1, #pa - 1, sa do
            local x, y = pa[i], pa[i + 1]
            for j = 1, #pb - 1, sb do
                local dx, dy = x - pb[j], y - pb[j + 1]
                if dx * dx + dy * dy <= d2 then return true end
            end
        end
    end
    return false
end

local function grow(c, s)
    c.strokes[#c.strokes + 1] = s.pts
    if s.x0 < c.x0 then c.x0 = s.x0 end
    if s.y0 < c.y0 then c.y0 = s.y0 end
    if s.x1 > c.x1 then c.x1 = s.x1 end
    if s.y1 > c.y1 then c.y1 = s.y1 end
    if s.order < c.order then c.order = s.order end
end

local JOIN = 0.4    -- a stroke joins a character it overlaps this much
local MERGE = 0.5   -- two characters overlapping this much are one
local LINK = 0.45   -- strokes overlapping this much of the shorter one's height share a line
local SPECK = 0.3   -- a stroke smaller than this share of the line's height is a dot

-- A gap's chance of being a space: a logistic curve in the gap's width over the
-- letter height, centred SPACE_OVER above the line's median gap (kept between
-- SPACE_MIN and SPACE_MAX), SPACE_SOFT wide.
Hwr.SPACE_OVER, Hwr.SPACE_MIN, Hwr.SPACE_MAX, Hwr.SPACE_SOFT = 0.35, 0.5, 0.95, 0.12
-- Below SURE_JOIN a gap is never a space, above SURE_SPACE always; each word
-- past the first costs WORD_COST, so a doubtful gap splits a word only when the
-- word list clearly prefers it.
Hwr.SURE_JOIN, Hwr.SURE_SPACE, Hwr.WORD_COST = 0.1, 0.97, 1.0
-- Reading two almost touching letters as one costs this much (log probability).
Hwr.MERGE_COST = 1.0
-- A line's first word read as "1" is "I" when "I" scores within this of it.
Hwr.I_OVER_1 = 1.5
local MAX_WORD = 20

-- The characters of one line's strokes (see the notes at the top), in
-- writing order; `lh` is the line's stroke height.
local function characters(strokes, lh)
    local minw = 0.35 * lh
    local touch2 = (0.08 * lh) ^ 2
    local chars = {}
    for _, s in ipairs(strokes) do
        local best, br = nil, 0
        for _, c in ipairs(chars) do
            local r = overlapRatio(s, c, minw)
            -- strokes of one letter usually touch, those of two letters rarely
            if r > 0.05 and touches(s, c, touch2) then r = r + 1 end
            if r > br then best, br = c, r end
        end
        if best and br >= JOIN then
            grow(best, s)
            -- the grown character may now cover another one: merge them
            local merged = true
            while merged do
                merged = false
                for k = #chars, 1, -1 do
                    local d = chars[k]
                    if d ~= best and overlapRatio(best, d, minw) >= MERGE then
                        for _, pts in ipairs(d.strokes) do best.strokes[#best.strokes + 1] = pts end
                        best.x0, best.y0 = math.min(best.x0, d.x0), math.min(best.y0, d.y0)
                        best.x1, best.y1 = math.max(best.x1, d.x1), math.max(best.y1, d.y1)
                        best.order = math.min(best.order, d.order)
                        table.remove(chars, k)
                        merged = true
                    end
                end
            end
        else
            local c = { strokes = {}, x0 = s.x0, y0 = s.y0, x1 = s.x1, y1 = s.y1, order = s.order }
            grow(c, s)
            chars[#chars + 1] = c
        end
    end
    return chars
end

-- A comma or a full stop, for a small mark low on the line.
local function mark(o, base, lh)
    local w, h = o.x1 - o.x0, o.y1 - o.y0
    if h > 0.25 * lh and h > 1.3 * w then return "," end
    if o.y1 > base + 0.15 * lh and h > 0.15 * lh then return "," end
    return "."
end

-- Split strokes into lines, top to bottom. Each line is
--   { letters = { c, ... }   left to right; c = { strokes = { pts, ... },
--                            x0, y0, x1, y1, specks, punct }, its strokes in
--                            writing order, `punct` the marks that follow it
--     p_space = { p, ... }   the chance that the gap after letter k is a space
--     words = { { chars = { c, ... } }, ... }   the letters split at the
--                            likely spaces (Hwr.read weighs the doubtful ones)
--     height, base }         letter height and baseline
function Hwr.segment(strokes)
    local S = {}
    for i, pts in ipairs(strokes) do
        if #pts >= 2 then
            local x0, y0, x1, y1 = bbox(pts)
            S[#S + 1] = { pts = pts, order = i, x0 = x0, y0 = y0, x1 = x1, y1 = y1,
                cy = (y0 + y1) / 2, h = y1 - y0, size = math.max(x1 - x0, y1 - y0) }
        end
    end
    if #S == 0 then return {} end
    local sizes = {}
    for i, s in ipairs(S) do sizes[i] = s.size end
    local M = math.max(median(sizes), 1)

    -- lines come from the strokes with some height; flat bars, dots and commas,
    -- and anything taller than three lines, follow the stroke nearest them
    local body, rest, hs = {}, {}, {}
    for _, s in ipairs(S) do
        if s.h >= 0.35 * M and s.size >= 0.3 * M then body[#body + 1] = s; hs[#hs + 1] = s.h
        else rest[#rest + 1] = s end
    end
    if #body == 0 then
        body, rest = S, {}
        for i, s in ipairs(S) do hs[i] = s.h end
    end
    local H = math.max(median(hs), 1)
    local kept = {}
    for _, s in ipairs(body) do
        if s.h > 3 * H then rest[#rest + 1] = s else kept[#kept + 1] = s end
    end
    if #kept > 0 then body = kept end

    local parent = {}
    for i = 1, #body do parent[i] = i end
    local function root(i)
        while parent[i] ~= i do parent[i] = parent[parent[i]]; i = parent[i] end
        return i
    end
    for i = 1, #body do
        local a = body[i]
        for j = i + 1, #body do
            local b = body[j]
            local ov = math.min(a.y1, b.y1) - math.max(a.y0, b.y0)
            if ov > 0 and ov >= LINK * math.max(math.min(a.h, b.h), 1) then
                local ri, rj = root(i), root(j)
                if ri ~= rj then parent[ri] = rj end
            end
        end
    end
    local by_root, lines = {}, {}
    for i, s in ipairs(body) do
        local r = root(i)
        local line = by_root[r]
        if not line then
            line = { body = {}, extra = {}, cys = {} }
            by_root[r] = line
            lines[#lines + 1] = line
        end
        line.body[#line.body + 1] = s
        line.cys[#line.cys + 1] = s.cy
    end
    -- a "line" of nothing but small marks (a comma below its word) is not one
    local real = {}
    for _, line in ipairs(lines) do
        local big = 0
        for _, s in ipairs(line.body) do big = math.max(big, s.size) end
        if big >= 0.7 * H then real[#real + 1] = line end
    end
    if #real > 0 and #real < #lines then
        for _, line in ipairs(lines) do
            local big = 0
            for _, s in ipairs(line.body) do big = math.max(big, s.size) end
            if big < 0.7 * H then
                for _, s in ipairs(line.body) do rest[#rest + 1] = s end
            end
        end
        lines = real
    end
    for _, line in ipairs(lines) do line.cy = median(line.cys) end
    table.sort(lines, function(a, b) return a.cy < b.cy end)
    for _, s in ipairs(rest) do
        local best, bd = lines[1], math.huge
        for _, line in ipairs(lines) do
            for _, b in ipairs(line.body) do
                local dx = math.max(0, s.x0 - b.x1, b.x0 - s.x1)
                local dy = math.max(0, s.y0 - b.y1, b.y0 - s.y1)
                local d = dx * dx + dy * dy
                if d < bd then best, bd = line, d end
            end
        end
        best.extra[#best.extra + 1] = s
    end

    local out = {}
    for _, line in ipairs(lines) do
        local lhs = {}
        for i, s in ipairs(line.body) do lhs[i] = s.h end
        local LH = math.max(median(lhs) or H, 1)
        local all = {}
        for _, s in ipairs(line.body) do all[#all + 1] = s end
        for _, s in ipairs(line.extra) do all[#all + 1] = s end
        table.sort(all, function(a, b) return a.order < b.order end)
        local parts, specks = {}, {}
        for _, s in ipairs(all) do
            if s.size < SPECK * LH then specks[#specks + 1] = s else parts[#parts + 1] = s end
        end
        local chars = characters(parts, LH)
        table.sort(chars, function(a, b) return (a.x0 + a.x1) < (b.x0 + b.x1) end)
        -- the baseline and letter height, from the characters of some size
        local bots, hts = {}, {}
        for _, c in ipairs(chars) do
            if c.y1 - c.y0 >= 0.5 * LH then bots[#bots + 1] = c.y1; hts[#hts + 1] = c.y1 - c.y0 end
        end
        local base = median(bots) or line.cy
        local lh = math.max(median(hts) or LH, 1)
        -- a small one-stroke mark low on the line is a comma or a full stop
        local letters, marks = {}, {}
        for _, c in ipairs(chars) do
            if #c.strokes == 1 and math.max(c.x1 - c.x0, c.y1 - c.y0) <= 0.6 * lh and c.y0 >= base - 0.4 * lh then
                marks[#marks + 1] = { x = (c.x0 + c.x1) / 2, text = mark(c, base, lh) }
            else
                letters[#letters + 1] = c
            end
        end
        -- dots: low ones clear of the letters are full stops, the others join
        -- the nearest letter within half a letter's height (an i's dot)
        for _, sp in ipairs(specks) do
            local cx = (sp.x0 + sp.x1) / 2
            -- a mark touching a letter's ink, or a flat one (the end of a bar),
            -- is part of a letter
            local within = (sp.x1 - sp.x0) > 2.5 * (sp.y1 - sp.y0) + 0.1 * lh
            local near2 = (0.12 * lh) ^ 2
            for _, c in ipairs(letters) do
                if within then break end
                if (cx >= c.x0 and cx <= c.x1) or touches(sp, c, near2) then within = true end
            end
            if not within and (sp.y0 + sp.y1) / 2 >= base - 0.3 * lh then
                marks[#marks + 1] = { x = cx, text = mark(sp, base, lh) }
            else
                local best, bd = nil, 0.5 * lh
                for _, c in ipairs(letters) do
                    local d = (cx < c.x0) and (c.x0 - cx) or (cx > c.x1 and cx - c.x1 or 0)
                    if d <= bd then best, bd = c, d end
                end
                if best then grow(best, sp); best.specks = (best.specks or 0) + 1 end
            end
        end
        if #letters > 0 then
            -- each mark follows the letter left of it (one before any letter is dropped)
            table.sort(marks, function(a, b) return a.x < b.x end)
            for _, m in ipairs(marks) do
                local k = 0
                for i, c in ipairs(letters) do
                    if (c.x0 + c.x1) / 2 < m.x then k = i end
                end
                if k > 0 then letters[k].punct = (letters[k].punct or "") .. m.text end
            end
            -- gaps, against the line's own letter spacing
            local gaps, reach = {}, letters[1].x1
            for i = 2, #letters do
                gaps[i - 1] = (letters[i].x0 - reach) / lh
                reach = math.max(reach, letters[i].x1)
            end
            local mid = math.min(Hwr.SPACE_MAX, math.max(Hwr.SPACE_MIN, (median(gaps) or 0) + Hwr.SPACE_OVER))
            local p_space = {}
            for k, g in ipairs(gaps) do
                local p = 1 / (1 + math.exp(-(g - mid) / Hwr.SPACE_SOFT))
                -- a comma is always followed by a space
                if letters[k].punct and letters[k].punct:find(",", 1, true) then p = math.max(p, 0.9) end
                p_space[k] = p
            end
            local words, word = {}, nil
            for i, c in ipairs(letters) do
                if not word or p_space[i - 1] >= 0.5 then
                    word = { chars = {} }
                    words[#words + 1] = word
                end
                word.chars[#word.chars + 1] = c
            end
            out[#out + 1] = { letters = letters, p_space = p_space, words = words, height = lh, base = base }
        end
    end
    return out
end

-- Two neighbouring letters that almost touch and together are about one letter
-- wide may be one letter in two strokes.
local function mergeable(a, b, lh)
    return b.x0 - a.x1 < 0.12 * lh and math.max(a.x1, b.x1) - math.min(a.x0, b.x0) <= 3.0 * lh
        and a.y1 - a.y0 >= 0.4 * lh and b.y1 - b.y0 >= 0.4 * lh
        and a.y1 - a.y0 <= 1.3 * lh and b.y1 - b.y0 <= 1.3 * lh
end

local function joined(a, b)
    local c = { strokes = {}, x0 = math.min(a.x0, b.x0), y0 = math.min(a.y0, b.y0),
        x1 = math.max(a.x1, b.x1), y1 = math.max(a.y1, b.y1),
        specks = (a.specks or 0) + (b.specks or 0), punct = (a.punct or "") .. (b.punct or "") }
    if c.specks == 0 then c.specks = nil end
    if c.punct == "" then c.punct = nil end
    for _, pts in ipairs(a.strokes) do c.strokes[#c.strokes + 1] = pts end
    for _, pts in ipairs(b.strokes) do c.strokes[#c.strokes + 1] = pts end
    return c
end

-- Read one line (from Hwr.segment): the best grouping of its letters into words
-- and of almost touching letters into one. Returns the line's text.
local function readLine(line, net, words)
    local L, P = line.letters, line.p_space
    local n = #L
    local lps, pair = {}, {}
    for i, c in ipairs(L) do lps[i] = net:classify(c.strokes) end
    for i = 1, n - 1 do
        if mergeable(L[i], L[i + 1], line.height) then
            local c = joined(L[i], L[i + 1])
            pair[i] = { c = c, lps = net:classify(c.strokes) }
        end
    end
    -- letters a..b as one word: the best reading over the ways of joining its
    -- almost touching pairs; { score, text, chars, lps, best }
    local function wordOf(a, b)
        local best
        local chars, seq = {}, {}
        local function walk(p, merges)
            if p > b then
                local text, _, idx, score = words:decode(seq)
                score = score - merges * Hwr.MERGE_COST
                if not best or score > best.score then
                    local cs, ls = {}, {}
                    for i = 1, #chars do cs[i] = chars[i]; ls[i] = seq[i] end
                    best = { score = score, text = text, chars = cs, lps = ls, best = idx }
                end
                return
            end
            chars[#chars + 1], seq[#seq + 1] = L[p], lps[p]
            walk(p + 1, merges)
            chars[#chars], seq[#seq] = nil, nil
            if pair[p] and p + 1 <= b and merges < 3 then
                chars[#chars + 1], seq[#seq + 1] = pair[p].c, pair[p].lps
                walk(p + 2, merges + 1)
                chars[#chars], seq[#seq] = nil, nil
            end
        end
        walk(a, 0)
        return best
    end
    -- best[j]: the best reading of letters 1..j ending a word at j
    local best = { [0] = { score = 0 } }
    for j = 1, n do
        if j == n or P[j] > Hwr.SURE_JOIN then
            local inside = 0   -- log chance that the gaps inside the word are not spaces
            for i = j - 1, math.max(0, j - MAX_WORD), -1 do
                if i < j - 1 then
                    if P[i + 1] >= Hwr.SURE_SPACE then break end
                    inside = inside + math.log(1 - P[i + 1])
                end
                if best[i] and (i == 0 or P[i] > Hwr.SURE_JOIN) then
                    local w = wordOf(i + 1, j)
                    local s = best[i].score + w.score + inside
                    if j < n then s = s + math.log(P[j]) - Hwr.WORD_COST end
                    if not best[j] or s > best[j].score then best[j] = { score = s, from = i, word = w } end
                end
            end
        end
    end
    local chosen, j = {}, n
    while j > 0 and best[j] do
        table.insert(chosen, 1, best[j].word)
        j = best[j].from
    end
    -- capitals need the line's x-height, from every letter read
    local all_chars, all_best = {}, {}
    for _, w in ipairs(chosen) do
        for k, c in ipairs(w.chars) do all_chars[#all_chars + 1] = c; all_best[#all_best + 1] = w.best[k] end
    end
    local xh, base = Hwr.lineMetrics(all_chars, net.classes, all_best)
    -- a lone stroke starting a line of words is far more often "I" than "1"
    local I, one = nil, nil
    for i, ch in ipairs(net.classes) do
        if ch == "I" then I = i elseif ch == "1" then one = i end
    end
    local first = chosen[1]
    if first and #chosen > 1 and first.text == "1" and I and one
            and first.lps[1][I] > first.lps[1][one] - Hwr.I_OVER_1 then
        first.text, first.best = "I", { I }
    end
    local out = {}
    for wi, w in ipairs(chosen) do
        local text = Hwr.cased(w.text, w.chars, w.lps, net.classes, xh, base)
        -- put the commas and full stops back after their letters
        if #text == #w.chars then
            local t = {}
            for k = 1, #text do t[k] = text:sub(k, k) .. (w.chars[k].punct or "") end
            text = table.concat(t)
        else
            local tail = {}
            for _, c in ipairs(w.chars) do tail[#tail + 1] = c.punct or "" end
            text = text .. table.concat(tail)
        end
        out[wi] = text
    end
    return table.concat(out, " ")
end

-- Read `strokes` with the character model `net` and the word list `words`.
-- Returns the text: words joined by spaces, lines by new lines.
function Hwr.read(strokes, net, words)
    local out = {}
    for _, line in ipairs(Hwr.segment(strokes)) do out[#out + 1] = readLine(line, net, words) end
    return table.concat(out, "\n")
end

-- Small letters whose own class says they are small and that have no ascender
-- or descender: their height is the line's x-height.
local XHEIGHT_CLASSES = { a = true, e = true, n = true, r = true }

-- A line's x-height, the median height of its characters read as a, e, n or r
-- (nil when there are none), and its baseline, the median bottom of all its
-- characters (most sit on it). `best[i]` is character i's best class index into
-- `classes`.
function Hwr.lineMetrics(chars, classes, best)
    local hs, bottoms = {}, {}
    for i, c in ipairs(chars) do
        if XHEIGHT_CLASSES[classes[best[i]]] then hs[#hs + 1] = c.y1 - c.y0 end
        bottoms[#bottoms + 1] = c.y1
    end
    return median(hs), median(bottoms)
end

-- Capitals for a word. `text` is the decoded word (lower case from the word
-- list, or the classes as read), `chars` its characters, `lps` their class log
-- probabilities, `classes` the class names, `xh` and `base` the line's x-height
-- and baseline (see lineMetrics; xh may be nil). A letter whose small and
-- capital forms differ (a/A, b/B ...) is a capital when the model says so; one
-- whose forms look alike (c/C, o/O ...) when it reaches at least 1.35 x-heights
-- above the baseline, unless it hangs below it (p, y) or carries a dot (i, j).
-- Most letters capital: the word in capitals; a capital first letter: just
-- that one.
function Hwr.cased(text, chars, lps, classes, xh, base)
    local index = {}
    for i, ch in ipairs(classes) do index[ch] = i end
    local verdict, n_letters = {}, 0
    local model_caps, model_known, height_caps, height_known = 0, 0, 0, 0
    for p = 1, #text do
        local ch = text:sub(p, p)
        if ch:match("%a") then
            n_letters = n_letters + 1
            local up, lo = index[ch:upper()], index[ch:lower()]
            local lp = lps[p]
            local c = chars[p]
            local lc = ch:lower()
            if up and lo and up ~= lo and lp then
                verdict[p] = lp[up] > lp[lo]
                model_known = model_known + 1
                if verdict[p] then model_caps = model_caps + 1 end
            elseif c and (lc == "i" or lc == "j") and (c.specks or 0) > 0 then
                verdict[p] = false                                 -- dotted: small
            elseif c and lc == "l" then
                -- l and L are one class and both tall: only a foot makes it L
                verdict[p] = (c.x1 - c.x0) >= 0.55 * (c.y1 - c.y0)
            elseif c and lc == "k" then
                verdict[p] = nil                                   -- k and K are both tall
            elseif xh and c and base and c.y1 > base + 0.3 * xh then
                verdict[p] = false                                 -- hangs below the line: p, y
            elseif xh and c then
                verdict[p] = ((base or c.y1) - c.y0) >= 1.35 * xh
                height_known = height_known + 1
                if verdict[p] then height_caps = height_caps + 1 end
            end
        end
    end
    local lower = text:lower()
    if n_letters == 0 then return text end
    local all_caps
    if model_known > 0 then
        all_caps = n_letters >= 2 and model_caps >= 0.75 * model_known
            and (height_known == 0 or height_caps >= 0.5 * height_known)
    else
        all_caps = n_letters >= 2 and height_known == n_letters and height_caps == height_known
    end
    if all_caps then return text:upper() end
    -- the first letter decides a leading capital
    for p = 1, #text do
        if text:sub(p, p):match("%a") then
            if verdict[p] then return lower:sub(1, p - 1) .. lower:sub(p, p):upper() .. lower:sub(p + 1) end
            break
        end
    end
    return lower
end

return Hwr

--[[
The text of the page a reflowing book shows, a line at a time with where each line
is on the screen, for an export to lay invisible text under the page's picture
(see ink/pdf.lua). The reader gives no call for a page's words with their places,
but it does give the text between two points and the boxes, a line each, of a
stretch of text, which is enough: the lines' boxes come from the whole page, and
each line's text from the reader again along the middle of its box.
]]

local PageText = {}

-- A word without its punctuation, to tell that two spellings are the same word.
local function bare(w) return (w:gsub("[^%w\128-\255]", "")):lower() end

-- Line by line text, set right against the page's whole text. The reader begins a
-- line now and then with the word the line before ended on, and gives a word at a
-- line's end without its comma or its 's. So each line's words are matched, in
-- order, with the page's whole text, which is complete: a word takes its spelling
-- from there, and one that repeats the word just placed is dropped.
local function settle(lines, whole)
    local full = {}
    for w in whole:gmatch("%S+") do full[#full + 1] = w end
    local j = 1   -- the next word of the whole text
    for _i, l in ipairs(lines) do
        local kept = {}
        for w in l.s:gmatch("%S+") do
            local bw = bare(w)
            local nxt, prv = full[j], full[j - 1]
            local bn, bp = nxt and bare(nxt), prv and bare(prv)
            if bn and (bw == bn or (#bw > 0 and (bn:sub(1, #bw) == bw or bw:sub(1, #bn) == bn))) then
                kept[#kept + 1] = nxt
                j = j + 1
            elseif not (bp and #bw > 0 and (bw == bp or bp:sub(1, #bw) == bw or bw:sub(1, #bp) == bp
                    or bp:sub(-#bw) == bw)) then
                -- not where the whole text has it (and not the word just placed, or its
                -- end, which is left out): look a few words on, else keep it
                local found
                for k = j + 1, math.min(#full, j + 3) do
                    if bare(full[k]) == bw then found = k; break end
                end
                if found then
                    for k = j, found do kept[#kept + 1] = full[k] end
                    j = found + 1
                else
                    kept[#kept + 1] = w
                end
            end
        end
        l.s = table.concat(kept, " ")
    end
    -- the last line's own text can stop a word short: what is left of the whole
    -- text, if it is only a word or two, belongs to it
    local last = lines[#lines]
    if last and j <= #full and #full - j < 3 then
        local rest = {}
        for k = j, #full do rest[#rest + 1] = full[k] end
        last.s = last.s .. " " .. table.concat(rest, " ")
    end
end

-- The lines of the page shown, top to bottom: { s = its text, x, y, w, h } in screen
-- pixels. `doc` is the reader's document, `W`, `H` the screen's size. Empty when the
-- page has no text (a picture) or the reader cannot say.
function PageText.lines(doc, W, H)
    local out = {}
    local ok, sel = pcall(doc.getTextFromPositions, doc, { x = 0, y = 0 }, { x = W, y = H }, true)
    if not (ok and sel and sel.pos0 and sel.pos1) then return out end
    local ok2, boxes = pcall(doc.getScreenBoxesFromPositions, doc, sel.pos0, sel.pos1, true)
    if not (ok2 and boxes) then return out end
    for _i, b in ipairs(boxes) do
        if b.w > 2 and b.h > 2 then
            local y = b.y + b.h / 2
            local ok3, r = pcall(doc.getTextFromPositions, doc, { x = b.x + 1, y = y }, { x = b.x + b.w - 1, y = y }, true)
            local s = ok3 and r and r.text
            if type(s) == "string" then
                s = s:gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
                if s ~= "" then out[#out + 1] = { s = s, x = b.x, y = b.y, w = b.w, h = b.h } end
            end
        end
    end
    if type(sel.text) == "string" then settle(out, sel.text) end
    local kept = {}
    for _i, l in ipairs(out) do if l.s ~= "" then kept[#kept + 1] = l end end
    return kept
end

-- Those lines as a PDF page's text lines (see ink/pdf.lua): `pt` points to a pixel,
-- `page_h` the page's height in points. A line's text is sized to three quarters of
-- its box, which holds the leading too.
function PageText.forPdf(lines, pt, page_h)
    local out = {}
    for _i, l in ipairs(lines) do
        out[#out + 1] = { s = l.s, x = l.x * pt, y = page_h - (l.y + l.h * 0.75) * pt, w = l.w * pt,
            size = l.h * 0.75 * pt }
    end
    return out
end

return PageText

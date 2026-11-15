--[[
Exact lines for Make room, the book's side (mixed into Book; the editing of the
page's XHTML is in ink/reader/exactmark.lua, the edited copy in
ink/reader/exactbook.lua).

A box room can only start where something to hang a float on is: a paragraph's
start, an inline element. Where a box is drawn on a line without one, Rooms.planBox
starts the room higher or lower, or finds nowhere. With Exact lines on, the first
word of that line is wrapped in a span in the book's edited copy, and the room
hangs on the span: it starts on that line, to the pixel.

Wrapping a word splits its text node, which renumbers the places after it in that
paragraph (text()[2] becomes text()[4]), so every xpointer Ink Away or KOReader
holds in the book is moved with it (Book:moveXPointers): the highlights, notes and
bookmarks of the reader, the reading place, Ink Away's own ink and rooms. Taking the
marks away again moves them back.
]]

local logger = require("logger")
local Rooms = require("ink/reader/rooms")
local Exact = require("ink/reader/exactbook")
local ExactMark = require("ink/reader/exactmark")

local ExactRooms = {}

-- A short text for a path of element steps, for a mark's id.
local function stepsKey(steps)
    local parts = {}
    for _i, st in ipairs(steps or {}) do parts[#parts + 1] = st.name .. st.idx end
    return table.concat(parts, "-")
end

-- Is the book an EPUB (the only kind whose pages Ink Away can edit a copy of)?
local function isEpub(file)
    return type(file) == "string" and file:lower():match("%.epub$") ~= nil
end

-- Could exact lines be used in this book at all (a reflowing EPUB, render mode floats)?
function ExactRooms:exactAvailable()
    if self.ui.paging or not self:canRoom() or not self:floats() then return false end
    local document = self.ui.document
    return document ~= nil and isEpub(document.file)
end

-- Can a room start on an exact line now: the setting on, and a reflowing EPUB shown
-- in a render mode that floats, laid out with markers, whose ink can be changed.
function ExactRooms:exactOn()
    if not Exact.enabled() then return false end
    if self.ui.paging or not self:canRoom() or not self:floats() then return false end
    local document = self.ui.document
    if not (document and isEpub(document.file)) then return false end
    return not self:data().read_only
end

-- The words wrapped in this book's edited copy.
function ExactRooms:exactMarks()
    return self:data().exact_marks or {}
end

-- Has the book words wrapped (is it read from an edited copy)?
function ExactRooms:hasExact()
    return #self:exactMarks() > 0
end

-- The marks with their `split` (how each word was cut out of its text node),
-- worked out from the book's file for the set the book is read with now.
-- ExactMark.toNew and toOld need them. Nil when the book is not the one the marks
-- were made in.
function ExactRooms:exactState()
    local marks = self:exactMarks()
    if #marks == 0 then return {} end
    local sig = Exact.signature(marks)
    local c = self._exact_state
    if c and c.sig == sig then return c.marks, c.xps end
    local xps, computed = Exact.spanXPointers(self.ui.document.file, marks)
    if not computed then return nil end
    self._exact_state = { sig = sig, marks = computed, xps = xps }
    return computed, xps
end

-- The xpointer in the book as it is now, in the original file's terms.
function ExactRooms:originalXP(xp)
    local state = self:exactState()
    if not state or #state == 0 then return xp end
    return ExactMark.toOld(xp, state) or xp
end

-- The visible word at `w` (a word of the page model: { xp, y, h }), or nil.
local function wordText(document, xp)
    local ok, text = pcall(function()
        return document:getTextFromXPointers(xp, document:getNextVisibleWordEnd(xp))
    end)
    if not (ok and type(text) == "string") then return nil end
    text = text:gsub("^%s+", ""):gsub("%s+$", "")
    if text == "" or #text > 80 or text:find("%s") then return nil end
    return text
end

-- The spans of the book's marks and `mark` ({ [id] = xp }) and the marks with
-- their splits, or nil and why. Kept for the marks the book has now: a box
-- dragged in the Make room tool asks for the same line many times a second.
function ExactRooms:exactSpans(mark)
    local key = mark.id .. "|" .. Exact.signature(self:exactMarks())
    local memo = self._exact_memo
    if not memo or memo.n > 64 then memo = { n = 0, by = {} }; self._exact_memo = memo end
    local hit = memo.by[key]
    if hit then return hit.xps, hit.computed end
    local marks_all = Exact.copyMarks(self:exactMarks())
    marks_all[#marks_all + 1] = mark
    local xps, computed = Exact.spanXPointers(self.ui.document.file, marks_all)
    memo.by[key] = { xps = xps, computed = computed }
    memo.n = memo.n + 1
    return xps, computed
end

-- A mark for the word at `xp` (a word start of the book as it is shown), or nil:
-- where it is in the file's own terms, the word, and the text node it is in when
-- no mark has cut that node yet.
function ExactRooms:markAt(xp)
    local document = self.ui.document
    local orig_xp = self:originalXP(xp)
    local at = ExactMark.parse(orig_xp)
    if not (at and at.text and at.off) then return nil, "no_position" end
    local word = wordText(document, xp)
    if not word then return nil, "no_word" end
    -- (lead: the span begins at the space before the word, so the line before keeps
    -- its last word; a mark of the older kind, "x...", begins at the word)
    local mark = { id = string.format("y%d_%d_%d_%s", at.frag, at.text, at.off, stepsKey(at.steps)),
        frag = at.frag, steps = at.steps, text = at.text, off = at.off, word = word, lead = true }
    -- (a book's own style can change how its nodes are counted: the node checked)
    if orig_xp == xp then
        local nok, node = pcall(document.getTextFromXPointer, document, xp)
        if nok and type(node) == "string" then mark.node_text = node end
    end
    return mark
end

-- Pages before and after the room's page whose lines get a mark too, when a mark
-- is added (the book is loaded again for it anyway): a room made later on one of
-- them hangs on its line's mark, with no loading again.
ExactRooms.SPARE_BEFORE, ExactRooms.SPARE_AFTER = 2, 4
ExactRooms.SPARE_WORDS = 6000   -- (words looked at, at most)

-- Marks for the first word of each line of the pages around the current one
-- that has nothing to hang a room on (a paragraph's first line has its
-- paragraph's marker; a line that begins inside a word, or inside an inline
-- element, is left to an exact room of its own). `known` holds ids to skip.
function ExactRooms:spareMarks(known)
    local document = self.ui.document
    local page = self:currentPage()
    local out = {}
    if not page then return out end
    pcall(function()
        local count = document:getPageCount()
        local p0 = math.max(1, page - ExactRooms.SPARE_BEFORE)
        local p1 = math.min(count, page + ExactRooms.SPARE_AFTER)
        local stop = p1 < count and document:getPageXPointer(p1 + 1) or nil
        local xp = document:getNextVisibleWordStart(document:getPageXPointer(p0))
        local prev_xp, prev_y, prev_block
        for _n = 1, ExactRooms.SPARE_WORDS do
            if not xp then break end
            if stop and (document:compareXPointers(xp, stop) or 0) <= 0 then break end
            local y = document:getPosFromXPointer(xp)
            local block = Rooms.blockOf(xp)
            if prev_y and y and y > prev_y and block and block == prev_block then
                -- a new line of the same paragraph: its first word, when the line
                -- begins with it (not with the end of a word cut by a hyphen)
                local pend = document:getNextVisibleWordEnd(prev_xp)
                local ey = pend and document:getPosFromXPointer(pend)
                local path = xp:gsub("/text%(%).*$", ""):gsub("%.%d+$", "")
                if ey and ey < y and path == block then
                    local mark = self:markAt(xp)
                    -- (only where a space comes before the word: see ExactMark's planWord)
                    if mark then mark.lead = "must" end
                    if mark and not known[mark.id] then
                        known[mark.id] = true
                        out[#out + 1] = mark
                    end
                end
            end
            prev_xp, prev_y, prev_block = xp, y or prev_y, block
            local nxt = document:getNextVisibleWordStart(xp)
            if not nxt or nxt == xp then break end
            xp = nxt
        end
    end)
    return out
end

-- The room a box makes when a word of its top line is wrapped, where it could
-- not start exactly otherwise (Rooms.planBox): the room (and the box it keeps
-- and the area it frees), with the mark to add kept in self._exact_pending; or nil
-- and why. The box grows up to the top of that line, so what it holds stays in it.
function ExactRooms:exactPlan(rect, except)
    if not self:exactOn() then return nil, "off" end
    local model = self:pageModel(except)
    local cache = self._blocks
    local words = cache and cache.words
    if not words or #words == 0 then return nil, "no_text" end
    local document = self.ui.document
    local area = model.area
    local t = math.max(rect.y, area.y0)
    if t >= (model.bottom or area.y1) - 1 then return nil, "no_text" end
    -- the line the box's top is on (or just below), and its first word
    local line_y
    for _i, w in ipairs(words) do
        if w.y <= t + 1 then line_y = w.y else break end
    end
    line_y = line_y or words[1].y
    local first
    for i, w in ipairs(words) do
        if w.y == line_y then first = i; break end
    end
    if not first then return nil, "no_text" end
    local w = words[first]
    local block_xp = Rooms.blockOf(w.xp)
    local block
    for _i, b in ipairs(model.blocks) do
        if b.xp == block_xp then block = b; break end
    end
    if not block then return nil, "no_block" end
    -- the word, in the file's own terms (the book may be read from a copy already)
    local mark, why = self:markAt(w.xp)
    if not mark then return nil, why end
    for _i, m in ipairs(self:exactMarks()) do
        if m.id == mark.id then return nil, "marked" end   -- (a span is there already)
    end
    local xps, computed = self:exactSpans(mark)
    local span = xps and xps[mark.id]
    if not span then return nil, computed or "no_span" end
    if not Rooms.hostable(span) then return nil, "not_hostable" end
    -- the box's top moves up to the line's top
    local r2 = { x = rect.x, w = rect.w, y = math.min(rect.y, line_y), h = rect.h + math.max(0, rect.y - line_y) }
    -- the span as an anchor of its paragraph, on the line it starts
    local ex
    pcall(function()
        local boxes = document:getScreenBoxesFromPositions(w.xp, document:getNextVisibleWordEnd(w.xp), false)
        ex = boxes and boxes[1] and boxes[1].x
    end)
    local ny0, nl1
    for j = first + 1, #words do
        local n = words[j]
        if Rooms.blockOf(n.xp) ~= block_xp then break end
        if n.y > line_y then ny0, nl1 = n.y, n.y + (n.h or 0); break end
    end
    local anchor = { xp = span, y0 = line_y, l1 = line_y + (w.h or 0), ex = ex, at_start = true, ny0 = ny0, nl1 = nl1 }
    local list = block.anchors
    local made = false
    if not list then list = {}; block.anchors = list; made = true end
    local pos = #list + 1
    for i, a in ipairs(list) do if a.y0 > anchor.y0 then pos = i; break end end
    table.insert(list, pos, anchor)
    local ok, room, box, free, loose = pcall(Rooms.planBox, r2, model)
    table.remove(list, pos)
    if made then block.anchors = nil end
    if not ok then return nil, "failed" end
    if not room or loose or room.xp ~= span then return nil, "not_there" end
    self._exact_pending = { xp = span, mark = mark, marks = computed, xps = xps }
    return room, box, free
end

-- Each xpointer string the book holds, moved by `fn(xp)` (which returns the new
-- one, or nil to leave it): the reader's highlights, notes and bookmarks, the
-- reading place, Ink Away's ink and rooms. `skip` is a room table to leave alone.
function ExactRooms:moveXPointers(fn, skip)
    local function mv(t, key)
        local v = t[key]
        if type(v) == "string" and v:sub(1, 6) == "/body[" then
            local n = fn(v)
            if n then t[key] = n end
        end
    end
    local ui = self.ui
    local ann = ui.annotation and ui.annotation.annotations
    if type(ann) == "table" then
        for _i, a in ipairs(ann) do
            mv(a, "page"); mv(a, "pos0"); mv(a, "pos1")
        end
    end
    if ui.rolling and type(ui.rolling.xpointer) == "string" then
        local n = fn(ui.rolling.xpointer)
        if n then ui.rolling.xpointer = n end
    end
    local data = self:data()
    -- (an item is written out once and kept as text while it lives, see
    -- ink/reader/bookink.lua: a changed one is a new item)
    for i, it in ipairs(data.items) do
        if type(it.a) == "table" then
            local a = {}
            for k, v in pairs(it.a) do a[k] = v end
            mv(a, "xp0"); mv(a, "xp1"); mv(a, "pxp")
            if a.xp0 ~= it.a.xp0 or a.xp1 ~= it.a.xp1 or a.pxp ~= it.a.pxp then
                local n = {}
                for k, v in pairs(it) do n[k] = v end
                n.a = a
                data.items[i] = n
            end
        end
    end
    for _i, r in ipairs(data.rooms or {}) do
        if r ~= skip then
            mv(r, "xp"); mv(r, "sp")
            if type(r.xps) == "table" then
                for k, x in ipairs(r.xps) do
                    local n = type(x) == "string" and fn(x)
                    if n then r.xps[k] = n end
                end
            end
        end
    end
    self._blocks, self._index, self._placed, self._text_starts = nil, nil, nil, nil
end

-- Add the pending mark (made by exactPlan for room `r`): every xpointer moves to
-- where it is once the word is wrapped, and the mark is kept with the book. The
-- room itself is already in the edited copy's terms.
function ExactRooms:addExactMark(r)
    local pending = self._exact_pending
    if not (pending and pending.xp == r.xp) then return false end
    local before, before_xps = self:exactState()
    if not before then return false end
    local after, after_xps = pending.marks, pending.xps
    -- the lines of the pages around get their marks in the same go (only when all of
    -- them, the book's and the new one, still go in as they did)
    local known = {}
    for _i, m in ipairs(after) do known[m.id] = true end
    local spares = self:spareMarks(known)
    if #spares > 0 then
        local all = Exact.copyMarks(after)
        for _i, m in ipairs(spares) do all[#all + 1] = m end
        local xps2, computed2 = Exact.spanXPointers(self.ui.document.file, all)
        local ok = computed2 ~= nil
        local kept = {}
        for i, m in ipairs(computed2 or {}) do
            if m.split then
                kept[#kept + 1] = m
            elseif i <= #after then
                ok = false   -- (a mark the book needs did not go in with them)
            end
        end
        if ok and xps2[pending.mark.id] then after, after_xps = kept, xps2 end
    end
    local bad = false
    -- (an earlier mark's span is the same span afterwards, where the numbering moved it)
    local by_span = {}
    for id, xp in pairs(before_xps or {}) do by_span[xp] = after_xps[id] end
    self:moveXPointers(function(xp)
        if by_span[xp] then return by_span[xp] end
        local orig = #before > 0 and ExactMark.toOld(xp, before) or xp
        local new = orig and ExactMark.toNew(orig, after)
        if not new then bad = true end
        return new
    end, r)
    -- the room itself was planned with the new mark alone: moved to the final copy
    if after ~= pending.marks then
        local pend_span = {}
        for id, xp in pairs(pending.xps) do pend_span[xp] = after_xps[id] end
        local function mv(x)
            if type(x) ~= "string" then return x end
            if pend_span[x] then return pend_span[x] end
            local orig = ExactMark.toOld(x, pending.marks)
            local new = orig and ExactMark.toNew(orig, after)
            if not new then bad = true end
            return new or x
        end
        r.xp, r.sp = mv(r.xp), mv(r.sp)
        pending.xp = r.xp
    end
    if bad then logger.warn("Ink Away: some places in the book could not be moved to the edited copy") end
    Exact.slim(after)
    local data = self:data()
    data.exact_marks = after
    data.room_marks = 2   -- (inline elements carry markers: the span is one)
    self._exact_pending, self._exact_state, self._exact_memo = nil, nil, nil
    return true
end

-- Take every mark away, so the book is read as it is on the reader's storage again:
-- the xpointers move back. Not while a room hangs on one of the spans. Returns
-- true, or false and why. The book is loaded again by the caller.
function ExactRooms:removeExactMarks()
    local marks = self:exactMarks()
    if #marks == 0 then return true end
    local file = self.ui.document.file
    local xps, state = Exact.spanXPointers(file, marks)
    if not state then return false, "unreadable" end
    local spans = {}
    for _id, xp in pairs(xps or {}) do spans[xp] = true end
    for _i, r in ipairs(self:rooms()) do
        if spans[r.xp] or (r.sp and spans[r.sp]) then return false, "rooms" end
    end
    local copy = Exact.pathFor(file, marks)
    self:moveXPointers(function(xp) return (ExactMark.toOld(xp, state)) end)
    local data = self:data()
    data.exact_marks = nil
    self._exact_state, self._exact_memo = nil, nil
    self:save()
    if copy then os.remove(copy) end
    return true
end

function ExactRooms.into(Class)
    for k, f in pairs(ExactRooms) do
        if k ~= "into" then Class[k] = f end
    end
end

return ExactRooms

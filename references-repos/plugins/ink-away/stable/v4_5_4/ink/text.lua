--[[
Rich text model, layout and rendering for the note text box.

A text op is one entry in a page's ops list, so it saves, undoes and exports
through the same engine as everything else:

    { kind = "text",
      x, y, w, h,          -- box rect in canvas pixels (h auto-grows unless set)
      auto_h = true,       -- height follows the content until the user resizes
      font = <name|nil>,   -- nil uses the default font
      size = <px>,         -- base glyph size
      align = "left"|"center"|"right",
      angle = <degrees>,   -- turned clockwise about (x, y); nil or 0 upright
      grid_snap = false,   -- snap each line to the ruling
      spacing = nil|"tight"|"loose",   -- line spacing (nil is normal)
      paras = {            -- paragraphs (a newline starts a new paragraph)
        { bullet = nil|"disc"|"number"|"check", checked = true|nil,
          spans = { { t = "text", b=, i=, u=, s=, hl=, sz=, c= }, ... } },
        ...
      } }

A span is a maximal run of one style. Style flags: b bold, i italic, u
underline, s strikethrough; hl highlight (true for the default colour, or a
colour packed as 0xRRGGBB); c the letters' colour, packed the same (nil is the
page's ink); sz is a size multiplier (nil = 1).

Layout and the edit operations are pure Lua and take an injected `ctx` for any
measuring, so they run under the headless tests. Only render() touches KOReader
(RenderText), and it is loaded lazily.

A turned box keeps its own frame: x along its lines and y down them, from its
top-left corner (x, y), about which it turns. Text.toPage and Text.toLocal map
a point between that frame and the page, and Text.bounds is the page box it
covers, so everything that finds, erases or redraws a box follows its angle.
]]

local Text = {}

------------------------------------------------------------------------------
-- UTF-8 helpers (LuaJIT has no utf8 library). One pattern matches one glyph's
-- bytes: an ASCII/lead byte followed by any continuation bytes.
------------------------------------------------------------------------------

local UTF8 = "[%z\1-\127\194-\253][\128-\191]*"

local function chars(s)
    local t = {}
    for c in s:gmatch(UTF8) do t[#t + 1] = c end
    return t
end

local function ulen(s)
    local n = 0
    for _ in s:gmatch(UTF8) do n = n + 1 end
    return n
end

-- substring by character offsets [i, j) (0-based, j exclusive)
local function usub(s, i, j)
    local out, k = {}, 0
    for c in s:gmatch(UTF8) do
        if k >= i and (not j or k < j) then out[#out + 1] = c end
        k = k + 1
        if j and k >= j then break end
    end
    return table.concat(out)
end

Text.chars, Text.ulen, Text.usub = chars, ulen, usub

------------------------------------------------------------------------------
-- Style helpers
------------------------------------------------------------------------------

local STYLE_KEYS = { "b", "i", "u", "s", "hl", "sz", "c" }

-- A colour {r, g, b} packed into one number (as style.c and style.hl keep it),
-- and back.
function Text.packRGB(rgb)
    return rgb[1] * 65536 + rgb[2] * 256 + rgb[3]
end

function Text.unpackRGB(n)
    n = math.floor(n)
    return { math.floor(n / 65536) % 256, math.floor(n / 256) % 256, n % 256 }
end

local function copyStyle(st)
    local o = {}
    if st then for _, k in ipairs(STYLE_KEYS) do o[k] = st[k] end end
    return o
end

local function sameStyle(a, b)
    for _, k in ipairs(STYLE_KEYS) do
        if (a[k] or false) ~= (b[k] or false) then return false end
    end
    return true
end

------------------------------------------------------------------------------
-- A turned box's geometry
------------------------------------------------------------------------------

-- cos and sin of a box's angle (1, 0 when upright), exact for quarter turns.
function Text.turn(op)
    local a = (op.angle or 0) % 360
    if a == 0 then return 1, 0 end
    if a == 90 then return 0, 1 end
    if a == 180 then return -1, 0 end
    if a == 270 then return 0, -1 end
    local r = math.rad(a)
    return math.cos(r), math.sin(r)
end

function Text.turned(op) return ((op.angle or 0) % 360) ~= 0 end

-- A point (lx, ly) of the box's own frame on the page.
function Text.toPage(op, lx, ly)
    local c, s = Text.turn(op)
    return op.x + lx * c - ly * s, op.y + lx * s + ly * c
end

-- A page point in the box's own frame.
function Text.toLocal(op, px, py)
    local c, s = Text.turn(op)
    local dx, dy = px - op.x, py - op.y
    return dx * c + dy * s, -dx * s + dy * c
end

-- The page box x0, y0, x1, y1 the box covers, or nil before it is laid out.
function Text.bounds(op)
    local h = op.h
    if not (h and h > 0) then return nil end   -- (also catches NaN)
    local w = op.w or 0
    if not Text.turned(op) then return op.x, op.y, op.x + w, op.y + h end
    local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
    for _, p in ipairs({ { 0, 0 }, { w, 0 }, { 0, h }, { w, h } }) do
        local x, y = Text.toPage(op, p[1], p[2])
        x0, y0 = math.min(x0, x), math.min(y0, y)
        x1, y1 = math.max(x1, x), math.max(y1, y)
    end
    return x0, y0, x1, y1
end

-- The middle of the box on the page.
function Text.centre(op)
    return Text.toPage(op, (op.w or 0) / 2, (op.h or 0) / 2)
end

-- Is the page point (px, py) on the box, within `slack` of it?
function Text.contains(op, px, py, slack)
    slack = slack or 0
    local lx, ly = Text.toLocal(op, px, py)
    return lx >= -slack and lx <= (op.w or 0) + slack and ly >= -slack and ly <= (op.h or 0) + slack
end

-- Turn the box to `deg` degrees about its middle (it stays where it is).
function Text.turnTo(op, deg)
    local cx, cy = Text.centre(op)
    deg = deg % 360
    if math.abs(deg - math.floor(deg + 0.5)) < 1e-6 then deg = math.floor(deg + 0.5) % 360 end
    op.angle = deg ~= 0 and deg or nil
    local c, s = Text.turn(op)
    local hw, hh = (op.w or 0) / 2, (op.h or 0) / 2
    op.x, op.y = cx - (hw * c - hh * s), cy - (hw * s + hh * c)
end

------------------------------------------------------------------------------
-- Construction and normalisation
------------------------------------------------------------------------------

local function emptyPara(bullet)
    return { bullet = bullet, spans = { { t = "" } } }
end

-- Build a fresh text op. opts: x, y, w, size, font, align, grid_snap.
function Text.new(opts)
    opts = opts or {}
    return {
        kind = "text",
        x = opts.x or 0, y = opts.y or 0,
        w = opts.w or 100, h = opts.h,
        auto_h = opts.h == nil,
        font = opts.font, size = opts.size or 32,
        align = opts.align or "left",
        grid_snap = opts.grid_snap or false,
        paras = { emptyPara() },
    }
end

-- Concatenated text of one paragraph.
local function paraText(p)
    local t = {}
    for _, sp in ipairs(p.spans) do t[#t + 1] = sp.t end
    return table.concat(t)
end
Text.paraText = paraText

function Text.paraLen(p) return ulen(paraText(p)) end

-- Merge neighbouring same-style spans and drop empties; keep one empty span so a
-- paragraph is never span-less.
local function normalizePara(p)
    local out = {}
    for _, sp in ipairs(p.spans) do
        if sp.t ~= "" then
            local last = out[#out]
            if last and sameStyle(last, sp) then
                last.t = last.t .. sp.t
            else
                out[#out + 1] = sp
            end
        end
    end
    if #out == 0 then out[1] = { t = "" } end
    p.spans = out
end

-- The plain text of the whole op (for search and emptiness checks).
function Text.plain(op)
    local t = {}
    for _, p in ipairs(op.paras) do t[#t + 1] = paraText(p) end
    return table.concat(t, "\n")
end

-- The plain text of a selection (paragraphs joined with "\n"), for copying.
function Text.plainRange(op, sel)
    local a, b = Text.orderSel(sel)
    local out = {}
    for pi = a.p, b.p do
        local t = paraText(op.paras[pi])
        out[#out + 1] = usub(t, (pi == a.p) and a.o or 0, (pi == b.p) and b.o or nil)
    end
    return table.concat(out, "\n")
end

function Text.isEmpty(op)
    return #op.paras == 1 and paraText(op.paras[1]) == ""
end

------------------------------------------------------------------------------
-- Cursor addressing. A cursor is { p = <paragraph idx>, o = <char offset> }.
-- Selections are { a = cur, b = cur }; orderSel returns them start..end.
------------------------------------------------------------------------------

local function curLE(a, b)   -- a <= b ?
    if a.p ~= b.p then return a.p < b.p end
    return a.o <= b.o
end

function Text.orderSel(sel)
    if curLE(sel.a, sel.b) then return sel.a, sel.b end
    return sel.b, sel.a
end

function Text.selEmpty(sel)
    return sel.a.p == sel.b.p and sel.a.o == sel.b.o
end

-- Split a paragraph's spans at char offset `o`, returning left and right span
-- lists (each normalised, never empty). Styles are preserved on both sides.
local function splitSpans(p, o)
    local left, right = {}, {}
    local k = 0
    for _, sp in ipairs(p.spans) do
        local n = ulen(sp.t)
        if o >= k + n then
            left[#left + 1] = sp
        elseif o <= k then
            right[#right + 1] = sp
        else
            local cut = o - k
            local a = copyStyle(sp); a.t = usub(sp.t, 0, cut)
            local b = copyStyle(sp); b.t = usub(sp.t, cut)
            left[#left + 1] = a
            right[#right + 1] = b
        end
        k = k + n
    end
    if #left == 0 then left[1] = { t = "" } end
    if #right == 0 then right[1] = { t = "" } end
    return left, right
end

-- Style that new typing at the cursor should inherit: the style of the char just
-- before the cursor, else the first span's style.
function Text.styleAt(op, cur)
    local p = op.paras[cur.p]
    if not p then return {} end
    if cur.o == 0 then return copyStyle(p.spans[1]) end
    local k = 0
    for _, sp in ipairs(p.spans) do
        local n = ulen(sp.t)
        if cur.o <= k + n then return copyStyle(sp) end
        k = k + n
    end
    return copyStyle(p.spans[#p.spans])
end

------------------------------------------------------------------------------
-- Editing operations. Each mutates op.paras and returns the new cursor.
------------------------------------------------------------------------------

-- Delete a (non-empty) selection; returns the collapsed cursor.
function Text.deleteRange(op, sel)
    local a, b = Text.orderSel(sel)
    if a.p == b.p then
        local p = op.paras[a.p]
        local left = splitSpans(p, a.o)
        local _, right = splitSpans(p, b.o)
        local spans = {}
        for _, sp in ipairs(left) do spans[#spans + 1] = sp end
        for _, sp in ipairs(right) do spans[#spans + 1] = sp end
        p.spans = spans
        normalizePara(p)
        return { p = a.p, o = a.o }
    end
    -- multi-paragraph: keep head of first + tail of last, drop the middle
    local first, last = op.paras[a.p], op.paras[b.p]
    local head = splitSpans(first, a.o)
    local _, tail = splitSpans(last, b.o)
    local spans = {}
    for _, sp in ipairs(head) do spans[#spans + 1] = sp end
    for _, sp in ipairs(tail) do spans[#spans + 1] = sp end
    first.spans = spans
    normalizePara(first)
    for i = b.p, a.p + 1, -1 do table.remove(op.paras, i) end
    return { p = a.p, o = a.o }
end

-- Insert plain text (may contain newlines) at the cursor, all in one style
-- (defaults to the inherited style). Returns the cursor after the insert.
function Text.insert(op, cur, str, style)
    style = style or Text.styleAt(op, cur)
    local p = op.paras[cur.p]
    local left, right = splitSpans(p, cur.o)
    local pieces = {}
    do   -- split str on "\n" (keep empty trailing pieces)
        local start = 1
        while true do
            local nl = str:find("\n", start, true)
            if not nl then pieces[#pieces + 1] = str:sub(start); break end
            pieces[#pieces + 1] = str:sub(start, nl - 1)
            start = nl + 1
        end
    end
    if #pieces == 1 then
        local spans = {}
        for _, sp in ipairs(left) do spans[#spans + 1] = sp end
        if pieces[1] ~= "" then local sp = copyStyle(style); sp.t = pieces[1]; spans[#spans + 1] = sp end
        for _, sp in ipairs(right) do spans[#spans + 1] = sp end
        p.spans = spans
        normalizePara(p)
        return { p = cur.p, o = cur.o + ulen(pieces[1]) }
    end
    -- multi-line: first piece joins the head, last piece precedes the tail,
    -- middle pieces become their own paragraphs. New paragraphs inherit the
    -- bullet of the paragraph being split.
    local firstSpans = {}
    for _, sp in ipairs(left) do firstSpans[#firstSpans + 1] = sp end
    if pieces[1] ~= "" then local sp = copyStyle(style); sp.t = pieces[1]; firstSpans[#firstSpans + 1] = sp end
    p.spans = firstSpans
    normalizePara(p)
    local insertAt = cur.p
    for i = 2, #pieces - 1 do
        insertAt = insertAt + 1
        local np = { bullet = p.bullet, spans = {} }
        if pieces[i] ~= "" then
            local sp = copyStyle(style); sp.t = pieces[i]; np.spans[1] = sp
        else
            np.spans[1] = { t = "" }
        end
        table.insert(op.paras, insertAt, np)
    end
    insertAt = insertAt + 1
    local lastSpans = {}
    local lastPiece = pieces[#pieces]
    if lastPiece ~= "" then local sp = copyStyle(style); sp.t = lastPiece; lastSpans[#lastSpans + 1] = sp end
    for _, sp in ipairs(right) do lastSpans[#lastSpans + 1] = sp end
    local np = { bullet = p.bullet, spans = lastSpans }
    normalizePara(np)
    table.insert(op.paras, insertAt, np)
    return { p = insertAt, o = ulen(lastPiece) }
end

-- Backspace one char (or join with the previous paragraph at the start).
function Text.deleteBack(op, cur)
    if cur.o > 0 then
        return Text.deleteRange(op, { a = { p = cur.p, o = cur.o - 1 }, b = cur })
    end
    if cur.p == 1 then return cur end   -- nothing before
    local prev = op.paras[cur.p - 1]
    local prevLen = Text.paraLen(prev)
    -- merge current paragraph's spans onto the previous one
    local spans = {}
    for _, sp in ipairs(prev.spans) do spans[#spans + 1] = sp end
    for _, sp in ipairs(op.paras[cur.p].spans) do spans[#spans + 1] = sp end
    prev.spans = spans
    normalizePara(prev)
    table.remove(op.paras, cur.p)
    return { p = cur.p - 1, o = prevLen }
end

-- Apply a style change across a selection. `key` is one of the style keys;
-- `value` the value to set (for a toggle, pass the new boolean). Returns nothing;
-- op.paras is edited in place with spans split at the range boundaries.
function Text.applyStyle(op, sel, key, value)
    local a, b = Text.orderSel(sel)
    local function styleParaRange(pi, o0, o1)
        local p = op.paras[pi]
        local left, after = splitSpans(p, o0)
        -- split the rest again at (o1 - o0), in its own coordinates
        local mid, right = splitSpans({ spans = after }, o1 - o0)
        for _, sp in ipairs(mid) do sp[key] = value or nil end
        local spans = {}
        for _, sp in ipairs(left) do spans[#spans + 1] = sp end
        for _, sp in ipairs(mid) do spans[#spans + 1] = sp end
        for _, sp in ipairs(right) do spans[#spans + 1] = sp end
        p.spans = spans
        normalizePara(p)
    end
    if a.p == b.p then
        styleParaRange(a.p, a.o, b.o)
    else
        styleParaRange(a.p, a.o, Text.paraLen(op.paras[a.p]))
        for pi = a.p + 1, b.p - 1 do
            styleParaRange(pi, 0, Text.paraLen(op.paras[pi]))
        end
        styleParaRange(b.p, 0, b.o)
    end
end

-- Is `key` set on every char of the selection? Decides which way a toggle goes.
function Text.styleCovers(op, sel, key)
    local a, b = Text.orderSel(sel)
    if Text.selEmpty(sel) then
        return Text.styleAt(op, a)[key] and true or false
    end
    local function paraCovered(pi, o0, o1)
        if o1 <= o0 then return true end
        local p = op.paras[pi]
        local k = 0
        for _, sp in ipairs(p.spans) do
            local n = ulen(sp.t)
            local lo, hi = math.max(o0, k), math.min(o1, k + n)
            if hi > lo and not sp[key] then return false end
            k = k + n
        end
        return true
    end
    if a.p == b.p then return paraCovered(a.p, a.o, b.o) end
    if not paraCovered(a.p, a.o, Text.paraLen(op.paras[a.p])) then return false end
    for pi = a.p + 1, b.p - 1 do
        if not paraCovered(pi, 0, Text.paraLen(op.paras[pi])) then return false end
    end
    return paraCovered(b.p, 0, b.o)
end

-- Set the bullet type of every paragraph the selection touches. `kind` is nil,
-- "disc", "number" or "check" (a box to tick). Toggling the same kind off is
-- the caller's job.
function Text.setBullet(op, sel, kind)
    local a, b = Text.orderSel(sel)
    for pi = a.p, b.p do
        op.paras[pi].bullet = kind
        if kind ~= "check" then op.paras[pi].checked = nil end
    end
end

-- The size of a checklist's box, and the indent of its text, for a paragraph
-- whose letters have ascent `asc`.
function Text.checkMetrics(asc)
    local box = math.max(6, math.floor(asc * 0.8 + 0.5))
    return box, box + math.max(4, math.floor(asc * 0.5 + 0.5))
end

-- The checklist box on a laid-out line at op-local (lx, ly), as the paragraph
-- index, or nil. The box's whole indent counts, and the line's height.
function Text.checkAt(layout, lx, ly)
    for _, ln in ipairs(layout.lines) do
        if ln.bullet and ln.bullet.check and ly >= ln.top and ly < ln.top + ln.height
                and lx >= ln.bullet.x - 2 and lx <= ln.text_x then
            return ln.para
        end
    end
end

------------------------------------------------------------------------------
-- Layout. `ctx` supplies all measuring so this stays pure:
--   ctx.measure(text, style)  -> pixel width of that text in that style
--   ctx.lineHeight(style)     -> line box height in px for that style
--   ctx.ascent(style)         -> baseline offset from the line top in px
--   ctx.bulletLabel(para, n)  -> "• " / "1. " string for a bulleted paragraph
--   ctx.gridStep, ctx.gridPhase (optional) -> snap each line onto the ruling
-- Returns { lines = {...}, width = op.w, height = <total px> }. Each line:
--   { para, first, top, height, baseline, text_x, o_start, o_end,
--     bullet = { text, style, x } | nil, segs = { {t, style, x, w, o0} } }
------------------------------------------------------------------------------

-- Break one paragraph's spans into tokens split on spaces and style, each
-- carrying its char offset within the paragraph.
local function tokenize(p)
    local toks, off = {}, 0
    for _, sp in ipairs(p.spans) do
        -- split sp.t into maximal space / non-space chunks, keeping utf8 chars
        local buf, buf_is_space, buf_o = {}, nil, off
        local k = off
        for _, c in ipairs(chars(sp.t)) do
            local is_sp = (c == " ")
            if buf_is_space == nil then buf_is_space = is_sp; buf_o = k end
            if is_sp ~= buf_is_space then
                toks[#toks + 1] = { t = table.concat(buf), style = sp, sp = buf_is_space, o0 = buf_o }
                buf, buf_is_space, buf_o = {}, is_sp, k
            end
            buf[#buf + 1] = c
            k = k + 1
        end
        if #buf > 0 then
            toks[#toks + 1] = { t = table.concat(buf), style = sp, sp = buf_is_space, o0 = buf_o }
        end
        off = off + ulen(sp.t)
    end
    return toks, off
end

-- Break any non-space token wider than the line into character-sized pieces that
-- each fit, so a single very long word wraps instead of overflowing the box. Each
-- piece keeps the token's style and its own char offset, so the cursor and hit
-- testing still line up. A single char wider than the line is emitted on its own.
local function breakLongTokens(toks, avail, ctx)
    local out = {}
    for _, tk in ipairs(toks) do
        if tk.sp or ctx.measure(tk.t, tk.style) <= avail then
            out[#out + 1] = tk
        else
            local cs = chars(tk.t)
            local buf, buf_w, buf_o = {}, 0, tk.o0
            for k, c in ipairs(cs) do
                local cw = ctx.measure(c, tk.style)
                if #buf > 0 and buf_w + cw > avail then
                    out[#out + 1] = { t = table.concat(buf), style = tk.style, sp = false, o0 = buf_o }
                    buf, buf_w, buf_o = {}, 0, tk.o0 + (k - 1)
                end
                buf[#buf + 1] = c
                buf_w = buf_w + cw
            end
            if #buf > 0 then
                out[#out + 1] = { t = table.concat(buf), style = tk.style, sp = false, o0 = buf_o }
            end
        end
    end
    return out
end

-- Merge a run of tokens into style segments with x offsets, from a start x.
local function segmentsFromTokens(toks, i0, i1, x0, ctx)
    local segs, x = {}, x0
    for i = i0, i1 do
        local tk = toks[i]
        local last = segs[#segs]
        if last and sameStyle(last.style, tk.style) then
            last.t = last.t .. tk.t
            last.w = last.w + ctx.measure(tk.t, tk.style)
        else
            segs[#segs + 1] = { t = tk.t, style = tk.style, o0 = tk.o0,
                                w = ctx.measure(tk.t, tk.style) }
        end
    end
    for _, sg in ipairs(segs) do sg.x = x; x = x + sg.w end
    return segs
end

function Text.layout(op, ctx)
    local lines = {}
    local y = 0
    for pi, p in ipairs(op.paras) do
        local indent, bulletLabel, bulletStyle, check = 0, nil, nil, nil
        if p.bullet == "check" then
            -- a box drawn by the renderer, sized to the letters (no font needed)
            bulletStyle = p.spans[1]
            local box
            box, indent = Text.checkMetrics(ctx.ascent(bulletStyle))
            check = { box = box }
        elseif p.bullet and ctx.bulletLabel then
            bulletLabel = ctx.bulletLabel(p, pi)
            bulletStyle = p.spans[1]
            indent = ctx.measure(bulletLabel, bulletStyle)
        end
        local avail = math.max(1, op.w - indent)
        local toks = breakLongTokens(tokenize(p), avail, ctx)

        -- greedy wrap into runs of token indices [start..last]
        local function flush(i0, i1, is_first)
            -- trim a single trailing space token from the width used for align
            local segs = segmentsFromTokens(toks, i0, i1, 0, ctx)
            local content_w = 0
            for _, sg in ipairs(segs) do content_w = content_w + sg.w end
            local line_indent = indent
            local extra = 0
            if op.align == "center" then extra = math.max(0, (avail - content_w) / 2)
            elseif op.align == "right" then extra = math.max(0, avail - content_w) end
            local text_x = line_indent + extra
            for _, sg in ipairs(segs) do sg.x = sg.x + text_x end
            -- line metrics: tallest style on the line (or the paragraph style)
            local lh, asc = ctx.lineHeight(p.spans[1]), ctx.ascent(p.spans[1])
            for _, sg in ipairs(segs) do
                lh = math.max(lh, ctx.lineHeight(sg.style))
                asc = math.max(asc, ctx.ascent(sg.style))
            end
            local o_start = (i0 <= i1) and toks[i0].o0 or (lines[#lines] and lines[#lines].o_end or 0)
            local o_end = (i0 <= i1) and (toks[i1].o0 + ulen(toks[i1].t)) or o_start
            -- Grid-line snapping: when a ruling step is supplied, each line
            -- occupies a whole number of ruling rows and its baseline rests on
            -- the ruling at the row's bottom, so text lands on the printed lines
            -- whatever its size (the box origin is snapped to the ruling, so the
            -- op-local rulings fall at multiples of the step from y = 0).
            local top, adv, baseline = y, lh, y + asc
            if ctx.gridStep and ctx.gridStep > 0 then
                local step = ctx.gridStep
                -- Rows are counted from the ascent (baseline to the top of the tall
                -- letters), not the full line box, whose leading and descender
                -- space would push large one-row text onto two rows. The font is
                -- sized so the ascent nearly fills a row.
                adv = math.max(1, math.ceil((asc - 0.5) / step)) * step
                baseline = y + adv           -- sit on the ruling at the row bottom
            end
            local line = {
                para = pi, first = is_first, top = top, height = adv, baseline = baseline,
                text_x = text_x, o_start = o_start, o_end = o_end, segs = segs,
            }
            if is_first and check then
                line.bullet = { check = true, checked = p.checked or false, box = check.box,
                    style = bulletStyle, x = 0 }
            elseif is_first and bulletLabel then
                line.bullet = { text = bulletLabel, style = bulletStyle, x = 0 }
            end
            lines[#lines + 1] = line
            y = y + adv
        end

        if #toks == 0 then
            flush(1, 0, true)   -- empty paragraph: one empty line
        else
            local i0, cur_w, is_first = 1, 0, true
            for i = 1, #toks do
                local w = ctx.measure(toks[i].t, toks[i].style)
                if not toks[i].sp and cur_w > 0 and cur_w + w > avail then
                    flush(i0, i - 1, is_first); is_first = false
                    i0, cur_w = i, 0
                end
                cur_w = cur_w + w
            end
            flush(i0, #toks, is_first)
        end
    end
    -- if the very last paragraph ends with an explicit empty line handled above
    return { lines = lines, width = op.w, height = y }
end

-- Pixel x of the caret at char offset o on a given line.
local function caretXOnLine(line, o, ctx)
    local x = line.text_x
    for _, sg in ipairs(line.segs) do
        local segEnd = sg.o0 + ulen(sg.t)
        if o >= segEnd then
            x = sg.x + sg.w
        elseif o <= sg.o0 then
            return x
        else
            return sg.x + ctx.measure(usub(sg.t, 0, o - sg.o0), sg.style)
        end
    end
    return x
end

-- The line index a cursor sits on (the earliest line whose range contains o).
local function lineOfCursor(layout, cur)
    local fallback
    for i, ln in ipairs(layout.lines) do
        if ln.para == cur.p then
            fallback = i
            if cur.o <= ln.o_end then return i end
        end
    end
    return fallback or 1
end

-- Width of a laid-out line's text.
local function lineContentWidth(line)
    local w = 0
    for _, sg in ipairs(line.segs) do w = w + sg.w end
    return w
end

Text.caretX = caretXOnLine
Text.lineContentWidth = lineContentWidth

-- Caret geometry {x, y, h} in op-local pixels for the cursor.
function Text.caret(op, layout, cur, ctx)
    local i = lineOfCursor(layout, cur)
    local ln = layout.lines[i] or { text_x = 0, top = 0, height = ctx.lineHeight(op.paras[1].spans[1]) }
    return { x = caretXOnLine(ln, cur.o, ctx), y = ln.top, h = ln.height }
end

-- Hit test: op-local (lx, ly) -> nearest cursor {p, o}.
function Text.hit(_op, layout, lx, ly, ctx)
    local pick
    for _, ln in ipairs(layout.lines) do
        if ly < ln.top + ln.height then pick = ln; break end
    end
    pick = pick or layout.lines[#layout.lines]
    if not pick then return { p = 1, o = 0 } end
    -- walk chars on the line, choose the boundary nearest lx
    local best_o, best_dx = pick.o_start, math.abs(lx - pick.text_x)
    local x = pick.text_x
    for _, sg in ipairs(pick.segs) do
        local cs = chars(sg.t)
        local o = sg.o0
        for _, c in ipairs(cs) do
            x = x + ctx.measure(c, sg.style)
            o = o + 1
            local dx = math.abs(lx - x)
            if dx < best_dx then best_dx, best_o = dx, o end
        end
    end
    return { p = pick.para, o = best_o }
end

------------------------------------------------------------------------------
-- Rendering. Draws the laid-out text into a blitbuffer at (ox, oy) in that
-- buffer's pixels. `rctx` supplies KOReader bits so layout stays testable:
--   rctx.color         -> the letters' colour (Blitbuffer colour)
--   rctx.highlight     -> the highlight's colour
--   rctx.ink(c)        -> for a span with a colour c (packed): its colour, and
--                         whether it is a real colour to keep (optional)
--   rctx.mark(hl)      -> the same for a span's highlight (optional)
--   rctx.lineWidth     -> px thickness for underline / strike / bullet rules
-- Underline, strikethrough and highlight are drawn by us; bold/size come from
-- the face (ctx.face, ctx.bold); italic is slanted here. A colour is kept on a
-- colour (RGB32) bitmap; on any other KOReader shows it as its grey.
------------------------------------------------------------------------------

function Text.render(_op, layout, bb, ox, oy, ctx, rctx)
    local RenderText = require("ui/rendertext")
    local Blitbuffer = require("ffi/blitbuffer")
    local fg = rctx.color or Blitbuffer.COLOR_BLACK
    local hlcolor = rctx.highlight or Blitbuffer.COLOR_LIGHT_GRAY
    local lw = math.max(1, rctx.lineWidth or 2)
    local rgb32 = bb:getType() == Blitbuffer.TYPE_BBRGB32 and bb.paintRectRGB32 ~= nil
    -- a span's letters and its highlight: the colour, and whether to keep its hue
    local function inkOf(st)
        if st.c == false then return rctx.done or Blitbuffer.Color8(0x99), false end   -- (a ticked item)
        if st.c and rctx.ink then
            local c, chroma = rctx.ink(st.c)
            return c, chroma and rgb32
        end
        return fg, false
    end
    local function markOf(st)
        if rctx.mark then
            local c, chroma = rctx.mark(st.hl)
            return c, chroma and rgb32
        end
        return hlcolor, false
    end
    local function fill(x, y, w, h, c, chroma)
        if chroma then bb:paintRectRGB32(x, y, w, h, c) else bb:paintRect(x, y, w, h, c) end
    end
    -- One run of text in one style, its baseline at (x, baseline). A slanted
    -- (italic) or coloured run is rendered to a coverage buffer first, then
    -- blitted in its colour (row by row with a slant offset for italic, so no
    -- italic font is needed).
    local function run(text, st, x, baseline, w)
        local face = ctx.face(st)
        local bold = ctx.bold and ctx.bold(st) or false
        local color, chroma = inkOf(st)
        if text == "" then return color, chroma end
        if not (st.i or chroma) then
            RenderText:renderUtf8Text(bb, math.floor(x), math.floor(baseline), face, text, true, bold, color)
            return color, chroma
        end
        local asc = ctx.ascent(st)
        local h = math.ceil(ctx.lineHeight(st))
        local slant = st.i and 0.2 or 0
        local wseg = math.ceil(w) + 2 + (st.i and math.ceil(slant * asc) or 0)
        local tmp = Blitbuffer.new(wseg, h, Blitbuffer.TYPE_BB8)
        tmp:fill(Blitbuffer.COLOR_BLACK)   -- 0 = no coverage
        RenderText:renderUtf8Text(tmp, 0, asc, face, text, true, bold, Blitbuffer.COLOR_WHITE)
        local top = baseline - asc
        local blit = chroma and bb.colorblitFromRGB32 or bb.colorblitFrom
        if slant == 0 then
            blit(bb, tmp, math.floor(x), math.floor(top), 0, 0, wseg, h, color)
        else
            for row = 0, h - 1 do
                local dx = math.floor(slant * (asc - row) + 0.5)
                blit(bb, tmp, math.floor(x + dx), math.floor(top + row), 0, row, wseg, 1, color)
            end
        end
        tmp:free()
        return color, chroma
    end
    local done_ink = rctx.done or Blitbuffer.Color8(0x99)   -- a ticked item's letters
    local function drawSeg(sg, baseline)
        local asc = ctx.ascent(sg.style)
        if sg.style.hl then
            local hc, hchroma = markOf(sg.style)
            fill(math.floor(ox + sg.x), math.floor(oy + baseline - asc),
                math.ceil(sg.w), math.ceil(ctx.lineHeight(sg.style)), hc, hchroma)
        end
        local st = sg.style
        if sg.ticked then   -- a ticked item reads as done: greyed, in no colour
            st = setmetatable({ c = false }, { __index = sg.style })
        end
        local color, chroma = run(sg.t, st, ox + sg.x, oy + baseline, sg.w)
        if sg.ticked then color, chroma = done_ink, false end
        if sg.style.u then
            local uy = math.floor(oy + baseline + math.max(1, asc * 0.12))
            fill(math.floor(ox + sg.x), uy, math.ceil(sg.w), lw, color, chroma)
        end
        if sg.style.s then
            local sy = math.floor(oy + baseline - asc * 0.32)
            fill(math.floor(ox + sg.x), sy, math.ceil(sg.w), lw, color, chroma)
        end
    end
    for _, ln in ipairs(layout.lines) do
        local bl = ln.bullet
        if bl and bl.check then
            -- the checklist's box, on the letters' x-height, ticked when done
            local asc = ctx.ascent(bl.style)
            local color, chroma = inkOf(bl.style)
            local b = bl.box
            local bx = math.floor(ox + bl.x + 1)
            local by = math.floor(oy + ln.baseline - asc * 0.5 - b / 2 + 0.5)
            local t = math.max(1, math.floor(b / 9 + 0.5))
            fill(bx, by, b, t, color, chroma); fill(bx, by + b - t, b, t, color, chroma)
            fill(bx, by, t, b, color, chroma); fill(bx + b - t, by, t, b, color, chroma)
            if bl.checked then
                -- the tick: a short stroke down, a long one up
                local function seg(x0, y0, x1, y1)
                    local n = math.max(1, math.floor(math.max(math.abs(x1 - x0), math.abs(y1 - y0))))
                    for k = 0, n do
                        fill(math.floor(x0 + (x1 - x0) * k / n), math.floor(y0 + (y1 - y0) * k / n),
                            t + 1, t + 1, color, chroma)
                    end
                end
                seg(bx + b * 0.22, by + b * 0.52, bx + b * 0.42, by + b * 0.72)
                seg(bx + b * 0.42, by + b * 0.72, bx + b * 0.80, by + b * 0.26)
            end
        elseif bl then
            local st = bl.style
            local plain = { b = st.b, sz = st.sz, c = st.c }   -- a bullet is never slanted
            run(bl.text, plain, ox + bl.x, oy + ln.baseline, ctx.measure(bl.text, plain))
        end
        local ticked = _op.paras and _op.paras[ln.para] and _op.paras[ln.para].checked
        for _, sg in ipairs(ln.segs) do
            sg.ticked = ticked or nil
            drawSeg(sg, ln.baseline)
        end
    end
end

return Text

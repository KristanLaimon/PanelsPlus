--[[
Room in a reflowing book: space the text moves out of, so stickers, pictures and
notes have somewhere to go. Nothing in the book's file changes. Ink Away adds a
few style rules to the book, next to KOReader's own style tweaks, and the book is
laid out again with the space in it.

Exact rooms (the book and web render modes, which float things):

  * a box room, { kind = "box", side = "left" | "right" | "full", x, w, h, xp,
    sp, spp, sh, off, cw }: the space from the text column's side (or across it)
    to the box's far edge, as tall as the box, at the pixel where it was drawn (cw:
    its float's width, when the laid-out text asked for another, Book:calibrateBox).

The book is laid out once with markers (Rooms.MARKERS): before and after every
block element, an empty float of no size. A room sizes two of them. The one
before its paragraph (xp) is the box (its width and, as padding, its height: the
book mode sizes nothing else on a float). An earlier one, of no width, pushes it
down to its top: the end of the paragraph just before (sp, spp "after", from the
top of that paragraph's last line) or the start of one before that (spp "before",
from its top), by sh pixels; the box clears it. The box's top is off pixels below
where its marker sits: -1 when pushed (one pixel lower, or crengine shortens the
line just above too), more in a paragraph's first line (the marker starts there).
crengine lays out a book's elements when it loads it, so the first exact room
loads the book again (Book:reloadForRooms); after that a room is only sized. A
float across a page's foot moves the page break before it, so both markers are
on the room's page; a paragraph holds one room, and two rooms on a side keep their
markers in the order of their tops (Rooms.planBox).

Rooms of whole paragraphs (legacy and flat, which do not float things, and the
rooms made before exact ones):

  * a band across the page: empty space before a paragraph
    (its padding-top), { kind = "band", xp = <paragraph>, h = <px> };
  * space at a side: the paragraphs it covers are narrower on that side
    (their padding-left or padding-right), { kind = "side", side = "left" |
    "right", xps = { <paragraph>, ... }, w = <px> }.

Every room also has an id and xp (its paragraph). Sizes are in screen pixels and
stay the same whatever the font: the rules are written in the book's own CSS
pixels, which KOReader's "Zoom (dpi)" setting scales (Rooms.css takes the scale).
A margin at the top of a page is dropped, so the paragraph rooms use padding.

crengine matches nothing above a book's DocFragment (the element KOReader puts
around each file of an EPUB), so a paragraph's rule names the path from there:
DocFragment:nth-of-type(9) > body:nth-of-type(1) > p:nth-of-type(10). The
xpointer gives that path already: p[10] is the tenth <p> among its parent's <p>s,
which is what :nth-of-type counts. This file is plain Lua; the book's side is in
ink/reader/book.lua.
]]

local Rooms = {}

-- Size limits, as fractions of the page's text area.
Rooms.MIN_H, Rooms.MAX_H = 0.04, 0.85   -- a band's height
Rooms.MIN_W, Rooms.MAX_W = 0.15, 0.6    -- a side room's width
Rooms.EDGE = 0.15                       -- a box this close to a side becomes side space
Rooms.WIDE = 0.6                        -- a box at least this wide becomes a band

-- Elements inside a paragraph: a room is made around the paragraph holding them.
local INLINE = {}
for w in ([[a abbr b bdi bdo big br cite code del dfn em font i img ins kbd mark nobr
    q rb rp rt rtc ruby s samp small span strike strong sub sup time tt u var wbr]]):gmatch("%S+") do
    INLINE[w] = true
end
-- Elements that hold a whole file or the book: never a room's paragraph.
local OUTER = { DocFragment = true, body = true, html = true, FictionBook = true }

-- The block elements that carry a marker, before and after their content: an
-- empty float of no size, which a box room sizes (see the top).
Rooms.HOST_TAGS = { "p", "div", "li", "blockquote", "h1", "h2", "h3", "h4", "h5", "h6", "dd", "dt",
    "pre", "section", "article", "aside", "header", "footer", "figure", "figcaption", "address",
    "center", "td", "th", "v", "stanza", "epigraph", "subtitle", "text-author", "poem" }
local HOSTS = {}
for _i, t in ipairs(Rooms.HOST_TAGS) do HOSTS[t] = true end
local function markers(tags)
    local sels = {}
    for _i, t in ipairs(tags) do sels[#sels + 1] = t .. "::before, " .. t .. "::after" end
    return table.concat(sels, ", ") .. ' { content: ""; float: right; width: 0; height: 0; }'
end
Rooms.MARKERS = markers(Rooms.HOST_TAGS)

-- The inline elements that carry one too, in books laid out with them (Book's
-- room_marks 2): where one begins inside a paragraph, its marker sits on that
-- line, so a box can start there (a paragraph's own marker is only at its top).
-- Zero-size floats in a line change nothing in its layout.
Rooms.INLINE_TAGS = { "a", "b", "big", "cite", "em", "font", "i", "q", "small", "span", "strong", "sub", "sup", "u" }
local INLINE_HOSTS = {}
for _i, t in ipairs(Rooms.INLINE_TAGS) do INLINE_HOSTS[t] = true end
Rooms.INLINE_MARKERS = markers(Rooms.INLINE_TAGS)

local function lastName(elem_xp)
    local name = type(elem_xp) == "string" and elem_xp:match("/([%w_%-]+)%[?%d*%]?$")
    return name and name:lower()
end

-- Does the element (an element xpointer) carry markers? A paragraph does; an
-- inline element (Rooms.INLINE_TAGS) does in a book laid out with them.
function Rooms.hostable(elem_xp)
    local name = lastName(elem_xp)
    return name ~= nil and (HOSTS[name] == true or INLINE_HOSTS[name] == true)
end

-- Is it an inline element's (a marker inside a paragraph, not at its top)?
function Rooms.isInline(elem_xp)
    local name = lastName(elem_xp)
    return name ~= nil and INLINE_HOSTS[name] == true
end

-- The steps of an xpointer's element path: { { name = "p", idx = 10 }, ... }
-- (idx nil when the xpointer names no index: the only, or first, of its name).
function Rooms.steps(xp)
    if type(xp) ~= "string" or xp:sub(1, 1) ~= "/" then return nil end
    local path = xp:gsub("/text%(%).*$", ""):gsub("%.%d+$", "")
    local out = {}
    for seg in path:gmatch("/([^/]+)") do
        local name, idx = seg:match("^([^%[]+)%[(%d+)%]$")
        if name then out[#out + 1] = { name = name, idx = tonumber(idx) }
        elseif seg:match("^[%w_:%-]+$") then out[#out + 1] = { name = seg }
        else return nil end
    end
    return #out > 0 and out or nil
end

local function join(steps, n)
    local o = {}
    for i = 1, n or #steps do
        local e = steps[i]
        o[i] = "/" .. e.name .. (e.idx and ("[" .. e.idx .. "]") or "")
    end
    return table.concat(o)
end

-- The paragraph (block element) holding the text at `xp`, as an element
-- xpointer, or nil when the text sits right in the book's body.
function Rooms.blockOf(xp)
    local s = Rooms.steps(xp)
    if not s then return nil end
    local n = #s
    while n > 0 and INLINE[s[n].name:lower()] do n = n - 1 end
    if n == 0 or OUTER[s[n].name] then return nil end
    return join(s, n)
end

-- The CSS selector for one paragraph (an element xpointer), or nil.
function Rooms.selector(elem_xp)
    local s = Rooms.steps(elem_xp)
    if not s then return nil end
    local first
    for i, e in ipairs(s) do if e.name == "DocFragment" then first = i; break end end
    -- (a book without DocFragment, FB2 or a plain HTML file: from under its root)
    first = first or 2
    if first > #s then return nil end
    local o = {}
    for i = first, #s do
        local e = s[i]
        if not e.name:match("^[%a_][%w_%-]*$") then return nil end
        o[#o + 1] = e.name .. ":nth-of-type(" .. (e.idx or 1) .. ")"
    end
    return table.concat(o, " > ")
end

-- A new room's id.
local seq = 0
function Rooms.newId(now)
    seq = seq + 1
    return string.format("r%d%03d", now or os.time(), seq % 1000)
end

local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end
local function round(v) return math.floor(v + 0.5) end

-- A box room as a room of whole paragraphs, for the render modes that do not
-- float anything (legacy and flat): across the page, a band before its paragraph;
-- at a side, space beside that paragraph.
function Rooms.asParagraphs(r)
    if r.kind ~= "box" then return r end
    -- (a box held by an inline element: its paragraph)
    local xp = Rooms.isInline(r.xp) and Rooms.blockOf(r.xp) or r.xp
    if r.side == "full" then return { id = r.id, kind = "band", xp = xp, h = r.h, from = r } end
    return { id = r.id, kind = "side", side = r.side, xp = xp, xps = { xp }, w = r.w, from = r }
end

local function px(v, scale)
    -- (two decimals: the box keeps its size to the pixel at any zoom)
    local s = string.format("%.2f", math.max(0, v * scale)):gsub("0+$", ""):gsub("%.$", "")
    return s .. "px"
end

-- The style rules for `rooms`. `scale` is CSS pixels per screen pixel (96 / the
-- render dpi; 1 when KOReader does not scale). One rule per paragraph, so two
-- rooms on one paragraph (a band and side space) add up. With `opts.ready` the
-- book has its markers (Rooms.MARKERS, and Rooms.INLINE_MARKERS with
-- `opts.inline`); with `opts.floats` its render mode floats them, and a box room
-- is one of them sized (else it is made of paragraphs).
function Rooms.css(rooms, scale, opts)
    scale = scale or 1
    opts = opts or {}
    local by, order = {}, {}
    local function prop(xp, name, v)
        local sel = Rooms.selector(xp)
        if not sel then return end
        local r = by[sel]
        if not r then r = {}; by[sel] = r; order[#order + 1] = sel end
        r[name] = math.max(r[name] or 0, v)
    end
    local out = {}
    if opts.ready then out[#out + 1] = Rooms.MARKERS end
    if opts.ready and opts.inline then out[#out + 1] = Rooms.INLINE_MARKERS end
    for _i, room in ipairs(rooms or {}) do
        if room.kind == "box" and not (opts.floats and opts.ready) then room = Rooms.asParagraphs(room) end
        if room.kind == "band" and room.xp and room.h then
            prop(room.xp, "padding-top", room.h)
        elseif room.kind == "side" and room.w then
            local name = room.side == "left" and "padding-left" or "padding-right"
            for _j, xp in ipairs(room.xps or { room.xp }) do prop(xp, name, room.w) end
        elseif room.kind == "box" then
            local side = room.side == "right" and "right" or "left"
            local clear = room.side == "full" and "both" or side
            local box = Rooms.selector(room.xp)
            local spacer = room.sp and Rooms.selector(room.sp)
            if box and (spacer or not room.sp) then
                if spacer then
                    out[#out + 1] = string.format("%s::%s { float: %s !important; padding-bottom: %s !important; }",
                        spacer, room.spp == "before" and "before" or "after", side, px(room.sh or 0, scale))
                end
                out[#out + 1] = string.format("%s::before { float: %s !important; clear: %s !important; width: %s !important; padding-bottom: %s !important; }",
                    box, side, clear, px(room.cw or room.w, scale), px(room.h + (room.off or 0), scale))
            end
        end
    end
    for _i, sel in ipairs(order) do
        local parts = {}
        for _j, name in ipairs({ "padding-top", "padding-left", "padding-right" }) do
            local v = by[sel][name]
            if v then parts[#parts + 1] = string.format("%s: %dpx !important;", name, math.max(1, round(v * scale))) end
        end
        out[#out + 1] = sel .. " { " .. table.concat(parts, " ") .. " }"
    end
    return table.concat(out, "\n")
end

-- The paragraphs on a page, from its words in reading order (each
-- { xp, y, h }, y the top of its line on the screen): { { xp = <paragraph>,
-- y0, y1, starts = <its first line is on this page> }, ... }. The first one may
-- have begun on the page before: `starts_here(paragraph, first_word_xp)` says.
--
-- Each also has l1 (the bottom of its first line here), lt and lb (the top and
-- bottom of its last line here) and ends (its last line is on this page: true but
-- for the last one, which `ends_here(paragraph)` says, when given).
function Rooms.blocksFromWords(words, starts_here, ends_here)
    local out, last = {}, nil
    for _i, w in ipairs(words) do
        local b = Rooms.blockOf(w.xp)
        if b then
            local bottom = w.y + (w.h or 0)
            if not (last and last.xp == b) then
                last = { xp = b, y0 = w.y, y1 = bottom, starts = true, l1 = bottom, lt = w.y, lb = bottom, ends = true }
                if #out == 0 and starts_here then last.starts = starts_here(b, w.xp) and true or false end
                out[#out + 1] = last
            else
                last.y1 = math.max(last.y1, bottom)
                if w.y > last.lt then last.lt, last.lb = w.y, bottom end
                if w.y == last.y0 then last.l1 = math.max(last.l1, bottom) end
            end
        end
    end
    if last and ends_here then last.ends = ends_here(last.xp) and true or false end
    return out
end

-- What a box drawn on the page (`rect`, screen pixels) makes: a band before the
-- paragraph break nearest its top, or, for a box near a side and not too wide,
-- space at that side beside the paragraphs it covers. `blocks` are the page's
-- paragraphs (Rooms.blocksFromWords), `area` its text area { x0, y0, x1, y1 }.
-- Returns the room (without an id) and the box it will roughly take now, or nil
-- and why ("no_break", "no_text").
function Rooms.plan(rect, blocks, area)
    local cw, ch = area.x1 - area.x0, area.y1 - area.y0
    if cw <= 0 or ch <= 0 or not blocks or #blocks == 0 then return nil, "no_text" end
    local edge = Rooms.EDGE * cw
    local near_left = rect.x <= area.x0 + edge
    local near_right = rect.x + rect.w >= area.x1 - edge
    local band = rect.w >= Rooms.WIDE * cw or near_left == near_right
    if band then
        local best, bd
        for _i, b in ipairs(blocks) do
            if b.starts then
                local d = math.abs(b.y0 - rect.y)
                if not bd or d < bd then best, bd = b, d end
            end
        end
        if not best then return nil, "no_break" end
        local h = round(clamp(rect.h, Rooms.MIN_H * ch, Rooms.MAX_H * ch))
        return { kind = "band", xp = best.xp, h = h },
            { x = area.x0, y = best.y0, w = cw, h = h }
    end
    local side = near_left and "left" or "right"
    local w = side == "left" and (rect.x + rect.w - area.x0) or (area.x1 - rect.x)
    w = round(clamp(w, Rooms.MIN_W * cw, Rooms.MAX_W * cw))
    local xps, y0, y1 = {}, nil, nil
    for _i, b in ipairs(blocks) do
        if b.y1 > rect.y and b.y0 < rect.y + rect.h then
            xps[#xps + 1] = b.xp
            y0 = y0 and math.min(y0, b.y0) or b.y0
            y1 = y1 and math.max(y1, b.y1) or b.y1
        end
    end
    if #xps == 0 then return nil, "no_text" end
    return { kind = "side", side = side, w = w, xp = xps[1], xps = xps },
        { x = side == "left" and area.x0 or (area.x1 - w), y = y0, w = w, h = y1 - y0 }
end

Rooms.MIN_BOX = 12     -- a box room's smallest side, in pixels
Rooms.FIT_MARGIN = 16  -- an inline element's float: text this close to fitting beside it is too close to tell
Rooms.MIN_TEXT = 0.2   -- text narrower than this (of the column) beside a box: none, the box goes across

-- The exact room a box drawn on the page makes (see the top), where the render
-- mode floats the markers. `page` describes the page shown: { area = { x0, y0,
-- x1, y1 }, blocks (Rooms.blocksFromWords), cl, cr (the left and right of its text
-- column), bottom (the bottom of its last line), used (the markers other rooms
-- size: [xp .. "::before"] = true), rooms (the other box rooms on it: { side,
-- top, bottom (where their markers sit), x0, x1, s, b (where their markers are in
-- the page's order, Rooms.slot) }) }. Returns the room (without an id), the box it
-- keeps (where ink in it goes: the box drawn, cut to the text column and the page)
-- and the area it frees (from the box's edge to the column's, from where its
-- marker sits to the box's bottom), and, when the room cannot start at the box's
-- top, how it starts instead: "top" (higher: no marker above the box on this page
-- to push it down from, so from the top of its paragraph's or anchor's line) or
-- "lower" (at the next spot below); or nil and why ("small", "no_break",
-- "overlap", "taken"). The blocks may carry inline anchors (Rooms.spots).
--
-- A box room is two markers: the one before its paragraph holds the box, and an
-- earlier one, of no width, pushes it down to its top ("clear"). A marker that
-- pushes clears every earlier one on its side, so two rooms on a side are kept in
-- order: the one higher on the page has its markers first.
function Rooms.slot(i, pseudo) return i * 2 + (pseudo == "after" and 1 or 0) end

function Rooms.planBox(rect, page)
    local area, blocks = page.area, page.blocks or {}
    local t = math.max(rect.y, area.y0)
    local b = math.min(rect.y + rect.h, page.bottom or area.y1)
    -- (below the page's last line there is no text to move)
    if t >= (page.bottom or area.y1) - 1 then return nil, "no_text" end
    if b - t < Rooms.MIN_BOX then return nil, "small" end
    local others = page.rooms or {}
    -- across, or from the nearer side of the column to the box's far edge; the
    -- column is the holding paragraph's own (its marker is in it), else the page's
    local side, bx, bw, why
    local function across(P)
        local cl = P and P.cl or page.cl or area.x0
        local cr = P and P.cr or page.cr or area.x1
        local cw = cr - cl
        local x0, x1 = math.max(rect.x, cl), math.min(rect.x + rect.w, cr)
        if cw <= 0 or x1 - x0 < Rooms.MIN_BOX then why = "small"; return false end
        local rest_l, rest_r, least = x0 - cl, cr - x1, Rooms.MIN_TEXT * cw
        if rest_l <= rest_r then side = rest_r < least and "full" or "left"
        else side = rest_l < least and "full" or "right" end
        if side == "left" then bx, bw = cl, x1 - cl
        elseif side == "right" then bx, bw = x0, cr - x0
        else bx, bw = cl, cw end
        -- not over another room
        for _i, e in ipairs(others) do
            if e.x0 < bx + bw and e.x1 > bx and e.top < b and e.bottom > t then why = "overlap"; return false end
        end
        return true
    end
    if not across(nil) then return nil, why end
    local used = page.used or {}
    local function free(xp, pseudo) return Rooms.hostable(xp) and not used[xp .. "::" .. pseudo] end
    local function floatSide(sd) return sd == "right" and "right" or "left" end
    local function clears(sd, fs) return sd == "full" or floatSide(sd) == fs end
    -- the markers in this order keep the other rooms where they are, and this one
    local function inOrder(s_key, b_key, top)
        for _i, e in ipairs(others) do
            if e.s and e.s < b_key and clears(side, floatSide(e.side)) and e.top > top then return false end
            if s_key and s_key < e.b and clears(e.side, floatSide(side)) and top > e.top then return false end
        end
        return true
    end
    local function made(top, xp, sp, spp, sh, off, loose, nl)
        local h = b - top
        local room = { kind = "box", side = side, x = bx, w = bw, h = h, xp = xp, sp = sp, spp = spp, sh = sh, off = off,
            nl = nl or nil }
        local css_top = top - (off or 0)
        return room, { x = bx, y = top, w = bw, h = h }, { x = bx, y = css_top, w = bw, h = b - css_top }, loose
    end
    local taken = false
    local spots = Rooms.spots(blocks)
    -- the last spot starting at or above the box's top holds it (or one before
    -- it, when its marker is taken)
    -- the line a box's float starts on at spot S, this box's size given: an inline
    -- element's own line when the text before it there fits beside the box, else
    -- the next line (nl); nil when too close to tell, or S cannot hold this box
    local function boxLine(S)
        -- (a paragraph whose first line has nothing before its first word: there)
        if not S.inline and not S.ex then return S.y0, S.l1, nil end
        if not across(S.block) then return nil end
        local cl = S.block.cl or page.cl or area.x0
        local cr = S.block.cr or page.cr or area.x1
        local before = (S.ex or cl) - cl
        local room_left = (side == "full") and 0 or ((cr - cl) - bw)
        -- (a box across, at an inline element that begins its line, would push that
        -- line's words below it, and nothing would say where it is: not there)
        if S.inline and side == "full" and (S.at_start or before <= 1) then return nil end
        if S.at_start or before <= 1 then return S.y0, S.l1, nil end
        if before + Rooms.FIT_MARGIN < room_left then return S.y0, S.l1, nil end
        -- (the next line: nl is how far below the element's own line it is)
        if before - Rooms.FIT_MARGIN > room_left and S.ny0 then return S.ny0, S.nl1, S.ny0 - S.y0 end
        return nil
    end
    for k = #spots, 1, -1 do
        local S = spots[k]
        local P = S.block
        local sy0, sl1, snl = boxLine(S)
        if sy0 and sy0 <= t then
            if not free(S.xp, "before") then
                taken = true
            elseif not across(P) then
                return nil, why
            else
                local bk = S.slot
                -- at its top, or in its first line: the marker starts that line, and
                -- so does the box's effect on the text (the box is where it was drawn)
                if t < sl1 then
                    if inOrder(nil, bk, sy0) then return made(t, S.xp, nil, nil, nil, t - sy0, nil, snl) end
                else
                    -- pushed down by a marker above it on this page: the end of the
                    -- paragraph just before its own (the top of its last line), or
                    -- an earlier spot; one pixel lower, so the line just above keeps
                    -- its width
                    local O = blocks[S.bi - 1]
                    if O and O.ends and O.lt >= area.y0 and free(O.xp, "after")
                        and inOrder(Rooms.slot(S.bi - 1, "after"), bk, t + 1) then
                        return made(t, S.xp, O.xp, "after", t + 1 - O.lt, -1, nil, snl)
                    end
                    for j = k - 1, 1, -1 do
                        local X = spots[j]
                        -- (a spacer has no width: on its element's own line, always)
                        if X.y0 >= area.y0 and X.y0 <= sy0 and free(X.xp, "before")
                            and inOrder(X.slot, bk, t + 1) then
                            return made(t, S.xp, X.xp, "before", t + 1 - X.y0, -1, nil, snl)
                        end
                    end
                    -- nothing above it on this page: from the top of the spot's line
                    -- (the room starts higher than the box: "top")
                    if inOrder(nil, bk, sy0) then return made(t, S.xp, nil, nil, nil, t - sy0, "top", snl) end
                end
            end
        end
    end
    -- above every spot on this page (in a paragraph that began before): from the
    -- first one below it (the room starts lower than the box: "lower")
    for _k, S in ipairs(spots) do
        local sy0, _sl1, snl = boxLine(S)
        if sy0 and sy0 > t and free(S.xp, "before") and across(S.block) and inOrder(nil, S.slot, sy0) then
            if b - sy0 < Rooms.MIN_BOX then break end
            return made(sy0, S.xp, nil, nil, nil, 0, "lower", snl)
        end
    end
    return nil, taken and "taken" or "no_break"
end

-- The places on a page a box's marker can sit, in the page's order: where each
-- paragraph starting on it begins, and where an inline element begins inside one
-- (`anchors` of a block: { xp, y0, l1 } the top and bottom of the line it begins
-- on, ex where it begins on it, at_start whether it begins the line, ny0, nl1 the
-- next line's, when on the page). Each: { xp, y0, l1, block, bi (the block's
-- place), slot (Rooms.slot order), and an inline one's facts }.
--
-- A float on an inline element starts on its line when the text before it there
-- fits beside the float, else on the next line (as CSS has it): which depends on
-- the box, so Rooms.planBox decides, and keeps "next line" in the room (nl: how
-- far below the element's own line, whose words stay put, the float starts). The
-- same holds at a paragraph's start when its first line is indented (a block's
-- ex, ny0, nl1): a box wider than the indent leaves room for starts on its
-- second line.
function Rooms.spots(blocks)
    local out = {}
    for i, P in ipairs(blocks or {}) do
        if P.starts then
            -- (ex: where its first word is, after an indent; ny0, nl1 its second line)
            out[#out + 1] = { xp = P.xp, y0 = P.y0, l1 = P.l1, block = P, bi = i, slot = Rooms.slot(i, "before"),
                ex = P.ex, ny0 = P.ny0, nl1 = P.nl1 }
        end
        local n = P.anchors and #P.anchors or 0
        for k = 1, n do
            local A = P.anchors[k]
            -- (between the paragraph's own two markers)
            out[#out + 1] = { xp = A.xp, y0 = A.y0, l1 = A.l1, block = P, bi = i, slot = Rooms.slot(i, "before") + k / (n + 1),
                inline = true, ex = A.ex, at_start = A.at_start, ny0 = A.ny0, nl1 = A.nl1 }
        end
    end
    return out
end

-- A box drawn where no room can start (Rooms.planBox would start it higher or
-- lower than the box, or finds nowhere): the box moved to the nearest top on
-- the page where a room starts exactly, or nil when it is exact already, or no
-- such top is near. `keep` "height" moves the whole box; "bottom" moves only its
-- top edge. Only tops: the box's sides and size stay as drawn.
--
-- Whether a top is exact changes only where it crosses a line of the page model
-- (a paragraph's or anchor's top, its first line's bottom, another room's edges),
-- so the nearest exact top is found among those lines and a pixel either side.
function Rooms.snapTop(rect, page, keep)
    local room, _box, _free, loose = Rooms.planBox(rect, page)
    if room and not loose then return nil end
    if not room and _box ~= "no_break" then return nil end
    local area = page.area
    local bottom = rect.y + rect.h
    local function tryAt(t)
        if t < area.y0 then return nil end
        local r
        if keep == "bottom" then
            if bottom - t < Rooms.MIN_BOX then return nil end
            r = { x = rect.x, y = t, w = rect.w, h = bottom - t }
        else
            r = { x = rect.x, y = t, w = rect.w, h = rect.h }
        end
        local p, _b, _f, l = Rooms.planBox(r, page)
        if p and not l then return r end
    end
    local seen, cands = {}, {}
    local function add(v)
        if type(v) ~= "number" then return end
        v = math.floor(v)
        for d = -1, 1 do
            local c = v + d
            if not seen[c] then seen[c] = true; cands[#cands + 1] = c end
        end
    end
    add(area.y0)
    for _i, P in ipairs(page.blocks or {}) do
        add(P.y0); add(P.l1); add(P.lt); add(P.lb); add(P.y1); add(P.ny0); add(P.nl1)
        for _k, A in ipairs(P.anchors or {}) do add(A.y0); add(A.l1); add(A.ny0); add(A.nl1) end
    end
    for _i, e in ipairs(page.rooms or {}) do
        add(e.top); add(e.bottom)
        if keep ~= "bottom" then add(e.top - rect.h) end
    end
    if keep ~= "bottom" and page.bottom then add(page.bottom - rect.h) end
    if keep == "bottom" then add(bottom - Rooms.MIN_BOX) end
    table.sort(cands, function(a, b) return math.abs(a - rect.y) < math.abs(b - rect.y) or
        (math.abs(a - rect.y) == math.abs(b - rect.y) and a < b) end)
    for _i, c in ipairs(cands) do
        if c ~= rect.y then
            local r = tryAt(c)
            if r then return r end
        end
    end
    return nil
end

-- A copy of a room (the same id), safe to change.
function Rooms.copy(room)
    local c = {}
    for k, v in pairs(room) do c[k] = v end
    if room.xps then
        c.xps = {}
        for i, x in ipairs(room.xps) do c.xps[i] = x end
    end
    return c
end

-- Two lists of rooms in one: every room of `a`, then those only `b` has (by id),
-- for the cloud sync and for ink brought together from two folders.
function Rooms.merge(a, b)
    local out, seen = {}, {}
    for _i, r in ipairs(a or {}) do
        if type(r) == "table" and r.id and not seen[r.id] then seen[r.id] = true; out[#out + 1] = r end
    end
    for _i, r in ipairs(b or {}) do
        if type(r) == "table" and r.id and not seen[r.id] then seen[r.id] = true; out[#out + 1] = r end
    end
    return out
end

-- Is it a room this version understands?
function Rooms.valid(r)
    if type(r) ~= "table" or type(r.id) ~= "string" or type(r.xp) ~= "string" then return false end
    if r.kind == "band" then return type(r.h) == "number" and r.h > 0 end
    if r.kind == "box" then
        local function num(v) return type(v) == "number" end
        return num(r.h) and r.h > 0 and num(r.w) and r.w > 0 and num(r.x)
            and (r.side == "left" or r.side == "right" or r.side == "full")
            and (r.sp == nil or (type(r.sp) == "string" and num(r.sh)))
            and (r.spp == nil or r.spp == "before" or r.spp == "after")
            and (r.off == nil or num(r.off)) and (r.cw == nil or (num(r.cw) and r.cw > 0))
    end
    if r.kind == "side" then
        return type(r.w) == "number" and r.w > 0 and (r.side == "left" or r.side == "right")
            and (r.xps == nil or type(r.xps) == "table")
    end
    return false
end

return Rooms

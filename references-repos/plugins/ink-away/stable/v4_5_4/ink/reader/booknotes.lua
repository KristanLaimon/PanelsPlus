--[[
Book notes: one notebook per book, in the library's "Book notes" folder, named
after the book, with a page (or a run of pages) per chapter in the book's
order. Opening the notes in a chapter goes to that chapter's last page; a
chapter without one gets a new page titled with its name, put where the
chapter comes in the book, so the notebook's contents are the book's chapters.

Each chapter page remembers its chapter as page.book = { toc = <the chapter's
place in the book's contents>, md5 = <the book's checksum> }; pages added by
hand belong to the chapter page before them. Plain Lua: the headless tests
drive it.

A handwritten note on one of the reader's highlights is a page too, in the
highlight's chapter, after that chapter's pages: page.book also has hl = { dt =
<the highlight's date and time, KOReader's own mark for it>, pos0, pos1 }, and
the page is titled with the highlighted words. Opening the chapter's notes does
not land on it.
]]

local BookNotes = {}

BookNotes.FOLDER = "Book notes"
-- Where that folder is now, relative to the library, once it was renamed or
-- moved in the library (see InkAwayView:pathMoved); unset, it is FOLDER.
BookNotes.SETTING = "inkaway_booknotes_folder"

-- A file name for a book title: no path separators or characters some file
-- systems refuse, no leading dot, not too long.
function BookNotes.fileName(title)
    local s = tostring(title or ""):gsub("[%c/\\:%*%?\"<>|]", " "):gsub("%s+", " ")
    s = s:gsub("^[%s%.]+", ""):gsub("[%s%.]+$", "")
    if #s > 80 then
        -- cut at a character boundary
        local cut = 80
        while cut > 0 and s:byte(cut + 1) and s:byte(cut + 1) >= 0x80 and s:byte(cut + 1) < 0xC0 do cut = cut - 1 end
        s = s:sub(1, cut):gsub("%s+$", "")
    end
    if s == "" then s = "Book" end
    return s
end

-- Is a notebook (its pages) another book's? Only when its chapter pages say so.
function BookNotes.otherBook(pages, md5)
    if not md5 then return false end
    for _i, p in ipairs(pages or {}) do
        if type(p.book) == "table" and p.book.md5 then return p.book.md5 ~= md5 end
    end
    return false
end

-- Are these pages (a notebook's) the notes of the book with checksum `md5`?
-- One of its chapter pages must say so, and the first that says anything.
function BookNotes.ofBook(pages, md5)
    if not md5 or BookNotes.otherBook(pages, md5) then return false end
    for _i, p in ipairs(pages or {}) do
        if type(p.book) == "table" and p.book.md5 == md5 then return true end
    end
    return false
end

-- Does any page say which book it is for?
function BookNotes.tagged(pages)
    for _i, p in ipairs(pages or {}) do
        if type(p.book) == "table" and p.book.md5 then return true end
    end
    return false
end

-- The order to look through the library's notebooks (`docs`, { path, mtime })
-- for a book's notes that are no longer at `lost`: those with its file name
-- first (a renamed or moved folder keeps the names in it), newest first.
function BookNotes.searchOrder(docs, lost)
    local name = (lost or ""):match("([^/]+)$") or ""
    local same, rest = {}, {}
    for _i, d in ipairs(docs) do
        local list = ((d.path:match("([^/]+)$") or "") == name) and same or rest
        list[#list + 1] = d
    end
    local function newest(a, b) return (a.mtime or 0) > (b.mtime or 0) end
    table.sort(same, newest)
    table.sort(rest, newest)
    for _i, d in ipairs(rest) do same[#same + 1] = d end
    return same, name
end

-- Where to write for chapter `key` (its place in the contents; nil when the
-- book has none): { index = n } for an existing page, or { insert = n } for a
-- new chapter page to put at n. A notebook that is just one empty page without
-- a chapter takes the chapter itself: { index = 1, claim = true }.
function BookNotes.placeFor(pages, key)
    local n = #pages
    if n == 0 then return { insert = 1 } end
    if n == 1 and not pages[1].book and #(pages[1].ops or {}) == 0 then
        return { index = 1, claim = true }
    end
    if key == nil then return { index = n } end
    -- each page's chapter: its own, or the chapter page's before it (a
    -- highlight's note, and pages added after it, are not the chapter's notes)
    local last_of, insert_at, cur, of_note = nil, nil, nil, false
    for i, p in ipairs(pages) do
        if type(p.book) == "table" and type(p.book.toc) == "number" then
            cur, of_note = p.book.toc, type(p.book.hl) == "table"
        end
        if cur == key and not of_note then last_of = i end
        if not insert_at and cur and cur > key then insert_at = i end
    end
    if last_of then return { index = last_of } end
    -- before the first page of a later chapter, else at the end
    return { insert = insert_at or (n + 1) }
end

-- Is page tag `tag` (page.book) the note of highlight `hl` ({ dt, pos0, pos1 })?
-- By KOReader's date and time for it (moving its ends keeps that), else by where
-- it is.
function BookNotes.isNoteOf(tag, hl)
    local t = type(tag) == "table" and tag.hl
    if type(t) ~= "table" or type(hl) ~= "table" then return false end
    if t.dt and hl.dt then return t.dt == hl.dt end
    return t.pos0 ~= nil and t.pos0 == hl.pos0 and t.pos1 == hl.pos1
end

-- Where highlight `hl`'s note is, in chapter `key`: { index = n } for its page,
-- or { insert = n } for a new one after the chapter's pages (before the next
-- chapter's), { index = 1, claim = true } for a new notebook's empty page.
function BookNotes.placeForHighlight(pages, key, hl)
    local n = #pages
    for i, p in ipairs(pages) do
        if BookNotes.isNoteOf(p.book, hl) then return { index = i } end
    end
    if n == 0 then return { insert = 1 } end
    if n == 1 and not pages[1].book and #(pages[1].ops or {}) == 0 then
        return { index = 1, claim = true }
    end
    if key == nil then return { insert = n + 1 } end
    local last_of, insert_at, cur = nil, nil, nil
    for i, p in ipairs(pages) do
        if type(p.book) == "table" and type(p.book.toc) == "number" then cur = p.book.toc end
        if cur == key then last_of = i end
        if not insert_at and cur and cur > key then insert_at = i end
    end
    if last_of then return { insert = last_of + 1 } end
    return { insert = insert_at or (n + 1) }
end

-- A page title for highlighted words: in quotes, cut to about `max` letters.
function BookNotes.quote(text, max)
    max = max or 60
    local s = tostring(text or ""):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
    local chars = {}
    for ch in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do chars[#chars + 1] = ch end
    if #chars > max then
        s = table.concat(chars, "", 1, max):gsub("%s+%S*$", "") .. "\u{2026}"
    end
    return "\u{201C}" .. s .. "\u{201D}"
end

return BookNotes

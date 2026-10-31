--[[
Adding files from a phone or computer, through Send to phone or computer's
page (see ink/view/share.lua), while "Allow adding files" is on for that
sharing. Only into Ink Away's own folders, under names the reader chooses,
each kind in its own folder of Library > Imported (never in Imported itself):
  a PDF            -> a notebook on it in Imported > PDFs (the PDF file itself
                      kept once, in the hidden "imported pdfs" folder)
  a JPEG or PNG    -> Imported > Pictures (also Add image > Sent from your phone)
  an Ink Away file -> Imported > Notebooks and drawings
Every file is checked by what it is, not what it is called, against a size
limit and the space left on the reader, written to a hidden part file and
only kept once it is whole and checked; anything cut short is removed.
Pictures larger than a reader can open are turned away (the page offers to
make them smaller on the phone first).
When a notebook arrives, the reader asks whether to open it (or says where it
is, once "Don't ask again" is on). Notebooks arriving together share one
question, nothing waits for an answer, and opening one while others are still
coming waits until they are in.
Part of InkAwayView (see ink/view.lua).
]]

local Device = require("device")
local Font = require("ui/font")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local logger = require("logger")
local _ = require("ink/l10n")
local Folder = require("ink/folder")
local Http = require("ink/share/http")
local Notebook = require("ink/notebook")
local Project = require("ink/project")
local SafeData = require("ink/share/safedata")
local Storage = require("ink/storage")
local ToggleRow = require("ink/ui/controls").ToggleRow

local Screen = Device.screen
local function S(px) return Screen:scaleBySize(px) end

local InkAwayView = {}

-- What may be sent, and how big.
local LIMITS = { pdf = 300 * 1024 * 1024, image = 30 * 1024 * 1024, inkaway = 10 * 1024 * 1024 }
local MAX_PDF_PAGES = 2000             -- a PDF with more is not made into a notebook
local MAX_PIXELS = 16 * 1000 * 1000   -- a picture larger than this is too much for a reader to open
local RESERVE = 64 * 1024 * 1024      -- free space always left on the reader
local MAX_FILES = 100                 -- files one sharing may take
local MAX_UPLOADS = 2                 -- coming in at once
InkAwayView.RECEIVE_LIMITS = { limits = LIMITS, max_pixels = MAX_PIXELS }

-- Where things sent to the reader go: a folder each in Library > Imported.
-- (One name in every language: a translated name would make a second folder
-- whenever KOReader's language changed.)
local SUB = { image = "Pictures", pdf = "PDFs", inkaway = "Notebooks and drawings" }
InkAwayView.IMPORTED_SUB = SUB
function InkAwayView:importedFolder() return Storage.join(self:libraryDir(), "Imported") end

-- The folder of Library > Imported for `kind` ("image", "pdf" or "inkaway"),
-- made when missing, or nil when it can't be.
function InkAwayView:importedDir(kind)
    local top = self:importedFolder()
    local dir = SUB[kind] and Storage.join(top, SUB[kind])
    if not (dir and Storage.ensureDir(top) and Storage.ensureDir(dir)) then return nil end
    return dir
end

-- Where `kind` is, as the reader reads it: "Library › Imported › Pictures".
function InkAwayView:importedPlace(kind)
    return _("Library") .. " › Imported › " .. (SUB[kind] or "")
end

-- Parts of uploads cut short by a power cut or a crash: removed when sharing
-- starts again.
function InkAwayView:clearUploadParts()
    for _i, dir in ipairs({ self:importedPdfsDir(), self:importedDir("image"), self:importedDir("inkaway") }) do
        for _j, e in ipairs(dir and Storage.list(dir) or {}) do
            if e.mode == "file" and e.name:match("^%..*%.part$") then os.remove(e.path) end
        end
    end
end
-- The hidden home of the PDFs sent to the reader (one copy each; the notebook
-- in Imported > PDFs is written over it).
function InkAwayView:importedPdfsDir() return Storage.appDir("imported pdfs") end
-- Pictures sent to the reader (Add image > Sent from your phone opens it).
function InkAwayView:importedImagesDir() return self:importedDir("image") end

-- Put what earlier test versions left in the wrong place where it belongs:
-- pictures from the old hidden "imported images" folder, and files sitting in
-- Imported itself, each into its own folder of Imported. Once a session.
function InkAwayView:sortImported()
    if self._imported_sorted then return end
    self._imported_sorted = true
    local app = Storage.appRootPath()
    local old_pics = app and Storage.join(app, "imported images")
    for _i, e in ipairs(old_pics and Storage.list(old_pics) or {}) do
        if e.mode == "file" and e.name:sub(1, 1) ~= "." and require("ink/library").isPicture(e.name) then
            local dir = self:importedDir("image")
            if dir then self:moveInto(e.path, dir) end
        end
    end
    local top = self:importedFolder()
    if not Storage.isDir(top) then return end
    local pdfs = (self:importedPdfsDir() or "") .. "/"
    for _i, e in ipairs(Storage.list(top)) do
        if e.mode == "file" and e.name:sub(1, 1) ~= "." then
            local kind
            if require("ink/library").isPicture(e.name) then
                kind = "image"
            elseif require("ink/library").isDocument(e.name) then
                local data = Project.load(e.path)
                local t = data and data.template
                local pdf = type(t) == "table" and t.pdf_path
                kind = (type(pdf) == "string" and pdf:sub(1, #pdfs) == pdfs) and "pdf" or "inkaway"
            end
            local dir = kind and self:importedDir(kind)
            if dir then pcall(self.moveInto, self, e.path, dir) end
        end
    end
end

-- Ask to open notebooks that arrive? (Don't ask again turns it off.)
-- (Over a book there is nothing to open a notebook in: a note then.)
function InkAwayView:askToOpenArrivals()
    if self.reader_mode or self.over_book then return false end
    return self:getSetting("inkaway_send_ask_open", true) ~= false
end

local function jsonReply(reply, code, ok, message)
    local esc = message:gsub('[%c"\\]', function(c) return string.format("\\u%04x", c:byte()) end)
    reply.send(code, "application/json; charset=utf-8", string.format('{"ok":%s,"message":"%s"}',
        ok and "true" or "false", esc))
end

-- A free name for `name` in `dir`: "Report.pdf", else "Report (2).pdf"...
local function freeName(dir, name)
    if not Storage.exists(Storage.join(dir, name)) then return name end
    local stem, ext = name:match("^(.*)%.([^.]+)$")
    stem, ext = stem or name, ext and ("." .. ext) or ""
    for n = 2, 999 do
        local cand = string.format("%s (%d)%s", stem, n, ext)
        if not Storage.exists(Storage.join(dir, cand)) then return cand end
    end
    return string.format("%s %d%s", stem, os.time(), ext)
end

-- Space left on the drive holding `dir`, or nil when it can't be told.
local function available(dir)
    local ok, util = pcall(require, "util")
    if not (ok and util and util.diskUsage) then return nil end
    local u = util.diskUsage(dir)
    return u and u.available
end

------------------------------------------------------------------------------
-- Taking a file in
------------------------------------------------------------------------------

-- POST <token>/upload?kind=pdf|image|inkaway&name=...&batch=...&i=...&n=...
-- with the file as the body.
function InkAwayView:sendUpload(req, reply)
    local send = self._send
    if req.method ~= "POST" then return jsonReply(reply, 405, false, "Send files here with the page's Send button.") end
    if not send.allow_upload then
        return jsonReply(reply, 403, false, "Adding files is turned off on the reader. Turn on \"Allow adding files\" there.")
    end
    local kind = req.query.kind
    local limit = LIMITS[kind]
    if not limit then return jsonReply(reply, 415, false, "Only PDFs, JPEG and PNG pictures and Ink Away files.") end
    local length = tonumber(req.headers and req.headers["content-length"] or "")
    if not length or length <= 0 or length % 1 ~= 0 then return jsonReply(reply, 411, false, "The file's size is missing.") end
    if length > limit then
        return jsonReply(reply, 413, false, string.format("Too big for the reader: at most %s.", Http.size(limit)))
    end
    if send.received >= MAX_FILES then
        return jsonReply(reply, 429, false, "That's enough for one go. Stop and start sharing again for more.")
    end
    if send.server:uploads() >= MAX_UPLOADS then return jsonReply(reply, 503, false, "The reader is busy. Try again.") end
    -- (a PDF itself goes to its hidden home; its notebook to Imported > PDFs, see importArrivedPdf)
    local dir = kind == "pdf" and self:importedPdfsDir() or self:importedDir(kind)
    if not dir then return jsonReply(reply, 507, false, "The reader has nowhere to put it.") end
    -- the space it needs, besides what the uploads still coming will take
    local free = available(dir)
    if free and free - (send.incoming or 0) - length < RESERVE then
        return jsonReply(reply, 507, false, "There isn't enough space left on the reader.")
    end
    local sink = self:uploadSink(kind, dir, req.query.name, req.query.batch, tonumber(req.query.i), tonumber(req.query.n))
    if not sink then return jsonReply(reply, 507, false, "The reader couldn't save it.") end
    send.incoming = (send.incoming or 0) + length
    local released = false
    local function release()
        if not released then released = true; send.incoming = math.max(0, (send.incoming or 0) - length) end
    end
    local finish, abort = sink.finish, sink.abort
    sink.finish = function(r) release(); return finish(r) end
    sink.abort = function(why) release(); return abort(why) end
    reply.receive(sink, length, Http.cleanName(req.query.name, nil, 40),
        (req.headers.expect or ""):lower() == "100-continue")
end

-- Where an upload goes as it comes in, and what happens when it is whole.
function InkAwayView:uploadSink(kind, dir, sent_name, batch, i, n)
    local send = self._send
    local part = Storage.join(dir, "." .. Http.token(Http.randomBytes(8), 10) .. ".part")
    local f = io.open(part, "wb")
    if not f then return nil end
    local head, what = "", nil
    local sink = {}
    local function drop()
        if f then pcall(f.close, f); f = nil end
        os.remove(part)
    end
    function sink.write(chunk)
        if #head < 16 then
            head = head .. chunk:sub(1, 16 - #head)
            if #head >= 16 or not what then what = Http.sniff(head) end
        end
        -- checked as soon as its first bytes are here: anything else is refused at once
        if #head >= 16 or #chunk == 0 then
            local want = kind == "image" and (what == "jpg" or what == "png")
                or kind == "pdf" and what == "pdf" or kind == "inkaway" and what == "inkaway"
            if not want then
                return nil, kind == "image" and "Only JPEG and PNG pictures (or make it smaller on the page first)."
                    or kind == "pdf" and "That isn't a PDF." or "That isn't an Ink Away file."
            end
        end
        if not f:write(chunk) then return nil, "The reader couldn't write it. Is it full?" end
        return true
    end
    function sink.abort(why)
        drop()
        logger.info("InkAway: upload stopped:", why)
    end
    function sink.finish(reply)
        f:close(); f = nil
        -- a file shorter than its check: look once more at the whole start
        local rf = io.open(part, "rb")
        local start = rf and rf:read(1024 * 1024) or ""   -- (a phone's EXIF can come before the size)
        if rf then rf:close() end
        what = Http.sniff(start)
        local ext = kind == "image" and what or kind
        if not ((kind == "image" and (what == "jpg" or what == "png")) or what == kind) then
            os.remove(part)
            return jsonReply(reply, 415, false, "That file isn't what it says it is.")
        end
        if kind == "image" then
            local w, h = Http.imageSize(start)
            if not w then
                os.remove(part)
                return jsonReply(reply, 422, false, "The reader can't read this picture.")
            end
            if w * h > MAX_PIXELS then
                os.remove(part)
                return jsonReply(reply, 413, false, string.format(
                    "This picture is %d x %d, too large for an e-reader. Choose a smaller size on the page.", w, h))
            end
        elseif kind == "inkaway" then
            -- read as data only, never run; then written again as Ink Away writes
            -- its own, without any reference to a file elsewhere on the reader
            local rf2 = io.open(part, "rb")
            local text = rf2 and rf2:read("*a") or ""
            if rf2 then rf2:close() end
            local data, why = SafeData.decode(text)
            text = nil   -- luacheck: ignore
            local fine = type(data) == "table" and type(data.w) == "number" and type(data.h) == "number"
                and data.w > 0 and data.h > 0 and data.w < 20000 and data.h < 20000
                and (type(data.ops) == "table" or type(data.pages) == "table")
            if not fine then
                logger.info("InkAway: a sent Ink Away file was refused:", why)
                os.remove(part)
                return jsonReply(reply, 422, false, "The reader can't read this Ink Away file.")
            end
            local root = Storage.appRootPath()
            local dropped = SafeData.dropOutside(data, function(p)
                return root ~= nil and p:sub(1, #root + 1) == root .. "/" and not p:find("/%.%./") and not p:find("/%.%.$")
            end)
            if dropped > 0 then logger.info("InkAway: a sent Ink Away file pointed elsewhere:", dropped) end
            if not Storage.writeAtomic(part, Project.encode(data)) then
                os.remove(part)
                return jsonReply(reply, 507, false, "The reader couldn't save it.")
            end
        end
        local name = freeName(dir, Http.cleanName(sent_name, ext))
        local final = Storage.join(dir, name)
        if not os.rename(part, final) then
            os.remove(part)
            return jsonReply(reply, 500, false, "The reader couldn't save it.")
        end
        send.received = send.received + 1
        send.last = os.time()
        self:sendStatusChanged()
        local arrival = { kind = kind, name = name, path = final, batch = batch, last = (i and n and i >= n) }
        if kind == "pdf" then
            send.importing = send.importing + 1
            UIManager:nextTick(function() self:importArrivedPdf(arrival) end)
            jsonReply(reply, 200, true, string.format("Sent. It's becoming a notebook in %s.", self:importedPlace("pdf")))
        elseif kind == "image" then
            self:arrived(arrival)
            jsonReply(reply, 200, true, string.format("Sent to %s.", self:importedPlace("image")))
        else
            Folder.update(dir, function(d) Folder.add(d, name) end)
            arrival.kind = "notebook"
            arrival.from = "inkaway"
            arrival.name = Storage.stem(name)
            self:arrived(arrival)
            jsonReply(reply, 200, true, string.format("Sent to %s.", self:importedPlace("inkaway")))
        end
    end
    return sink
end

-- Make a notebook on a PDF that arrived, in Library > Imported.
function InkAwayView:importArrivedPdf(arrival)
    local send = self._send
    local ok, nb_path = pcall(function()
        local doc = require("document/documentregistry"):openDocument(arrival.path)
        if not doc then error("not a PDF KOReader can open") end
        local pages = 1
        pcall(function() pages = doc:getPageCount() or 1 end)
        pcall(function() doc:close() end)
        if not pages or pages < 1 then pages = 1 end
        if pages > MAX_PDF_PAGES then error("too many pages") end
        local nb = Notebook.forPdf(self.screen_w, self.screen_h, {
            style = "blank", size = self.grid_size or 40, strength = self.grid_strength or 45, pdf_path = arrival.path,
        }, pages)
        local dir = self:importedDir("pdf")
        if not dir then error("no Imported > PDFs folder") end
        local name = freeName(dir, Storage.fileName(Storage.stem(arrival.name), Project.EXT))
        local path = Storage.join(dir, name)
        local sok, serr = Project.saveNotebook(nb, path)
        if not sok then error(serr or "not saved") end
        Folder.update(dir, function(d) Folder.add(d, name) end)
        return path
    end)
    if send then send.importing = math.max(0, send.importing - 1) end
    if not ok then
        logger.warn("InkAway: import of a sent PDF failed:", nb_path)
        os.remove(arrival.path)
        if not self.closing then
            self:showNotice(string.format(_("Couldn't open %s as a notebook"), arrival.name))
        end
        return self:arrivalsMaybeDone()
    end
    if self.closing then return end   -- (Ink Away closed meanwhile: the notebook is there, nothing to ask)
    self:refreshLibrary()
    self:arrived{ kind = "notebook", from = "pdf", name = Storage.stem(arrival.name), path = nb_path,
        batch = arrival.batch, last = arrival.last }
end

------------------------------------------------------------------------------
-- Telling the reader what arrived
------------------------------------------------------------------------------

-- Is anything still coming (uploads, or PDFs being made into notebooks)?
function InkAwayView:arrivalsComing()
    local send = self._send
    return send ~= nil and (send.server:uploads() > 0 or send.importing > 0)
end

-- A file arrived: notebooks wait for the question (or a note, after Don't ask
-- again), pictures for a note; both are gathered for a moment, so files sent
-- together are told about together.
function InkAwayView:arrived(a)
    local send = self._send
    if not send then return end
    self:refreshLibrary()
    if a.kind == "notebook" and self:askToOpenArrivals() then
        send.arrived[#send.arrived + 1] = a
    else
        send.noted[#send.noted + 1] = a
    end
    self:arrivalsMaybeDone()
end

-- Tell about what arrived once nothing more is coming (checked again every
-- second or so while it is); a question already up shows the new ones too.
function InkAwayView:arrivalsMaybeDone()
    local send = self._send
    if not send or send.arrival_tick then return end
    send.arrival_tick = function()
        send.arrival_tick = nil
        if self._send ~= send then return end
        if self:arrivalsComing() then return self:arrivalsMaybeDone() end
        if #send.noted > 0 then self:noteArrivals() end
        if self._arrived_dialog then
            self:rebuildSheet("_arrived_dialog")
        elseif #send.arrived > 0 then
            self:showArrivals()
        end
        if send.open_after then
            local a = send.open_after
            send.open_after = nil
            self:openArrived(a)
        end
    end
    UIManager:scheduleIn(1.2, send.arrival_tick)
end

-- A short note for what arrived without a question: pictures, and notebooks
-- once Don't ask again is on.
function InkAwayView:noteArrivals()
    local send = self._send
    local count = { image = 0, pdf = 0, inkaway = 0 }
    for _i, a in ipairs(send.noted) do
        local k = a.kind == "image" and "image" or (a.from or "pdf")
        count[k] = count[k] + 1
    end
    send.noted = {}
    local parts = {}
    local words = { pdf = { _("1 notebook from a PDF"), _("%d notebooks from PDFs") },
        inkaway = { _("1 notebook or drawing"), _("%d notebooks and drawings") },
        image = { _("1 picture"), _("%d pictures") } }
    for _i, k in ipairs({ "pdf", "inkaway", "image" }) do
        if count[k] > 0 then
            local what = count[k] == 1 and words[k][1] or string.format(words[k][2], count[k])
            parts[#parts + 1] = string.format(_("%s in %s"), what, self:importedPlace(k))
        end
    end
    self:showNotice(string.format(_("Arrived: %s"), table.concat(parts, "; ")))
end

-- The question: the notebooks that arrived, each to open, or later; and
-- Don't ask again. One sheet whatever arrives, brought up to date.
function InkAwayView:showArrivals()
    local send = self._send
    if not send then return end
    local content_w = self:sheetWidth()
    local closeSelf = function() self:closeSheet("_arrived_dialog") end
    local function para(text, size, color)
        return TextBoxWidget:new{ text = text, face = Font:getFace("cfont", size or 16), width = content_w, fgcolor = color }
    end
    local build = function()
        local list = send.arrived
        local content = VerticalGroup:new{ align = "left" }
        local function add(w) table.insert(content, w) end
        add(self:sheetTitle(_("From your phone or computer"), content_w, _("Later"), closeSelf))
        add(VerticalSpan:new{ width = S(10) })
        local where = list[1] and self:importedPlace(list[1].from or "pdf")
        for _i, a in ipairs(list) do
            if self:importedPlace(a.from or "pdf") ~= where then where = _("Library") .. " › Imported" end
        end
        add(para(#list == 1 and string.format(_("%s arrived in %s. Open it now?"), list[1].name, where)
            or string.format(_("%d notebooks arrived in %s. Open one now?"), #list, where)))
        if self:arrivalsComing() then
            add(VerticalSpan:new{ width = S(6) })
            add(para(_("More are still coming."), 14))
        end
        add(VerticalSpan:new{ width = S(12) })
        for k = 1, math.min(#list, 4) do
            local a = list[k]
            add(self:actionButton(#list == 1 and _("Open") or string.format(_("Open %s"), a.name), content_w,
                function() self:openArrived(a) end, k == 1))
            add(VerticalSpan:new{ width = S(8) })
        end
        if #list > 4 then
            add(self:actionButton(_("Show them in the library"), content_w, function()
                closeSelf()
                self:openLibrary(self:importedFolder())
            end))
            add(VerticalSpan:new{ width = S(8) })
        end
        add(VerticalSpan:new{ width = S(6) })
        add(ToggleRow:new{ label = _("Don't ask again"), is_on = not self:askToOpenArrivals(), width = content_w,
            parent = self._arrived_dialog,
            callback = function(on) self:setSetting("inkaway_send_ask_open", not on) end })
        add(VerticalSpan:new{ width = S(4) })
        add(para(_("Either way they stay in Library › Imported. To be asked again, turn on \"Ask to open notebooks that arrive\" in Phone or computer (Wi-Fi)."), 13))
        return content
    end
    self:showSheet("_arrived_dialog", build)
    -- what was shown is answered once the sheet closes, however it closes
    local sheet = self._arrived_dialog
    local closed = sheet.onCloseWidget
    sheet.onCloseWidget = function(w, ...)
        if self._send == send and self._arrived_dialog == w then send.arrived = {} end
        if closed then return closed(w, ...) end
    end
end

-- Open notebook arrival `a`: now, or once the files still coming are in
-- (opening it stops sharing).
function InkAwayView:openArrived(a)
    local send = self._send
    if send and self:arrivalsComing() then
        send.open_after = a
        self:closeSheet("_arrived_dialog")
        self:showNotice(string.format(_("%s opens once the rest have arrived"), a.name))
        return
    end
    self:closeSheet("_arrived_dialog")
    if not Storage.exists(a.path) then
        self:showNotice(string.format(_("%s isn't there any more"), a.name))
        return
    end
    self:closeSheet("_send_dialog")   -- sharing stops
    if self._library then self._library:close() end
    self:openDocument(a.path)
end

return InkAwayView

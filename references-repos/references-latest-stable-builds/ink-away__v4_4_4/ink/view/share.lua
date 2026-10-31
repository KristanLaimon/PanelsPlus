--[[
Send to phone or computer: while its sheet is open, the reader serves a small
web page on the home Wi-Fi (see ink/share/), and a phone or computer on the
same network opens it from a QR code or the address under it. The page lists
the library's folders and documents with their pictures, and hands out each
one as a PDF, a PNG (a drawing) or its Ink Away file, plus the files already
exported. PDFs and PNGs are made when asked for, one at a time and a page per
tick, with their progress on the reader and on the page (which reloads itself
and downloads the file once it is ready), and either can cancel; they are
kept until sharing stops. Pictures for the page are drawn one at a time in
the background. Nothing leaves the home network, and nothing can be changed
from the page. Sharing stops when the sheet closes, when the reader
sleeps, when Ink Away closes, or after a while with nothing asked for.
Part of InkAwayView (see ink/view.lua).
]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local CenterContainer = require("ui/widget/container/centercontainer")
local Geom = require("ui/geometry")
local logger = require("logger")
local _ = require("ink/l10n")
local Accent = require("ink/accent")
local Export = require("ink/export")
local Folder = require("ink/folder")
local FolderLook = require("ink/folderlook")
local Http = require("ink/share/http")
local Library = require("ink/library")
local Net = require("ink/share/net")
local Page = require("ink/share/page")
local Storage = require("ink/storage")

local Screen = Device.screen
local function S(px) return Screen:scaleBySize(px) end

local IDLE_MINUTES = 15
local THUMB_W, THUMB_H = 240, 320
local MAX_JOBS = 8        -- PDFs and PNGs waiting to be made, at most
local MAX_THUMBS = 64     -- pictures waiting to be drawn, at most

local InkAwayView = {}

local function deviceIs(name)
    local f = Device[name]
    if type(f) ~= "function" then return false end
    local ok, yes = pcall(f, Device)
    return ok and yes == true
end

-- Is `path` inside folder `root` once links are followed? (A link the reader
-- made in the library could lead anywhere.) True where it can't be told.
local function realInside(path, root)
    local ok, util = pcall(require, "ffi/util")
    if not (ok and util and util.realpath) then return true end
    local rp, rr = util.realpath(path), util.realpath(root)
    if not (rp and rr) then return false end
    return rp == rr or rp:sub(1, #rr + 1) == rr .. "/"
end

-- An HTML reply, with the page's security policy (`nonce`: the one script
-- the page may run).
local function html(reply, code, body, nonce)
    reply.send(code, Http.TYPES.html, body, { Page.csp(nonce), "X-Frame-Options: DENY" })
end

-- The page's theme colour: the reader's own (a preset, one from the wheel, or
-- black) on a colour screen, and Ink Away's green on a grey one, where the
-- reader's theme is always black. nil means the green the page starts with.
local function pageAccent(colour_screen)
    if not colour_screen then return nil end
    local a = Accent.get()
    if a.rgb then return Page.accent(a.rgb, a.dark_text) end
    return Page.accent({ 0, 0, 0 }, false)   -- black, chosen on a colour screen
end

local function hex(rgb)
    return rgb and string.format("#%02x%02x%02x", rgb[1], rgb[2], rgb[3]) or nil
end

------------------------------------------------------------------------------
-- Starting and stopping
------------------------------------------------------------------------------

-- Open Send to phone or computer: Wi-Fi first (KOReader asks to turn it on,
-- then comes back here), then the server and its sheet.
-- `o.adding`: opened to add files (from Add image), so Allow adding files
-- starts on; it can still be turned off on the sheet.
function InkAwayView:openSend(o)
    o = o or {}
    if self._send then
        if o.adding then self._send.allow_upload = true end
        return self:showSendSheet()
    end
    local okn, NetworkMgr = pcall(require, "ui/network/manager")
    if okn and NetworkMgr and NetworkMgr.willRerunWhenConnected
            and NetworkMgr:willRerunWhenConnected(function() if not self.closing then self:openSend(o) end end) then
        return
    end
    self:leaveDocument()   -- the open document's latest changes go out too
    local ok, err = self:startSend()
    if not ok then
        self:tell(err)
        return
    end
    if o.adding then self._send.allow_upload = true end
    self:showSendSheet()
end

-- Start the server. Returns true, or false and what to tell the reader.
function InkAwayView:startSend()
    local oks, socket = pcall(require, "socket")
    if not oks then return false, _("This reader can't share over Wi-Fi.") end
    local okn, NetworkMgr = pcall(require, "ui/network/manager")
    local ip = Net.localIP(socket, nil, okn and NetworkMgr and NetworkMgr.interface or nil)
    if not ip then
        return false, _("This reader has no address on a network yet. Connect it to Wi-Fi and try again.")
    end
    local Server = require("ink/share/server")
    local Event = require("ui/event")
    local send = { token = Http.token(Http.randomBytes(12), 12), ip = ip, sent = 0, last = os.time(),
        cache = Storage.join(Storage.cacheDir(), "send"), queue = {}, jobs = {}, thumbs = {}, cancelled = {},
        -- adding files (see ink/view/receive.lua): off each time sharing starts
        allow_upload = false, received = 0, importing = 0, arrived = {}, noted = {} }
    Storage.ensureDir(send.cache)
    -- what a crash or a power cut left from the last sharing
    for _i, e in ipairs(Storage.list(send.cache)) do os.remove(e.path) end
    pcall(self.clearUploadParts, self)
    pcall(self.sortImported, self)
    local kindle = deviceIs("isKindle")
    send.server = Server.new{
        socket = socket,
        handler = function(req, reply) self:sendRoute(req, reply) end,
        on_activity = function() send.last = os.time() end,
        make_event = function() return Event:new("InputEvent") end,   -- keeps the reader awake while in use
        on_error = function(err) logger.warn("InkAway: send:", err) end,
        -- the Kindle's firewall is closed again however the server stops (KOReader quitting too)
        on_stop = kindle and function() Net.closeFirewall(send.port) end or nil,
    }
    local port, perr = send.server:start()
    if not port then
        logger.warn("InkAway: send: no port:", perr)
        return false, _("Couldn't start sharing: no free port on this reader.") .. "\n" .. tostring(perr)
    end
    send.port = port
    send.url = string.format("http://%s:%d/%s/", ip, port, send.token)
    if kindle then
        Net.closeFirewall(port)   -- (a rule left by a crash is not added twice)
        Net.openFirewall(port)
    end
    UIManager:insertZMQ(send.server)
    -- no light sleep (a Kobo's standby) while sharing: the phone couldn't reach it
    if UIManager.preventStandby then UIManager:preventStandby(); send.standby = true end
    self._send = send
    send.idle = function()
        if self._send ~= send then return end
        if os.time() - send.last >= IDLE_MINUTES * 60 and not send.server:busy() and not send.current
                and send.importing == 0 then
            self:stopSend()
            self:closeSheet("_send_dialog")
            self:showNotice(string.format(_("Phone or computer sharing stopped: nothing happened for %d minutes"), IDLE_MINUTES))
            return
        end
        UIManager:scheduleIn(60, send.idle)
    end
    UIManager:scheduleIn(60, send.idle)
    logger.info("InkAway: sharing at", ip, port)
    return true
end

-- Stop sharing: the server, its downloads, the firewall hole, and the PDFs
-- and PNGs made for it.
function InkAwayView:stopSend()
    local send = self._send
    if not send then return end
    self._send = nil
    UIManager:unschedule(send.idle)
    if send.status_tick then UIManager:unschedule(send.status_tick) end
    if send.thumb_tick then UIManager:unschedule(send.thumb_tick) end
    if send.arrival_tick then UIManager:unschedule(send.arrival_tick) end
    if send.step then UIManager:unschedule(send.step) end
    if send.job then pcall(send.job.cancel) end
    if send.spec_done then pcall(send.spec_done) end
    UIManager:removeZMQ(send.server)
    send.server:stop()   -- (closes the Kindle's firewall again, see on_stop)
    if send.standby then UIManager:allowStandby(); send.standby = nil end
    for _i, e in ipairs(Storage.list(send.cache)) do os.remove(e.path) end
    logger.info("InkAway: sharing stopped")
end

-- The reader goes to sleep: sharing stops (its network goes too).
function InkAwayView:stopSendForSleep()
    if self._send then
        self:stopSend()
        self:closeSheet("_send_dialog")
    end
end

-- Wi-Fi went away: nothing can reach the page any more.
function InkAwayView:onNetworkDisconnected()
    if self._send then
        self:stopSend()
        self:closeSheet("_send_dialog")
        self:showNotice(_("Phone or computer sharing stopped: Wi-Fi is off"))
    end
end

------------------------------------------------------------------------------
-- The sheet
------------------------------------------------------------------------------

-- What the reader is doing for the page now: { label, fraction (0..1),
-- cancel = function } for a PDF or PNG being made or files going out, or nil.
function InkAwayView:sendProgress()
    local send = self._send
    if not send then return nil end
    local job = send.current
    if job then
        local n, i = job.n or 0, job.i or 0
        local label = string.format(_("Preparing %s"), job.name)
        if n > 1 then label = label .. "\n" .. string.format(_("%d of %d pages"), math.min(i + 1, n), n) end
        if #send.queue > 0 then
            label = label .. "\n" .. (#send.queue == 1 and _("1 more after it")
                or string.format(_("%d more after it"), #send.queue))
        end
        return { label = label, fraction = n > 0 and i / n or 0, cancel = function() self:sendCancelAll() end }
    end
    local list = send.server:transfers()
    if #list > 0 then
        local sent, total, incoming = 0, 0, 0
        for _i, t in ipairs(list) do
            sent = sent + t.sent; total = total + t.total
            if t.incoming then incoming = incoming + 1 end
        end
        local label
        if #list == 1 then
            label = string.format(incoming == 1 and _("Receiving %s: %s of %s") or _("Sending %s: %s of %s"),
                list[1].name, Http.size(sent), Http.size(total))
        else
            label = string.format(incoming == #list and _("Receiving %d files: %s of %s")
                or _("Sending %d files: %s of %s"), #list, Http.size(sent), Http.size(total))
        end
        return { label = label, fraction = total > 0 and sent / total or 0, cancel = function()
            send.server:cancelTransfers()
            send.server:cancelUploads("cancelled on the reader")
            self:sendStatusChanged()
        end }
    end
    if send.importing > 0 then
        return { label = _("Making a notebook in Library › Imported › PDFs\u{2026}"), fraction = 1 }
    end
end

function InkAwayView:sendStatus()
    local send = self._send
    if not send then return "" end
    if send.sent == 0 and send.received == 0 then return _("Waiting for your phone or computer\u{2026}") end
    local parts = {}
    if send.sent > 0 then parts[#parts + 1] = send.sent == 1 and _("1 file sent") or string.format(_("%d files sent"), send.sent) end
    if send.received > 0 then
        parts[#parts + 1] = send.received == 1 and _("1 file received") or string.format(_("%d files received"), send.received)
    end
    return table.concat(parts, ", ")
end

-- Show the status again (at most every couple of seconds, as e-ink redraws the
-- sheet), and keep showing it while something is going on.
function InkAwayView:sendStatusChanged()
    local send = self._send
    if not send or send.status_tick then return end
    send.status_tick = function()
        send.status_tick = nil
        if self._send ~= send then return end
        -- (not under the arrivals question: the sheet below would be drawn over it)
        if not self._arrived_dialog then self:rebuildSheet("_send_dialog") end
        if self:sendProgress() or self._arrived_dialog then self:sendStatusChanged() end
    end
    UIManager:scheduleIn(2, send.status_tick)
end

function InkAwayView:showSendSheet()
    local send = self._send
    if not send then return end
    if self._send_dialog then return self:rebuildSheet("_send_dialog") end   -- (already up: no second one)
    local content_w = self:sheetWidth()
    local closeSelf = function() self:closeSheet("_send_dialog") end
    local function para(text, size, bold, color)
        return TextBoxWidget:new{ text = text, face = Font:getFace("cfont", size or 16), bold = bold,
            fgcolor = color, width = content_w, alignment = "center" }
    end
    local build = function()
        local content = VerticalGroup:new{ align = "center" }
        local function add(w) table.insert(content, w) end
        add(self:sheetTitle(_("Phone or computer (Wi-Fi)"), content_w, _("Stop"), closeSelf))
        add(VerticalSpan:new{ width = S(10) })
        add(para(_("Scan with a phone or computer on the same Wi-Fi, or open:")))
        add(VerticalSpan:new{ width = S(12) })
        local side = math.floor(math.min(content_w * 0.62, math.min(Screen:getWidth(), Screen:getHeight()) * 0.5))
        local okq, QRWidget = pcall(require, "ui/widget/qrwidget")
        if okq and QRWidget then
            add(CenterContainer:new{ dimen = Geom:new{ w = content_w, h = side },
                QRWidget:new{ text = send.url, width = side, height = side } })
            add(VerticalSpan:new{ width = S(12) })
        end
        add(para(send.url, 18, true))
        add(VerticalSpan:new{ width = S(14) })
        local prog = self:sendProgress()
        if prog then
            add(para(prog.label, 16, true))
            add(VerticalSpan:new{ width = S(8) })
            local ProgressWidget = require("ui/widget/progresswidget")
            add(ProgressWidget:new{ width = content_w, height = S(12), percentage = prog.fraction })
            add(VerticalSpan:new{ width = S(10) })
            if prog.cancel then
                add(self:actionButton(_("Cancel"), content_w, function()
                    prog.cancel()
                    self:rebuildSheet("_send_dialog")
                end))
            end
        else
            add(para(self:sendStatus(), 16, true, Blitbuffer.COLOR_DARK_GRAY))
        end
        add(VerticalSpan:new{ width = S(12) })
        local ToggleRow = require("ink/ui/controls").ToggleRow
        add(ToggleRow:new{ label = _("Allow adding files"), is_on = send.allow_upload, width = content_w,
            parent = self._send_dialog, callback = function(on)
                send.allow_upload = on
                self:rebuildSheet("_send_dialog")
            end })
        if send.allow_upload then
            add(VerticalSpan:new{ width = S(6) })
            add(ToggleRow:new{ label = _("Ask to open notebooks that arrive"), is_on = self:askToOpenArrivals(),
                width = content_w, parent = self._send_dialog,
                callback = function(on) self:setSetting("inkaway_send_ask_open", on) end })
            add(VerticalSpan:new{ width = S(6) })
            add(para(_("Files arrive in Library › Imported. Reload the page if it was open."), 14, false, Blitbuffer.COLOR_DARK_GRAY))
        else
            add(VerticalSpan:new{ width = S(6) })
            add(para(_("Turn on to send PDFs and pictures here."), 14, false, Blitbuffer.COLOR_DARK_GRAY))
        end
        add(VerticalSpan:new{ width = S(10) })
        add(para(string.format(_("Stops when closed or after %d idle minutes. Use a Wi-Fi you trust."), IDLE_MINUTES), 14, false, Blitbuffer.COLOR_DARK_GRAY))
        return content
    end
    self:showSheet("_send_dialog", build)
    -- sharing stops with the sheet, however it closes (Stop, Back, a tap
    -- outside, or Ink Away closing)
    local sheet = self._send_dialog
    local closed = sheet.onCloseWidget
    sheet.onCloseWidget = function(w, ...)
        if self._send_dialog == w or self._send_dialog == nil then self:stopSend() end
        if closed then return closed(w, ...) end
    end
end

------------------------------------------------------------------------------
-- The page's routes
------------------------------------------------------------------------------

-- The library folder or document at `rel` (see Http.safeRel), as a path, or
-- nil when it isn't one the page may show.
function InkAwayView:sendPath(rel, want_dir)
    rel = Http.safeRel(rel)
    if not rel then return nil end
    local root = self:libraryDir()
    local path = rel == "" and root or Storage.join(root, rel)
    -- the library's own folders (exports, legacy folders) are not part of it
    local first = rel:match("^[^/]+")
    if first and Library.INTERNAL[first] then return nil end
    if not realInside(path, root) then return nil end
    if want_dir then return Storage.isDir(path) and path or nil end
    local name = Storage.baseName(path)
    if not (Storage.exists(path) and not Storage.isDir(path) and (Library.isDocument(name) or Library.isPicture(name))) then
        return nil
    end
    return path
end

function InkAwayView:sendRoute(req, reply)
    local send = self._send
    if not send then return reply.send(503, Http.TYPES.txt, "Stopped") end
    local base = "/" .. send.token .. "/"
    if req.path:sub(1, #base) ~= base and req.path .. "/" ~= base then
        return html(reply, 404, Page.gone())
    end
    local route = req.path:sub(#base + 1)
    local q = req.query
    if route == "" then return self:sendListing(q.d or "", reply) end
    if route == "export" then return self:sendExport(q.n, reply) end
    if route == "cancel" then return self:sendCancelPage(q.k, reply) end
    if route == "upload" then return self:sendUpload(req, reply) end
    if req.method ~= "GET" then return reply.send(405, Http.TYPES.txt, "Not here") end
    local path = self:sendPath(q.p)
    if not path then return reply.send(404, Http.TYPES.txt, "Not found") end
    local picture = Library.isPicture(Storage.baseName(path))
    if route == "file" then
        return reply.file(path, picture and Http.typeOf(path) or Http.TYPES.inkaway, Storage.baseName(path),
            function() self:sendCounted() end)
    elseif picture then
        if route == "thumb" then return self:sendThumb(path, reply, true) end
        return reply.send(404, Http.TYPES.txt, "Not found")
    elseif route == "thumb" then
        return self:sendThumb(path, reply)
    elseif route == "pdf" then
        return self:sendMade(path, "pdf", req, reply)
    elseif route == "png" and not Library.isNotebookFile(path) then
        return self:sendMade(path, "png", req, reply)
    end
    reply.send(404, Http.TYPES.txt, "Not found")
end

function InkAwayView:sendCounted()
    if not self._send then return end
    self._send.sent = self._send.sent + 1
    self:sendStatusChanged()
end

-- The page for library folder `rel`.
function InkAwayView:sendListing(rel, reply)
    local send = self._send
    local dir = self:sendPath(rel, true)
    if not dir then return html(reply, 404, Page.gone()) end
    rel = Http.safeRel(rel)
    local base = "/" .. send.token .. "/"
    local function here(sub) return rel == "" and sub or (rel .. "/" .. sub) end
    local folders, docs, pics = Library.list(dir, self:libraryDir(), self:getSetting("inkaway_library_sort"))
    local looks = #folders > 0 and Folder.load(dir).folders or {}
    local o = { title = rel == "" and _("Library") or Storage.baseName(dir), folders = {}, docs = {},
        note = _("Served by your reader over your Wi-Fi. When you're done, close Phone or computer (Wi-Fi) on the reader.") }
    -- the way back up
    if rel ~= "" then
        o.crumbs = { { label = _("Library"), href = base } }
        local acc = ""
        local parts = {}
        for part in rel:gmatch("[^/]+") do parts[#parts + 1] = part end
        for i, part in ipairs(parts) do
            acc = acc == "" and part or (acc .. "/" .. part)
            o.crumbs[#o.crumbs + 1] = { label = part, href = i < #parts and (base .. "?d=" .. Http.urlEncode(acc)) or nil }
        end
    end
    for _i, f in ipairs(folders) do
        local look = FolderLook.clean(looks[f.name])
        o.folders[#o.folders + 1] = { name = f.name, href = base .. "?d=" .. Http.urlEncode(here(f.name)),
            color = hex(look and FolderLook.rgb(look.color)) }
    end
    for _i, d in ipairs(docs) do
        local p = Http.urlEncode(here(d.name))
        local notebook = Library.isNotebookFile(d.path)
        local links = notebook
            and { { label = "PDF", href = base .. "pdf?p=" .. p, main = true } }
            or { { label = "PNG", href = base .. "png?p=" .. p, main = true }, { label = "PDF", href = base .. "pdf?p=" .. p } }
        links[#links + 1] = { label = _("Ink Away file"), href = base .. "file?p=" .. p }
        o.docs[#o.docs + 1] = { name = Storage.stem(d.name), thumb = base .. "thumb?p=" .. p,
            kind = (notebook and _("Notebook") or _("Drawing")) .. " · " .. os.date("%d %b %Y", d.mtime or 0),
            links = links }
    end
    o.pictures = {}
    for _i, pic in ipairs(pics or {}) do
        local p = Http.urlEncode(here(pic.name))
        o.pictures[#o.pictures + 1] = { name = Storage.stem(pic.name), thumb = base .. "thumb?p=" .. p,
            kind = _("Picture") .. " · " .. os.date("%d %b %Y", pic.mtime or 0),
            links = { { label = _("Download"), href = base .. "file?p=" .. p, main = true } } }
    end
    if rel == "" then o.exports = self:sendExportsList(base) end
    local R = self.RECEIVE_LIMITS
    local nonce = Http.token(Http.randomBytes(12), 16)
    o.upload = { allowed = send.allow_upload, url = base .. "upload", nonce = nonce,
        limits = { pdf = R.limits.pdf, image = R.limits.image, inkaway = R.limits.inkaway }, max_pixels = R.max_pixels }
    o.accent = pageAccent(self:colorScreen())
    html(reply, 200, Page.render(o), nonce)
end

-- The folders exports are saved in: Ink Away's own, and the one chosen in
-- Settings when it is another.
function InkAwayView:sendExportDirs()
    local dirs, seen = {}, {}
    local app = Storage.appRootPath()
    for _i, d in ipairs({ Storage.appDir("exports"), self:exportDir() }) do
        -- only Ink Away's own folders: a chosen export folder elsewhere (the
        -- books' folder, say) is not offered
        if d and not seen[d] and Storage.isDir(d) and app and realInside(d, app) then
            seen[d] = true; dirs[#dirs + 1] = d
        end
    end
    return dirs
end

-- The PDFs and PNGs already exported, newest first.
function InkAwayView:sendExportsList(base)
    local files = {}
    for _i, dir in ipairs(self:sendExportDirs()) do
        for _j, e in ipairs(Storage.list(dir)) do
            local ext = e.name:match("%.(%w+)$")
            ext = ext and ext:lower()
            if e.mode == "file" and (ext == "pdf" or ext == "png") and e.name:sub(1, 1) ~= "." then
                files[#files + 1] = e
            end
        end
    end
    table.sort(files, function(a, b) return (a.mtime or 0) > (b.mtime or 0) end)
    local out = {}
    for i = 1, math.min(#files, 40) do
        local e = files[i]
        local attr = Storage.size and Storage.size(e.path)
        out[i] = { name = e.name, href = base .. "export?n=" .. Http.urlEncode(e.name),
            size = attr and Http.size(attr) or nil }
    end
    return out
end

-- An exported file, by its name.
function InkAwayView:sendExport(name, reply)
    name = tostring(name or "")
    local ext = name:match("%.(%w+)$")
    ext = ext and ext:lower()
    if name == "" or name:find("[/\\%z]") or name:sub(1, 1) == "." or (ext ~= "pdf" and ext ~= "png") then
        return reply.send(404, Http.TYPES.txt, "Not found")
    end
    for _i, dir in ipairs(self:sendExportDirs()) do
        local path = Storage.join(dir, name)
        if Storage.exists(path) and not Storage.isDir(path) and realInside(path, dir) then
            return reply.file(path, Http.typeOf(name), name, function() self:sendCounted() end)
        end
    end
    reply.send(404, Http.TYPES.txt, "Not found")
end

-- A document's picture for the page: from the library's thumbnail cache, or
-- drawn in the background (one at a time, see sendNextThumb) and sent then.
function InkAwayView:sendThumb(path, reply, picture)
    local send = self._send
    local file = Storage.join(Storage.cacheDir(), Library.thumbName(path, Storage.mtime(path), THUMB_W, THUMB_H))
    if Storage.exists(file) then return reply.file(file, Http.TYPES.png, nil) end
    -- the library's own picture of it, any size (the browser scales it): no drawing at all
    local prefix = string.format("%s-%d-", Library.pathCode(path), Storage.mtime(path) or 0)
    for _i, e in ipairs(Storage.list(Storage.cacheDir())) do
        if e.name:sub(1, #prefix) == prefix and e.name:match("%.png$") then
            return reply.file(e.path, Http.TYPES.png, nil)
        end
    end
    if #send.thumbs >= MAX_THUMBS then return reply.send(503, Http.TYPES.txt, "Busy") end
    reply.wait()
    send.thumbs[#send.thumbs + 1] = { path = path, file = file, reply = reply, picture = picture }
    self:sendNextThumb()
end

function InkAwayView:sendNextThumb()
    local send = self._send
    if not send or send.thumb_tick or #send.thumbs == 0 then return end
    send.thumb_tick = function()
        send.thumb_tick = nil
        if self._send ~= send then return end
        local t = table.remove(send.thumbs, 1)
        if t and t.reply.open() then
            if not Storage.exists(t.file) then
                local ok, bb = pcall(t.picture and self.pictureThumb or self.docThumb, self, t.path, THUMB_W, THUMB_H)
                if ok and bb then bb:free() end
            end
            if Storage.exists(t.file) then t.reply.file(t.file, Http.TYPES.png, nil)
            else t.reply.send(404, Http.TYPES.txt, "No picture") end
        end
        self:sendNextThumb()
    end
    -- after a PDF's page, when one is being made, so the two take turns
    UIManager:scheduleIn(0.05, send.thumb_tick)
end

------------------------------------------------------------------------------
-- PDFs and PNGs, made when asked for
------------------------------------------------------------------------------

-- The page shown while a PDF or PNG is made: it reloads itself every couple
-- of seconds, and the reload that finds it ready downloads it.
local function progressPage(job, here, cancel, accent)
    local n, i = job.n or 0, job.i or 0
    local what = n > 1 and string.format("%d of %d pages", math.min(i + 1, n), n) or "Almost ready\u{2026}"
    if job.state == "queued" then what = "Waiting for the files before it\u{2026}" end
    local pct = n > 0 and math.floor(100 * i / n) or 0
    return '<!doctype html><html lang="en"><head><meta charset="utf-8">'
        .. '<meta name="viewport" content="width=device-width,initial-scale=1">'
        .. '<meta http-equiv="refresh" content="2;url=' .. Http.html(here) .. '">'
        .. '<title>Preparing ' .. Http.html(job.name) .. '</title><style>'
        .. 'body{font:16px/1.4 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;margin:0;'
        .. 'background:#f6f7f4;color:#1d1f1b;display:flex;min-height:100vh;align-items:center;justify-content:center}'
        .. '@media (prefers-color-scheme:dark){body{background:#141613;color:#eef0ea}}'
        .. 'main{width:min(420px,90vw);text-align:center}h1{font-size:20px;margin:0 0 6px;word-break:break-word}'
        .. 'p{color:#6b7066;margin:6px 0}.bar{height:12px;border-radius:6px;background:#e3e6df;overflow:hidden;margin:18px 0}'
        .. '.bar i{display:block;height:100%;background:' .. (accent and accent.fill or '#9fd665') .. ';width:' .. pct .. '%}'
        .. 'a{display:inline-block;margin-top:14px;padding:8px 16px;border-radius:999px;background:#eef1ea;color:inherit;'
        .. 'text-decoration:none;font-weight:600}</style></head><body><main>'
        .. '<h1>Preparing ' .. Http.html(job.name) .. '</h1><p>' .. Http.html(what) .. '</p>'
        .. '<div class="bar"><i></i></div><p>The download starts by itself when it\'s ready.</p>'
        .. '<a href="' .. Http.html(cancel) .. '">Cancel</a></main></body></html>'
end

-- A short page with a way back to the library.
local function notePage(base, title, text, accent)
    return Page.render{ title = title, crumbs = { { label = "Library", href = base } }, note = text, accent = accent }
end

-- Send the document at `path` as a PDF or PNG (`kind`): the copy made for
-- this sharing when there is one, else a page following it being made.
function InkAwayView:sendMade(path, kind, req, reply)
    local send = self._send
    local base = "/" .. send.token .. "/"
    local out = Storage.join(send.cache, string.format("%s-%d.%s", Library.pathCode(path), Storage.mtime(path) or 0, kind))
    local key = Storage.baseName(out)
    local name = Storage.stem(Storage.baseName(path)) .. "." .. kind
    if Storage.exists(out) then
        return reply.file(out, Http.TYPES[kind], name, function() self:sendCounted() end)
    end
    local job = send.jobs[key]
    -- cancelled (on the reader or the page): the page's reloads don't start it
    -- again, only Make it again does
    if send.cancelled[key] then
        if req.query.retry ~= "1" then
            local again = base .. kind .. "?p=" .. Http.urlEncode(req.query.p or "") .. "&retry=1"
            return html(reply, 200, Page.render{ title = string.format("%s was cancelled", name),
                crumbs = { { label = "Library", href = base }, { label = "Make it again", href = again } },
                note = "Nothing more is made for it on the reader." })
        end
        send.cancelled[key] = nil
    end
    if job and job.state == "failed" and req.query.retry ~= "1" then
        send.jobs[key] = nil
        return html(reply, 200, notePage(base, string.format("Couldn't make %s", name),
            "The reader couldn't make this file. Try again, or use the Ink Away file."))
    end
    if not job or job.state == "failed" or job.state == "cancelled" then
        if #send.queue >= MAX_JOBS then
            return html(reply, 503, notePage(base, "The reader is busy",
                "It's making other files. Try again in a moment."))
        end
        job = { key = key, path = path, kind = kind, out = out, name = name, state = "queued" }
        send.jobs[key] = job
        send.queue[#send.queue + 1] = job
        self:sendNextJob()
        self:sendStatusChanged()
    end
    local here = base .. kind .. "?p=" .. Http.urlEncode(req.query.p or "")
    html(reply, 200, progressPage(job, here, base .. "cancel?k=" .. Http.urlEncode(key), pageAccent(self:colorScreen())))
end

-- The page's Cancel: stop that PDF or PNG, made or waiting.
function InkAwayView:sendCancelPage(key, reply)
    local send = self._send
    local base = "/" .. send.token .. "/"
    local job = key and send.jobs[key]
    if job then self:sendCancelJob(job) end
    html(reply, 200, notePage(base, "Cancelled", "Nothing more is made for it on the reader."))
end

-- Stop `job`: out of the queue, or stopped where it is (its part removed).
function InkAwayView:sendCancelJob(job)
    local send = self._send
    if not send then return end
    for i = #send.queue, 1, -1 do if send.queue[i] == job then table.remove(send.queue, i) end end
    job.state = "cancelled"
    send.jobs[job.key] = nil
    send.cancelled[job.key] = true
    if send.current == job then self:sendStopCurrent() end
    self:sendStatusChanged()
end

-- The reader's Cancel: every PDF and PNG being made or waiting.
function InkAwayView:sendCancelAll()
    local send = self._send
    if not send then return end
    for _i, job in ipairs(send.queue) do
        job.state = "cancelled"; send.jobs[job.key] = nil; send.cancelled[job.key] = true
    end
    send.queue = {}
    if send.current then
        send.current.state = "cancelled"
        send.jobs[send.current.key] = nil
        send.cancelled[send.current.key] = true
        self:sendStopCurrent()
    end
end

-- Stop the PDF or PNG being made, safely: its file is closed and removed, the
-- PDFs it read from are closed, and the next one starts.
function InkAwayView:sendStopCurrent()
    local send = self._send
    if send.step then UIManager:unschedule(send.step); send.step = nil end
    if send.job then pcall(send.job.cancel); send.job = nil end
    if send.spec_done then pcall(send.spec_done); send.spec_done = nil end
    send.current = nil
    UIManager:nextTick(function() self:sendNextJob() end)
end

-- Start the next PDF or PNG waiting, one at a time.
function InkAwayView:sendNextJob()
    local send = self._send
    if not send or send.current then return end
    local item = table.remove(send.queue, 1)
    if not item then return end
    send.current = item
    item.state, item.i, item.n = "running", 0, item.kind == "png" and 1 or 0
    local function finished(ok)
        if self._send ~= send or send.current ~= item then return end
        send.current, send.job, send.spec_done, send.step = nil, nil, nil, nil
        send.last = os.time()
        if ok and Storage.exists(item.out) then
            item.state = "done"
            send.jobs[item.key] = nil   -- (the file says it is ready)
        else
            item.state = "failed"
            os.remove(item.out)
        end
        self:sendStatusChanged()
        UIManager:nextTick(function() self:sendNextJob() end)
    end
    if item.kind == "png" then
        -- a drawing at its full size, on its paper
        send.step = function()
            send.step = nil
            if self._send ~= send or send.current ~= item then return end
            local ok, err = pcall(function()
                local bb = self:renderDocThumb(item.path, self.view.canvas_w, self.view.canvas_h)
                if not bb then error("no picture") end
                local tmp = item.out .. ".part"
                bb:writePNG(tmp)
                bb:free()
                os.rename(tmp, item.out)
            end)
            if not ok then logger.warn("InkAway: send: png failed:", err); os.remove(item.out .. ".part") end
            item.i = 1
            finished(ok)
        end
        UIManager:scheduleIn(0.05, send.step)
        return
    end
    -- a PDF, one page per step so the reader keeps up, and never filling the reader
    local function roomLeft()
        local okd, util = pcall(require, "util")
        local u = okd and util and util.diskUsage and util.diskUsage(send.cache)
        return not (u and u.available) or u.available > 64 * 1024 * 1024
    end
    if not roomLeft() then
        logger.warn("InkAway: send: not enough space for a PDF")
        return finished(false)
    end
    local ok, err = pcall(function()
        local acc = { pages = {}, templates = {}, sources = {}, places = {} }
        local entry = self:collectDocumentPages(item.path, acc)
        if not entry or #acc.pages == 0 then error("nothing to put in it") end
        local spec = self:pagesPdfSpec(acc, { entry })
        send.spec_done = spec.done
        local job, jerr = Export.notebookPDFJob(spec.pages, spec.w, spec.h, spec.template, item.out .. ".part", 85,
            Storage.settingsDir(), spec.bg, { outline = spec.outline, links = spec.links })
        if not job then error(jerr) end
        send.job = job
        item.n = #spec.pages
    end)
    if not ok then
        logger.warn("InkAway: send: pdf failed:", err)
        if send.spec_done then pcall(send.spec_done); send.spec_done = nil end
        return finished(false)
    end
    local job = send.job
    local function step()
        send.step = nil
        if self._send ~= send or send.job ~= job then return end
        -- a page that fails to draw fails the PDF, never KOReader
        local sok, state, serr = pcall(job.step)
        if sok and state == "done" then
            if send.spec_done then pcall(send.spec_done); send.spec_done = nil end
            os.rename(item.out .. ".part", item.out)
            return finished(true)
        elseif not sok or not state then
            logger.warn("InkAway: send: pdf failed:", sok and serr or state)
            pcall(job.cancel)
            if send.spec_done then pcall(send.spec_done); send.spec_done = nil end
            return finished(false)
        end
        item.i = job.i or item.i
        if item.i % 10 == 0 and not roomLeft() then
            logger.warn("InkAway: send: the reader is nearly full, PDF stopped")
            pcall(job.cancel)
            if send.spec_done then pcall(send.spec_done); send.spec_done = nil end
            return finished(false)
        end
        self:sendStatusChanged()
        send.step = step
        UIManager:scheduleIn(0.02, step)
    end
    send.step = step
    UIManager:scheduleIn(0.02, send.step)
end

return InkAwayView

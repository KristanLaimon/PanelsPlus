--[[
The web server behind Send to phone or computer: it runs on the reader itself,
on the home Wi-Fi, only while its sheet is open. KOReader's UI loop calls
waitEvent every few milliseconds (UIManager:insertZMQ, as for its own HTTP
tools), and each call does a little and never waits: it reads what requests
have arrived so far, answers the ones complete, and hands the open downloads
a few chunks each, so neither a big file nor a slow or hostile browser can
stop the reader. A reply may also wait (a picture still being drawn) and be
sent later. A file sent to the reader (an upload) is read the same way, a few
chunks a turn, into whatever the page's handler gives it, never past the size
the browser announced. Only sends and takes the files the page's handler
chooses (see ink/view/share.lua).
]]

local Http = require("ink/share/http")

local Server = {}
Server.__index = Server

local CHUNK = 64 * 1024        -- read from a file at a time
local BUDGET = 512 * 1024      -- sent per download per poll, at most
local MAX_HEAD = 8 * 1024      -- a request's headers, at most
local MAX_CONN = 16            -- connections at once (reading, waiting, sending and receiving)
local SILENT = 30              -- s an upload or download may go without a byte before it is dropped
local WAIT_LIMIT = 120         -- s a reply may wait (a picture being drawn) before it gives up
local LINGER = 2               -- s a refused upload's browser is read (and ignored) after the answer
local EVENT_EVERY = 1          -- s between the events that keep the reader awake

-- A server for `o.handler(req, reply)`, on the first free port of `o.ports`.
-- `o.socket` is LuaSocket (tests pass their own); `o.head_timeout` is how long
-- a request may take to arrive (s).
function Server.new(o)
    return setmetatable({ handler = o.handler, ports = o.ports or { 8642, 8643, 8644, 8645, 8646 },
        socket = o.socket or require("socket"), head_timeout = o.head_timeout or 5, silent = o.silent or SILENT,
        wait_limit = o.wait_limit or WAIT_LIMIT,
        reading = {}, sends = {}, waiting = {}, receiving = {}, draining = {}, requests = 0, files_sent = 0,
        on_activity = o.on_activity, make_event = o.make_event, on_error = o.on_error, on_stop = o.on_stop,
        last_event = 0 }, Server)
end

-- Listen on all addresses. Returns the port, or nil and the error.
function Server:start()
    local err
    for _, port in ipairs(self.ports) do
        local srv, e = self.socket.bind("*", port)
        if srv then
            srv:settimeout(0)
            self.srv, self.port = srv, port
            return port
        end
        err = e
    end
    return nil, err
end

local function close(c) pcall(c.close, c) end

-- Close the server and every connection, whatever it was doing.
function Server:stop()
    for i = #self.sends, 1, -1 do self:finish(self.sends[i]) end
    for _, r in ipairs(self.reading) do close(r.client) end
    self.reading = {}
    for client, reply in pairs(self.waiting) do reply.gone = true; close(client) end
    self.waiting = {}
    self:cancelUploads("stopped")
    for _, d in ipairs(self.draining) do close(d.client) end
    self.draining = {}
    if self.srv then
        close(self.srv); self.srv = nil
        if self.on_stop then pcall(self.on_stop) end
    end
end

function Server:running() return self.srv ~= nil end

function Server:connections()
    local n = #self.reading + #self.sends + #self.receiving + #self.draining
    for _ in pairs(self.waiting) do n = n + 1 end
    return n
end

-- A reply on `client`: send(code, type, body, extra headers), file(path,
-- type, name for a download or nil to show it, after) or wait() then either
-- of them later. `after()` runs once a file has gone out whole. `gone` turns
-- true when the browser leaves while it waits.
function Server:reply(client)
    local done = false
    local r = {}
    local function queue(item)
        if done then return end
        done = true
        self.waiting[client] = nil
        if not self.srv or r.gone then close(client); return end   -- stopped or left meanwhile
        item.client = client
        item.last = self.socket.gettime()
        -- a body the browser is still sending (a refused upload): it is read and
        -- dropped for a moment after the answer, or closing now would cut the
        -- answer off and the page would only say the reader can't be reached
        item.linger = r.unread
        client:settimeout(0)
        self.sends[#self.sends + 1] = item
    end
    function r.send(code, ctype, body, extra)
        body = body or ""
        queue{ buf = Http.header(code, ctype, #body, extra) .. body }
    end
    function r.file(path, ctype, name, after)
        local f = io.open(path, "rb")
        if not f then return r.send(404, Http.TYPES.txt, "Not found") end
        local size = f:seek("end")
        f:seek("set", 0)
        local extra = { Http.disposition(name or path:match("[^/]+$"), name == nil) }
        queue{ buf = Http.header(200, ctype or Http.typeOf(path), size, extra), file = f, after = after,
            counts = name ~= nil, name = name, total = size, sent = 0 }
    end
    function r.wait() r.waiting = true; r.since = self.socket.gettime(); self.waiting[client] = r end
    -- Take the request's body (`length` bytes) into `sink`: write(chunk) ->
    -- true or nil, err; finish(r) once it is all here (it replies); abort(why)
    -- if it stops short. `name` shows in the progress.
    function r.receive(sink, length, name, expect_continue)
        r.waiting = true   -- (answered by sink.finish, or on abort)
        r.unread = nil     -- (its body is read now)
        local item = { client = client, sink = sink, left = length, total = length, got = 0, name = name,
            reply = r, last = self.socket.gettime() }
        self.receiving[#self.receiving + 1] = item
        client:settimeout(0)
        if expect_continue then client:send("HTTP/1.1 100 Continue\r\n\r\n") end
        if r.rest and #r.rest > 0 then self:feed(item, r.rest) end
        r.rest = nil
    end
    function r.open() return not done and not r.gone end
    return r
end

-- Answer the request in `head` (complete) from `client`; `rest` is what came
-- after it (the start of an upload).
function Server:dispatch(client, head, rest)
    local req = Http.parseRequest(head)
    local reply = self:reply(client)
    reply.rest = rest
    if req and tonumber(req.headers["content-length"] or "0") then
        reply.unread = (tonumber(req.headers["content-length"] or "0") or 0) > #(rest or "")
    end
    if not req then
        return reply.send(400, Http.TYPES.txt, "Bad request")
    elseif req.method ~= "GET" and req.method ~= "POST" then
        return reply.send(405, Http.TYPES.txt, "Not here")
    end
    self.requests = self.requests + 1
    if self.on_activity then pcall(self.on_activity) end
    local ok, err = pcall(self.handler, req, reply)
    if not ok then
        if self.on_error then pcall(self.on_error, err) end
        reply.send(500, Http.TYPES.txt, "Something went wrong on the reader.")
    elseif not reply.waiting and reply.open() then
        reply.send(404, Http.TYPES.txt, "Not found")
    end
end

-- Take new connections, up to the limit; any more are closed at once.
function Server:acceptNew(now)
    local got = false
    for _ = 1, 8 do
        local client = self.srv:accept()
        if not client then break end
        got = true
        if self:connections() >= MAX_CONN then
            close(client)
        else
            client:settimeout(0)
            self.reading[#self.reading + 1] = { client = client, buf = "", deadline = now + self.head_timeout }
        end
    end
    return got
end

-- Read what has arrived of each request, without waiting; answer the complete
-- ones, drop the ones too big, too slow or gone.
function Server:readRequests(now)
    local active = false
    for i = #self.reading, 1, -1 do
        local r = self.reading[i]
        local data, err, partial = r.client:receive(4096)
        local got = data or partial
        if got and #got > 0 then r.buf = r.buf .. got; active = true end
        local head_end = r.buf:find("\r\n\r\n", 1, true)
        if (head_end or #r.buf) > MAX_HEAD then
            table.remove(self.reading, i)
            self:reply(r.client).send(400, Http.TYPES.txt, "Request too big")
        elseif head_end then
            table.remove(self.reading, i)
            self:dispatch(r.client, r.buf:sub(1, head_end - 1), r.buf:sub(head_end + 4))
            active = true
        elseif err == "closed" or now > r.deadline then
            table.remove(self.reading, i)
            close(r.client)
        end
    end
    return active
end

-- Notice browsers that left while their reply waited.
function Server:checkWaiting(now)
    for client, reply in pairs(self.waiting) do
        local _, err = client:receive(0)
        if err == "closed" then
            reply.gone = true
            self.waiting[client] = nil
            close(client)
        elseif reply.since and now - reply.since > self.wait_limit then
            reply.send(503, Http.TYPES.txt, "The reader took too long.")
            reply.gone = true
        end
    end
end

-- Read and drop what a refused upload's browser still sends, then close.
function Server:drain(now)
    for i = #self.draining, 1, -1 do
        local d = self.draining[i]
        local _, err = d.client:receive(65536)
        if err == "closed" or now > d.until_t then
            close(d.client)
            table.remove(self.draining, i)
        end
    end
end

-- Hand `data` (part of an upload) to its sink. Returns whether it goes on.
function Server:feed(item, data)
    if #data > item.left then data = data:sub(1, item.left) end   -- never past the announced size
    item.got, item.left = item.got + #data, item.left - #data
    local ok, wok, werr = pcall(item.sink.write, data)
    if not (ok and wok) then
        self:endUpload(item, (ok and werr) or wok or "write failed", 422)
        return false
    end
    if item.left == 0 then
        self:dropUpload(item)
        local fok, ferr = pcall(item.sink.finish, item.reply)
        if not fok then
            pcall(item.sink.abort, ferr)
            if self.on_error then pcall(self.on_error, ferr) end
            item.reply.send(500, Http.TYPES.txt, "Something went wrong on the reader.")
        elseif item.reply.open() then
            item.reply.send(200, Http.TYPES.txt, "OK")
        end
        return false
    end
    return true
end

function Server:dropUpload(item)
    for i = #self.receiving, 1, -1 do if self.receiving[i] == item then table.remove(self.receiving, i) end end
end

-- Stop an upload short: its sink drops what it wrote, the browser is told why
-- when it is still there (`code`), else the connection just closes.
function Server:endUpload(item, why, code)
    self:dropUpload(item)
    pcall(item.sink.abort, why)
    if code and self.srv then
        item.reply.unread = item.left > 0
        item.reply.send(code, Http.TYPES.txt, tostring(why))
    else
        item.reply.gone = true
        close(item.client)
    end
end

-- Read some more of each upload, without waiting.
function Server:pumpUploads(now)
    local active = false
    for i = #self.receiving, 1, -1 do
        local item = self.receiving[i]
        local taken = 0
        while item and taken < BUDGET and item.left > 0 do
            local data, err, partial = item.client:receive(math.min(CHUNK, item.left))
            local got = data or partial
            if got and #got > 0 then
                item.last = now
                taken = taken + #got
                active = true
                if not self:feed(item, got) then item = nil end
            elseif err == "closed" then
                self:endUpload(item, "the browser left")
                item = nil
            else
                if now - item.last > self.silent then self:endUpload(item, "nothing came for a while") end
                break
            end
        end
    end
    return active
end

-- Stop every upload coming in (the reader's Cancel, or stopping).
function Server:cancelUploads(why)
    for i = #self.receiving, 1, -1 do self:endUpload(self.receiving[i], why or "cancelled") end
end

function Server:finish(item, lingering)
    if item.file then pcall(item.file.close, item.file); item.file = nil end
    if lingering and item.linger and self.srv then
        pcall(item.client.shutdown, item.client, "send")
        self.draining[#self.draining + 1] = { client = item.client, until_t = self.socket.gettime() + LINGER }
    else
        close(item.client)
    end
    for i = #self.sends, 1, -1 do if self.sends[i] == item then table.remove(self.sends, i) end end
end

-- Send `item` up to BUDGET bytes now. Returns how much went (0 when its
-- browser isn't taking any); a browser that takes nothing for a while is let go.
function Server:pump(item, now)
    local sent = 0
    while sent < BUDGET do
        if item.buf == "" and item.file then
            local chunk = item.file:read(CHUNK)
            if not chunk then
                item.file:close(); item.file = nil
            else
                item.buf = chunk
                if item.total then item.sent = item.sent + #chunk end
            end
        end
        if item.buf == "" then
            if item.counts then self.files_sent = self.files_sent + 1 end
            local after = item.after
            self:finish(item, true)
            if after then pcall(after) end
            return sent
        end
        local last, err, partial = item.client:send(item.buf)
        local n = last or partial or 0
        item.buf = item.buf:sub(n + 1)
        sent = sent + n
        if n > 0 then item.last = now end
        if not last then
            if err ~= "timeout" then self:finish(item); return sent end   -- the browser went away
            if now and item.last and now - item.last > self.silent then self:finish(item) end   -- it stopped taking any
            return sent   -- its buffer is full: more next time
        end
    end
    return sent
end

-- One turn of KOReader's loop, never waiting. Returns an event while in use
-- (see make_event, it keeps the reader awake), then nothing.
function Server:waitEvent()
    -- KOReader asks again after an event: nothing more this turn
    if self.yielded then self.yielded = nil; return nil end
    if not self.srv then return nil end
    local now = self.socket.gettime()
    local active = self:acceptNew(now)
    if self:readRequests(now) then active = true end
    if self:pumpUploads(now) then active = true end
    self:checkWaiting(now)
    self:drain(now)
    for i = #self.sends, 1, -1 do
        local item = self.sends[i]
        if item and self:pump(item, now) > 0 then active = true end
    end
    -- only when something really moved, and not every turn
    if active and self.make_event and now - self.last_event >= EVENT_EVERY then
        self.last_event = now
        self.yielded = true
        return self.make_event()
    end
    return nil
end

-- The downloads going out and the uploads coming in: { name, sent, total,
-- incoming } for each named file.
function Server:transfers()
    local out = {}
    for _, item in ipairs(self.sends) do
        if item.name and item.total then out[#out + 1] = { name = item.name, sent = item.sent, total = item.total } end
    end
    for _, item in ipairs(self.receiving) do
        out[#out + 1] = { name = item.name or "file", sent = item.got, total = item.total, incoming = true }
    end
    return out
end

function Server:uploads() return #self.receiving end

-- Stop every download going out (the reader's Cancel).
function Server:cancelTransfers()
    for i = #self.sends, 1, -1 do
        if self.sends[i].name then self:finish(self.sends[i]) end
    end
end

-- Downloads still going, or uploads still coming.
function Server:busy() return #self.sends > 0 or #self.receiving > 0 end

return Server

--[[
The helper that refreshes the original Elipsa's screen while Ink Away draws.
On that Kobo each screen update holds KOReader until the panel has taken it,
and while it waits no pen or finger frame is read, so the ink falls behind the
nib. Here the updates are made by a second process, forked from KOReader, which
waits on the panel instead: KOReader goes on reading the pen and only sends the
helper the rectangle to show next, with the waveform to show it in (the fast
one, or the grey one for a stroke that needs it, see ink/elipsadrive.lua).

The screen's pixels are shared memory (ION), so the helper sees every stroke
drawn after it started without a copy; what the driver is told about the screen
(its layers, its rotation) is the helper's own copy from the moment it started.
So the caller (ink/elipsadrive.lua) stops the helper before anything else
reaches the screen: another kind of refresh, a turn of the screen, sleep.

The helper also turns on the panel's handwriting mode, as Kobo's own notebooks
do, and turns it off again when it stops (or when KOReader has gone).
]]
local ElipsaWorker = {}

-- Start the helper with KOReader's fork helper, for `screen` (KOReader's
-- framebuffer) and `refresh` (its own update call). Returns the helper's side
-- of the channel { send, poll, close }, or nil and why.
function ElipsaWorker.start(screen, refresh)
    local ffi = require("ffi")
    require("ffi/posix_h")
    require("ffi/sunxi_kobo_h")
    local util = require("ffi/util")
    local C = ffi.C
    ffi.cdef[[
        int socketpair(int domain, int type, int protocol, int sv[2]);
        int shutdown(int sockfd, int how);
        int getppid(void);
    ]]
    local MSG_NOSIGNAL, MSG_DONTWAIT = 0x4000, 0x40   -- (Linux values; KOReader does not name them)
    local timeout = 3000
    local sockets = ffi.new("int[2]")
    if C.socketpair(C.AF_UNIX, C.SOCK_SEQPACKET + C.SOCK_CLOEXEC, 0, sockets) ~= 0 then
        return nil, "socketpair failed"
    end
    local parent, child = tonumber(sockets[0]), tonumber(sockets[1])
    -- The handwriting mode on or off, sent as KOReader sends its own sunxi
    -- display commands: a zeroed command block, whatever the driver reads of it.
    local function handwriting(on)
        local cmd = ffi.new("sunxi_disp_eink_ioctl")
        cmd.toggle_handw.enable = on
        return C.ioctl(screen.fd, C.DISP_EINK_SET_NTX_HANDWRITE_ONOFF, cmd) >= 0
    end
    if not handwriting(true) then
        C.close(parent); C.close(child)
        return nil, "handwriting ioctl failed: " .. ffi.errno()
    end
    local function disable() return handwriting(false) end
    local parent_pid = C.getpid()
    local started, pid, err = pcall(util.runInSubProcess, function()
        C.close(parent)
        -- The fork helper normally gives background jobs batch scheduling and
        -- nice +5. Drawing must compete normally with the input process.
        local param = ffi.new("struct sched_param")
        C.sched_setscheduler(0, 0, param) -- SCHED_OTHER (not declared by KOReader)
        C.setpriority(C.PRIO_PROCESS, 0, 0)
        local rect, reply = ffi.new("int32_t[5]"), ffi.new("uint32_t[2]")
        local incoming = ffi.new("struct pollfd[1]")
        incoming[0].fd, incoming[0].events = child, C.POLLIN
        pcall(function()
            while true do
                -- Other Lua subprocesses can inherit the socket too. Detect a
                -- dead parent even if their duplicate keeps our socket open.
                if C.getppid() ~= parent_pid then break end
                local ready = C.poll(incoming, 1, 1000)
                if ready < 0 and ffi.errno() ~= C.EINTR then break end
                if ready > 0 then
                    local n = C.recv(child, rect, ffi.sizeof(rect), MSG_DONTWAIT)
                    -- A signal consumes no command; return to the parent check.
                    if n >= 0 or ffi.errno() ~= C.EINTR then
                        if n ~= ffi.sizeof(rect) or rect[2] == 0 then break end
                        local ok = pcall(refresh, screen, false, false, tonumber(rect[4]),
                            tonumber(rect[0]), tonumber(rect[1]), tonumber(rect[2]), tonumber(rect[3]))
                        reply[0], reply[1] = ok and 1 or 0, screen.marker_data[0]
                        if C.send(child, reply, ffi.sizeof(reply), MSG_NOSIGNAL) ~= ffi.sizeof(reply) or not ok then break end
                    end
                end
            end
        end)
        disable() -- also runs on EOF when the parent has gone away
        C.close(child)
    end)
    C.close(child)
    if not started or not pid then
        C.close(parent)
        disable()
        return nil, started and err or pid
    end

    local rect, reply = ffi.new("int32_t[5]"), ffi.new("uint32_t[2]")
    local pollfd = ffi.new("struct pollfd[1]")
    pollfd[0].fd, pollfd[0].events = parent, C.POLLIN
    local transport = {}

    -- Only one command may be outstanding; sends therefore cannot fill the socket.
    -- `r.mode` is the waveform, the fast one when not given.
    function transport:send(r)
        rect[0], rect[1], rect[2], rect[3] = r.x, r.y, r.w, r.h
        rect[4] = r.mode or screen.waveform_fast
        return C.send(parent, rect, ffi.sizeof(rect), MSG_NOSIGNAL + MSG_DONTWAIT) == ffi.sizeof(rect)
    end

    -- nil: busy; false: worker failed; number: completed marker (including zero).
    -- A wait that runs out is still busy (a grey update can take a while): a
    -- helper that has gone shows as its socket closing, not as silence.
    function transport:poll(wait)
        local n = C.poll(pollfd, 1, wait and timeout or 0)
        if n == 0 then return nil end
        if n < 0 then
            if ffi.errno() == C.EINTR then return nil end
            return false
        end
        if C.recv(parent, reply, ffi.sizeof(reply), MSG_DONTWAIT) ~= ffi.sizeof(reply) or reply[0] ~= 1 then
            return false
        end
        return tonumber(reply[1])
    end

    -- The caller has drained its commands before a normal shutdown. EOF wakes
    -- an idle worker; a failed worker is killed before synchronous fallback.
    function transport:close(failed)
        C.shutdown(parent, 2) -- EOF even if another subprocess inherited our fd
        C.close(parent)
        if failed then util.terminateSubProcess(pid) end
        util.isSubProcessDone(pid, true)
        if not disable() then return false end
        return true
    end
    return transport
end

return ElipsaWorker

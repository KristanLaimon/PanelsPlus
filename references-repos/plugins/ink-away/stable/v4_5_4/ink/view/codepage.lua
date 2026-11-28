--[[
The reader's end of the paste page for a long sign-in code (see
ink/share/codepage.lua): a small web server on the home Wi-Fi, running only
while the cloud sign-in screen is open. It is the Send-over-Wi-Fi server
(ink/share/server.lua) with one page. When the reader has no Wi-Fi address,
or no port is free, nothing starts and the sign-in falls back to typing the code.
Part of InkAwayView (see ink/view.lua).
]]

local UIManager = require("ui/uimanager")
local logger = require("logger")
local Accent = require("ink/accent")
local CodePage = require("ink/share/codepage")
local Http = require("ink/share/http")
local Net = require("ink/share/net")
local Page = require("ink/share/page")

local InkAwayView = {}

local function isKindle()
    local ok, Device = pcall(require, "device")
    if not (ok and Device and type(Device.isKindle) == "function") then return false end
    local okk, yes = pcall(Device.isKindle, Device)
    return okk and yes == true
end

-- The page's theme colour, as the Send page has it: the reader's own on a colour
-- screen (black when chosen), nil (Ink Away's green) on a grey one.
local function pageAccent(view)
    if not view:colorScreen() then return nil end
    local a = Accent.get()
    if a.rgb then return Page.accent(a.rgb, a.dark_text) end
    return Page.accent({ 0, 0, 0 }, false)
end

-- Start serving the paste page for the sign-in to `name`, whose address is
-- `auth_url`. `on_code(code)` is called once, with the code the phone sent.
-- Returns the page's address, or nil when it can't be served here.
function InkAwayView:startCodePage(name, auth_url, on_code)
    self:stopCodePage()
    local oks, socket = pcall(require, "socket")
    if not oks then return nil end
    local okn, NetworkMgr = pcall(require, "ui/network/manager")
    local ip = Net.localIP(socket, nil, okn and NetworkMgr and NetworkMgr.interface or nil)
    if not ip then return nil end
    local Server = require("ink/share/server")
    local Event = require("ui/event")
    local kindle = isKindle()
    local st = { token = Http.token(Http.randomBytes(12), 12), nonce = Http.token(Http.randomBytes(16), 16),
        name = name, auth_url = auth_url, on_code = on_code, done = false, accent = pageAccent(self) }
    local server = Server.new{
        socket = socket,
        handler = function(req, reply) CodePage.route(req, reply, st) end,
        make_event = function() return Event:new("InputEvent") end,
        on_error = function(err) logger.warn("InkAway: code page:", err) end,
        on_stop = kindle and function() Net.closeFirewall(st.port) end or nil,
    }
    local port, perr = server:start()
    if not port then
        logger.warn("InkAway: code page: no port:", perr)
        return nil
    end
    st.port = port
    if kindle then
        Net.closeFirewall(port)
        Net.openFirewall(port)
    end
    UIManager:insertZMQ(server)
    if UIManager.preventStandby then UIManager:preventStandby(); st.standby = true end
    st.server = server
    self._code_page = st
    return string.format("http://%s:%d/%s/", ip, port, st.token)
end

-- Stop serving it (and close the Kindle's firewall hole again).
function InkAwayView:stopCodePage()
    local st = self._code_page
    if not st then return end
    self._code_page = nil
    UIManager:removeZMQ(st.server)
    st.server:stop()
    if st.standby then UIManager:allowStandby() end
end

return InkAwayView

--[[
The reader on its network, for Send to phone or computer: the address other
devices on the same Wi-Fi reach it at, and on a Kindle a hole in its firewall
for the page's port while it is open (as KOReader's SSH server makes one).
]]

local Net = {}

local function isLan(ip)
    return type(ip) == "string" and ip:match("^%d+%.%d+%.%d+%.%d+$") ~= nil
        and ip ~= "0.0.0.0" and not ip:match("^127%.") and not ip:match("^169%.254%.")
end
Net.isLan = isLan

local function run(cmd)
    local p = io.popen(cmd .. " 2>/dev/null")
    if not p then return "" end
    local out = p:read("*a") or ""
    p:close()
    return out
end

-- The addresses `ip -4 addr` or `ifconfig` list, as { iface, ip } in order.
local function listed(runner)
    local out = {}
    local iface
    for line in (runner("ip -4 addr") .. "\n"):gmatch("([^\n]*)\n") do
        iface = line:match("^%d+:%s*([^:@%s]+)") or iface
        local ip = line:match("inet%s+(%d+%.%d+%.%d+%.%d+)")
        if ip and iface then out[#out + 1] = { iface = iface, ip = ip } end
    end
    if #out == 0 then
        iface = nil
        for line in (runner("ifconfig") .. "\n"):gmatch("([^\n]*)\n") do
            iface = line:match("^([%w%.%-_]+)[%s:]") or iface
            local ip = line:match("inet addr:(%d+%.%d+%.%d+%.%d+)") or line:match("inet%s+(%d+%.%d+%.%d+%.%d+)")
            if ip and iface then out[#out + 1] = { iface = iface, ip = ip } end
        end
    end
    return out
end

-- The reader's address on its Wi-Fi, or nil without one: on `iface` (the
-- interface KOReader uses for Wi-Fi) when known, else the address the system
-- would send from (a UDP socket only picks its route: nothing is sent), else
-- the first Wi-Fi-looking one the system lists. A USB network (a Kindle's
-- usbnet, say) is never chosen over Wi-Fi.
function Net.localIP(socket, runner, iface)
    runner = runner or run
    local all = listed(runner)
    if iface then
        for _, a in ipairs(all) do if a.iface == iface and isLan(a.ip) then return a.ip end end
    end
    if socket and socket.udp then
        local udp = socket.udp()
        if udp then
            local ok, ip = pcall(function()
                udp:setpeername("192.0.2.1", 9)   -- a documentation address: never reached
                return udp:getsockname()
            end)
            pcall(udp.close, udp)
            local usb = false
            for _, a in ipairs(all) do if a.ip == ip and a.iface:match("^usb") then usb = true end end
            if ok and isLan(ip) and not usb then return ip end
        end
    end
    local ip = runner("ip -4 route get 192.0.2.1"):match("%ssrc%s+(%d+%.%d+%.%d+%.%d+)")
    local via_usb = false
    for _, a in ipairs(all) do if a.ip == ip and a.iface:match("^usb") then via_usb = true end end
    if isLan(ip) and not via_usb then return ip end
    for _, pat in ipairs({ "^wl", "^eth", "^en", "." }) do
        for _, a in ipairs(all) do
            if a.iface:match(pat) and not a.iface:match("^usb") and not a.iface:match("^lo") and isLan(a.ip) then
                return a.ip
            end
        end
    end
    return nil
end

-- The Kindle's firewall turns away connections from other devices: let them
-- reach `port` while the page is open, and close it again after.
local function firewall(action, port, runner)
    runner = runner or run
    runner(string.format("iptables -%s INPUT -p tcp --dport %d -m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT",
        action, port))
    runner(string.format("iptables -%s OUTPUT -p tcp --sport %d -m conntrack --ctstate ESTABLISHED -j ACCEPT",
        action, port))
end
function Net.openFirewall(port, runner) firewall("A", port, runner) end
function Net.closeFirewall(port, runner) firewall("D", port, runner) end

return Net

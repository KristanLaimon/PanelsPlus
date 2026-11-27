--[[
The web page for signing in to a cloud service whose code is too long to type
on the reader (Dropbox's is about 40 letters and digits, case matters): the
reader serves it on the home Wi-Fi while the sign-in screen is open, the phone
opens it from the QR code, taps the button that opens the service, taps Allow,
and pastes the code on the page, which hands it to the reader. The address has
a secret in it, the page takes one code only, and the code is of no use without
the one-time secret the reader kept when the sign-in started. Plain Lua apart
from the server it is handed to, so the headless tests drive it.
]]

local Http = require("ink/share/http")
local Page = require("ink/share/page")

local CodePage = {}
local esc = Http.html

CodePage.MIN, CodePage.MAX = 8, 400    -- a code's length, in characters

-- The code in `s` with its spaces and line breaks taken out, or nil when it
-- is not shaped like one (too short, too long, or a character a code never has).
function CodePage.clean(s)
    s = tostring(s or ""):gsub("%s", "")
    if #s < CodePage.MIN or #s > CodePage.MAX or not s:match("^[%w%-_%.~%+/=]+$") then return nil end
    return s
end

local SCRIPT = [==[
(function(){
var b=document.getElementById('go'),t=document.getElementById('c'),m=document.getElementById('msg');
b.onclick=function(){
var v=t.value.replace(/\s+/g,'');
if(v.length<8){m.textContent='Paste the code first.';return;}
b.disabled=true;m.textContent='Sending…';
fetch(window.IA.url+'code?c='+encodeURIComponent(v)).then(function(r){
return r.text().then(function(x){
if(r.ok){m.textContent='Sent. Look at your reader: it is connecting. You can close this page.';}
else{m.textContent=x;b.disabled=false;}});
}).catch(function(){m.textContent='Could not reach the reader. Is this phone on the same Wi-Fi?';b.disabled=false;});
};
})();
]==]

-- The page for `o`: { name = "Dropbox", auth_url, base ("/secret/"), nonce, accent }.
function CodePage.render(o)
    local name = esc(o.name)
    local card = '<div class="add"><h2>Connect ' .. name .. '</h2>'
        .. '<p>1. Tap the button, sign in and tap Allow.</p>'
        .. '<a class="btn main" href="' .. esc(o.auth_url) .. '" target="_blank" rel="noopener">Open ' .. name .. '</a>'
        .. '<p>2. ' .. name .. ' shows a code. Copy it, come back to this page and paste it here.</p>'
        .. '<textarea id="c" rows="3" autocapitalize="off" autocorrect="off" autocomplete="off" spellcheck="false" '
        .. 'style="width:100%;font:16px monospace;padding:10px;border:1px solid var(--line);border-radius:10px;'
        .. 'background:var(--card);color:inherit;margin-bottom:10px"></textarea>'
        .. '<button id="go" class="btn main">Send to the reader</button><div id="msg"></div>'
        .. '<noscript><p>Sending needs JavaScript turned on in this browser.</p></noscript></div>'
        .. '<script nonce="' .. esc(o.nonce) .. '">window.IA={url:"' .. esc(o.base) .. '"};' .. SCRIPT .. '</script>'
    return Page.render{ title = "Connect " .. o.name, card = card, accent = o.accent,
        note = "Served by your reader over your Wi-Fi. It closes when the reader's sign-in screen does." }
end

-- Answer one request. `st` is the page's state: { token, name, auth_url, nonce,
-- accent, on_code(code), done }. Returns nothing; the reply is sent.
function CodePage.route(req, reply, st)
    local base = "/" .. st.token .. "/"
    local function html(code, body, nonce)
        reply.send(code, Http.TYPES.html, body, { Page.csp(nonce), "X-Frame-Options: DENY" })
    end
    if req.path:sub(1, #base) ~= base and req.path .. "/" ~= base then return html(404, Page.gone()) end
    if req.method ~= "GET" then return reply.send(405, Http.TYPES.txt, "Not here") end
    local route = req.path:sub(#base + 1)
    if route == "" then
        return html(200, CodePage.render{ name = st.name, auth_url = st.auth_url, base = base, nonce = st.nonce,
            accent = st.accent }, st.nonce)
    end
    if route == "code" then
        local code = CodePage.clean(req.query.c)
        if not code then return reply.send(400, Http.TYPES.txt, "That does not look like the code. Copy all of it.") end
        if st.done then return reply.send(409, Http.TYPES.txt, "A code was sent already.") end
        st.done = true
        st.on_code(code)
        return reply.send(200, Http.TYPES.txt, "OK")
    end
    reply.send(404, Http.TYPES.txt, "Not found")
end

return CodePage

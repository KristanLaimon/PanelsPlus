--[[
The web page Send to phone or computer shows in the other device's browser: a
library folder's subfolders and documents, each document with its picture and
its downloads, and the files already exported, and (when the reader allows
adding files) a way to send files to it, with pictures made smaller on the
phone first if wished. Plain HTML and CSS in one reply, light or dark as the
device is set; the only script is the sending, inline, allowed by a nonce in
the page's Content-Security-Policy (see Page.csp), so nothing else can run.
]]

local Http = require("ink/share/http")

local Page = {}
local esc = Http.html

local CSS = [[
:root{--bg:#f6f7f4;--card:#fff;--ink:#1d1f1b;--mute:#6b7066;--line:#e3e6df;--acc:#9fd665;--acc-ink:#1a1a1a;--chip:#eef1ea}
@media (prefers-color-scheme:dark){:root{--bg:#141613;--card:#1f221d;--ink:#eef0ea;--mute:#a3a89c;--line:#30342d;--chip:#2a2e27}}
*{box-sizing:border-box}
[hidden]{display:none!important}
body{margin:0;background:var(--bg);color:var(--ink);font:16px/1.4 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif}
header{background:var(--card);border-bottom:1px solid var(--line);padding:14px 16px;position:sticky;top:0;z-index:1}
header .brand{font-weight:700;font-size:13px;letter-spacing:.06em;text-transform:uppercase;color:var(--mute)}
header h1{margin:2px 0 0;font-size:22px}
nav{margin-top:6px;font-size:14px;color:var(--mute)}
nav a{color:var(--mute)}
main{max-width:1100px;margin:0 auto;padding:16px}
h2{font-size:15px;color:var(--mute);margin:22px 0 10px;text-transform:uppercase;letter-spacing:.05em}
.folders{display:flex;flex-wrap:wrap;gap:10px}
.folder{display:flex;align-items:center;gap:10px;background:var(--card);border:1px solid var(--line);border-radius:12px;padding:10px 14px;color:inherit;text-decoration:none;font-weight:600}
.folder i{width:22px;height:17px;border-radius:3px 3px 4px 4px;background:var(--dot,#c4c4c4);position:relative}
.folder i:before{content:"";position:absolute;left:0;top:-4px;width:10px;height:5px;border-radius:2px 2px 0 0;background:inherit;filter:brightness(.85)}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(160px,1fr));gap:14px}
.doc{background:var(--card);border:1px solid var(--line);border-radius:14px;overflow:hidden;display:flex;flex-direction:column}
.doc img{width:100%;aspect-ratio:3/4;object-fit:contain;background:#fff;border-bottom:1px solid var(--line)}
.doc .meta{padding:10px 12px 4px}
.doc .name{font-weight:650;word-break:break-word}
.doc .kind{font-size:13px;color:var(--mute)}
.doc .dl{display:flex;flex-wrap:wrap;gap:6px;padding:8px 12px 12px;margin-top:auto}
.btn{display:inline-block;padding:7px 12px;border-radius:999px;background:var(--chip);color:inherit;text-decoration:none;font-size:14px;font-weight:600}
.btn.main{background:var(--acc);color:var(--acc-ink)}
.files{background:var(--card);border:1px solid var(--line);border-radius:14px}
.files a{display:flex;justify-content:space-between;gap:12px;padding:12px 14px;color:inherit;text-decoration:none;border-top:1px solid var(--line)}
.files a:first-child{border-top:0}
.files span{color:var(--mute);font-size:14px;white-space:nowrap}
.empty{color:var(--mute)}
footer{color:var(--mute);font-size:13px;text-align:center;padding:24px 16px 32px}
.add{background:var(--card);border:1px solid var(--line);border-radius:14px;padding:14px 16px;margin:4px 0 8px}
.add h2{margin:0 0 6px}
.add p{margin:4px 0 10px;color:var(--mute);font-size:14px}
.add input[type=file]{display:none}
button.btn{border:0;font:inherit;font-size:14px;font-weight:600;cursor:pointer}
.levels{display:flex;flex-wrap:wrap;gap:6px;margin:12px 0 4px;align-items:center}
.levels .lt{width:100%;font-size:14px;color:var(--mute)}
.levels label{background:var(--chip);border-radius:999px;padding:6px 12px;font-size:14px;font-weight:600}
.levels input{margin:0 6px 0 0;accent-color:var(--acc)}
.flist{list-style:none;margin:10px 0;padding:0}
.flist li{border-top:1px solid var(--line);padding:9px 0;font-size:14px}
.flist li:first-child{border-top:0}
.flist .n{font-weight:600;word-break:break-word}
.flist .s{color:var(--mute)}
.flist .e{color:#c0392b}
.flist .ok{color:#3c8a2e}
.flist progress{width:100%;height:8px;margin-top:6px;accent-color:var(--acc)}
#msg{font-size:14px;margin-top:8px}
]]

-- The page for `o`: { title, crumbs = { { label, href } }, folders = { { name,
-- href, color = "#rrggbb" } }, docs = { { name, kind, thumb, links = { { label,
-- href, main } } } }, exports = { { name, href, size } }, note }.
function Page.render(o)
    local h = {}
    local function add(s) h[#h + 1] = s end
    add('<!doctype html><html lang="en"><head><meta charset="utf-8">')
    add('<meta name="viewport" content="width=device-width,initial-scale=1">')
    add('<meta name="robots" content="noindex">')
    add("<title>" .. esc(o.title) .. " · Ink Away</title><style>" .. CSS .. Page.accentCSS(o.accent) .. "</style></head><body>")
    add('<header><div class="brand">Ink Away</div><h1>' .. esc(o.title) .. "</h1>")
    if o.crumbs and #o.crumbs > 0 then
        local parts = {}
        for _, c in ipairs(o.crumbs) do
            parts[#parts + 1] = c.href and ('<a href="' .. esc(c.href) .. '">' .. esc(c.label) .. "</a>") or esc(c.label)
        end
        add("<nav>" .. table.concat(parts, " › ") .. "</nav>")
    end
    add("</header><main>")
    if o.upload then add(Page.uploadCard(o.upload)) end
    if #(o.folders or {}) > 0 then
        add('<h2>Folders</h2><div class="folders">')
        for _, f in ipairs(o.folders) do
            local dot = f.color and (' style="--dot:' .. esc(f.color) .. '"') or ""
            add('<a class="folder" href="' .. esc(f.href) .. '"><i' .. dot .. "></i>" .. esc(f.name) .. "</a>")
        end
        add("</div>")
    end
    local function cards(list)
        add('<div class="grid">')
        for _, d in ipairs(list) do
            add('<div class="doc">')
            if d.thumb then add('<img loading="lazy" alt="" src="' .. esc(d.thumb) .. '">') end
            add('<div class="meta"><div class="name">' .. esc(d.name) .. '</div><div class="kind">'
                .. esc(d.kind or "") .. "</div></div>")
            add('<div class="dl">')
            for _, l in ipairs(d.links or {}) do
                add('<a class="btn' .. (l.main and " main" or "") .. '" href="' .. esc(l.href) .. '">'
                    .. esc(l.label) .. "</a>")
            end
            add("</div></div>")
        end
        add("</div>")
    end
    if #(o.docs or {}) > 0 then
        add('<h2>Notebooks and drawings</h2>')
        cards(o.docs)
    end
    if #(o.pictures or {}) > 0 then
        add('<h2>Pictures</h2>')
        cards(o.pictures)
    end
    if #(o.docs or {}) == 0 and #(o.pictures or {}) == 0 and #(o.folders or {}) == 0 then
        add('<p class="empty">Nothing here yet.</p>')
    end
    if #(o.exports or {}) > 0 then
        add('<h2>Already exported</h2><div class="files">')
        for _, e in ipairs(o.exports) do
            add('<a href="' .. esc(e.href) .. '">' .. esc(e.name) .. "<span>" .. esc(e.size or "") .. "</span></a>")
        end
        add("</div>")
    end
    add("</main><footer>" .. esc(o.note or "") .. "</footer></body></html>")
    return table.concat(h)
end

-- The Content-Security-Policy every page is sent with: nothing from
-- anywhere else, no frames, no forms, and scripts only with `nonce`.
function Page.csp(nonce)
    return "Content-Security-Policy: default-src 'none'; img-src 'self' blob: data:; style-src 'unsafe-inline'; "
        .. "script-src " .. (nonce and ("'nonce-" .. nonce .. "'") or "'none'") .. "; connect-src 'self'; "
        .. "base-uri 'none'; form-action 'none'; frame-ancestors 'none'"
end

-- The script that sends files: picks them, makes pictures smaller on the
-- phone at the chosen size (showing how much smaller), sends them one at a
-- time with their progress, and can stop.
local SCRIPT = [==[
(function(){
var C=window.IA,list=document.getElementById('list'),inp=document.getElementById('f'),
lv=document.getElementById('lv'),act=document.getElementById('act'),go=document.getElementById('go'),
stop=document.getElementById('stop'),msg=document.getElementById('msg'),items=[],xhr=null,busy=false,halted=false;
var LV={orig:null,large:{m:3000,q:0.85},medium:{m:2000,q:0.8},small:{m:1400,q:0.72}};
function sz(b){return b<1048576?Math.max(1,Math.round(b/1024))+' KB':(b/1048576).toFixed(1)+' MB';}
function kindOf(f){var n=f.name.toLowerCase();
 if(/\.pdf$/.test(n)||f.type==='application/pdf')return 'pdf';
 if(/\.inkaway$/.test(n))return 'inkaway';
 if(/^image\//.test(f.type)||/\.(jpe?g|png|heic|heif|webp|gif|bmp)$/.test(n))return 'image';
 return null;}
function level(){var r=document.querySelector('input[name=lv]:checked');return r?r.value:'large';}
function el(t,c,x){var e=document.createElement(t);if(c)e.className=c;if(x!=null)e.textContent=x;return e;}
function decode(f){
 // the quick way where it works; else the browser's own image loading, which
 // copes with very large phone photos where the other runs out of memory
 function viaImg(){return new Promise(function(res,rej){var u=URL.createObjectURL(f),im=new Image();
  im.onload=function(){res({src:im,w:im.naturalWidth,h:im.naturalHeight,close:function(){URL.revokeObjectURL(u);}});};
  im.onerror=function(){URL.revokeObjectURL(u);rej(new Error("x"));};im.src=u;});}
 if(!window.createImageBitmap)return viaImg();
 return createImageBitmap(f).then(function(b){return {src:b,w:b.width,h:b.height,close:function(){b.close&&b.close();}};},viaImg);}
function shrink(f,key){
 var L=LV[key];
 return decode(f).then(function(d){
  var w=d.w,h=d.h,png=f.type==='image/png',jpg=/^image\/jpe?g$/.test(f.type);
  if(!L&&(png||jpg)&&w*h<=C.maxpx){d.close();return {blob:f,w:w,h:h,same:true};}
  var s=L?Math.min(1,L.m/Math.max(w,h)):1,cw=Math.max(1,Math.round(w*s)),ch=Math.max(1,Math.round(h*s));
  if(cw*ch>C.maxpx){d.close();throw new Error(w+' x '+h+' is too large for the reader at this size. Choose a smaller one.');}
  var c=document.createElement('canvas');c.width=cw;c.height=ch;var x=c.getContext('2d');
  if(!png){x.fillStyle='#fff';x.fillRect(0,0,cw,ch);}
  x.drawImage(d.src,0,0,cw,ch);d.close();
  return new Promise(function(res,rej){c.toBlob(function(o){o?res({blob:o,w:cw,h:ch}):rej(new Error("Couldn't make it smaller."));},
   png?'image/png':'image/jpeg',L?L.q:0.92);});
 },function(e){if(e&&e.message&&e.message.length>2)throw e;throw new Error("This picture can't be read here (try another browser, or a JPEG).");});}
function show(it){
 var key=level(),r=it.res[key];it.s.className='s';
 if(it.kind!=='image'){it.s.textContent=sz(it.f.size)+(it.f.size>C.lim[it.kind]?'':'');
  if(it.f.size>C.lim[it.kind]){it.s.className='e';it.s.textContent=sz(it.f.size)+': too big for the reader (at most '+sz(C.lim[it.kind])+')';}
  return;}
 if(!r){it.s.textContent=sz(it.f.size)+' → …';return;}
 if(r.err){it.s.className='e';it.s.textContent=r.err;return;}
 var pct=Math.round(100*(1-r.blob.size/it.f.size));
 it.s.textContent=r.same?sz(it.f.size)+', as it is ('+r.w+' x '+r.h+')':
  sz(it.f.size)+' → '+sz(r.blob.size)+(pct>0?' ('+pct+'% smaller)':'')+', '+r.w+' x '+r.h;}
function prepare(){
 var key=level(),chain=Promise.resolve();
 items.forEach(function(it){if(it.kind!=='image'||it.res[key])return show(it);
  show(it);chain=chain.then(function(){return shrink(it.f,key).then(function(r){it.res[key]=r;},function(e){it.res[key]={err:e.message};}).then(function(){show(it);});});});
 return chain;}
inp.addEventListener('change',function(){
 items=[];list.textContent='';msg.textContent='';halted=false;
 Array.prototype.forEach.call(inp.files,function(f){var k=kindOf(f),li=el('li'),n=el('div','n',f.name),s=el('div','s','');
  li.appendChild(n);li.appendChild(s);list.appendChild(li);
  if(!k){s.className='e';s.textContent='Only PDFs, pictures and Ink Away files.';return;}
  items.push({f:f,kind:k,li:li,s:s,res:{}});});
 lv.hidden=!items.some(function(i){return i.kind==='image';});
 act.hidden=items.length===0;prepare();});
Array.prototype.forEach.call(document.querySelectorAll('input[name=lv]'),function(r){r.addEventListener('change',prepare);});
function sendOne(it,i,n,batch){return new Promise(function(done){
 var key=level(),body=it.f,name=it.f.name;
 if(it.kind==='image'){var r=it.res[key];if(!r||r.err){return done(false);}body=r.blob;
  if(!r.same)name=name.replace(/\.[^.]*$/,'')+(r.blob.type==='image/png'?'.png':'.jpg');}
 if(body.size>C.lim[it.kind]){it.s.className='e';it.s.textContent='Too big for the reader.';return done(false);}
 var p=el('progress');p.max=1;p.value=0;it.li.appendChild(p);
 xhr=new XMLHttpRequest();
 xhr.open('POST',C.url+'?kind='+it.kind+'&name='+encodeURIComponent(name)+'&batch='+batch+'&i='+i+'&n='+n);
 xhr.upload.onprogress=function(e){if(e.lengthComputable)p.value=e.loaded/e.total;};
 xhr.onload=function(){var j={};try{j=JSON.parse(xhr.responseText);}catch(e){}
  p.remove();it.s.className=(xhr.status===200)?'ok':'e';
  it.s.textContent=j.message||(xhr.responseText&&xhr.responseText.length<300?xhr.responseText:'The reader said '+xhr.status);
  if(xhr.status===403)halted=true;done(xhr.status===200);};
 xhr.onerror=xhr.onabort=function(){p.remove();it.s.className='e';it.s.textContent=halted?'Cancelled':"Not sent: the reader can't be reached.";done(false);};
 xhr.send(body);});}
go.addEventListener('click',function(){
 if(busy)return;busy=true;halted=false;go.hidden=true;stop.hidden=false;inp.disabled=true;msg.textContent='';
 var batch=Math.random().toString(36).slice(2,10),todo=items.filter(function(it){return it.kind;}),ok=0,i=0;
 prepare().then(function next(){
  if(halted||i>=todo.length){busy=false;go.hidden=false;stop.hidden=true;inp.disabled=false;
   msg.textContent=ok?(ok+' of '+todo.length+' sent to the reader.'):'';return;}
  var it=todo[i];i++;return sendOne(it,i,todo.length,batch).then(function(r){if(r)ok++;return next();});});});
stop.addEventListener('click',function(){halted=true;if(xhr)xhr.abort();});
})();
]==]

-- The part of the page for sending files to the reader: `u` = { allowed,
-- url, nonce, limits = { pdf, image, inkaway }, max_pixels }.
function Page.uploadCard(u)
    if not u.allowed then
        return '<div class="add"><h2>Add to Ink Away</h2><p>To send PDFs and pictures to the reader from here, '
            .. 'turn on <b>Allow adding files</b> on the reader, then reload this page.</p></div>'
    end
    local conf = string.format('window.IA={url:"%s",maxpx:%d,lim:{pdf:%d,image:%d,inkaway:%d}};',
        esc(u.url), u.max_pixels, u.limits.pdf, u.limits.image, u.limits.inkaway)
    return '<div class="add"><h2>Add to Ink Away</h2>'
        .. '<p>What you send arrives on the reader in Library › Imported, each kind in its own folder: '
        .. 'PDFs (as notebooks you can write on), Pictures, and Notebooks and drawings.</p>'
        .. '<label class="btn main">Choose files<input id="f" type="file" multiple '
        .. 'accept=".pdf,.inkaway,application/pdf,image/*"></label>'
        .. '<div id="lv" class="levels" hidden><div class="lt">Picture size: smaller pictures send faster '
        .. 'and take less space on the reader</div>'
        .. '<label><input type="radio" name="lv" value="orig">Original</label>'
        .. '<label><input type="radio" name="lv" value="large" checked>Large</label>'
        .. '<label><input type="radio" name="lv" value="medium">Medium</label>'
        .. '<label><input type="radio" name="lv" value="small">Small</label></div>'
        .. '<ul id="list" class="flist"></ul>'
        .. '<div id="act" hidden><button id="go" class="btn main">Send to the reader</button> '
        .. '<button id="stop" class="btn" hidden>Cancel</button></div><div id="msg"></div>'
        .. '<noscript><p>Sending needs JavaScript turned on in this browser.</p></noscript></div>'
        .. '<script nonce="' .. esc(u.nonce) .. '">' .. conf .. SCRIPT .. '</script>'
end

-- The theme colour on the page, the reader's own (see Page.accent): CSS
-- that sets it, or "" for Ink Away's green.
function Page.accentCSS(a)
    if not a then return "" end
    return ":root{--acc:" .. a.fill .. ";--acc-ink:" .. a.ink .. "}"
end

-- The page's colours from the reader's theme: { fill = "#rrggbb", ink =
-- "#rrggbb" for text on it } for `rgb` ({r,g,b}, or nil for Ink Away's green),
-- with dark or light text, whichever reads (`dark_text`).
function Page.accent(rgb, dark_text)
    if type(rgb) ~= "table" then return nil end
    local function c(v) return math.max(0, math.min(255, math.floor(tonumber(v) or 0))) end
    return { fill = string.format("#%02x%02x%02x", c(rgb[1]), c(rgb[2]), c(rgb[3])),
        ink = dark_text and "#1a1a1a" or "#ffffff" }
end

-- The page shown for an old or mistyped address.
function Page.gone()
    return Page.render{ title = "This link has expired",
        note = "On your reader, open Phone or computer (Wi-Fi) again and scan the new code." }
end

return Page

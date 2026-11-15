--[[
Exact markers: a word wrapped in <span class="iar"> in a derived copy of an EPUB,
so a room can hang on any line of a paragraph, not only on its first one. The
book's own file is never changed; this module only works on XHTML strings.

crengine (KOReader's layout engine) gives every place in a book an xpointer such
as /body[1]/DocFragment[3]/body[1]/div[2]/p[12]/text()[2].57: the 3rd spine item,
then elements counted among their siblings of the same name, then the 2nd text
node of the last element and a character offset into it. To turn that back into
a byte of the XHTML file, the file is read the way crengine reads it (measured
with the real engine, see the lab notes at the end of this file):

  * one DocFragment per spine itemref whose idref is in the manifest, whatever
    its media type, and one more for every extra <body> in a file;
  * a text node is a run of text between two tags; a comment, a CDATA section
    or a processing instruction ends it, and a run longer than 8192 characters
    is cut into several nodes;
  * runs of spaces, tabs and newlines become one space (pre excepted), an entity
    is one character, offsets count code points, not bytes;
  * a text node of only spaces is dropped when it is the first child of a block
    element, and between block elements when the layout boxes inline content;
  * names lose their namespace prefix (svg:image is image), tags are lowercase,
    and <br> without a slash is not void: it holds what follows it.

Whenever a file or a place does not look the way this model expects, the
functions return nil and a reason, and nothing is written.
]]

local ExactMark = {}

local byte, char, sub, find, lower = string.byte, string.char, string.sub, string.find, string.lower
local concat = table.concat
local floor = math.floor

-- crengine cuts a text run into nodes of at most this many characters.
local TEXT_SPLIT_SIZE = 8192

-- Element sets taken from crengine's fb2def.h and KOReader's html5.css.
local function set(list)
    local t = {}
    for name in list:gmatch("%S+") do t[name] = true end
    return t
end

-- Elements that never hold a text node.
local NO_TEXT = set([[html head docfragment applet area track input keygen param audio source
    fictionbook annotation author coverpage epigraph part poem stanza svg object embed img image
    base basefont bgsound meta link table colgroup col thead tbody tfoot tr description
    document-info empty-line publish-info src-title-info title-info ?xml ?xml-stylesheet]])
-- Elements laid out as blocks by default.
local BLOCK = set([[body hr form pre blockquote div h1 h2 h3 h4 h5 h6 p output section ol ul li
    dl dt dd table caption colgroup col thead tbody tfoot tr th td address article aside canvas
    fieldset figcaption figure footer header hgroup legend main nav noscript video center dir
    menu multicol noframes search listing textarea plaintext xmp details dialog summary frame
    frameset iframe select button marquee applet optgroup map track input keygen audio source
    html fictionbook annotation author coverpage epigraph part poem stanza city date email
    history id isbn keywords lang nickname publisher sequence subtitle v version year
    document-info empty-line publish-info src-title-info title-info book-name book-title
    custom-info home-page program-used src-lang src-ocr src-url text-author]])
-- Elements hidden by default (display: none).
local HIDDEN = set([[area base basefont bgsound datalist head link meta noembed param script style
    template title binary description genre stylesheet]])
-- Elements whose text keeps its spaces and newlines.
local PRE = set("pre listing plaintext xmp textarea style")
-- Elements that are void in HTML: text crengine puts inside them is not ordinary text.
local VOID = set([[area base br col embed hr img input link meta param source track wbr keygen
    basefont bgsound frame image]])
-- Elements a marker never goes into.
local NO_MARK = set("svg math script style textarea pre listing plaintext xmp ruby rt rp rb rtc rbc title select option button")
-- xpointer names of crengine's own boxing elements (only in old, non-normalized xpointers).
local BOXING = set("autoBoxing floatBox inlineBox tabularBox rubyBox mathBox pseudoElem")

-- Named entities (the HTML 4 set and apos). A name that is not here is refused
-- rather than guessed, since crengine knows the whole HTML 5 list.
local ENTITIES = {}
do
    local list = [[quot=34 amp=38 apos=39 lt=60 gt=62 nbsp=160 iexcl=161 cent=162 pound=163
    curren=164 yen=165 brvbar=166 sect=167 uml=168 copy=169 ordf=170 laquo=171 not=172 shy=173
    reg=174 macr=175 deg=176 plusmn=177 sup2=178 sup3=179 acute=180 micro=181 para=182
    middot=183 cedil=184 sup1=185 ordm=186 raquo=187 frac14=188 frac12=189 frac34=190
    iquest=191 Agrave=192 Aacute=193 Acirc=194 Atilde=195 Auml=196 Aring=197 AElig=198
    Ccedil=199 Egrave=200 Eacute=201 Ecirc=202 Euml=203 Igrave=204 Iacute=205 Icirc=206
    Iuml=207 ETH=208 Ntilde=209 Ograve=210 Oacute=211 Ocirc=212 Otilde=213 Ouml=214 times=215
    Oslash=216 Ugrave=217 Uacute=218 Ucirc=219 Uuml=220 Yacute=221 THORN=222 szlig=223
    agrave=224 aacute=225 acirc=226 atilde=227 auml=228 aring=229 aelig=230 ccedil=231
    egrave=232 eacute=233 ecirc=234 euml=235 igrave=236 iacute=237 icirc=238 iuml=239 eth=240
    ntilde=241 ograve=242 oacute=243 ocirc=244 otilde=245 ouml=246 divide=247 oslash=248
    ugrave=249 uacute=250 ucirc=251 uuml=252 yacute=253 thorn=254 yuml=255 OElig=338
    oelig=339 Scaron=352 scaron=353 Yuml=376 fnof=402 circ=710 tilde=732 Alpha=913 Beta=914
    Gamma=915 Delta=916 Epsilon=917 Zeta=918 Eta=919 Theta=920 Iota=921 Kappa=922 Lambda=923
    Mu=924 Nu=925 Xi=926 Omicron=927 Pi=928 Rho=929 Sigma=931 Tau=932 Upsilon=933 Phi=934
    Chi=935 Psi=936 Omega=937 alpha=945 beta=946 gamma=947 delta=948 epsilon=949 zeta=950
    eta=951 theta=952 iota=953 kappa=954 lambda=955 mu=956 nu=957 xi=958 omicron=959 pi=960
    rho=961 sigmaf=962 sigma=963 tau=964 upsilon=965 phi=966 chi=967 psi=968 omega=969
    thetasym=977 upsih=978 piv=982 ensp=8194 emsp=8195 thinsp=8201 zwnj=8204 zwj=8205
    lrm=8206 rlm=8207 ndash=8211 mdash=8212 lsquo=8216 rsquo=8217 sbquo=8218 ldquo=8220
    rdquo=8221 bdquo=8222 dagger=8224 Dagger=8225 bull=8226 hellip=8230 permil=8240
    prime=8242 Prime=8243 lsaquo=8249 rsaquo=8250 oline=8254 frasl=8260 euro=8364
    image=8465 weierp=8472 real=8476 trade=8482 alefsym=8501 larr=8592 uarr=8593 rarr=8594
    darr=8595 harr=8596 crarr=8629 lArr=8656 uArr=8657 rArr=8658 dArr=8659 hArr=8660
    forall=8704 part=8706 exist=8707 empty=8709 nabla=8711 isin=8712 notin=8713 ni=8715
    prod=8719 sum=8721 minus=8722 lowast=8727 radic=8730 prop=8733 infin=8734 ang=8736
    and=8743 or=8744 cap=8745 cup=8746 int=8747 there4=8756 sim=8764 cong=8773 asymp=8776
    ne=8800 equiv=8801 le=8804 ge=8805 sub=8834 sup=8835 nsub=8836 sube=8838 supe=8839
    oplus=8853 otimes=8855 perp=8869 sdot=8901 lceil=8968 rceil=8969 lfloor=8970
    rfloor=8971 lang=9001 rang=9002 loz=9674 spades=9824 clubs=9827 hearts=9829 diams=9830]]
    for name, code in list:gmatch("(%w+)=(%d+)") do ENTITIES[name] = tonumber(code) end
end

-- Windows-1252 code points crengine substitutes for numeric entities 128 to 159.
local CP1252 = { [128] = 8364, [130] = 8218, [131] = 402, [132] = 8222, [133] = 8230, [134] = 8224,
    [135] = 8225, [136] = 710, [137] = 8240, [138] = 352, [139] = 8249, [140] = 338, [142] = 381,
    [145] = 8216, [146] = 8217, [147] = 8220, [148] = 8221, [149] = 8226, [150] = 8211, [151] = 8212,
    [152] = 732, [153] = 8482, [154] = 353, [155] = 8250, [156] = 339, [158] = 382, [159] = 376 }

-- ---- characters -------------------------------------------------------------

-- Encodes one code point as UTF-8.
local function utf8char(cp)
    if cp < 0x80 then return char(cp) end
    if cp < 0x800 then return char(0xC0 + floor(cp / 64), 0x80 + cp % 64) end
    if cp < 0x10000 then
        return char(0xE0 + floor(cp / 4096), 0x80 + floor(cp / 64) % 64, 0x80 + cp % 64)
    end
    return char(0xF0 + floor(cp / 262144), 0x80 + floor(cp / 4096) % 64, 0x80 + floor(cp / 64) % 64, 0x80 + cp % 64)
end
ExactMark.utf8char = utf8char

-- Decodes the UTF-8 character at byte i: its code point and byte length, or nil when malformed.
local function utf8at(s, i)
    local c = byte(s, i)
    if not c then return nil end
    if c < 0x80 then return c, 1 end
    local n, cp
    if c >= 0xC2 and c <= 0xDF then n, cp = 1, c - 0xC0
    elseif c >= 0xE0 and c <= 0xEF then n, cp = 2, c - 0xE0
    elseif c >= 0xF0 and c <= 0xF4 then n, cp = 3, c - 0xF0
    else return nil end
    for k = 1, n do
        local d = byte(s, i + k)
        if not d or d < 0x80 or d > 0xBF then return nil end
        cp = cp * 64 + (d - 0x80)
    end
    if (n == 2 and cp < 0x800) or (n == 3 and (cp < 0x10000 or cp > 0x10FFFF)) or (cp >= 0xD800 and cp <= 0xDFFF) then
        return nil
    end
    return cp, n + 1
end

-- True for the bytes crengine treats as spaces in markup.
local function isSpace(b)
    return b == 32 or b == 9 or b == 10 or b == 13
end

-- True for an ASCII letter.
local function isAlpha(b)
    return b and ((b >= 65 and b <= 90) or (b >= 97 and b <= 122))
end

-- True for an ASCII letter or digit.
local function isAlnum(b)
    return b and ((b >= 65 and b <= 90) or (b >= 97 and b <= 122) or (b >= 48 and b <= 57))
end

-- True for a character crengine accepts inside a tag or attribute name.
local function isIdent(b)
    return isAlnum(b) or b == 45 or b == 95 or b == 46 or b == 58
end

-- Decodes the text of a node the way crengine does (entities, spaces made one).
-- Returns { cps, bs, be, str } (code points, first byte and byte after each one,
-- the UTF-8 string), or nil and a reason when crengine's result is not certain.
local function decodeRange(s, a, b, cdata)
    local cps, bs, be = {}, {}, {}
    local n, nsp, i = 0, 0, a
    while i <= b do
        local c = byte(s, i)
        if c == 38 and not cdata then
            local c1 = i < b and byte(s, i + 1) or nil
            if c1 == 35 then
                local k, hex = i + 2, false
                if k <= b and byte(s, k) == 120 then hex, k = true, k + 1 end
                local d0, v = k, 0
                while k <= b do
                    local d = byte(s, k)
                    local dv
                    if d >= 48 and d <= 57 then dv = d - 48
                    elseif hex and d >= 97 and d <= 102 then dv = d - 87
                    elseif hex and d >= 65 and d <= 70 then dv = d - 55
                    else break end
                    v = v * (hex and 16 or 10) + dv
                    k = k + 1
                end
                if k > b or k == d0 or byte(s, k) ~= 59 or v > 0x10FFFF then return nil, "entity" end
                if v ~= 0 then
                    n = n + 1
                    cps[n], bs[n], be[n] = CP1252[v] or v, i, k + 1
                end
                nsp, i = 0, k + 1
            elseif isAlpha(c1) then
                local k = i + 1
                while k <= b and k < i + 33 and isAlnum(byte(s, k)) do k = k + 1 end
                local name = sub(s, i + 1, k - 1)
                local code = k <= b and byte(s, k) == 59 and ENTITIES[name]
                if not code then return nil, "entity" end
                n = n + 1
                cps[n], bs[n], be[n] = code, i, k + 1
                nsp, i = 0, k + 1
            else
                return nil, "entity"
            end
        elseif isSpace(c) then
            if nsp == 0 then
                n = n + 1
                cps[n], bs[n], be[n] = 32, i, i + 1
            end
            nsp, i = nsp + 1, i + 1
        else
            local cp, len = utf8at(s, i)
            if not cp or i + len - 1 > b then return nil, "encoding" end
            n = n + 1
            cps[n], bs[n], be[n] = cp, i, i + len
            nsp, i = 0, i + len
        end
    end
    local out = {}
    for k = 1, n do out[k] = utf8char(cps[k]) end
    return { cps = cps, bs = bs, be = be, str = concat(out), n = n }
end

-- True when a raw text chunk becomes only spaces in crengine (or nil when unsure).
local function chunkIsSpace(s, a, b, cdata, pre)
    local nonspace = find(s, "[^ \t\r\n]", a)
    if not nonspace or nonspace > b then return true end
    if pre or cdata then return false end
    local piece = sub(s, a, b)
    if not find(piece, "&", 1, true) then return false end
    local d = decodeRange(s, a, b, false)
    if not d then return nil end
    for k = 1, d.n do
        if d.cps[k] ~= 32 then return false end
    end
    return true
end

-- Splits a raw text run [a, b] into crengine's text nodes of at most 8192
-- characters: each cut is after the last space or newline of a full window.
local function chunks(s, a, b)
    if b - a + 1 < TEXT_SPLIT_SIZE then return { { a, b } } end
    local starts = {}
    local i = a
    while i <= b do
        starts[#starts + 1] = i
        local c = byte(s, i)
        if c < 0x80 then i = i + 1
        elseif c >= 0xF0 then i = i + 4
        elseif c >= 0xE0 then i = i + 3
        elseif c >= 0xC0 then i = i + 2
        else i = i + 1 end
    end
    local total = #starts
    if total < TEXT_SPLIT_SIZE then return { { a, b } } end
    local out, first = {}, 1
    while first <= total do
        if total - first + 1 < TEXT_SPLIT_SIZE then
            out[#out + 1] = { starts[first], b }
            break
        end
        local last = first + TEXT_SPLIT_SIZE - 1
        local cut = last
        for k = last, first, -1 do
            local c = byte(s, starts[k])
            if c == 32 then cut = k; break end
            if c == 13 or c == 10 then
                local nb = k < last and byte(s, starts[k + 1]) or 0
                if (c == 13 and nb ~= 10) or (c == 10 and nb ~= 13) then cut = k; break end
            end
        end
        local stop = cut < total and starts[cut + 1] - 1 or b
        out[#out + 1] = { starts[first], stop }
        first = cut + 1
    end
    return out
end

-- ---- the model of a file ------------------------------------------------------

-- Reads crengine's tag or attribute name at byte p: namespace, name and the byte
-- after it, or nil when crengine would not accept it as a name there.
local function readIdent(s, p)
    if not isAlpha(byte(s, p)) then return nil end
    local q, colon = p + 1, nil
    while true do
        local c = byte(s, q)
        if not c or not isIdent(c) then break end
        if c == 58 then
            if colon then break end
            colon = q
        end
        q = q + 1
    end
    local nb = byte(s, q)
    if nb and nb ~= 32 and nb ~= 47 and nb ~= 62 and nb ~= 63 and nb ~= 61 and nb ~= 13 and nb ~= 10 then
        return nil
    end
    local ns, name = nil, sub(s, p, q - 1)
    if colon then ns, name = sub(s, p, colon - 1), sub(s, colon + 1, q - 1) end
    if name == "" then return nil end
    return ns, name, q
end

-- Skips spaces from byte p.
local function skipSpaces(s, p)
    local q = find(s, "[^ \t\r\n]", p)
    return q or #s + 1
end

-- Checks the file's declared character set: crengine reads it as UTF-8 only when
-- it says so or says nothing and is valid UTF-8.
local function encodingOk(s)
    local b1, b2 = byte(s, 1, 2)
    if (b1 == 0xFF and b2 == 0xFE) or (b1 == 0xFE and b2 == 0xFF) then return false end
    local head = lower(sub(s, 1, 1024))
    local enc = head:match("<%?xml[^>]-encoding%s*=%s*[\"']([^\"']+)")
        or head:match("<meta[^>]-charset%s*=%s*[\"']?([%w_%-]+)")
    if enc then return enc == "utf-8" or enc == "utf8" end
    local i, n = 1, #s
    while i <= n do
        local q = find(s, "[\128-\255]", i)
        if not q then return true end
        local cp, len = utf8at(s, q)
        if not cp then return false end
        i = q + len
    end
    return true
end

-- Builds crengine's view of one XHTML file: the elements and text nodes of its
-- body. Returns { body, bodies, anomaly, texts, elems }; anomaly is set when
-- the markup is broken in a way crengine handles unpredictably inside the body.
function ExactMark.model(s)
    local doc = { s = s, bodies = 0, texts = {}, elems = {} }
    if not encodingOk(s) then doc.anomaly = "encoding" end
    local n = #s
    local stack, top = {}, nil
    local inBody = false
    local function oddity(why)
        if inBody and not doc.anomaly then doc.anomaly = why end
    end
    local function openElem(name, attrs, ts, te)
        if not inBody then
            if name == "body" then
                doc.bodies = doc.bodies + 1
                inBody = true
                if doc.bodies == 1 then
                    local body = { name = "body", kids = {}, ts = ts, te = te, block = true, allow = true }
                    doc.body = body
                    doc.elems[#doc.elems + 1] = body
                    stack, top = { body }, body
                else
                    stack, top = { false }, false
                end
            end
            return nil
        end
        if top == false then return nil end
        local svg = top.svg or name == "svg"
        local el = { name = name, kids = {}, parent = top, ts = ts, te = te, svg = svg,
            math = top.math or name == "math" }
        local lname = svg and lower(name) or name
        if top.svg then
            el.allow = lname == "style" or lname == "text" or lname == "tspan" or lname == "textpath"
                or lname == "title" or lname == "desc" or lname == "metadata"
            el.pre = el.allow
        else
            el.allow = not NO_TEXT[lname]
            el.pre = top.pre or PRE[lname] or false
        end
        local hidden = HIDDEN[lname] or (attrs and attrs.hidden)
            or (lname == "span" and attrs and attrs.type == "pagebreak")
            or (lname == "input" and attrs and attrs.type and lower(attrs.type) == "hidden")
        el.hidden = hidden or false
        el.block = (not hidden) and BLOCK[lname] or false
        el.void = top.void or VOID[lname] or false
        el.nomark = top.nomark or NO_MARK[lname] or el.void or el.hidden or top.hidden or false
        el.marker = top.marker or (lname == "span" and attrs and attrs.class
            and (" " .. attrs.class .. " "):find("%siar%s") ~= nil) or false
        if lname:sub(1, 1) == "?" then oddity("instruction") end
        top.kids[#top.kids + 1] = el
        doc.elems[#doc.elems + 1] = el
        stack[#stack + 1] = el
        top = el
        return el
    end
    local function closeElem(name)
        if not inBody then return end
        if name == "body" then
            inBody = false
            stack, top = {}, nil
            return
        end
        if top == false then return end
        for k = #stack, 2, -1 do
            if stack[k].name == name then
                for m = #stack, k, -1 do stack[m] = nil end
                top = stack[#stack]
                return
            end
        end
    end
    local function addText(a, b, kind)
        if not inBody or not top or not top.allow or b < a then return end
        local runs = chunks(s, a, b)
        for _k, r in ipairs(runs) do
            local ws = chunkIsSpace(s, r[1], r[2], kind == "cdata", top.pre)
            if ws == nil then
                oddity("entity")
                ws = false
            end
            if ws and top.block and #top.kids == 0 and not top.pre then
                top.dropped = true
            else
                local t = { t = true, s = r[1], e = r[2], kind = kind, parent = top, ws = ws,
                    pre = top.pre, chunked = #runs > 1 }
                top.kids[#top.kids + 1] = t
                doc.texts[#doc.texts + 1] = t
            end
        end
    end

    -- the parser, in crengine's states: text, raw text of style/script, CDATA, tags
    local p = find(s, "<", 1, true)
    if not p then return doc end
    local state, raw = "lt", nil
    p = p + 1
    while p and p <= n + 1 do
        if state == "text" then
            if raw then
                local q = p
                local stop
                while true do
                    q = find(s, "</", q, true)
                    if not q then break end
                    if lower(sub(s, q + 2, q + 1 + #raw)) == raw then stop = q; break end
                    q = q + 1
                end
                addText(p, (stop or n + 1) - 1, "text")
                raw = nil
                if not stop then break end
                state, p = "lt", stop + 1
            else
                local q = find(s, "<", p, true)
                addText(p, (q or n + 1) - 1, "text")
                if not q then break end
                state, p = "lt", q + 1
            end
        elseif state == "cdata" then
            local q = find(s, "]]>", p, true)
            addText(p, (q or n + 1) - 1, "cdata")
            if not q then break end
            state, p = "text", q + 3
        else
            -- just after '<'
            local lt = p - 1
            p = skipSpaces(s, p)
            if p > n then break end
            local c = byte(s, p)
            if c == 47 then
                local _, name, q = readIdent(s, p + 1)
                if not name or byte(s, q) == 61 then
                    oddity("tag")
                    local e = find(s, ">", p, true)
                    if not e then break end
                    state, p = "text", e + 1
                else
                    if not (top and top.svg) then name = lower(name) end
                    closeElem(name)
                    local e = find(s, ">", q, true)
                    if not e then break end
                    state, p = "text", e + 1
                end
            elseif c == 33 and sub(s, p + 1, p + 2) == "--" then
                local e = find(s, "-->", p + 3, true)
                if not e then break end
                state, p = "text", e + 3
            elseif c == 33 and sub(s, p + 1, p + 7) == "[CDATA[" then
                state, p = "cdata", p + 8
            else
                local qmark = c == 63
                local _ns, name, q = readIdent(s, qmark and p + 1 or p)
                if not name or byte(s, q) == 61 then
                    oddity("tag")
                    local e = find(s, ">", p, true)
                    if not e then break end
                    state, p = "text", e + 1
                else
                    if not (top and top.svg) then name = lower(name) end
                    if qmark then name = "?" .. name end
                    -- attributes
                    local attrs, k, selfclose, tagEnd, broken = {}, q, false, nil, nil
                    while true do
                        k = skipSpaces(s, k)
                        if k > n then break end
                        local a1, a2 = byte(s, k), byte(s, k + 1)
                        if a1 == 62 then tagEnd = k + 1; break end
                        if a2 == 62 and (a1 == 47 or a1 == 63) then selfclose, tagEnd = true, k + 2; break end
                        local _, aname, k2 = readIdent(s, k)
                        if not aname then
                            broken = find(s, "<", k, true)
                            break
                        end
                        aname = lower(aname)
                        k = skipSpaces(s, k2)
                        local value = ""
                        if byte(s, k) == 61 then
                            k = skipSpaces(s, k + 1)
                            local quote = byte(s, k)
                            if quote == 34 or quote == 39 then k = k + 1 else quote = nil end
                            local v0 = k
                            while k <= n do
                                local vc = byte(s, k)
                                if vc == 62 then break end
                                if not quote and isSpace(vc) then break end
                                if quote and vc == quote then break end
                                k = k + 1
                            end
                            value = sub(s, v0, k - 1)
                            if quote and byte(s, k) == quote then k = k + 1 end
                        end
                        attrs[aname] = value
                    end
                    if broken or (not tagEnd and k > n) then
                        oddity("attribute")
                    end
                    openElem(name, attrs, lt, tagEnd or k)
                    local lname = lower(name)
                    if selfclose then
                        closeElem(name)
                    elseif lname == "style" or lname == "script" then
                        raw = lname
                    end
                    if broken then
                        raw = nil
                        state, p = "lt", broken + 2
                    elseif tagEnd then
                        state, p = "text", tagEnd
                    else
                        break
                    end
                end
            end
        end
    end
    return doc
end
local model = ExactMark.model

-- Text of a node as crengine holds it ({ cps, bs, be, str, n }), cached.
local function nodeText(doc, t)
    if t.dec == nil then
        if t.pre then
            t.dec, t.bad = false, "pre"
        else
            local d, why = decodeRange(doc.s, t.s, t.e, t.kind == "cdata")
            t.dec, t.bad = d or false, why
        end
    end
    return t.dec or nil, t.bad
end

-- True when crengine lays an element out as a block among its siblings.
local function isBlockish(el)
    if el.t then return false end
    if el.blockish == nil then
        local v = el.block
        if not v and not el.hidden and not el.svg then
            -- an inline element holding only blocks (and spaces) becomes a block
            local blocks, inl = false, false
            for _, k in ipairs(el.kids) do
                if k.t then
                    if not k.ws then inl = true end
                elseif isBlockish(k) then
                    blocks = true
                elseif not k.hidden then
                    inl = true
                end
            end
            v = blocks and not inl
        end
        el.blockish = v
    end
    return el.blockish
end

-- True for a child crengine lays out inline: text, or a visible inline element.
local function isInline(k)
    if k.t then return true end
    return not k.hidden and not isBlockish(k)
end

-- The children of an element once crengine has laid it out: text nodes of only
-- spaces next to blocks are gone. Works on any list of kids of that element.
local function layoutKids(el, kids)
    if el.pre or el.svg then return kids end
    local hasBlock = false
    for _, k in ipairs(kids) do
        if not k.t and isBlockish(k) then hasBlock = true; break end
    end
    if not hasBlock then return kids end
    local out = {}
    if el.block or isBlockish(el) then
        local i, n = 1, #kids
        while i <= n do
            local k = kids[i]
            if k.t and k.ws then
                local j = i
                while j + 1 <= n and kids[j + 1].t and kids[j + 1].ws do j = j + 1 end
                local prev, nxt = kids[i - 1], kids[j + 1]
                if prev and nxt and isInline(prev) and isInline(nxt) then
                    for m = i, j do out[#out + 1] = kids[m] end
                end
                i = j + 1
            else
                out[#out + 1] = k
                i = i + 1
            end
        end
    else
        local hasInl = false
        for _, k in ipairs(kids) do
            if (k.t and not k.ws) or (not k.t and isInline(k)) then hasInl = true; break end
        end
        if not hasInl then return kids end
        local drop = {}
        for i, k in ipairs(kids) do
            if not k.t and isBlockish(k) then
                if kids[i + 1] and kids[i + 1].t and kids[i + 1].ws then drop[i + 1] = true end
                if kids[i - 1] and kids[i - 1].t and kids[i - 1].ws then drop[i - 1] = true end
            end
        end
        for i, k in ipairs(kids) do
            if not drop[i] then out[#out + 1] = k end
        end
    end
    return out
end

-- The laid-out children of an element, cached.
local function effKids(el)
    if not el.eff then el.eff = layoutKids(el, el.kids) end
    return el.eff
end

-- The element at a path of steps under the body, or nil.
local function findElem(doc, steps)
    local el = doc.body
    if not el then return nil end
    for _, st in ipairs(steps) do
        local count, found = 0, nil
        for _, k in ipairs(el.kids) do
            if not k.t and k.name == st.name then
                count = count + 1
                if count == st.idx then found = k; break end
            end
        end
        if not found then return nil end
        el = found
    end
    return el
end

-- The path of steps from the body down to an element.
local function elemPath(el)
    local steps = {}
    while el.parent do
        local idx = 0
        for _, k in ipairs(el.parent.kids) do
            if not k.t and k.name == el.name then
                idx = idx + 1
                if k == el then break end
            end
        end
        table.insert(steps, 1, { name = el.name, idx = idx })
        el = el.parent
    end
    return steps
end
ExactMark.elemPath = elemPath

-- The jth laid-out text node of an element, with its place among the element's children.
local function textChild(el, j)
    local count = 0
    for ci, k in ipairs(effKids(el)) do
        if k.t then
            count = count + 1
            if count == j then return k, ci - 1 end
        end
    end
    return nil
end

-- Where a text node sits in its element: its text() index and child index, or nil when laid out away.
local function textIndex(t)
    local count = 0
    for ci, k in ipairs(effKids(t.parent)) do
        if k.t then
            count = count + 1
            if k == t then return count, ci - 1 end
        end
    end
    return nil
end

-- The laid-out text nodes of a modelled element, as { node, text, why } where
-- text is the node's text as crengine holds it, or nil with why when unsure.
function ExactMark.textsOf(doc, el)
    local out = {}
    for _, k in ipairs(effKids(el)) do
        if k.t then
            local d, why = nodeText(doc, k)
            out[#out + 1] = { node = k, text = d and d.str, why = why }
        end
    end
    return out
end

-- ---- xpointers ------------------------------------------------------------------

-- Splits a crengine xpointer into its DocFragment, element steps under the
-- fragment's body, and text node and offset (nil for an element xpointer; an
-- element xpointer with a child offset has point set).
function ExactMark.parse(xp)
    if type(xp) ~= "string" then return nil end
    local frag, rest = xp:match("^/body%[?1?%]?/DocFragment(%b[])/body%[?1?%]?(.*)$")
    if not frag then
        rest = xp:match("^/body%[?1?%]?/DocFragment/body%[?1?%]?(.*)$")
        if not rest then return nil end
        frag = "[1]"
    end
    frag = tonumber(frag:sub(2, -2))
    if not frag or frag < 1 then return nil end
    local r = { frag = frag, steps = {} }
    local pos = 1
    while pos <= #rest do
        if rest:find("^/text%(%)", pos) then
            local tidx, off, e2 = rest:match("^/text%(%)%[(%d+)%]%.(%d+)()", pos)
            if not tidx then
                off, e2 = rest:match("^/text%(%)%.(%d+)()", pos)
                tidx = "1"
            end
            if not off or e2 ~= #rest + 1 then return nil end
            r.text, r.off = tonumber(tidx), tonumber(off)
            if r.text < 1 then return nil end
            return r
        end
        local name, idx, e = rest:match("^/([%a_][%w_%-%.]*)(%b[])()", pos)
        if not name then
            name, e = rest:match("^/([%a_][%w_%-%.]*)()", pos)
            idx = "[1]"
        end
        if not name then
            local pt, e2 = rest:match("^%.(%d+)()", pos)
            if pt and e2 == #rest + 1 then
                r.point = tonumber(pt)
                return r
            end
            return nil
        end
        if BOXING[name] then return nil end
        idx = tonumber(idx:sub(2, -2))
        if not idx or idx < 1 then return nil end
        r.steps[#r.steps + 1] = { name = name, idx = idx }
        pos = e
    end
    return r
end

-- Writes a parsed xpointer back, with every index explicit (the form KOReader
-- writes for books opened with its current engine).
function ExactMark.format(p)
    local t = { "/body[1]/DocFragment[", tostring(p.frag), "]/body[1]" }
    for _, st in ipairs(p.steps) do
        t[#t + 1] = "/" .. st.name .. "[" .. st.idx .. "]"
    end
    if p.text then
        t[#t + 1] = "/text()[" .. p.text .. "]." .. p.off
    elseif p.point then
        t[#t + 1] = "." .. p.point
    end
    return concat(t)
end

-- Copies a list of steps.
local function copySteps(steps)
    local out = {}
    for i, st in ipairs(steps) do out[i] = { name = st.name, idx = st.idx } end
    return out
end

-- ---- the spine -----------------------------------------------------------------

-- Undoes %XX escapes in a path.
local function percentDecode(href)
    return (href:gsub("%%(%x%x)", function(h) return char(tonumber(h, 16)) end))
end

-- Decodes the few entities an attribute value in an OPF may hold.
local function attrDecode(v)
    v = v:gsub("&#x(%x+);", function(h) return utf8char(tonumber(h, 16)) end)
    v = v:gsub("&#(%d+);", function(d) return utf8char(tonumber(d)) end)
    v = v:gsub("&(%a+);", function(name) return ENTITIES[name] and utf8char(ENTITIES[name]) end)
    return (v:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- The attributes of every element with a local name in an XML string, in order.
local function xmlElements(xml, want)
    local out = {}
    for tag in xml:gmatch("<([%a_][^>]*)>") do
        local name, rest = tag:match("^([%w_%-%.:]+)(.*)$")
        if name then
            local lname = name:match(":([%w_%-%.]+)$") or name
            if lname == want then
                local attrs = {}
                for an, _, av in rest:gmatch("([%w_%-%.:]+)%s*=%s*([\"'])(.-)%2") do
                    attrs[an:match(":([%w_%-%.]+)$") or an] = attrDecode(av)
                end
                out[#out + 1] = attrs
            end
        end
    end
    return out
end

-- Joins a base folder and a relative href the way crengine does, resolving "..".
local function combinePath(base, href)
    if href:sub(1, 1) == "/" then return href:sub(2) end
    local parts = {}
    for piece in (base .. href):gmatch("[^/]+") do
        if piece == ".." then
            if #parts > 0 then parts[#parts] = nil end
        elseif piece ~= "." then
            parts[#parts + 1] = piece
        end
    end
    return concat(parts, "/")
end

-- The zip paths of the book's spine items in DocFragment order, from read(path)
-- returning an entry's bytes. opts.dom_version below 20240114 keeps only XHTML
-- items (as crengine did for books first opened before then); opts.bodies reads
-- every spine file and repeats a file once per extra <body> it has. The second
-- result describes each item: { path, id, media, linear, bodies }.
function ExactMark.spine(read, opts)
    opts = opts or {}
    local container = read("META-INF/container.xml")
    if not container then return nil, "container" end
    local roots = xmlElements(container, "rootfile")
    local root = roots[1]
    if not root or not root["full-path"] or root["media-type"] ~= "application/oebps-package+xml" then
        return nil, "rootfile"
    end
    local opfPath = root["full-path"]
    local opf = read(opfPath)
    if not opf then return nil, "opf" end
    local base = opfPath:match("^(.*/)") or ""
    local manifestXml = opf:match("<[%w_]*:?manifest[^>]*>(.-)</[%w_]*:?manifest>") or ""
    local spineXml = opf:match("<[%w_]*:?spine[^>]*>(.-)</[%w_]*:?spine>") or ""
    local items = {}
    for _, a in ipairs(xmlElements(manifestXml, "item")) do
        if a.id and a.id ~= "" and a.href and a.href ~= "" and not items[a.id] then
            items[a.id] = a
        end
    end
    local paths, info = {}, {}
    for _, ref in ipairs(xmlElements(spineXml, "itemref")) do
        local item = ref.idref and items[ref.idref]
        if item then
            local media = item["media-type"] or ""
            if not (opts.dom_version and opts.dom_version < 20240114 and media ~= "application/xhtml+xml") then
                local path = combinePath(base, percentDecode(item.href))
                local rec = { path = path, id = item.id, media = media, linear = ref.linear ~= "no", bodies = 1 }
                local copies = 1
                if opts.bodies then
                    local bytes = read(path)
                    if bytes then
                        local d = model(bytes)
                        rec.bodies = d.bodies
                        if d.bodies > 1 then copies = d.bodies end
                    end
                end
                for _ = 1, copies do
                    paths[#paths + 1] = path
                    info[#info + 1] = rec
                end
            end
        end
    end
    return paths, info
end

-- ---- finding and wrapping words ---------------------------------------------------

-- Finds the text node at steps / text() j in a model: node, its decoded text, or nil and a reason.
local function findText(doc, steps, j)
    if doc.anomaly then return nil, doc.anomaly end
    if not doc.body then return nil, "nobody" end
    if doc.bodies ~= 1 then return nil, "bodies" end
    local el = findElem(doc, steps)
    if not el then return nil, "path" end
    local t = textChild(el, j or 1)
    if not t then return nil, "text" end
    local d, why = nodeText(doc, t)
    if not d then return nil, why end
    return t, d
end

-- The byte in the XHTML source of character off of text node j at steps (a
-- character's first byte; an entity's "&"; the first byte of a run of spaces;
-- the byte after the node for off at its end), or nil and a reason. The second
-- result is { text = the node's text as crengine holds it, chars = its length }.
function ExactMark.locate(xhtml, steps, text, off, doc)
    doc = doc or model(xhtml)
    local t, d = findText(doc, steps, text)
    if not t then return nil, d end
    if t.chunked then return nil, "long-text" end
    off = off or 0
    if off < 0 or off > d.n then return nil, "offset" end
    local pos = off < d.n and d.bs[off + 1] or (d.n > 0 and d.be[d.n] or t.e + 1)
    return pos, { text = d.str, chars = d.n, node = t }
end

-- True when the text() index of node t depends on the book's CSS: a node of only
-- spaces before it sits next to an element, and the stylesheet could make that
-- element a block (or float or hide it), which drops the spaces from the layout.
local function indexDependsOnCss(t)
    if t.parent.dropped then return true end
    local kids = t.parent.kids
    for i, k in ipairs(kids) do
        if k == t then return false end
        if k.t and k.ws then
            local prev, nxt = kids[i - 1], kids[i + 1]
            if (prev and not prev.t) or (nxt and not nxt.t) then return true end
        end
    end
    return false
end

ExactMark.indexDependsOnCss = indexDependsOnCss

-- Why a marker may not go into a text node, or nil when it may.
local function refusal(t)
    local p = t.parent
    if p.svg then return "svg" end
    if p.math then return "math" end
    if t.pre or p.pre then return "pre" end
    if p.marker then return "marker" end
    if p.void then return "void" end
    if p.nomark then return "inside " .. p.name end
    if t.kind == "cdata" then return "cdata" end
    if t.chunked then return "long-text" end
    return nil
end

-- Plans one marker over character c (1-based) of text node t: the word around it
-- (or from it, when exact), or nil and a reason.
local function planWord(doc, t, c, exact, lead)
    local why = refusal(t)
    if why then return nil, why end
    local d, bad = nodeText(doc, t)
    if not d then return nil, bad end
    if c < 1 or c > d.n then return nil, "offset" end
    if d.cps[c] == 32 then return nil, "space" end
    local c0, c1 = c, c
    if not exact then
        while c0 > 1 and d.cps[c0 - 1] ~= 32 do c0 = c0 - 1 end
    end
    while c1 < d.n and d.cps[c1 + 1] ~= 32 do c1 = c1 + 1 end
    local w = {}
    for k = c0, c1 do w[#w + 1] = utf8char(d.cps[k]) end
    -- (lead: the span starts at the space before the word. crengine keeps a line's
    -- break chance on the character before a word, and a marker float there would
    -- take it: the word before would be pushed to the next line.)
    -- lead = "must" refuses a word with no space before it in its node.
    if lead then
        if c0 > 1 and d.cps[c0 - 1] == 32 then
            c0 = c0 - 1
        elseif lead == "must" then
            return nil, "no-space"
        end
    end
    return { t = t, c0 = c0, c1 = c1, bstart = d.bs[c0], bend = d.be[c1], word = concat(w) }
end

-- A text item of a planned layout: a piece of a node's text.
local function piece(t, d, from, to)
    local out = {}
    for k = from, to do out[#out + 1] = utf8char(d.cps[k]) end
    local str = concat(out)
    return { t = true, ws = not str:find("[^ ]"), str = str, src = t }
end

-- The children an element will have once its words are wrapped, as crengine
-- parses them: each marked text node becomes text, span, text... A piece of only
-- spaces that crengine drops because it starts a block is left out, and the
-- marker before it is returned in the second table.
local function plannedKids(doc, el, opsByNode)
    local kids, lost = {}, {}
    for _, k in ipairs(el.kids) do
        local ops = k.t and opsByNode[k]
        if ops then
            local d = nodeText(doc, k)
            local at = 1
            for _, op in ipairs(ops) do
                if op.c0 > at then
                    local pc = piece(k, d, at, op.c0 - 1)
                    pc.op = op
                    if pc.ws and el.block and #kids == 0 then
                        lost[op] = true
                    else
                        kids[#kids + 1] = pc
                    end
                end
                local w = piece(k, d, op.c0, op.c1)
                kids[#kids + 1] = { span = true, op = op, str = w.str, name = "span", kids = {},
                    hidden = false, block = false, blockish = false }
                at = op.c1 + 1
            end
            if at <= d.n then
                local pc = piece(k, d, at, d.n)
                pc.op = ops[#ops]
                kids[#kids + 1] = pc
            end
        else
            kids[#kids + 1] = k
        end
    end
    return kids, lost
end

-- Text of a kid of a planned or modelled layout.
local function kidText(doc, k)
    if k.str then return k.str end
    local d = nodeText(doc, k)
    return d and d.str
end

-- Checks the planned layout of an element: every piece of the marked nodes and
-- every span must survive crengine's layout, and every other child must be laid
-- out as before. Returns the ops that break this, as a set.
local function checkPlan(doc, el, opsByNode)
    local kids, bad = plannedKids(doc, el, opsByNode)
    local laid = layoutKids(el, kids)
    local kept, before = {}, {}
    for _, k in ipairs(laid) do kept[k] = true end
    for _, k in ipairs(effKids(el)) do before[k] = true end
    local all = false
    for _, k in ipairs(kids) do
        if k.op then
            if not kept[k] then bad[k.op] = true end
        elseif (before[k] or false) ~= (kept[k] or false) then
            all = true
        end
    end
    if all then
        for _, ops in pairs(opsByNode) do
            for _, op in ipairs(ops) do bad[op] = true end
        end
    end
    return bad
end

-- Inserts the planned spans into the source. ops must not overlap; each gets
-- its open tag, and the result is the new source.
local function insertSpans(s, ops)
    local sorted = {}
    for _, op in ipairs(ops) do sorted[#sorted + 1] = op end
    table.sort(sorted, function(a, b) return a.bstart < b.bstart end)
    local out, at, shift = {}, 1, 0
    for _, op in ipairs(sorted) do
        out[#out + 1] = sub(s, at, op.bstart - 1)
        op.newpos = op.bstart + shift
        out[#out + 1] = op.open
        out[#out + 1] = sub(s, op.bstart, op.bend - 1)
        out[#out + 1] = "</span>"
        shift = shift + #op.open + 7
        at = op.bend
    end
    out[#out + 1] = sub(s, at)
    return concat(out), sorted
end

-- The byte shift of an original position after the spans are in.
local function shiftOf(sorted, pos)
    local shift = 0
    for _, op in ipairs(sorted) do
        if op.bstart < pos then shift = shift + #op.open + 7 else break end
    end
    return shift
end

-- The open tag of a marker: its id only when it is safe and not already in the file.
local function openTag(s, id)
    if id ~= nil then
        id = tostring(id)
        if id:find("^[%w_%-]+$") and not find(s, "iar" .. id, 1, true) then
            return '<span class="iar" id="iar' .. id .. '">'
        end
    end
    return '<span class="iar">'
end

-- Wraps a set of planned ops in one file and checks the edited file the way the
-- original was read. Fills each op's result; returns the new source (or nil).
local function wrapOps(doc, ops, frag)
    local s = doc.s
    local live = {}
    for _, op in ipairs(ops) do
        if not op.why then live[#live + 1] = op end
    end
    for _ = 1, 8 do
        if #live == 0 then return nil end
        -- overlaps
        table.sort(live, function(a, b) return a.bstart < b.bstart end)
        local keep = {}
        for _, op in ipairs(live) do
            local last = keep[#keep]
            if last and op.bstart < last.bend then
                op.why = (op.bstart == last.bstart) and "duplicate" or "overlap"
            else
                keep[#keep + 1] = op
            end
        end
        live = keep
        -- per element: the layout must keep every piece
        local byElem, order = {}, {}
        for _, op in ipairs(live) do
            local el = op.t.parent
            if not byElem[el] then byElem[el] = {}; order[#order + 1] = el end
            local m = byElem[el]
            m[op.t] = m[op.t] or {}
            table.insert(m[op.t], op)
        end
        local failed = false
        for _, el in ipairs(order) do
            for _, list in pairs(byElem[el]) do
                table.sort(list, function(a, b) return a.c0 < b.c0 end)
            end
            local bad = checkPlan(doc, el, byElem[el])
            for op in pairs(bad) do op.why = "block-edge"; failed = true end
        end
        if not failed then
            local used = {}
            for _, op in ipairs(live) do
                local id = op.id ~= nil and tostring(op.id) or nil
                if id and used[id] then id = nil end
                if id then used[id] = true end
                op.open = openTag(s, id)
            end
            local new, sorted = insertSpans(s, live)
            local nd = model(new)
            local wrong = {}
            if nd.anomaly or nd.bodies ~= doc.bodies or #nd.elems ~= #doc.elems + #live then
                for _, op in ipairs(live) do wrong[op] = true end
            else
                local byPos = {}
                for _, e in ipairs(nd.elems) do byPos[e.ts] = e end
                for _, el in ipairs(order) do
                    local expect = layoutKids(el, plannedKids(doc, el, byElem[el]))
                    local nel = byPos[el.ts + shiftOf(sorted, el.ts)]
                    local actual = nel and effKids(nel)
                    local ok = actual and #actual == #expect
                    if ok then
                        for i, k in ipairs(expect) do
                            local a = actual[i]
                            if k.span then
                                ok = not a.t and a.name == "span" and a.ts == k.op.newpos and #a.kids == 1
                                    and a.kids[1].t and kidText(nd, a.kids[1]) == k.str
                                if ok then k.op.newel = a end
                            elseif k.t then
                                ok = a.t and kidText(nd, a) == kidText(doc, k)
                            else
                                ok = not a.t and a.name == k.name and a.ts == k.ts + shiftOf(sorted, k.ts)
                            end
                            if not ok then break end
                        end
                    end
                    if not ok then
                        for _, list in pairs(byElem[el]) do
                            for _, op in ipairs(list) do wrong[op] = true end
                        end
                    end
                end
            end
            if not next(wrong) then
                -- split records, in the order the spans go in (from the end of the file)
                local seq = {}
                for i = #sorted, 1, -1 do seq[#seq + 1] = sorted[i] end
                for n, op in ipairs(seq) do
                    local el = op.t.parent
                    local j, child = textIndex(op.t)
                    local spansBefore = 0
                    for _, k in ipairs(el.kids) do
                        if k == op.t then break end
                        if not k.t and k.name == "span" then spansBefore = spansBefore + 1 end
                    end
                    local d = nodeText(doc, op.t)
                    local nextOp
                    for _, other in ipairs(byElem[el][op.t]) do
                        if other.c0 > op.c1 and (not nextOp or other.c0 < nextOp.c0) then nextOp = other end
                    end
                    local tailEnd = nextOp and nextOp.c0 - 1 or d.n
                    op.split = { frag = frag, parent_steps = elemPath(el), text = j, off = op.c0 - 1,
                        len = op.c1 - op.c0 + 1, tail = tailEnd - op.c1, span = spansBefore + 1,
                        child = child, seq = n }
                    op.steps = elemPath(op.newel)
                end
                return new, nd
            end
            for op in pairs(wrong) do op.why = "verify" end
        end
        local still = {}
        for _, op in ipairs(live) do
            if not op.why then still[#still + 1] = op end
        end
        live = still
    end
    return nil
end

-- Wraps the word starting at (or, when pos is inside it, holding) source byte
-- pos in <span class="iar" id="iar<id>">. opts.exact starts the span at pos.
-- Returns the new XHTML and { word, steps, split = { parent_steps, text, off,
-- len, tail, span, child, seq } }, or nil and a reason.
function ExactMark.wrap(xhtml, pos, id, opts)
    local doc = model(xhtml)
    if doc.anomaly then return nil, doc.anomaly end
    if doc.bodies ~= 1 then return nil, "bodies" end
    -- the text node holding pos
    local lo, hi, t = 1, #doc.texts, nil
    while lo <= hi do
        local mid = floor((lo + hi) / 2)
        local m = doc.texts[mid]
        if pos < m.s then hi = mid - 1
        elseif pos > m.e then lo = mid + 1
        else t = m; break end
    end
    if not t then return nil, "not text" end
    if not textIndex(t) then return nil, "laid out away" end
    local refused = refusal(t)
    if refused then return nil, refused end
    local d, bad = nodeText(doc, t)
    if not d then return nil, bad end
    local c
    for k = 1, d.n do
        if d.bs[k] <= pos and pos < d.be[k] then c = k; break end
    end
    if not c then return nil, "space" end
    local op, why = planWord(doc, t, c, opts and opts.exact)
    if not op then return nil, why end
    op.id = id
    local new = wrapOps(doc, { op })
    if not new then return nil, op.why or "verify" end
    return new, { word = op.word, steps = op.steps, split = op.split }
end

-- True when the word a mark expects is the wrapped word, or its start (the
-- engine may end a word before punctuation the span still takes in).
local function wordMatches(want, got)
    return type(want) == "string" and want ~= "" and sub(got, 1, #want) == want
end

-- Wraps marked words in the chapters of a book. entries maps zip paths to the
-- bytes of (at least) every marked chapter; spine is ExactMark.spine's list, so
-- mark.frag finds the file. Each mark is { frag, steps, text, off, id, word }
-- (or { xp, id, word }); word must be the wrapped word or its start. A mark
-- inside a word wraps the whole word, or from its offset on when word only
-- matches from there (exact = true always does); lead = true takes in the space
-- before the word too (see planWord). node_text, the whole text node
-- as the engine holds it (document:getTextFromXPointer(xp)), is checked when
-- given, and needed where the node's index could depend on the book's CSS.
-- Returns a copy of entries with the edited chapters replaced, and a result per
-- mark: { applied, why, xp, word, split }, where xp is the span's element
-- xpointer in the edited chapter. Each mark also gets mark.split (false when it
-- was not applied): toNew, toOld and affects read it from the stored marks.
-- (node_md5 in place of node_text: ExactMark.hash(node_text), when a hash
-- function is set; ink/reader/exactbook.lua sets md5, so marks kept with a book
-- do not carry whole paragraphs.)
function ExactMark.apply(entries, marks, spine)
    local out, results = {}, {}
    for k, v in pairs(entries) do out[k] = v end
    local byPath, paths = {}, {}
    for i, m in ipairs(marks) do
        local r = { applied = false }
        results[i] = r
        local frag, steps, text, off = m.frag, m.steps, m.text, m.off
        if m.xp and not steps then
            local p = ExactMark.parse(m.xp)
            if p then frag, steps, text, off = p.frag, p.steps, p.text, p.off end
        end
        local path = m.path or (spine and frag and spine[frag])
        if not steps or not text or not off then
            r.why = "xpointer"
        elseif not path then
            r.why = "frag"
        elseif not entries[path] then
            r.why = "nofile"
        else
            if not byPath[path] then byPath[path] = {}; paths[#paths + 1] = path end
            table.insert(byPath[path], { i = i, m = m, frag = frag, steps = steps, text = text, off = off })
        end
    end
    for _, path in ipairs(paths) do
        local doc = model(entries[path])
        local ops = {}
        for _, it in ipairs(byPath[path]) do
            local r = results[it.i]
            local t, d = findText(doc, it.steps, it.text)
            if not t then
                r.why = d
            elseif it.m.node_text and it.m.node_text ~= d.str then
                r.why = "node-text"
            elseif not it.m.node_text and it.m.node_md5 and ExactMark.hash and ExactMark.hash(d.str) ~= it.m.node_md5 then
                r.why = "node-text"
            elseif not it.m.node_text and not (it.m.node_md5 and ExactMark.hash) and indexDependsOnCss(t) then
                r.why = "needs node_text"
            elseif it.off >= d.n then
                r.why = "offset"
            else
                local op, why = planWord(doc, t, it.off + 1, it.m.exact, it.m.lead)
                if op and not wordMatches(it.m.word, op.word) and not it.m.exact and op.c0 < it.off + 1 then
                    -- the mark starts inside a word (a line after a hyphen): from there
                    local from = planWord(doc, t, it.off + 1, true)
                    if from and wordMatches(it.m.word, from.word) then op = from end
                end
                if not op then
                    r.why = why
                elseif not wordMatches(it.m.word, op.word) then
                    r.why = "mismatch"
                    r.word = op.word
                else
                    op.id, op.r, op.frag = it.m.id, r, it.frag
                    ops[#ops + 1] = op
                end
            end
        end
        if #ops > 0 then
            local new = wrapOps(doc, ops, ops[1].frag)
            for _, op in ipairs(ops) do
                local r = op.r
                r.word = op.word
                if new and not op.why then
                    r.applied = true
                    r.split = op.split
                    r.xp = ExactMark.format({ frag = op.frag, steps = op.steps })
                else
                    r.why = op.why or "verify"
                end
            end
            if new then out[path] = new end
        end
    end
    -- each mark keeps how its span split the text, for toNew, toOld and affects
    for i, m in ipairs(marks) do
        if type(m) == "table" then m.split = results[i].split or false end
    end
    return out, results
end

-- ---- moving xpointers between the book and its edited copy ------------------------

-- The split records of a list of marks (marks that went through apply, its
-- results, wrap infos or splits), in the order their spans went in; nil when a
-- mark never went through apply, as its split cannot be known without the file.
local function sortedSplits(marks)
    local list = {}
    for _, m in ipairs(marks or {}) do
        local sp = m.split or (m.parent_steps and m)
        if sp then
            list[#list + 1] = sp
        elseif m.split == nil and m.applied == nil then
            return nil
        end
    end
    table.sort(list, function(a, b)
        if (a.frag or 0) ~= (b.frag or 0) then return (a.frag or 0) < (b.frag or 0) end
        return (a.seq or 0) < (b.seq or 0)
    end)
    return list
end

-- The same, kept with the list of marks it came from (a list of marks is not
-- changed once its splits are known), and by chapter: { all, byFrag, any } (any:
-- a split that names no chapter, which every xpointer must go through).
local split_memo = setmetatable({}, { __mode = "k" })
local function splitsOf(marks)
    local memo = marks and split_memo[marks]
    if memo and memo.n == #marks then return memo end
    local list = sortedSplits(marks)
    if not list then return nil end
    local by, any = {}, false
    for _, sp in ipairs(list) do
        if sp.frag then
            by[sp.frag] = by[sp.frag] or {}
            table.insert(by[sp.frag], sp)
        else
            any = true
        end
    end
    memo = { n = marks and #marks or 0, all = list, byFrag = by, any = any }
    if marks then split_memo[marks] = memo end
    return memo
end

-- The splits an xpointer of chapter `frag` goes through, in order.
local NONE = {}
local function splitsFor(memo, frag)
    if memo.any then return memo.all end
    return memo.byFrag[frag] or NONE
end

-- True when the first n steps of a path equal steps.
local function hasPrefix(path, steps)
    if #path < #steps then return false end
    for i, st in ipairs(steps) do
        if path[i].name ~= st.name or path[i].idx ~= st.idx then return false end
    end
    return true
end

-- Moves a parsed xpointer across one split, from before it to after it.
local function forward(p, sp)
    if sp.frag and p.frag ~= sp.frag then return p end
    local P = sp.parent_steps
    if not hasPrefix(p.steps, P) then return p end
    local k = #P
    local b = sp.off > 0 and 1 or 0
    local a = sp.tail > 0 and 1 or 0
    local q = { frag = p.frag, steps = copySteps(p.steps), text = p.text, off = p.off, point = p.point }
    if #p.steps == k then
        if p.text then
            local t, o = p.text, p.off
            if t > sp.text then
                q.text = t + b + a - 1
            elseif t == sp.text then
                if o < sp.off then
                    q.text = t
                elseif o < sp.off + sp.len or (o == sp.off + sp.len and a == 0) then
                    q.steps[k + 1] = { name = "span", idx = sp.span }
                    q.text, q.off = 1, o - sp.off
                else
                    q.text, q.off = t + b, o - sp.off - sp.len
                end
            end
        elseif p.point and sp.child and p.point > sp.child then
            q.point = p.point + b + a
        end
    else
        local st = q.steps[k + 1]
        if st.name == "span" and st.idx >= sp.span then st.idx = st.idx + 1 end
    end
    return q
end

-- Moves a parsed xpointer across one split, from after it back to before it.
-- Returns the xpointer and "marker" when it named the marker span itself.
local function backward(p, sp)
    if sp.frag and p.frag ~= sp.frag then return p end
    local P = sp.parent_steps
    if not hasPrefix(p.steps, P) then return p end
    local k = #P
    local b = sp.off > 0 and 1 or 0
    local a = sp.tail > 0 and 1 or 0
    local q = { frag = p.frag, steps = copySteps(p.steps), text = p.text, off = p.off, point = p.point }
    if #p.steps == k then
        if p.text then
            local t, o = p.text, p.off
            if t < sp.text then
                return q
            elseif b == 1 and t == sp.text then
                if o > sp.off then return nil, "offset" end
                return q
            elseif a == 1 and t == sp.text + b then
                if o > sp.tail then return nil, "offset" end
                q.text, q.off = sp.text, sp.off + sp.len + o
            else
                q.text = t - (b + a - 1)
            end
        elseif p.point and sp.child then
            if p.point > sp.child + b + a then
                q.point = p.point - b - a
            elseif p.point > sp.child then
                return nil, "inside"
            end
        end
        return q
    end
    local st = q.steps[k + 1]
    if st.name ~= "span" or st.idx < sp.span then return q end
    if st.idx > sp.span then
        st.idx = st.idx - 1
        return q
    end
    -- the marker itself
    if #p.steps == k + 1 and p.text then
        if p.text ~= 1 or p.off > sp.len then return nil, "offset" end
        q.steps[k + 1] = nil
        q.text, q.off = sp.text, sp.off + p.off
        return q
    end
    if #p.steps == k + 1 and not p.point then
        q.steps[k + 1] = nil
        q.text, q.off = nil, nil
        return q, "marker"
    end
    return nil, "inside"
end

-- Accepts an xpointer string or parsed table.
local function asParsed(xp)
    if type(xp) == "table" then return xp end
    return ExactMark.parse(xp)
end

-- Where an xpointer of the original book is in the edited copy (a string, every
-- index explicit), or nil and a reason. marks are the marks given to apply (it
-- leaves mark.split in each), or its results, wrap infos or their splits, for
-- the xpointer's chapter or the whole book; "nosplit" when one never went
-- through apply.
function ExactMark.toNew(xp, marks)
    local p = asParsed(xp)
    if not p then return nil, "xpointer" end
    local memo = splitsOf(marks)
    if not memo then return nil, "nosplit" end
    for _, sp in ipairs(splitsFor(memo, p.frag)) do p = forward(p, sp) end
    return ExactMark.format(p)
end

-- Where an xpointer of the edited copy is in the original book, or nil and a
-- reason. An xpointer on a marker span itself gives its parent element and the
-- flag "marker" as a second result.
function ExactMark.toOld(xp, marks)
    local p = asParsed(xp)
    if not p then return nil, "xpointer" end
    local memo = splitsOf(marks)
    if not memo then return nil, "nosplit" end
    local list = splitsFor(memo, p.frag)
    local flag
    for i = #list, 1, -1 do
        local q, f = backward(p, list[i])
        if not q then return nil, f end
        p = q
        flag = flag or f
    end
    return ExactMark.format(p), flag
end

-- True when a split at candidate { parent_steps (or steps), text, off, span?,
-- frag? } (or any of a list of them, or apply results) would change how xp resolves.
function ExactMark.affects(xp, cand)
    local p = asParsed(xp)
    if not p or not cand then return false end
    if cand[1] then
        for _, c in ipairs(cand) do
            if ExactMark.affects(p, c) then return true end
        end
        return false
    end
    if cand.split == false or cand.applied == false then return false end
    local sp = cand.split or cand
    local P = sp.parent_steps or sp.steps
    if not P or (sp.frag and p.frag ~= sp.frag) or not hasPrefix(p.steps, P) then return false end
    local k = #P
    if #p.steps == k then
        if p.text then
            return p.text > sp.text or (p.text == sp.text and p.off >= (sp.off or 0))
        end
        if p.point then return sp.child == nil or p.point > sp.child end
        return false
    end
    local st = p.steps[k + 1]
    return st.name == "span" and (sp.span == nil or st.idx >= sp.span)
end

--[[ Lab notes (exactroom-lab, crengine in KOReader's emulator, DOM 20260812):
DocFragment: one per spine itemref found in the manifest, linear="no" included,
non-XHTML items get a placeholder fragment, an unknown idref none, a file with
two bodies two. Text: "a<!-- c -->b" is two nodes; CDATA is its own node; "AT &
T" reads "AT T"; "&foo;" stays; "&amp rest" reads "&rest"; "&#150;" is an en
dash; a <p>'s leading "\n   " before text becomes one space; a tab after a tag
name hides the whole tag; a '>' inside a quoted attribute ends the tag; <br>
without a slash nests what follows; a run over 8192 characters splits after its
last space; ns:foo is foo in xpointers. ]]

return ExactMark

--[[
Panels+
File: src/wordfinder/ocr.lua
Name: WordFinder
Description: OCR recognition, candidate validation and retry policy.
Author: KristanLaimon
Year: 2026
Copyright (c) 2026 KristanLaimon
License: MIT; see the repository LICENSE file.
SPDX-License-Identifier: MIT
]]
local Timing = require("src._timing")

return function(WordFinder)
    --- @param value number Value to constrain.
    --- @param low number Lower bound (inclusive).
    --- @param high number Upper bound (inclusive).
    --- @return number clamped
    local function clamp(value, low, high)
        if value < low then
            return low
        end
        if value > high then
            return high
        end
        return value
    end

    -- Extra margin, as a fraction of the word box's height, used for the retry
    -- OCR pass (see WordFinder.readWord). A box tightened to the word's own ink
    -- can clip an anti-aliased stem or an accent, so an unreadable first pass
    -- gets a second chance with this larger crop.
    local RETRY_PAD_RATIO = 0.25

    --- Purge any cached OCREngine instances in DocCache to release Tesseract C++ DAWGs
    --- and prevent memory leak warnings on KOReader shutdown.
    function WordFinder.cleanup()
        local DocCache = package.loaded["document/doccache"]
        if type(DocCache) == "table" and DocCache.cache then
            pcall(function()
                if DocCache.cache.delete then
                    DocCache.cache:delete("ocrengine")
                end
            end)
        end
        -- The tight-crop path below uses k2pdfopt's OCR engine directly, outside
        -- DocCache. Release that engine when the viewer closes as well.
        local KOPTContext = package.loaded["ffi/koptcontext"]
        if type(KOPTContext) == "table" and KOPTContext.k2pdfopt then
            pcall(KOPTContext.k2pdfopt.k2pdfopt_tocr_end)
        end
    end

    --- Evict KOReader's own OCR-word cache entry for this exact box, before the
    --- caller passes it to `document:getOCRWord()`.
    ---
    --- `KoptInterface:getNativeOCRWord` builds its cache key by concatenating
    --- pageno/rect.x/rect.y/rect.w/rect.h with no separators between them, so
    --- two different boxes can hash to the identical string (e.g. pageno=1,
    --- x=17,y=0.5 and pageno=1,x=1,y=70.5 both produce "1170.54..."). Its cache
    --- lookup (`Cache:check`) is a blind string-key match with no value
    --- comparison, so a collision silently returns a stale, unrelated word
    --- instead of erroring or missing. This is called on every hold-word tap
    --- with a wide variety of box values -- the render crop is re-centred per
    --- tap, so even the same word's box can shift by a fraction of a pixel
    --- between two taps on it -- which makes collisions with earlier session
    --- activity a real, observed failure, not just a theoretical one. Evicting
    --- our own upcoming key first guarantees a fresh, correct OCR read instead
    --- of risking someone else's cached result.
    ---
    --- @param document table KOReader document object.
    --- @param pageno number Page number.
    --- @param box table Box about to be passed as `{sbox = box}` to `getOCRWord`.
    function WordFinder.evictOCRWordCache(document, pageno, box)
        local ok_cache, DocCache = pcall(require, "document/doccache")
        if not (ok_cache and DocCache and DocCache.cache and DocCache.cache.delete) then
            return
        end
        local ok_hash, hash = pcall(function()
            return "ocrword|" .. document.file .. "|" .. pageno .. box.x .. box.y .. box.w .. box.h
        end)
        if ok_hash and hash then
            pcall(function()
                DocCache.cache:delete(hash)
            end)
        end
    end

    --- Collapse Tesseract's raw output into a single-line, trimmed string.
    ---
    --- `getTOCRWord` returns the engine's transcription verbatim, which carries a
    --- trailing newline and can carry stray control characters. `ReaderDictionary`
    --- trims before looking a word up, but everything else the selection feeds --
    --- "Copy", "Add note", Wikipedia, the highlight text saved to the annotation
    --- list -- takes `selected_text.text` as-is, so the raw string leaks through.
    ---
    --- @param text string|nil Raw OCR output.
    --- @return string|nil word Normalized word, or nil if nothing was left.
    function WordFinder.normalizeWord(text)
        if type(text) ~= "string" then
            return nil
        end
        -- %c is byte-wise but only ever matches 0x00-0x1F/0x7F, so UTF-8
        -- continuation bytes (>= 0x80) pass through untouched.
        local word = text:gsub("%c", " ")
        word = word:gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " ")
        if word == "" then
            return nil
        end
        return word
    end

    --- Decode the UTF-8 codepoint starting at `index`, LuaJIT having no `utf8`.
    ---
    --- @param text string Subject string.
    --- @param index integer Byte index of a sequence's lead byte.
    --- @return integer codepoint
    --- @return integer next_index Byte index just past this sequence.
    local function decodeUTF8(text, index)
        local lead = text:byte(index)
        local length, codepoint
        if lead < 0x80 then
            return lead, index + 1
        elseif lead >= 0xF0 then
            length, codepoint = 4, lead - 0xF0
        elseif lead >= 0xE0 then
            length, codepoint = 3, lead - 0xE0
        elseif lead >= 0xC0 then
            length, codepoint = 2, lead - 0xC0
        else
            -- Stray continuation byte: not a valid sequence start.
            return -1, index + 1
        end
        if index + length - 1 > #text then
            return -1, #text + 1
        end
        for offset = 1, length - 1 do
            local continuation = text:byte(index + offset)
            if continuation < 0x80 or continuation > 0xBF then
                return -1, index + offset
            end
            codepoint = codepoint * 64 + (continuation - 0x80)
        end
        return codepoint, index + length
    end

    --- Whether a non-ASCII codepoint reads as a letter rather than a symbol.
    ---
    --- Only the ranges Tesseract actually emits as noise are excluded, so
    --- accented Latin, Greek, Cyrillic and CJK all still count as letters --
    --- Lua's `%a` class is ASCII-only and would reject every one of them.
    ---
    --- @param codepoint integer
    --- @return boolean is_letter
    local function isLetterCodepoint(codepoint)
        if codepoint < 0x00C0 then
            -- C1 controls plus the Latin-1 punctuation and symbol block: the
            -- guillemets, inverted marks, degree/pilcrow/middot signs that an
            -- unreadable crop comes back as.
            return false
        end
        if codepoint == 0x00D7 or codepoint == 0x00F7 then
            return false -- multiplication and division signs
        end
        if codepoint >= 0x2000 and codepoint <= 0x206F then
            return false -- general punctuation (dashes, quotes, bullets, primes)
        end
        if codepoint >= 0x2190 and codepoint <= 0x2BFF then
            return false -- arrows, mathematical operators, box drawing, misc symbols
        end
        if codepoint >= 0x3000 and codepoint <= 0x303F then
            return false -- CJK symbols and punctuation
        end
        return true
    end

    --- Whether an OCR result is worth overwriting KOReader's own selection with.
    ---
    --- Tesseract given a crop it cannot read does not fail -- it returns
    --- confident-looking punctuation soup ("|_-", "»«") or a fragment. Taking
    --- that over the document's own word makes the feature actively worse than
    --- not running, so a result has to look like a word before it is accepted:
    --- at least one letter, no more junk characters than letters, and a single
    --- token (whitespace means the box straddled a word boundary, and a phrase
    --- never resolves in a dictionary).
    ---
    --- @param text string|nil Normalized OCR word.
    --- @return boolean plausible
    function WordFinder.isPlausibleWord(text)
        if type(text) ~= "string" or text == "" then
            return false
        end
        if text:find("%s") then
            return false
        end
        local letters, junk = 0, 0
        local index = 1
        while index <= #text do
            local codepoint, next_index = decodeUTF8(text, index)
            index = next_index
            if codepoint < 0 then
                junk = junk + 1
            elseif codepoint < 0x80 then
                local char = string.char(codepoint)
                if char:match("%a") then
                    letters = letters + 1
                elseif not char:match("[%d'%-%.,!%?]") then
                    junk = junk + 1
                end
            elseif isLetterCodepoint(codepoint) then
                letters = letters + 1
            else
                junk = junk + 1
            end
        end
        return letters > 0 and junk <= letters
    end

    --- Grow a word box outwards by a fraction of its height, clamped to the page.
    ---
    --- @param box PPRect Word box in native page coordinates.
    --- @param ratio number Margin to add on each side, as a fraction of `box.h`.
    --- @param native PPPageSize|nil Native page dimensions to clamp against.
    --- @return PPRect padded
    function WordFinder.padBox(box, ratio, native)
        local margin = math.max(1, box.h * ratio)
        local x0 = box.x - margin
        local y0 = box.y - margin
        local x1 = box.x + box.w + margin
        local y1 = box.y + box.h + margin
        if native and native.w and native.h then
            x0 = clamp(x0, 0, native.w)
            y0 = clamp(y0, 0, native.h)
            x1 = clamp(x1, 0, native.w)
            y1 = clamp(y1, 0, native.h)
        else
            x0 = math.max(0, x0)
            y0 = math.max(0, y0)
        end
        return { x = x0, y = y0, w = x1 - x0, h = y1 - y0 }
    end

    --- Return the single bounded retry crop used after an unreadable tight crop.
    --- Exposed so the dataset harness can schedule the same request in a batch;
    --- the reader still owns the policy and the Go worker only recognizes pixels.
    --- @param box PPRect Tight OCR crop.
    --- @param native PPPageSize|nil Native page dimensions.
    --- @return PPRect retry_box
    function WordFinder.retryBox(box, native)
        return WordFinder.padBox(box, RETRY_PAD_RATIO, native)
    end

    -- A session owns at most one small OCR bitmap. It lives for one lookup only;
    -- changing crop or resolution frees it before allocating its replacement.
    local function releaseOCRSession(session)
        if session.context then
            pcall(session.context.free, session.context)
            session.context = nil
        end
    end

    --- OCR a single box through KOReader's bundled engine and normalize the result.
    ---
    --- @param document table KOReader document object.
    --- @param pageno number Page number.
    --- @param box PPRect Box in native page coordinates.
    --- @param bundled_language string|nil Bundled model to use, or nil for KOReader's model.
    --- @param native PPPageSize|nil Page bounds for the horizontal OCR margin.
    --- @param options table|nil Optional render height and Tesseract segmentation mode.
    --- @return string|nil word Normalized word, or nil if OCR produced nothing.
    function WordFinder.ocrWord(document, pageno, box, bundled_language, native, options)
        -- KOReader's getNativeOCRWord adds 30% of the box height on *every* side
        -- before recognizing text. On tightly-set manga that routinely brings a
        -- neighbouring word into the crop. Its kopt context is already available
        -- on paging documents, so render the actual found box and ask the same
        -- OCR engine to treat it as a single word.
        local interface = document and document.koptinterface
        local backend = document and document._document
        if interface and interface.createContext and backend and backend.openPage and box.h > 0 then
            local context, page
            local session = options and options.session
            local render_height = options and options.height or 30
            local ok, raw = pcall(function()
                local bbox = { x0 = box.x, y0 = box.y, x1 = box.x + box.w, y1 = box.y + box.h }
                local datadir, language = interface.tessocr_data, document.configurable.doc_language
                local bundled_dir, bundled_model
                if session and session.model_resolved then
                    bundled_dir, bundled_model = session.bundled_dir, session.bundled_model
                else
                    bundled_dir, bundled_model = WordFinder.selectedModel(bundled_language)
                    if session then
                        session.model_resolved = true
                        session.bundled_dir, session.bundled_model = bundled_dir, bundled_model
                    end
                end
                if bundled_dir then
                    datadir, language = bundled_dir, bundled_model
                    -- Keep the measured English crop adjustment; other languages
                    -- use the exact found box until their accuracy is measured.
                    if bundled_language == "eng" then
                        local margin = box.h * 0.05
                        bbox.x0 = math.max(0, bbox.x0 - margin)
                        bbox.x1 = math.min(native and native.w or math.huge, bbox.x1 + margin)
                    end
                end
                if session and session.box == box and session.height == render_height then
                    context = session.context
                end
                if not context then
                    if session then
                        releaseOCRSession(session)
                    end
                    context = interface:createContext(document, pageno, bbox)
                    context:setZoom(render_height / box.h)
                    page = backend:openPage(pageno)
                    page:getPagePix(context, document.render_mode, document.configurable.background_cleanup)
                    if session then
                        session.context, session.box, session.height = context, box, render_height
                    end
                end
                local width, height = context:getPageDim()
                return context:getTOCRWord(
                    "src",
                    0,
                    0,
                    width,
                    height,
                    datadir,
                    language,
                    options and options.mode or 8,
                    0,
                    1
                )
            end)
            if page then
                pcall(page.close, page)
            end
            if context and (not session or not ok or not raw or raw == "") then
                pcall(context.free, context)
                if session then
                    session.context = nil
                end
            end
            if ok and raw and raw ~= "" then
                return WordFinder.normalizeWord(raw)
            end
        end

        -- A line must not fall back to the document's single-word OCR mode.
        if options and options.mode == 7 then
            return nil
        end
        WordFinder.evictOCRWordCache(document, pageno, box)
        local ok, raw = pcall(document.getOCRWord, document, pageno, { sbox = box })
        if not ok then
            return nil
        end
        return WordFinder.normalizeWord(raw)
    end

    -- Compare candidate letters without changing the returned transcription.
    local function candidateKey(word)
        if not word then
            return ""
        end
        local key, index = {}, 1
        while index <= #word do
            local codepoint, next_index = decodeUTF8(word, index)
            if
                (codepoint >= 0 and codepoint < 128 and string.char(codepoint):match("%w"))
                or (codepoint >= 128 and isLetterCodepoint(codepoint))
            then
                key[#key + 1] = word:sub(index, next_index - 1):upper()
            end
            index = next_index
        end
        return table.concat(key)
    end

    --- Normalize an OCR candidate for agreement checks between render sizes.
    --- Dataset tests use this to schedule only the character-mode jobs that the
    --- reader's real `readWord` path would request.
    --- @param word string|nil OCR candidate.
    --- @return string key
    function WordFinder.ocrCandidateKey(word)
        return candidateKey(word)
    end

    --- Expand a word to its nearby dialogue block. Split wide line gaps before
    --- joining adjacent lines so side-by-side bubbles remain separate.
    function WordFinder.readPhrase(document, pageno, seed, bundled_language)
        local boxes = document:getTextBoxes(pageno, seed)
        local runs = {}
        for _, line in ipairs(boxes or {}) do
            local run
            for _, word in ipairs(line) do
                local h = line.y1 - line.y0
                if not run or word.x0 - run.x1 > h * 1.5 then
                    run = { x0 = word.x0, x1 = word.x1, y0 = line.y0, y1 = line.y1, words = {} }
                    runs[#runs + 1] = run
                end
                run.x1 = word.x1
                if not WordFinder.normalizeWord(word.word) then
                    run.needs_ocr = true
                end
                run.words[#run.words + 1] = word.word or ""
                run.word_boxes = run.word_boxes or {}
                run.word_boxes[#run.word_boxes + 1] = word
            end
        end
        local cx, cy = seed.x + seed.w / 2, seed.y + seed.h / 2
        local selected, first = {}, nil
        for i, run in ipairs(runs) do
            if cx >= run.x0 and cx <= run.x1 and cy >= run.y0 and cy <= run.y1 then
                first = i
                selected[i] = true
                break
            end
        end
        if not first then
            return nil
        end
        local changed = true
        while changed do
            changed = false
            for i, run in ipairs(runs) do
                if not selected[i] then
                    for j in pairs(selected) do
                        local other = runs[j]
                        local h = math.min(run.y1 - run.y0, other.y1 - other.y0)
                        local gap = math.max(run.y0 - other.y1, other.y0 - run.y1)
                        local overlap = math.min(run.x1, other.x1) - math.max(run.x0, other.x0)
                        if
                            gap >= 0
                            and gap <= h * 0.9
                            and overlap > 0
                            and math.max(run.y1 - run.y0, other.y1 - other.y0) <= h * 1.6
                        then
                            selected[i], changed = true, true
                            break
                        end
                    end
                end
            end
        end
        local phrase_runs = {}
        for i in pairs(selected) do
            phrase_runs[#phrase_runs + 1] = runs[i]
        end
        table.sort(phrase_runs, function(a, b)
            return a.y0 < b.y0 or (a.y0 == b.y0 and a.x0 < b.x0)
        end)
        local parts, sboxes = {}, {}
        for _, run in ipairs(phrase_runs) do
            local box = { x = run.x0, y = run.y0, w = run.x1 - run.x0, h = run.y1 - run.y0 }
            local text = WordFinder.normalizeWord(table.concat(run.words, " "))
            if document.is_bitmap_source and run.needs_ocr then
                -- The native single-word API may return only the first word even in
                -- line mode. Read only the selected dialogue's word boxes individually.
                local words = {}
                for _, word in ipairs(run.word_boxes) do
                    local word_box = { x = word.x0, y = word.y0, w = word.x1 - word.x0, h = word.y1 - word.y0 }
                    local recognized = WordFinder.ocrWord(document, pageno, word_box, bundled_language)
                    if not recognized then
                        return nil
                    end
                    words[#words + 1] = recognized
                end
                text = table.concat(words, " ")
            elseif run.needs_ocr or not text then
                text = WordFinder.ocrWord(document, pageno, box, bundled_language, nil, { mode = 7, height = 40 })
            end
            if not text then
                return nil
            end
            parts[#parts + 1], sboxes[#sboxes + 1] = text, box
        end
        return table.concat(parts, " "), sboxes
    end

    --- Read a located word using its tight OCR crop when available.
    --- Bundled English compares 30px and 20px reads and breaks disagreements
    --- with character mode. An unreadable result gets one padded retry.
    --- @param document table KOReader document object.
    --- @param pageno number Page number.
    --- @param box PPRect Word highlight with optional tighter ocr_box.
    --- @param native PPPageSize|nil Native page dimensions, to clamp the retry box.
    --- @param bundled_language string|nil Bundled model, or nil for KOReader's model.
    --- @return string|nil word Plausible OCR word, or nil.
    local function readWord(document, pageno, box, native, bundled_language, session)
        -- The highlight includes a comfortable margin. Recognition needs the
        -- tighter ink crop so neighbouring lines cannot enter that margin.
        local ocr_box = box.ocr_box or box
        local word = WordFinder.ocrWord(document, pageno, ocr_box, bundled_language, native, { session = session })
        if
            bundled_language == "eng"
            and session.bundled_model
            and document.koptinterface
            and document.koptinterface.createContext
        then
            -- Comic lettering can produce a plausible but wrong first result.
            -- Compare two resolutions; a third character-mode read breaks a
            -- disagreement. Equal candidates keep the first transcription.
            local smaller = WordFinder.ocrWord(
                document,
                pageno,
                ocr_box,
                bundled_language,
                native,
                { height = 20, session = session }
            )
            local first_key, second_key = candidateKey(word), candidateKey(smaller)
            if first_key == "" or first_key ~= second_key then
                local character = WordFinder.ocrWord(
                    document,
                    pageno,
                    ocr_box,
                    bundled_language,
                    native,
                    { height = 20, mode = 10, session = session }
                )
                local third_key = candidateKey(character)
                if second_key ~= "" and second_key == third_key then
                    word = smaller
                elseif first_key == "" then
                    word = second_key ~= "" and smaller or character
                end
            end
        end
        if WordFinder.isPlausibleWord(word) then
            return word
        end

        local retry_box = WordFinder.retryBox(ocr_box, native)
        local retry_word =
            WordFinder.ocrWord(document, pageno, retry_box, bundled_language, native, { session = session })
        if Timing.enabled then
            WordFinder.logDiagnostic("retry OCR with padded box", {
                first = tostring(word),
                retry = tostring(retry_word),
                box = string.format(
                    "(x=%.1f,y=%.1f,w=%.1f,h=%.1f)",
                    retry_box.x,
                    retry_box.y,
                    retry_box.w,
                    retry_box.h
                ),
            })
        end
        if WordFinder.isPlausibleWord(retry_word) then
            return retry_word
        end
        return nil
    end

    function WordFinder.readWord(document, pageno, box, native, bundled_language)
        local session = {}
        local ok, word = pcall(readWord, document, pageno, box, native, bundled_language, session)
        releaseOCRSession(session)
        if not ok then
            error(word)
        end
        return word
    end
end

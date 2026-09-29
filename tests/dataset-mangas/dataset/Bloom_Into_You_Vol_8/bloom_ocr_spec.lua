--[[
Panels+
File: tests/dataset-mangas/dataset/Bloom_Into_You_Vol_8/bloom_ocr_spec.lua
Name: Bloom Into You OCR dataset spec
Description: Exercises WordFinder against the annotated word rectangles on real pages.
License: MIT; see the repository LICENSE file.
SPDX-License-Identifier: MIT
]]

local framework = require("tests.PanelsPlusTestFramework")
local describe, it, assert = framework.describe, framework.it, framework.assert
local JSON = require("tests.helpers.json")
local WordFinder = require("src._wordfinder")
local OCRBenchmark = require("tests.dataset-mangas.ocr_benchmark")

local BOOK_DIR = "tests/dataset-mangas/dataset/Bloom_Into_You_Vol_8"
local PAGE_W, PAGE_H = 1264, 1680
local NATIVE_OCR = os.getenv("PANELSPLUS_OCR_NATIVE") == "1"
local MODEL_DIR = os.getenv("PANELSPLUS_OCR_TESSDATA")
local CANDIDATE_DIR = os.getenv("PANELSPLUS_OCR_CANDIDATE")
local ocr_seconds, ocr_calls = 0, 0
local page_cache, box_cache = {}, {}
local selected_pages = os.getenv("PANELSPLUS_OCR_PAGES")
local go_batch_results
local go_batch_attempted = false
local OCR_RESULT_CACHE = "tests/dataset-mangas/.cache/ocr-results-v1.json"
local fingerprint_cache = {}

local function includePage(index)
    return not selected_pages or ("," .. selected_pages .. ","):find("," .. index .. ",", 1, true) ~= nil
end

local function quote(value)
    return "'" .. value:gsub("'", "'\\''") .. "'"
end

local function checkCoverage(evaluated, total)
    assert.is_true(evaluated > 0, "no annotated word images were available")
    if evaluated < total then
        print(string.format("  PARTIAL OCR DATASET: %d/%d words available", evaluated, total))
    end
    if os.getenv("PANELSPLUS_REQUIRE_DATASETS") == "1" then
        assert.equals(total, evaluated, "all annotated OCR pages are required")
    end
end

local function recordScore(metric, correct, evaluated, total)
    if CANDIDATE_DIR then
        print("  candidate model evaluation: benchmark record was not updated")
        return
    end
    local ok, message = OCRBenchmark.checkAndUpdate(BOOK_DIR, metric, {
        correct = correct,
        evaluated = evaluated,
        total = total,
    })
    if message then
        print("  " .. message)
    end
    assert.is_true(ok, message)
end

local function loadPage(index)
    if page_cache[index] then
        return page_cache[index][1], page_cache[index][2]
    end
    local path = string.format("%s/%02d.png", BOOK_DIR, index - 1)
    local file = io.open(path, "rb")
    if not file then
        return nil
    end
    file:close()
    local pipe = io.popen(string.format("magick '%s' -depth 8 gray:-", path), "r")
    assert.is_not_nil(pipe)
    local pixels = pipe:read("*a")
    assert.is_true(pipe:close(), "ImageMagick failed to decode " .. path)
    assert.equals(PAGE_W * PAGE_H, #pixels, "unexpected image dimensions in " .. path)
    page_cache[index] = { pixels, path }
    return pixels, path
end

local function findBox(document, page, expected)
    local key = string.format("%d:%.4f:%.4f", page, expected.x + expected.w / 2, expected.y + expected.h / 2)
    if not box_cache[key] then
        local box, native =
            WordFinder.findWordBox(document, page, expected.x + expected.w / 2, expected.y + expected.h / 2)
        box_cache[key] = { box or false, native or false }
    end
    local cached = box_cache[key]
    return cached[1] or nil, cached[2] or nil
end

local function fakeDocument(pixels, path, ocr_backend)
    local function readCrop(rect, zoom, datadir, language, mode)
        if CANDIDATE_DIR and language == "eng_fast" then
            datadir = CANDIDATE_DIR
        end
        if ocr_backend and not NATIVE_OCR then
            return ocr_backend(rect, zoom, datadir, language, mode)
        end
        local x0 = math.max(0, math.floor(rect.x0))
        local y0 = math.max(0, math.floor(rect.y0))
        local x1 = math.min(PAGE_W, math.ceil(rect.x1))
        local y1 = math.min(PAGE_H, math.ceil(rect.y1))
        local scaled_h = math.max(1, math.floor((y1 - y0) * zoom + 0.5))
        local scaled_w = math.max(1, math.floor((x1 - x0) * zoom + 0.5))
        local command = string.format("magick %s -crop %dx%d+%d+%d +repage", quote(path), x1 - x0, y1 - y0, x0, y0)
        if NATIVE_OCR then
            -- Run the actual bundled OCR library, with the renderer still
            -- represented by ImageMagick. This is not a device UI test.
            local KOPTContext = require("ffi/koptcontext")
            local ffi = require("ffi")
            local pipe = io.popen(command .. string.format(" -resize %dx%d! -depth 8 gray:-", scaled_w, scaled_h), "r")
            assert.is_not_nil(pipe)
            local crop_pixels = pipe:read("*a")
            assert.is_true(pipe:close(), "crop rendering failed")
            assert.equals(scaled_w * scaled_h, #crop_pixels)
            local context = KOPTContext.new()
            context:setDeviceDPI(300)
            context.src.width, context.src.height, context.src.bpp = scaled_w, scaled_h, 8
            KOPTContext.k2pdfopt.bmp_alloc(context.src)
            local stride = KOPTContext.k2pdfopt.bmp_bytewidth(context.src)
            for y = 0, scaled_h - 1 do
                ffi.copy(context.src.data + y * stride, crop_pixels:sub(y * scaled_w + 1, (y + 1) * scaled_w), scaled_w)
            end
            local started = os.clock()
            local ok, word =
                pcall(context.getTOCRWord, context, "src", 0, 0, scaled_w, scaled_h, datadir, language, mode, 0, 1)
            ocr_seconds = ocr_seconds + os.clock() - started
            ocr_calls = ocr_calls + 1
            context:free()
            assert.is_true(ok, tostring(word))
            return word
        end
        -- Match k2pdfopt's ocrtess_ocrwords_from_bmp8: fixed render dimensions,
        -- a white border of at least six pixels, width aligned to four, and
        -- the first recognized word. The old bare CLI crop omitted this border.
        local border = math.max(6, math.floor(scaled_w / 40))
        local bordered_w = math.ceil((scaled_w + 2 * border) / 4) * 4
        command = command
            .. string.format(
                " -resize %dx%d! -bordercolor white -border %d -gravity northwest -background white -extent %dx%d",
                scaled_w,
                scaled_h,
                border,
                bordered_w,
                scaled_h + 2 * border
            )
            .. " png:- | tesseract stdin stdout --psm "
            .. tostring(mode == -1 and 6 or mode)
            .. " --dpi 300"
            .. " -l "
            .. quote(language)
            .. (datadir and " --tessdata-dir " .. quote(datadir) or "")
            .. " -c tessedit_create_tsv=1 2>/dev/null"
        local pipe = io.popen(command, "r")
        if not pipe then
            return nil
        end
        local tsv = pipe:read("*a")
        assert.is_true(pipe:close(), "Tesseract failed; check the selected model directory")
        for line in tsv:gmatch("[^\r\n]+") do
            if line:match("^5\t") then
                return line:match("[^\t]*$")
            end
        end
        return nil
    end
    local document = {
        configurable = { doc_language = "eng", background_cleanup = 0 },
        render_mode = 0,
        getNativePageDimensions = function()
            return { w = PAGE_W, h = PAGE_H }
        end,
        transformRect = function(_, rect, zoom)
            return {
                x = math.floor(rect.x * zoom + 0.001),
                y = math.floor(rect.y * zoom + 0.001),
                w = math.ceil(rect.w * zoom - 0.001),
                h = math.ceil(rect.h * zoom - 0.001),
            }
        end,
        renderPage = function(_, _, rect, zoom)
            local scaled = rect.scaled_rect
            local bb = {
                w = scaled.w,
                h = scaled.h,
                getType = function()
                    return nil
                end,
                getRotation = function()
                    return 0
                end,
                getInverse = function()
                    return 0
                end,
                getPixel = function(_, x, y)
                    local page_x = math.floor((scaled.x + x) / zoom)
                    local page_y = math.floor((scaled.y + y) / zoom)
                    local value = pixels:byte(page_y * PAGE_W + page_x + 1) or 255
                    return {
                        getColor8 = function()
                            return { a = value }
                        end,
                    }
                end,
            }
            return { bb = bb }
        end,
        getOCRWord = function(_, _, wrapped)
            local box = wrapped.sbox
            local padding = math.floor(box.h * 0.3)
            return readCrop({
                x0 = box.x - padding,
                y0 = box.y - padding,
                x1 = box.x + box.w + padding,
                y1 = box.y + box.h + padding,
            }, 30 / box.h, MODEL_DIR, "eng", -1)
        end,
    }
    document.koptinterface = {
        tessocr_data = MODEL_DIR,
        createContext = function(_, _, _, bbox)
            local context = { zoom = 1 }
            function context:setZoom(zoom)
                self.zoom = zoom
            end
            function context:getPageDim()
                return math.floor((bbox.x1 - bbox.x0) * self.zoom + 0.5),
                    math.floor((bbox.y1 - bbox.y0) * self.zoom + 0.5)
            end
            function context:getTOCRWord(_, _, _, _, _, datadir, language, mode)
                return readCrop(bbox, self.zoom, datadir, language, mode)
            end
            function context:free() end
            return context
        end,
    }
    document._document = {
        openPage = function()
            return { getPagePix = function() end, close = function() end }
        end,
    }
    return document
end

local function commandSucceeded(result)
    return result == true or result == 0
end

local function commandFirstLine(command)
    local pipe = io.popen(command, "r")
    if not pipe then
        return "unknown"
    end
    local line = pipe:read("*l") or "unknown"
    pipe:close()
    return line
end

local function fileFingerprint(path)
    if fingerprint_cache[path] then
        return fingerprint_cache[path]
    end
    local line = commandFirstLine("sha256sum " .. quote(path) .. " 2>/dev/null")
    local hash = line:match("^(%x+)")
    if not hash then
        line = commandFirstLine("shasum -a 256 " .. quote(path) .. " 2>/dev/null")
        hash = line:match("^(%x+)")
    end
    hash = hash or "missing"
    fingerprint_cache[path] = hash
    return hash
end

local function systemTessdataDirectory()
    if fingerprint_cache.system_tessdata_dir then
        return fingerprint_cache.system_tessdata_dir
    end
    local pipe = io.popen("tesseract --list-langs 2>/dev/null", "r")
    local output = pipe and pipe:read("*a") or ""
    if pipe then
        pipe:close()
    end
    local directory = output:match('in "([^"]+)"') or output:match("in ([^\r\n]+)") or ""
    fingerprint_cache.system_tessdata_dir = directory
    return directory
end

local function toolFingerprint()
    if not fingerprint_cache.tools then
        fingerprint_cache.tools = table.concat({
            commandFirstLine("magick -version 2>/dev/null"),
            commandFirstLine("tesseract --version 2>/dev/null"),
        }, "|")
    end
    return fingerprint_cache.tools
end

local function requestKeyAndJob(path, rect, zoom, datadir, language, mode)
    if CANDIDATE_DIR and language == "eng_fast" then
        datadir = CANDIDATE_DIR
    end
    local x0 = math.max(0, math.floor(rect.x0))
    local y0 = math.max(0, math.floor(rect.y0))
    local x1 = math.min(PAGE_W, math.ceil(rect.x1))
    local y1 = math.min(PAGE_H, math.ceil(rect.y1))
    local width, height = x1 - x0, y1 - y0
    local scaled_h = math.max(1, math.floor(height * zoom + 0.5))
    local scaled_w = math.max(1, math.floor(width * zoom + 0.5))
    local model_dir = datadir or systemTessdataDirectory()
    local model_path = model_dir ~= "" and (model_dir .. "/" .. language .. ".traineddata") or language
    local key = table.concat({
        "v1",
        toolFingerprint(),
        path,
        fileFingerprint(path),
        x0,
        y0,
        width,
        height,
        scaled_w,
        scaled_h,
        datadir or "",
        language,
        fileFingerprint(model_path),
        mode,
    }, "|")
    return key,
        {
            image = path,
            x = x0,
            y = y0,
            width = width,
            height = height,
            scaled_width = scaled_w,
            scaled_height = scaled_h,
            data_dir = datadir or "",
            language = language,
            page_mode = mode == -1 and 6 or mode,
        }
end

local function buildGoHelper()
    local probe = os.execute("command -v go >/dev/null 2>&1")
    if not commandSucceeded(probe) then
        return nil, "Go is unavailable"
    end
    local cache_dir = "tests/dataset-mangas/.cache"
    local helper = cache_dir .. "/ocr_worker"
    os.execute("mkdir -p " .. quote(cache_dir))
    local result =
        os.execute("GOCACHE=/tmp/panelsplus-go-build-cache go build -o " .. quote(helper) .. " ./tools/ocr_worker")
    if not commandSucceeded(result) then
        return nil, "Go OCR helper build failed"
    end
    return helper
end

local function runGoBatch(helper, jobs, key_by_id)
    if #jobs == 0 then
        return {}
    end

    local request_path = os.tmpname()
    local request_file = io.open(request_path, "wb")
    assert.is_not_nil(request_file, "could not create the Go OCR request file")
    request_file:write(JSON.encode(jobs))
    request_file:close()

    local worker_count = math.max(1, math.floor(tonumber(os.getenv("PANELSPLUS_OCR_WORKERS")) or 4))
    local command = string.format(
        "MAGICK_THREAD_LIMIT=1 %s --input %s --workers %d",
        quote(helper),
        quote(request_path),
        worker_count
    )
    local pipe = io.popen(command, "r")
    assert.is_not_nil(pipe, "could not start the Go OCR helper")
    local output = pipe:read("*a")
    local succeeded = pipe:close()
    os.remove(request_path)
    assert.is_true(succeeded, "Go OCR helper failed")

    local by_key = {}
    for _, item in ipairs(JSON.decode(output)) do
        assert.equals("", item.error, "Go OCR request failed")
        local key = key_by_id[item.id]
        assert.is_not_nil(key, "Go OCR helper returned an unknown request")
        by_key[key] = item.text ~= "" and item.text or false
    end
    return by_key
end

local function newJobBatch(known_results, requested_keys)
    local batch = { jobs = {}, id_by_key = {}, key_by_id = {} }
    function batch:add(path, rect, zoom, datadir, language, mode)
        local key, job = requestKeyAndJob(path, rect, zoom, datadir, language, mode)
        requested_keys[key] = true
        if known_results[key] == nil and not self.id_by_key[key] then
            local id = tostring(#self.jobs + 1)
            self.id_by_key[key], self.key_by_id[id] = id, key
            job.id = id
            self.jobs[#self.jobs + 1] = job
        end
        return key
    end
    return batch
end

local function loadOCRResultCache()
    local file = io.open(OCR_RESULT_CACHE, "rb")
    if not file then
        return {}
    end
    local content = file:read("*a")
    file:close()
    if not content or not content:find("%S") then
        return {}
    end
    local ok, decoded = pcall(JSON.decode, content)
    return ok and type(decoded) == "table" and decoded or {}
end

local function saveOCRResultCache(results)
    local temporary = OCR_RESULT_CACHE .. ".tmp"
    local file = io.open(temporary, "wb")
    assert.is_not_nil(file, "could not write the OCR result cache")
    file:write(JSON.encode(results), "\n")
    file:close()
    assert.is_true(os.rename(temporary, OCR_RESULT_CACHE), "could not publish the OCR result cache")
end

local function mergeResults(destination, source)
    for key, value in pairs(source) do
        destination[key] = value
    end
end

local function resultText(results, key)
    local value = results[key]
    assert.is_not_nil(value, "OCR crop was not returned by the Go batch")
    return value or nil
end

local function prepareGoBatch(annotations)
    if go_batch_attempted then
        return go_batch_results
    end
    go_batch_attempted = true
    if NATIVE_OCR or os.getenv("PANELSPLUS_DISABLE_GO_OCR") == "1" then
        return nil
    end

    local helper, unavailable = buildGoHelper()
    if not helper then
        print("  Go OCR batching disabled: " .. unavailable .. "; using sequential Lua subprocesses")
        return nil
    end

    local entries = {}
    for _, page in ipairs(annotations) do
        if page.word and #page.word > 0 and includePage(page.page_index) then
            local pixels, path = loadPage(page.page_index)
            if pixels then
                local document = fakeDocument(pixels, path)
                for _, expected in ipairs(page.word) do
                    local box, native = findBox(document, page.page_index, expected)
                    if box then
                        entries[#entries + 1] = {
                            page = page.page_index,
                            pixels = pixels,
                            path = path,
                            native = native,
                            ocr_box = box.ocr_box or box,
                        }
                    end
                end
            end
        end
    end

    local results, total_jobs = loadOCRResultCache(), 0
    local requested_keys = {}
    local function record(entry, batch, crop, bundled_language, options)
        local captured_key
        local document = fakeDocument(entry.pixels, entry.path, function(rect, zoom, datadir, language, mode)
            captured_key = batch:add(entry.path, rect, zoom, datadir, language, mode)
            return "recorded"
        end)
        WordFinder.ocrWord(document, entry.page, crop, bundled_language, entry.native, options)
        assert.is_not_nil(captured_key, "WordFinder did not issue the expected OCR request")
        return captured_key
    end

    -- Stage 1 contains the requests every lookup performs: one configured
    -- read and the bundled model's two comparison resolutions.
    local stage = newJobBatch(results, requested_keys)
    for _, entry in ipairs(entries) do
        entry.configured = record(entry, stage, entry.ocr_box, nil)
        entry.bundled = record(entry, stage, entry.ocr_box, "eng")
        entry.bundled_small = record(entry, stage, entry.ocr_box, "eng", { height = 20 })
    end
    mergeResults(results, runGoBatch(helper, stage.jobs, stage.key_by_id))
    total_jobs = total_jobs + #stage.jobs

    -- Stage 2 mirrors readWord's conditional work: configured OCR retries only
    -- unreadable words, while bundled OCR asks character mode only when its
    -- 30px and 20px candidates disagree.
    stage = newJobBatch(results, requested_keys)
    for _, entry in ipairs(entries) do
        local configured = resultText(results, entry.configured)
        if not WordFinder.isPlausibleWord(configured) then
            entry.configured_retry = record(entry, stage, WordFinder.retryBox(entry.ocr_box, entry.native), nil)
        end
        local first = resultText(results, entry.bundled)
        local smaller = resultText(results, entry.bundled_small)
        local first_key = WordFinder.ocrCandidateKey(first)
        local second_key = WordFinder.ocrCandidateKey(smaller)
        if first_key == "" or first_key ~= second_key then
            entry.bundled_character = record(entry, stage, entry.ocr_box, "eng", { height = 20, mode = 10 })
        end
    end
    mergeResults(results, runGoBatch(helper, stage.jobs, stage.key_by_id))
    total_jobs = total_jobs + #stage.jobs

    -- Only the bundled candidates still rejected after their agreement check
    -- need the padded retry used by the production path.
    stage = newJobBatch(results, requested_keys)
    for _, entry in ipairs(entries) do
        local word = resultText(results, entry.bundled)
        if entry.bundled_character then
            local smaller = resultText(results, entry.bundled_small)
            local character = resultText(results, entry.bundled_character)
            local first_key = WordFinder.ocrCandidateKey(word)
            local second_key = WordFinder.ocrCandidateKey(smaller)
            local third_key = WordFinder.ocrCandidateKey(character)
            if second_key ~= "" and second_key == third_key then
                word = smaller
            elseif first_key == "" then
                word = second_key ~= "" and smaller or character
            end
        end
        if not WordFinder.isPlausibleWord(word) then
            entry.bundled_retry = record(entry, stage, WordFinder.retryBox(entry.ocr_box, entry.native), "eng")
        end
    end
    mergeResults(results, runGoBatch(helper, stage.jobs, stage.key_by_id))
    total_jobs = total_jobs + #stage.jobs

    saveOCRResultCache(results)
    local requested_count = 0
    for _ in pairs(requested_keys) do
        requested_count = requested_count + 1
    end
    local worker_count = math.max(1, math.floor(tonumber(os.getenv("PANELSPLUS_OCR_WORKERS")) or 4))
    print(
        string.format(
            "  Go OCR batch: %d new, %d cached crops with %d workers",
            total_jobs,
            requested_count - total_jobs,
            worker_count
        )
    )
    go_batch_results = results
    return go_batch_results
end

local function batchBackend(path, results)
    return function(rect, zoom, datadir, language, mode)
        local key = requestKeyAndJob(path, rect, zoom, datadir, language, mode)
        local result = results[key]
        assert.is_not_nil(result, "OCR crop was not present in the Go batch")
        return result or nil
    end
end

local function intersection(a, b)
    return math.max(0, math.min(a.x + a.w, b.x + b.w) - math.max(a.x, b.x))
        * math.max(0, math.min(a.y + a.h, b.y + b.h) - math.max(a.y, b.y))
end

describe("Bloom Into You annotated word boxes", function()
    it("locates the annotated words without including their neighbours", function()
        local file = io.open(BOOK_DIR .. "/annotation.json", "r")
        assert.is_not_nil(file)
        local annotations = JSON.decode(file:read("*a"))[1].pages
        file:close()
        local evaluated, good, total = 0, 0, 0
        local failures = {}
        for _, page in ipairs(annotations) do
            total = total + #(page.word or {})
            if page.word and #page.word > 0 and includePage(page.page_index) then
                local pixels, path = loadPage(page.page_index)
                if pixels then
                    local document = fakeDocument(pixels, path)
                    for _, expected in ipairs(page.word) do
                        local actual = findBox(document, page.page_index, expected)
                        evaluated = evaluated + 1
                        local overlap = actual and intersection(actual, expected) or 0
                        local coverage = overlap / (expected.w * expected.h)
                        local extra = actual and (actual.w * actual.h - overlap) / (expected.w * expected.h)
                            or math.huge
                        if coverage >= 0.75 and extra <= 0.80 then
                            good = good + 1
                        else
                            local diag = WordFinder.last_diagnostics or {}
                            failures[#failures + 1] = string.format(
                                "page %d %s: coverage %.2f extra %.2f box %s threshold %s median %s line %s shear %s gaps %s reason %s",
                                page.page_index,
                                expected.text or "?",
                                coverage,
                                extra,
                                actual and string.format("%.1f,%.1f %.1fx%.1f", actual.x, actual.y, actual.w, actual.h)
                                    or "nil",
                                tostring(diag.gap_threshold),
                                tostring(diag.median_gap),
                                tostring(diag.line_h),
                                tostring(diag.shear),
                                table.concat(diag.gaps or {}, ","),
                                tostring(diag.abort_reason)
                            )
                        end
                    end
                end
            end
        end
        checkCoverage(evaluated, total)
        print(string.format("  OCR boxes: %d/%d matched", good, evaluated))
        for _, failure in ipairs(failures) do
            print("  " .. failure)
        end
        recordScore("word_boxes", good, evaluated, total)
        assert.is_true(good >= math.ceil(evaluated * 0.95), "annotated word-box accuracy must reach 95%")
    end)

    local function checkText(bundled_language)
        local file = io.open(BOOK_DIR .. "/annotation.json", "r")
        assert.is_not_nil(file)
        local annotations = JSON.decode(file:read("*a"))[1].pages
        file:close()
        local batch_results = prepareGoBatch(annotations)
        local evaluated, correct, total = 0, 0, 0
        ocr_seconds, ocr_calls = 0, 0
        for _, page in ipairs(annotations) do
            total = total + #(page.word or {})
            if page.word and #page.word > 0 and includePage(page.page_index) then
                local pixels, path = loadPage(page.page_index)
                if pixels then
                    local document =
                        fakeDocument(pixels, path, batch_results and batchBackend(path, batch_results) or nil)
                    for _, expected in ipairs(page.word) do
                        local box, native = findBox(document, page.page_index, expected)
                        local actual = box
                            and WordFinder.readWord(document, page.page_index, box, native, bundled_language)
                        local normalized_actual = actual and actual:upper():gsub("[^%w]", "") or ""
                        local normalized_expected = expected.text:upper():gsub("[^%w]", "")
                        evaluated = evaluated + 1
                        -- A punctuation-only annotation must not match an
                        -- empty/failed recognition merely because both lose
                        -- all characters during normalization.
                        local matches = normalized_expected ~= "" and normalized_actual == normalized_expected
                            or normalized_expected == "" and actual == WordFinder.normalizeWord(expected.text)
                        if matches then
                            correct = correct + 1
                        else
                            print(
                                string.format(
                                    "  page %d expected %s, read %s",
                                    page.page_index,
                                    expected.text,
                                    tostring(actual)
                                )
                            )
                        end
                    end
                end
            end
        end
        checkCoverage(evaluated, total)
        print(
            string.format(
                "  OCR text (%s, %s): %d/%d matched (%.1f%%)",
                NATIVE_OCR and "native" or "CLI",
                bundled_language and "bundled fast English" or (MODEL_DIR or "system model"),
                correct,
                evaluated,
                correct / evaluated * 100
            )
        )
        if NATIVE_OCR then
            print(
                string.format(
                    "  OCR CPU: %.3fs / %d calls (includes model initialization, excludes crop rendering)",
                    ocr_seconds,
                    ocr_calls
                )
            )
        end
        WordFinder.cleanup()
        recordScore(
            "text_" .. (NATIVE_OCR and "native" or "cli") .. (bundled_language and "_bundled_eng" or "_configured"),
            correct,
            evaluated,
            total
        )
        if bundled_language then
            local minimum = math.ceil(evaluated * 0.95)
            assert.is_true(
                correct >= minimum,
                string.format("OCR accuracy below 95%%: %d/%d correct; need at least %d", correct, evaluated, minimum)
            )
        end
    end

    it("reads annotated text with the configured model", function()
        checkText(nil)
    end)
    it("reads annotated text with the bundled fast English model", function()
        checkText("eng")
    end)
end)

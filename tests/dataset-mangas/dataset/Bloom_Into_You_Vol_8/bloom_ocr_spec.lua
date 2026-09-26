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

local function fakeDocument(pixels, path)
    local function readCrop(rect, zoom, datadir, language, mode)
        if CANDIDATE_DIR and language == "eng_fast" then
            datadir = CANDIDATE_DIR
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
        local evaluated, correct, total = 0, 0, 0
        ocr_seconds, ocr_calls = 0, 0
        for _, page in ipairs(annotations) do
            total = total + #(page.word or {})
            if page.word and #page.word > 0 and includePage(page.page_index) then
                local pixels, path = loadPage(page.page_index)
                if pixels then
                    local document = fakeDocument(pixels, path)
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

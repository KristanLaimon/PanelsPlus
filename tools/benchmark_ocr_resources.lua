-- Run from /usr/lib/koreader:
-- OMP_THREAD_LIMIT=1 luajit /absolute/plugin/tools/benchmark_ocr_resources.lua [wordfinder.lua] [repeats]
-- Native MuPDF rendering + k2pdfopt OCR; excludes reader UI/DocCache.
io.stdout:setvbuf("line")
require("setupkoenv")
local BB = require("ffi/blitbuffer")
local Kopt = require("ffi/koptcontext")
local MuPDF = require("ffi/mupdf")
local DC = require("ffi/drawcontext")
local root = assert(arg[0]:match("^(/.*)/tools/benchmark_ocr_resources%.lua$"))
package.path = root .. "/?.lua;" .. package.path
require("tests.spec.helper")
local Finder = arg[1] and assert(loadfile(arg[1]))() or require("src._wordfinder")
local JSON = require("tests.helpers.json")
local model_dir = os.getenv("PANELSPLUS_OCR_TESSDATA") or root .. "/data/ocr"
local model_language = os.getenv("PANELSPLUS_OCR_LANGUAGE") or "eng_fast"
local bundled_language = os.getenv("PANELSPLUS_BUNDLED_OCR") ~= "0" and "eng" or nil
local dir = root .. "/tests/dataset-mangas/dataset/Bloom_Into_You_Vol_8"
local file = assert(io.open(dir .. "/annotation.json"))
local pages = JSON.decode(file:read("*a"))[1].pages
file:close()
local counters = { renders = 0, contexts = 0, live = 0, peak_live = 0, reads = 0 }
local function rss()
    local f = assert(io.open("/proc/self/status"))
    local status = f:read("*a")
    f:close()
    return tonumber(status:match("VmRSS:%s+(%d+)")), tonumber(status:match("VmHWM:%s+(%d+)"))
end
local result_path = os.getenv("PANELSPLUS_OCR_RESULTS")
local results = result_path and assert(io.open(result_path, "w"))
local start = os.clock()
local count, found, heap_peak = 0, 0, 0
local find_seconds, read_seconds = 0, 0
for round = 1, tonumber(arg[2]) or 3 do
    for _, annotation in ipairs(pages) do
        if annotation.word and #annotation.word > 0 then
            local backend = MuPDF.openDocument(string.format("%s/%02d.png", dir, annotation.page_index - 1))
            local probe = backend:openPage(1)
            local page_width = probe:getSize(DC.new())
            probe:close()
            local image_scale = 1264 / page_width
            local tile
            local document = {
                configurable = { doc_language = model_language, background_cleanup = 0 },
                render_mode = 0,
                getNativePageDimensions = function()
                    return { w = 1264, h = 1680 }
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
                    if tile then
                        tile:free()
                    end
                    local r = rect.scaled_rect
                    tile = BB.new(r.w, r.h, BB.TYPE_BB8)
                    local p = backend:openPage(1)
                    p:draw(DC.new(0, zoom * image_scale), tile, r.x, r.y, 0)
                    p:close()
                    return { bb = tile }
                end,
                _document = {
                    openPage = function()
                        local p = backend:openPage(1)
                        return {
                            getPagePix = function(_, context, mode, cleanup)
                                counters.renders = counters.renders + 1
                                p:getPagePix(context.native, mode, cleanup)
                            end,
                            close = function()
                                p:close()
                            end,
                        }
                    end,
                },
                koptinterface = {
                    tessocr_data = model_dir,
                    createContext = function(_, _, _, bbox)
                        local native = Kopt.new()
                        native:setBBox(
                            bbox.x0 / image_scale,
                            bbox.y0 / image_scale,
                            bbox.x1 / image_scale,
                            bbox.y1 / image_scale
                        )
                        native:setDeviceDPI(300)
                        counters.contexts = counters.contexts + 1
                        counters.live = counters.live + 1
                        counters.peak_live = math.max(counters.peak_live, counters.live)
                        local freed = false
                        return {
                            native = native,
                            setZoom = function(_, zoom)
                                native:setZoom(zoom * image_scale)
                            end,
                            getPageDim = function()
                                return native:getPageDim()
                            end,
                            getTOCRWord = function(_, ...)
                                counters.reads = counters.reads + 1
                                return native:getTOCRWord(...)
                            end,
                            free = function()
                                assert(not freed, "double free")
                                freed = true
                                counters.live = counters.live - 1
                                native:free()
                            end,
                        }
                    end,
                },
                getOCRWord = function(doc, pageno, wrapped)
                    local b = wrapped.sbox
                    local pad = math.floor(b.h * 0.3)
                    local context = doc.koptinterface:createContext(
                        doc,
                        pageno,
                        { x0 = b.x - pad, y0 = b.y - pad, x1 = b.x + b.w + pad, y1 = b.y + b.h + pad }
                    )
                    context:setZoom(30 / b.h)
                    local p = doc._document:openPage(pageno)
                    p:getPagePix(context, 0, 0)
                    local w, h = context:getPageDim()
                    local ok, word = pcall(
                        context.getTOCRWord,
                        context,
                        "src",
                        0,
                        0,
                        w,
                        h,
                        doc.koptinterface.tessocr_data,
                        doc.configurable.doc_language,
                        -1,
                        0,
                        1
                    )
                    p:close()
                    context:free()
                    return ok and word or nil
                end,
            }
            for _, expected in ipairs(annotation.word) do
                local t = os.clock()
                local box, size =
                    Finder.findWordBox(document, 1, expected.x + expected.w / 2, expected.y + expected.h / 2)
                find_seconds = find_seconds + os.clock() - t
                t = os.clock()
                local text = box and Finder.readWord(document, 1, box, size, bundled_language)
                read_seconds = read_seconds + os.clock() - t
                if results then
                    results:write(
                        string.format(
                            "%d:%d:%s:%s\n",
                            round,
                            count + 1,
                            box and string.format("%.9f,%.9f,%.9f,%.9f", box.x, box.y, box.w, box.h) or "nil",
                            tostring(text)
                        )
                    )
                end
                count = count + 1
                if text then
                    found = found + 1
                end
                assert(counters.live == 0, "context retained between lookups")
                heap_peak = math.max(heap_peak, collectgarbage("count"))
            end
            if tile then
                tile:free()
            end
            backend:close()
        end
    end
    local resident, peak = rss()
    print(
        string.format(
            "round=%d words=%d CPU=%.3fs RSS=%dKiB HWM=%dKiB Lua=%.0fKiB",
            round,
            count,
            os.clock() - start,
            resident,
            peak,
            collectgarbage("count")
        )
    )
end
if results then
    results:close()
end
Finder.cleanup()
collectgarbage("collect")
local resident, peak = rss()
print(
    string.format(
        "reads=%d renders=%d contexts=%d peak_live=%d found=%d Lua_peak=%.0fKiB Lua_final=%.0fKiB RSS_final=%dKiB HWM=%dKiB",
        counters.reads,
        counters.renders,
        counters.contexts,
        counters.peak_live,
        found,
        heap_peak,
        collectgarbage("count"),
        resident,
        peak
    )
)

print(string.format("find_CPU=%.3fs read_CPU=%.3fs", find_seconds, read_seconds))

-- Uses the same maps, detectors and matching thresholds as the production tests.
require("tests.helper")
local Manifest = require("tests.dataset-mangas.dataset_manifest")
local Loader = require("tests.dataset-mangas.dataset_loader")
local Evaluator = require("tests.dataset-mangas.panel_evaluator")
local detectors = {
    safe = require("src._safecomponentdetector"),
    smart = require("src._smartcomponentdetector"),
}
local function quote(value)
    return '"'
        .. value:gsub('[%z\1-\31\\"]', function(c)
            return string.format("\\u%04x", string.byte(c))
        end)
        .. '"'
end
local function boxes(items)
    local output = {}
    for _, b in ipairs(items) do
        output[#output + 1] = string.format("[%.3f,%.3f,%.3f,%.3f]", b.x, b.y, b.w, b.h)
    end
    return "[" .. table.concat(output, ",") .. "]"
end
local algorithms = arg[1] == "safe" and { "safe" } or arg[1] == "smart" and { "smart" } or { "safe", "smart" }
for _, directory in ipairs({ "dataset", "dataset-textbasedformats" }) do
    for _, book in ipairs(Manifest.loadManga("tests/dataset-mangas/" .. directory)) do
        if not arg[2] or book.book_title == arg[2] then
            for _, algorithm in ipairs(algorithms) do
                for _, page in ipairs(Manifest.getMappedPages(book, algorithm)) do
                    local map, load_error = Loader.loadPageMap(page.image_path, {
                        mode = page.reading_order,
                        embedded_image = page.embedded_image,
                    })
                    if not map then
                        error(page.image_path .. ": " .. tostring(load_error))
                    end
                    local detected, accepted, reason =
                        detectors[algorithm].detectPage(map, { mode = page.reading_order })
                    local result = Evaluator.evaluate(page.frames, detected, 0.50, 35)
                    local matched, sequence = {}, {}
                    for _, match in ipairs(result.matches) do
                        matched[match.d_idx] = match.g_idx
                    end
                    for i = 1, #detected do
                        sequence[i] = matched[i] or 0
                    end
                    io.write(
                        string.format(
                            '{"book":%s,"algorithm":%s,"directory":%s,"page":%d,"image":%s,"width":%d,"height":%d,"expected":%s,"detected":%s,"sequence":[%s],"correct":%s,"tp":%d,"accepted":%s,"reason":%s}\n',
                            quote(book.book_title),
                            quote(algorithm),
                            quote(directory),
                            page.page_index,
                            quote(page.image_path),
                            map.native_w,
                            map.native_h,
                            boxes(page.frames),
                            boxes(detected),
                            table.concat(sequence, ","),
                            tostring(result.reading_order_correct),
                            result.true_positives,
                            tostring(accepted),
                            quote(reason or "")
                        )
                    )
                    io.flush()
                    -- Full volumes should not retain every decoded page in memory.
                    Loader._cache = {}
                end
                detectors[algorithm].clearScratch()
            end
        end
    end
end

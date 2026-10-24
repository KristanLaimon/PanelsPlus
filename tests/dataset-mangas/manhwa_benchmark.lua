-- Manhwa ground truth is evaluated in continuous native coordinates, separately
-- from Manga/Comic production records and separately from viewer subdivisions.
local JSON = require("tests.helpers.json")
local Loader = require("tests.dataset-mangas.dataset_loader")
local Evaluator = require("tests.dataset-mangas.panel_evaluator")
local Manhwa = require("src.manhwa")
local Benchmark = {}

local function readJSON(path)
    local file = assert(io.open(path, "r"), "Missing annotation file: " .. path)
    local data = JSON.decode(file:read("*a"))
    file:close()
    return data
end

function Benchmark.run(root)
    local metadata = readJSON(root .. "/metadata.json")
    assert(metadata.type == "manhwa", "This benchmark only accepts manhwa datasets")
    local sizes = {}
    for page = 1, metadata.total_pages do
        local file =
            assert(io.open(string.format("%s/%02d.png", root, page - 1), "rb"), "Missing source image " .. page)
        local header = file:read(24)
        file:close()
        local function number(index)
            return header:byte(index) * 16777216
                + header:byte(index + 1) * 65536
                + header:byte(index + 2) * 256
                + header:byte(index + 3)
        end
        sizes[page] = { w = number(17), h = number(21) }
    end
    local document = {
        getNativePageDimensions = function(_, page)
            return sizes[page]
        end,
        getNextPage = function(_, page)
            return page < #sizes and page + 1 or 0
        end,
    }
    local settings = { mode = "manhwa", panel_finding_mode = "safe", segment_target_width = 480 }
    local layout = Manhwa.layout(document)
    local function build(_, page)
        return Loader.loadPageMap(string.format("%s/%02d.png", root, page - 1), settings)
    end
    local predicted, seen = {}, {}
    for page = 1, #sizes do
        for _, panel in ipairs(Manhwa.detect(document, settings, page, build)) do
            local key = string.format("%.3f:%.3f:%.3f:%.3f", panel.x, panel.y, panel.w, panel.h)
            if not seen[key] then
                seen[key] = true
                predicted[#predicted + 1] = panel
            end
        end
    end
    table.sort(predicted, function(a, b)
        return a.y == b.y and a.x < b.x or a.y < b.y
    end)
    -- Deliberately never load panels_smart.json while Manhwa Smart is disabled.
    local mapping = readJSON(root .. "/panels_safe.json")
    assert(mapping.algorithm == "safe", "Expected the independently annotated Safe mapping")
    local truth = {}
    for _, page in ipairs(mapping.pages) do
        for _, panel in ipairs(page.frame) do
            truth[#truth + 1] = { x = panel.x, y = panel.y + layout.pages[page.page_index].y, w = panel.w, h = panel.h }
        end
    end
    local metrics = Evaluator.evaluate(truth, predicted, 0.5)
    Manhwa.clear(document)
    return metrics, predicted, truth
end
return Benchmark

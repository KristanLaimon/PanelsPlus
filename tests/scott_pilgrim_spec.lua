local framework = require("tests.PanelsPlusTestFramework")
local describe, it, assert = framework.describe, framework.it, framework.assert
local Detector = require("src._safecomponentdetector")
local Manifest = require("tests.dataset-mangas.dataset_manifest")
local Loader = require("tests.dataset-mangas.dataset_loader")
local Evaluator = require("tests.dataset-mangas.panel_evaluator")

describe("Scott Pilgrim Volume 5", function()
    it("reads tilted rows in order and distinguishes faded panels from full-page artwork in Safe", function()
        if os.getenv("PANELSPLUS_TEST_ALGORITHM") == "smart" then
            framework.skip("Safe-only review regression")
        end
        local selected = {
            [13] = true,
            [15] = true,
            [90] = true,
            [101] = true,
            [108] = true,
            [129] = true,
            [139] = true,
            [140] = true,
            [177] = true,
            [187] = true,
            [201] = true,
            [205] = true,
            [211] = true,
            [216] = true,
        }
        for _, book in ipairs(Manifest.loadManga()) do
            if book.book_title == "Scott_Pilgrim_Vol_5" then
                for _, page in ipairs(Manifest.getMappedPages(book, "safe")) do
                    if selected[page.page_index] then
                        local image = io.open(page.image_path, "rb")
                        if not image then
                            framework.skip("Reviewed Scott Pilgrim images unavailable in this dataset clone")
                        end
                        image:close()
                        assert.equals("comic", page.reading_order)
                        local map, load_error = Loader.loadPageMap(page.image_path, { mode = page.reading_order })
                        assert.is_not_nil(map, load_error)
                        local panels = Detector.detectPage(map, { mode = page.reading_order })
                        local result = Evaluator.evaluate(page.frames, panels, 0.50, 35)
                        assert.is_true(result.reading_order_correct, "Safe review page " .. page.page_index)
                        selected[page.page_index] = nil
                    end
                end
                break
            end
        end
        assert.is_nil(next(selected))
    end)
end)

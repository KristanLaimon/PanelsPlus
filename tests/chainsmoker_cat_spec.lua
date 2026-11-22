local framework = require("tests.PanelsPlusTestFramework")
local describe, it, assert = framework.describe, framework.it, framework.assert
local Detector = require("src._safecomponentdetector")
local Manifest = require("tests.dataset-mangas.dataset_manifest")
local Loader = require("tests.dataset-mangas.dataset_loader")
local Evaluator = require("tests.dataset-mangas.panel_evaluator")

describe("Chainsmoker Cat Volume 1", function()
    it("recovers gray-gutter splits, retains reviewed merges and keeps the dark illustration whole in Safe", function()
        if os.getenv("PANELSPLUS_TEST_ALGORITHM") == "smart" then
            framework.skip("Safe-only review regression")
        end
        local reviewed = {
            [3] = true,
            [4] = true,
            [41] = true,
            [47] = true,
            [51] = true,
            [59] = true,
            [64] = true,
            [65] = true,
            [74] = true,
            [84] = true,
            [89] = true,
            [129] = true,
            [156] = true,
        }
        local mapped
        for _, book in ipairs(Manifest.loadManga()) do
            if book.book_title == "Chainsmoker_Cat_Vol_1" then
                mapped = Manifest.getMappedPages(book, "safe")
                break
            end
        end
        assert.is_not_nil(mapped)
        local checked = 0
        for _, page in ipairs(mapped) do
            if reviewed[page.page_index] then
                local image = io.open(page.image_path, "rb")
                if not image then
                    framework.skip("Reviewed Chainsmoker Cat pages unavailable in this dataset clone")
                end
                image:close()
                local map, load_error = Loader.loadPageMap(page.image_path, { mode = page.reading_order })
                assert.is_not_nil(map, load_error)
                local panels = Detector.detectPage(map, { mode = page.reading_order })
                local result = Evaluator.evaluate(page.frames, panels, 0.50, 35)
                assert.is_true(
                    result.reading_order_correct,
                    string.format(
                        "Page %d: expected %d panels, detected %d, matched %d",
                        page.page_index,
                        #page.frames,
                        #panels,
                        result.true_positives
                    )
                )
                checked = checked + 1
            end
        end
        assert.equals(13, checked)
    end)
end)

local framework = require("tests.PanelsPlusTestFramework")
local describe, it, assert = framework.describe, framework.it, framework.assert
local Benchmark = require("tests.dataset-mangas.algorithm_benchmark")

describe("Independent algorithm baselines", function()
    local function metrics(f1)
        return {
            pages_evaluated = 3,
            total_ground_truth = 12,
            iou_threshold = 0.5,
            gap_tolerance = 35,
            precision = f1,
            recall = f1,
            f1 = f1,
            mean_iou = f1,
            false_positives = 0,
        }
    end
    it("compares Safe only against its own record", function()
        local data = { safe_full_volume = metrics(0.5), smart_full_volume = metrics(0.95) }
        assert.is_true(Benchmark.verify(data, "safe", metrics(0.5)))
        assert.is_false(Benchmark.verify(data, "smart", metrics(0.5)))
    end)
    it("accepts historical Smart records only with matching coverage and evaluator settings", function()
        local historical = metrics(0.95)
        local data = { components_conservative_full_volume = historical }
        assert.equals(historical, Benchmark.baseline(data, "smart", metrics(0.95)))
        assert.is_nil(Benchmark.baseline(data, "safe", metrics(0.95)))
        historical.pages_evaluated = 2
        assert.is_nil(Benchmark.baseline(data, "smart", metrics(0.95)))
        historical.pages_evaluated = 3
        historical.iou_threshold = 0.75
        assert.is_nil(Benchmark.baseline(data, "smart", metrics(0.95)))
    end)
    it("fails explicitly when canonical baseline coverage changes", function()
        local data = { smart_full_volume = metrics(0.95) }
        local current = metrics(0.95)
        current.pages_evaluated = 4
        local ok, reason = Benchmark.verify(data, "smart", current)
        assert.is_false(ok)
        assert.is_true(reason:find("coverage changed", 1, true) ~= nil)
    end)
    it("evaluates each detector against its own mapped panels and skips pending pages", function()
        local Loader = require("tests.dataset-mangas.dataset_loader")
        local load = Loader.loadPageMap
        local safe_detector, smart_detector = Benchmark.detectors.safe, Benchmark.detectors.smart
        local a = { x = 0, y = 0, w = 40, h = 100 }
        local b = { x = 60, y = 0, w = 40, h = 100 }
        local merged = { x = 0, y = 0, w = 100, h = 100 }
        local book = {
            pages = {
                {
                    image_path = "page1",
                    reading_order = "manga",
                    frames = { a, b },
                    panel_mappings = { smart = { frames = { a, b } }, safe = { frames = { merged } } },
                },
                {
                    image_path = "page2",
                    reading_order = "manga",
                    frames = { a, b },
                    panel_mappings = { smart = { frames = { a, b } }, safe = { frames = {} } },
                },
            },
        }
        Loader.loadPageMap = function()
            return {}
        end
        Benchmark.detectors.safe = {
            detectPage = function()
                return { merged }
            end,
        }
        Benchmark.detectors.smart = {
            detectPage = function()
                return { a, b }
            end,
        }
        local ok, err = pcall(function()
            local safe, smart = Benchmark.evaluate(book, "safe"), Benchmark.evaluate(book, "smart")
            assert.equals(1, safe.pages_evaluated)
            assert.equals(1, safe.total_ground_truth)
            assert.equals(1, safe.f1)
            assert.equals(2, smart.pages_evaluated)
            assert.equals(4, smart.total_ground_truth)
            assert.equals(1, smart.f1)
        end)
        Loader.loadPageMap = load
        Benchmark.detectors.safe, Benchmark.detectors.smart = safe_detector, smart_detector
        assert.is_true(ok, tostring(err))
    end)
end)

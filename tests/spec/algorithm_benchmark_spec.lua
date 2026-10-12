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
end)

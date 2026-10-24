local framework = require("tests.PanelsPlusTestFramework")
local describe, it, assert = framework.describe, framework.it, framework.assert

describe("Separate manhwa Safe dataset regression", function()
    it("retains the initial Safe baseline on the complete continuous chapter", function()
        local root = "tests/dataset-mangas/dataset/Overgeared_Vol_1"
        for page = 1, 62 do
            local file = io.open(string.format("%s/%02d.png", root, page - 1), "rb")
            if not file then
                if os.getenv("PANELSPLUS_REQUIRE_DATASETS") == "1" then
                    error("Missing manhwa source page " .. page)
                end
                framework.skip("Complete local Overgeared images are unavailable")
                return
            end
            file:close()
        end
        local metrics, predictions, truth = require("tests.dataset-mangas.manhwa_benchmark").run(root)
        assert.equals(50, #truth, "Review a changed Safe mapping before updating the baseline")
        assert.is_true(metrics.precision >= 0.80)
        assert.is_true(metrics.recall >= 0.80)
        assert.is_true(metrics.f1 >= 0.80)
        assert.is_true(metrics.mean_iou >= 0.90)
        -- A tall manually mapped illustration must reach the viewer as one panel.
        local tall, best = nil, 0
        for _, panel in ipairs(truth) do
            if panel.h == 4277 then
                tall = panel
                break
            end
        end
        assert.is_not_nil(tall, "Expected the long illustration anchored on source page 37")
        local evaluator = require("tests.dataset-mangas.panel_evaluator")
        for _, panel in ipairs(predictions) do
            best = math.max(best, evaluator.boxIoU(tall, panel))
        end
        assert.is_true(best > 0.90, "The viewer must preserve the entire tall illustration")
        for i = 2, #predictions do
            assert.is_true(predictions[i].y >= predictions[i - 1].y)
        end
        print(
            string.format(
                "  Manhwa Safe initial baseline: %d/%d matches, %.2f%% F1 (not the Manga/Comic production target)",
                metrics.true_positives,
                #truth,
                metrics.f1 * 100
            )
        )
    end)
end)

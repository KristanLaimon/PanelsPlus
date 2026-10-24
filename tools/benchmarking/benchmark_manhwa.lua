package.path = "./?.lua;./?/init.lua;" .. package.path
require("tests.spec.helper")
local root = arg[1] or "tests/dataset-mangas/dataset/Overgeared_Vol_1"
local metrics = require("tests.dataset-mangas.manhwa_benchmark").run(root)
print(
    string.format(
        "Manhwa Safe: %d/%d matched; %d detections; precision %.2f%%, recall %.2f%%, F1 %.2f%%; matched mean IoU %.2f%%",
        metrics.true_positives,
        metrics.ground_truth_count,
        metrics.detected_count,
        metrics.precision * 100,
        metrics.recall * 100,
        metrics.f1 * 100,
        metrics.mean_iou * 100
    )
)
print(
    "Complete viewer panels are evaluated without height subdivision. Manhwa Smart is disabled; Manga/Comic records are unchanged."
)

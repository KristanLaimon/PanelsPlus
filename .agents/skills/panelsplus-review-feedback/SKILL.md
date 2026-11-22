---
name: panelsplus-review-feedback
description: Apply panels_revision feedback to fix general panel detection, one reviewed book and Safe/Smart algorithm at a time; validate mappings, regressions and scoped reports.
---

# Reviewed panels → general detector fix

Repo-root paths. Read `tools/panels_revision/README.md`; launch with `./start-reviewer.sh` when needed; reuse persistence, no automatic rescan.

## Scope

- Read book/algorithm/group/pages from `panels_revision_feedback` entries or `tools/panels_revision/revision/data-persistence/{safe,smart}/reviews.json`; never re-ask supplied identity. An explicit book/algorithm scope governs the work even when the export includes other groups. Otherwise establish scope one book/algorithm at a time.
- Latest user corrections win; clarify consequential ambiguity while continuing independent work. Safe: ignore gray-only shading links; preserve real border/artwork/balloon connections. Do not impose Safe's policy on Smart.
- Preserve edits/staging, unrelated mappings/metadata/reviews/baselines and the other algorithm. No stage/commit/push unless requested.
- Use general image evidence; no detector exceptions keyed by book/page/path/hash, fixed example coordinates/dimensions, expected-panel lookups or per-book tuning. Concrete test fixtures allowed.

## Loop

1. Capture prior detector/results. Validate feedback version, report/basis, image/dimensions and freshness. Pages are 1-based; use supplied image paths, not guessed offsets. Before = previous different stored result, not necessarily a commit; After = latest diagnosis.
2. Reconcile `chosen` with the current algorithm mapping; ignore abandoned custom `review.boxes` when another choice won. Save may already have applied it. Apply confirmed missing corrections with backup/stale-file protection; preserve unrelated fields. Never change mappings merely to fit detector output.
3. Inspect images and per-page counts, boxes, matches and order; distinguish mapping error, false/real connection, missed/split/merged panels, illustration fragments, fallback and sequencing. Fix the smallest general cause in the selected detector; protect approved merges/splits, real one-pixel bridges and enclosing frames. Keep coverage/panel-count guards.
4. Add failing-before/passing-after regressions plus generic counterexamples. Validate all reviews AND the whole volume: counts, F1/IoU, exact/pair reading order. Control the other algorithm. Compare representative manga/comic volumes with captured results; track previously passing pages newly failing, not just aggregates. Do not modify their annotations/baselines to hide regressions.
5. Keep evaluator tolerances/targets unchanged. After reviewed annotation changes and complete validation only: establish/archive the selected book/algorithm baseline via `Benchmark.establishBaseline`; verify unrelated records unchanged. Otherwise retain existing regression gates. Unresolved cases remain explicit.
6. With the reviewer stopped, run `bun tools/panels_revision/refresh.ts "$algorithm" "$book"` to regenerate and publish the scoped report. Use the reviewer's `REVISION_PORT` if customized. The command preserves other groups, historical comparisons, reviews and session. Restart the reviewer with `./start-reviewer.sh` to load the saved result. Record scope, decisions, before/after results, failed approaches, tests and limits in `tests/dataset-mangas/report/`. Report remaining cases honestly; tested matches ≠ pixel-identical boxes or universal accuracy.

## Checks

Use validated scope variables; run from root:

```sh
PANELSPLUS_TEST_ALGORITHM="$algorithm" PANELSPLUS_TEST_DATASET="$book" lua tests/run_tests.lua tests/new_dataset_benchmark_spec.lua
lua tests/run_tests.lua tests/componentdetector_spec.lua
lua tools/panels_revision/revision/diagnose.lua "$algorithm" "$book"
```

Add relevant book/consumer regressions and lint changed Lua. Use `diagnose.lua` for JSONL captures and comparisons; `refresh.ts` runs its own scoped scan when publishing. Full suite only when requested or justified; distinguish skipped tools/missing images, known failures and device validation. Finish with scope, general fix, measured results, untouched algorithm, remaining limits and restart instructions when needed.

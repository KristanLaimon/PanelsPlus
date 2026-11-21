# Panels revision

Dependency-free Bun app for reviewing panel detection and editing datasets. No
React, Vite, package install, CSS library, or build step.

From the repository root:

```sh
bun tools/panels_revision/revision.ts
```

Open **http://127.0.0.1:3210**. To change the port:

```sh
REVISION_PORT=3211 bun tools/panels_revision/revision.ts
```

The app uses `Bun.serve()` with an HTML entrypoint and native TypeScript bundling.
Keep it on localhost: the API can write this project's panel mappings.

## Review

- Select Safe or Smart, a manga, and a filter. All differences are shown by default.
  Page numbers start at 1; the source image filename is displayed separately.
- Compare the original mapping, Before, and After. Choose the correct result, or
  edit a copy. Drawing order is reading order; use Move earlier / Move later to reorder.
- Draw rectangles, move them, resize with corner handles, or type coordinates.
  Zoom, deletion, full-page rectangles, and undo are available.
- Add optional notes. Choices and notes automatically save to disk and localStorage.
- **Save this page to dataset** writes only that page. **Save reviewed pages** writes
  completed decisions for the current book and algorithm. Pending/incomplete/stale
  decisions are excluded. Unreviewed pages and unrelated metadata remain unchanged.
- Writes validate bounds, reject stale file hashes, create an exact original-file
  backup, and replace the mapping atomically. Baselines are never updated automatically.
- **Copy all feedback** exports notes, choices, expected/before/after/chosen rectangles
  and page identity as JSON for the conversation. Download/import restores feedback.
  If clipboard permission is unavailable, the app displays selectable JSON.

## Tests and automatic diagnostics

The single **Algorithm** selector switches the visible pages, findings, counts and
the next scan together: **Safe only**, **Smart only**, or **Safe + Smart**. **Run panel tests + diagnose** executes `./run-tests.sh --panels --strict`
(the repository's panel-focused suite, including datasets/benchmarks), then evaluates
the selected algorithm's mapped manga pages (including embedded-image EPUB/KEPUB/MOBI datasets) using the same loader and matching thresholds
as production tests: IoU 0.50 / edge tolerance 35px. It does not run OCR/Python/Go
suites excluded by `--panels`, or device validation.

Shared unit checks still run for both detectors. Production and embedded-image
accuracy benchmarks use `PANELSPLUS_TEST_ALGORITHM` to test only the selected
algorithm; an unscoped repository test run continues to test both.

The app itself needs only Bun. Running the existing tests/diagnostics also needs the
repository's existing test tools: Lua, Python for the parallel runner, and ImageMagick.
Missing tools are reported as failures; the app does not install dependencies.

Test failures do not prevent diagnostics. The UI shows exit codes and logs. A failed
or incomplete diagnostic preserves the previous complete report. With no earlier
report, Before equals After. On later runs Before means the previous different detector result, not
the Git version. Rerunning identical output retains the existing comparison. The existing 2026-11-21 Safe report is imported on first startup
when present; its Before column retains the historical detector comparison.

The diagnostic CLI `revision/diagnose.lua` accepts the algorithm as its first
argument and an optional exact book title as its second for scoped JSONL output.

A scan of one algorithm preserves the other algorithm's report and reviews. Startup
loads the saved reports without running tests or scanning images. The last algorithm,
book, page, filter, zoom and editor mode resume from `session.json`.

A page needs review if counts, matching, or reading order differ from the mapping.
This is a review queue, not proof that the detector is wrong. Existing reviews survive
reruns; decisions based on changed results are marked stale and must be confirmed
again before applying. The UI also offers every mapped page for optional review.

## Persistence

All server data lives in **`revision/data-persistence/`**, next to this README's app:

- `diagnostics.json`: atomic index of the current Safe/Smart report snapshots.
- `safe/diagnostics-*.json`, `smart/diagnostics-*.json`: separate page results.
- `diagnostics-before-*.json`: archived reports.
- `safe/reviews.json`, `smart/reviews.json`: separate choices, notes and custom boxes.
- `session.json`: last algorithm/book/page, filters, zoom and editor mode.
- `run.json`, `run-*.log`, `run-*.jsonl`: latest status and retained run output.
- `backups/<algorithm>::<book>/*.json`: exact originals before mapping writes.

The app migrates older combined report/review files on startup without rescanning.
Runtime data is ignored by Git. Export feedback before deleting it. LocalStorage is
a secondary draft cache scoped to the browser origin; server persistence survives
browser/port changes. Keep a stable port for clipboard/browser draft continuity.

Run app checks with:

```sh
bun test tools/panels_revision/revision/revision.test.ts
bun check tools/panels_revision --strict --target esnext --module preserve --moduleResolution bundler --lib esnext,dom --noUncheckedIndexedAccess
bun build tools/panels_revision/revision.ts --target bun --outdir /tmp/panels-revision-build
```

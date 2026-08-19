# CLAUDE.md

Guidance for Claude Code working in this repo.

## OCR debug session data: never `Read` the images directly

When `ocr_debug_mode` is on (see `src/_ocrdebug.lua`), a review session
produces:

- `OCR.debug.session.log` — one JSON object per tap: `document`, `page`,
  `tap` (exact long-press point), `box` (the box OCR read from), `native`
  (page size), `ocr_word`, `koreader_word`, `correct_text`, `verdict`,
  `ocr_failed` ("no_box"/"no_word"), `user_box` (the box the user drew as
  correct), `image` (relative path to a PNG crop).
- `OCR.debug.session.images/` — a cropped PNG per "incorrect"/failed entry,
  with the OCR box (thin, 1px outline) and the user's corrected box (thick,
  3px outline) burned in.

**Do not `Read` these PNGs to analyze a session.** Every rectangle in an
image was drawn *from* the log's own `box`/`user_box` numbers — the image
never contains geometry the log doesn't already have — and reading a batch
of them burns a large number of tokens for information that's already
sitting in the log as plain JSON. Instead:

```sh
lua tools/ocrdebug_report.lua --summary          # counts by classification
lua tools/ocrdebug_report.lua                    # full JSON array, one object per log line
```

`tools/ocrdebug_report.lua` reads the log and adds a pre-computed
`classification` field per entry (`correct` / `box_bug` / `engine_miss` /
`total_miss_no_box` / `total_miss_no_word` / `unclassified`), plus the
`overlap_ratio` / `size_ratio` / `edge_offset_ratio` metrics it derived that
classification from — all from arithmetic on the log's rectangles, no image
decoding involved (there is no PNG-decoding library available to a
standalone Lua script in this environment anyway; KOReader's own PNG
support lives in its C base library, not reachable outside the running
app). It is self-contained — no dependency on this repo's other modules —
so it also runs fine outside KOReader (`lua`/`lua5.1` on the host).

Only `Read` a specific PNG when the log's numbers genuinely aren't enough —
e.g. to see *why* an engine_miss happened (font style, contrast, art
bleeding through) — and even then, open one or two specific images the
report pointed at, not the whole folder.

See also: `docs/OCR-DEBUG-DATASET-PLAN.md` for how a debug session gets
collected in the first place.

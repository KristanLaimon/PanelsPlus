# Testing

A dependency-free test suite that runs the plugin's real modules — not
reimplementations of them — outside KOReader entirely.

See also: [DEBUGGING-DETECTION.md](DEBUGGING-DETECTION.md) for the
methodology this suite grew out of ("run the real module, never a
reimplementation" is the same rule applied here at the harness level), and
[ARCHITECTURE.md](ARCHITECTURE.md) for what each module under test does.

## Running it

```sh
lua tests/run_tests.lua
```

No `busted`, no `luarocks`, no external packages — plain Lua 5.4 (or any
Lua/LuaJIT with the same `require` semantics) is enough. `run_tests.lua`
sets `package.path` to the repo root, loads the mock layer once, then
requires each spec module in turn and prints a pass/fail summary, exiting
non-zero on any failure.

## Why there's a mock layer at all

The plugin's modules `require` real KOReader APIs (`ui/event`,
`ui/widget/imageviewer`, `device`, `ui/geometry`, …) at file scope, which
don't exist outside a running KOReader process. `tests/spec/helper.lua`
installs `package.preload` stubs for exactly the KOReader modules the
plugin touches — modeled on the mocking pattern used by the reference clone
`kobo.koplugin/spec/helper.lua` — so `require("src._panelviewer")` and
friends load and run as the shipping code, not a rewrite of it.
Dependency-light modules (`src/_geometry.lua`, `src/_timing.lua`) are left
unmocked and required for real.

`src/_segmenter.lua` needs one more shim beyond the standard mock layer: it
requires LuaJIT's `ffi`, which the plain Lua runner doesn't have. A minimal
`ffi.new`/`ffi.cast` stub — the segmenter only ever uses `ffi.new` as a
zero-filled, 0-based array — lives in `tests/spec/helper.lua` too. See
[DEBUGGING-DETECTION.md → Step 1](DEBUGGING-DETECTION.md#step-1-run-the-real-module-never-a-reimplementation)
for why this shim exists instead of a reimplementation.

## Framework

`tests/PanelsPlusTestFramework.lua` is intentionally small: `describe`/`it`
grouping, an `assert` table (`equals`, `is_true`, `is_false`, `is_nil`,
`is_not_nil`, `near`), and `spy()` call-tracking stubs (records args,
returns a settable `return_value`, exposes `:called()` /`:callCount()`
/`:lastCall()`) for asserting on calls into the mocked KOReader surface.

## What's covered

| Spec | Covers |
| --- | --- |
| `segmenter_spec.lua` | The recursive X-Y cut, both size floors, the drawn-border search — see [DEBUGGING-DETECTION.md](DEBUGGING-DETECTION.md) for how these cases were derived |
| `wordfinder_spec.lua` | Word-box finding math: background/polarity estimation, line-height and gap calibration, snapping |
| `panelviewer_transform_spec.lua` | `screenToPageTransform`/`pageToScreenTransform` round-tripping, including rotation |
| `panelviewer_highlight_spec.lua` | Highlight painting, including the anomalous-box outline fallback |
| `panelviewer_refineword_spec.lua` | The hold → `WordFinder` → selection-refinement pipeline |
| `panelviewer_tapnav_spec.lua` | Tap-to-navigate zones and reading-mode-dependent side |
| `panelviewer_leftedge_spec.lua` | Left-edge swipe zoom gesture |
| `panelviewer_gotoviewrel_spec.lua` | Hardware/Bluetooth page-turner navigation (`onGotoViewRel`) and boundary crossing |
| `ocrdebug_spec.lua` | The OCR debug review-mode state machine |
| `ocrdebug_report_spec.lua` | `tools/ocrdebug_report.lua`'s classifier (`box_bug`/`engine_miss`/etc.) |

`tests/beastars.manga.PDF`, `tests/deadpool.comic.cbr`, and
`tests/kobayashi.manga.cbz` are real comic/manga fixture files kept
alongside the specs, but the automated suite above doesn't decode them —
this environment has no image/archive tooling available to a standalone
Lua script (see
[DEBUGGING-DETECTION.md → Working without image tooling](DEBUGGING-DETECTION.md#working-without-image-tooling)).
They're for manual, on-device testing via `runkobo.sh` / `rungeneric.sh`
instead.

## Running against a real device profile

`rungeneric.sh` launches the KOReader Flatpak in ordinary desktop mode.
`runkobo.sh` launches the same Flatpak with `EMULATE_READER_W=632
EMULATE_READER_H=840 EMULATE_READER_DPI=300 EMULATE_BW_SCREEN=1`, emulating
a Kobo-class device's resolution, DPI, and grayscale e-ink rendering
without needing physical hardware — useful for anything screen-size- or
rotation-sensitive that the pure-Lua suite mocks away.

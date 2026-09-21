# Testing

Panels+ tests the production Lua modules through a small local framework and a
KOReader mock layer. Detector benchmarks can additionally decode annotated
comic pages and compare rectangles against ground truth.

See [the test-suite README](../tests/README.md) for dataset layout, benchmark
commands, baseline policy, and current corpus measurements. See
[ARCHITECTURE.md](ARCHITECTURE.md) for the modules under test and
[DETECTION.md](DETECTION.md) for the Deep-mode heuristics those tests exercise.

## Recommended entry points

```sh
./run-tests.sh                         # lint/style, Python tests, parallel Lua suite
./run-tests.sh --quick                 # parallel Lua suite without lint/style
./run-tests.sh --quicker               # Lua suite without lint/style, datasets, or benchmarks
./run-tests.sh --quick -j 1            # serial worker execution
./run-tests.sh --quick tests/spec/componentdetector_spec.lua
./run-tests.sh --check-only            # StyLua and Luacheck only
./run-tests.sh --python                # Python tests only
```

`run-tests.sh` uses `tests/run_parallel.py` for the Lua jobs. The complete Lua
suite can also run sequentially without that scheduler:

```sh
lua tests/run_tests.lua
lua tests/run_tests.lua tests/spec/componentdetector_spec.lua
```

Full private datasets may be absent in a clone. Set
`PANELSPLUS_REQUIRE_DATASETS=1` when missing dataset pages should fail rather
than skip. Use LuaJIT and preload `ffi` when you want the production-style
native-array path:

```sh
PANELSPLUS_REQUIRE_DATASETS=1 luajit -l ffi tests/run_tests.lua
```

## Test architecture

`tests/PanelsPlusTestFramework.lua` provides `describe`, `it`, assertions, and
spies. `tests/spec/helper.lua` installs `package.preload` stubs for KOReader
modules such as widgets, geometry, device services, and the UI manager. Tests
then `require` the real plugin module; detector or viewer logic is not copied
into a separate test implementation.

Plain Lua has no LuaJIT FFI runtime, so the helper supplies the minimal array
behavior needed by modules that use `ffi.new`, `ffi.cast`, and zero-based
indexing. LuaJIT runs can instead use real FFI storage. Maintaining both paths
is useful: plain Lua keeps the suite portable, while LuaJIT exercises memory
representations closer to KOReader.

## Coverage map

The current specs fall into these groups:

| Area | Representative specs |
| --- | --- |
| Deep detection | `componentdetector_spec.lua`, `pagebitmap_spec.lua`, `panelcollector_spec.lua` |
| Internal native fallback | `nativedetector_spec.lua`, `memory_spec.lua` |
| Geometry and viewports | `geometry_spec.lua`, `panelviewport_spec.lua`, `panelviewer_transform_spec.lua`, `panelviewer_margin_spec.lua` |
| Viewer input/navigation | `panelviewer_tapnav_spec.lua`, `panelviewer_leftedge_spec.lua`, `panelviewer_keyboard_nav_spec.lua`, `panelviewer_gotoviewrel_spec.lua`, `panelviewer_kobo_bluetooth_spec.lua`, `panelviewer_reader_gesture_spec.lua` |
| Transitions and controller behavior | `panelviewer_navtransition_spec.lua`, `viewer_controller_rotation_spec.lua`, `viewer_controller_more_config_spec.lua` |
| Embedded images | `embedded_image_spec.lua`, `textbasedformats_dataset_spec.lua` |
| KOReader integration/settings | `native_panel_zoom_spec.lua`, `doc_settings_spec.lua` |
| Word lookup and review | `wordfinder_spec.lua`, `panelviewer_refineword_spec.lua`, `panelviewer_highlight_spec.lua`, `ocrdebug_spec.lua`, `ocrdebug_report_spec.lua` |
| Dataset evaluation | `dataset_support_spec.lua`, `dataset_benchmark_spec.lua`, `new_dataset_benchmark_spec.lua` |
| Legacy algorithm regression | `segmenter_spec.lua` |

The legacy segmenter spec remains because Deep mode still reuses its
page-level `Segmenter.accept()` validator and benchmark tooling retains the old
algorithm for historical comparisons. Its presence does not imply a
reader-selectable detector mode.

## Testing computer-vision heuristics

A detector fix should normally include more than one positive example. At
minimum, cover:

1. the page that previously failed;
2. a visually similar page that must *not* trigger the new heuristic;
3. exact rectangle coordinates after map-to-source scaling;
4. Manga and Comic reading order when ordering could change;
5. the full-page continuity result when candidates are rejected;
6. repeated detection with changing map dimensions when FFI scratch capacity
   is involved.

For a corpus-level change, compare precision, recall, F1, mean intersection over
union (IoU), and perfect reading-order pages. A higher recall that creates many
speech-balloon boxes is not a free improvement; inspect the precision tradeoff
and per-book regressions.

## Real-device checks

The mock suite cannot reproduce renderer ownership, framebuffer effects,
touch-zone registration, or e-ink memory pressure. Use `rungeneric.sh` for the
desktop Flatpak and `runkobo.sh` for the Kobo-like emulated profile. Verify at
least:

- first open, next-panel prerender, and cross-page replacement;
- Manga/Comic order plus inverted gestures;
- Classic, Smooth, and Animated transitions;
- embedded-image navigation separately from fixed pages;
- rotation and night mode;
- teardown after OCR, prefetch, and component scratch buffers have been used;
- flat free-memory behavior over a longer reading session.

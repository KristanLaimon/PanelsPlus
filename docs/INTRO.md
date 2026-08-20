# Introduction

A first read of Panels+ before diving into the other documents: what the
plugin replaces, how a single page turns into a swipeable panel sequence, and
where each piece of the codebase lives.

See also: [ARCHITECTURE.md](ARCHITECTURE.md) for the full module map and
sequence diagrams, [DETECTION.md](DETECTION.md) for how panels are found,
[MODES.md](MODES.md) for what the reader-facing modes mean, and
[PERFORMANCE.md](PERFORMANCE.md) for what each step costs.

## What the plugin replaces

KOReader already detects comic panels: a long hold on a page runs
`ReaderHighlight:onPanelZoom`, which finds the one panel under the hold
point, renders it, and opens a plain `ImageViewer`. Reading a page means
repeating that for every panel — hold, read, close, hold again.

Panels+ keeps the detection idea and replaces the flow. It finds every panel
on the page, orders them for manga (right-to-left) or comic (left-to-right)
reading, and opens a viewer that can be swiped through — including across
page boundaries, so panel reading feels continuous instead of one hold per
panel.

It does this by patching a single method at startup rather than forking the
reader: `onPanelZoom` is saved, replaced with `PanelsPlus:showPanelSequence`
while the plugin is enabled, and restored on close. Disabling the plugin
returns KOReader to stock single-panel zoom with no restart required.

## One page, start to finish

A long hold on a page triggers this chain:

1. `showPanelSequence` turns the hold position into page-space coordinates.
2. `Cache:collectPanels` returns panels for that page immediately if they
   were already detected under the current reading mode and detector;
   otherwise it asks `PanelCollector.collect` to detect them.
3. `PanelCollector.collect` picks a detector — the gutter-finding segmenter
   or KOReader's own native detector — and returns an ordered list of panel
   rectangles.
4. `PanelCollector.buildImages` wraps each rectangle in a function rather
   than rendering it. Opening a nine-panel page renders exactly one panel;
   the other eight render only when reached.
5. `PanelViewer` opens showing the held panel, and the next page's panels
   are queued for background detection so swiping past the last panel on a
   page rarely waits.

That laziness — caching rectangles, not rendered images, and only rendering
the panel on screen — is the difference between opening a page and paying
for the whole page's panels up front.

## Two detectors, one dispatcher

Panel detection has two independent implementations behind one entry point,
because they fail in different places:

- **Quick mode** renders the page small, measures its border to learn
  whether it is a light or dark page, and recursively slices the resulting
  ink map along its widest empty band. Cheap, and the only mode that works
  on dark backgrounds, but it cannot separate panels that interlock without
  a clean gutter between them.
- **Deep mode** drives KOReader's own native detector directly, probing a
  grid of points against one shared page rasterization. Handles awkward
  layouts the segmenter cannot, at the cost of a full-resolution page render.
- **Smart Mode** runs Quick first and falls back to Deep only on pages
  the segmenter rejects, which is why it is the default.

Full detail, including the acceptance test that decides when a segmenter
result can be trusted, lives in [DETECTION.md](DETECTION.md).

## Module map

`main.lua` is the KOReader plugin class: it owns settings, cache state, and
teardown. Every other feature module is a plain Lua table of methods copied
onto that class through a small `include()` helper, so KOReader's event
dispatch keeps working regardless of which file defines a given method. The
one rule this creates: two modules can never define the same method name,
since the later `include()` call would silently win.

| File | Responsibility |
| --- | --- |
| `main.lua` | Plugin class, settings setters, teardown |
| `src/cache.lua` | Per-page panel cache, prefetch scheduling and cancellation |
| `src/viewer_controller.lua` | Opening viewers, page-boundary crossing, panel prerender |
| `src/actions.lua` | Gesture-manager actions |
| `src/menu.lua` | Main-menu entries |
| `src/native_panel_zoom.lua` | Patching and restoring `onPanelZoom` |
| `src/_panelcollector.lua` | Chooses a detector, builds lazy panel images and crop rects |
| `src/_pagebitmap.lua` | Renders a page small and binarizes it into an ink map |
| `src/_segmenter.lua` | Recursive X-Y cut over the ink map, plus its acceptance test |
| `src/_nativedetector.lua` | KOReader's native detector, batched over one rasterization |
| `src/_panelviewer.lua` | `ImageViewer` subclass: swipes, gestures, controls, screenshots |
| `src/_wordfinder.lua` | Comic-lettering-aware word-box finder for touch-and-hold lookup |
| `src/_rotationpicker.lua` | Modal dialog for device rotation vs. plugin-only image rotation |
| `src/_ocrdebug.lua` | Opt-in OCR review loop: correct/incorrect prompts, session log, cropped images |
| `src/_geometry.lua` | Rectangle helpers and reading-order sorting |
| `src/_settings.lua` | Defaults, persistence and profile migration |
| `src/_timing.lua` | Opt-in timing spans |
| `src/types.lua` | Side-effect-free LuaLS type annotations, no runtime code |

## Ideas worth carrying into the rest of the code

- **The cache key is `page:mode:detector`.** Reading mode changes panel
  order and the detector changes the panel list itself, so both are part of
  the key. A page detected under one combination stays cached when the
  reading mode or detector changes and changes back, instead of being
  recomputed on every switch.
- **Cost and correctness live at different layers.** The segmenter operates
  on a deliberately small bitmap, so its Lua-side cost is close to fixed
  regardless of page complexity. The native detector's cost instead scales
  with how many probe points a page needs, which is why it is batched over
  one shared rasterization rather than one render per probe.
- **Native reliability is verified at runtime, not assumed.** Whether
  KOReader's native detector can safely reuse one rasterization across
  multiple probes is not something that can be confirmed by reading its
  binary dependency's source, so the plugin re-probes the same point before
  and after a batch and compares results. A mismatch falls back to one
  render per probe for that document, retried periodically rather than
  disabled for the rest of the session — scoping the fallback to the
  document that triggered it, instead of penalizing every later page.

## Beyond panel detection

The viewer also carries touch-and-hold text selection with OCR-backed
dictionary lookup on CBZ/CBR (and the embedded text layer on PDF), an
opt-in OCR review mode for building up a labeled dataset of lookup
mistakes, a device/image rotation picker, tap- and swipe-based panel
navigation you can independently toggle, and night-mode-aware rendering.
See [WORD-LOOKUP.md](WORD-LOOKUP.md) for the first two.

## Where to go next

- [ARCHITECTURE.md](ARCHITECTURE.md) — the full module diagram, the
  sequence diagram for opening a panel view, and the plugin lifecycle.
- [DETECTION.md](DETECTION.md) — the complete detection pipeline and every
  tuning knob it exposes.
- [MODES.md](MODES.md) — what Smart, Quick, and Deep mean for the
  reading experience, mapped onto the internal `detector` values.
- [WORD-LOOKUP.md](WORD-LOOKUP.md) — touch-and-hold text selection,
  dictionary lookup, and the OCR debug review mode.
- [PERFORMANCE.md](PERFORMANCE.md) — what each step costs, the memory
  budget, and how to measure it on a given device.
- [KNOWN-LIMITATIONS.md](KNOWN-LIMITATIONS.md) — current edge cases and
  known behavior that is not yet handled.
- [TESTING.md](TESTING.md) — running the dependency-free test suite.

# Panels+ and Ink Away development integration

Implemented on 2026-10-31 at the developer's request against both rolling
sources. The immutable stable pin and upstream rolling reference are unchanged.

## Working copies

- Panels+: this project, metadata 1.5.1, based on
  `f5903ffaa29f5ce8f1bc223cdeb1d96f236f2264`, with the annotation-surface changes.
- Ink Away: upstream checked with `./run-sync-submodules.sh --ink-away`; it was
  already at latest fetched remote commit
  `8dda5407e05446dddb20ba5d6fbac263955d0db3` (metadata 4.4.0).
- Local target branch: `feature/annotation-surfaces`, in
  `.cache/plugin-compatibility/worktrees/ink-away-annotation-surfaces/`.
  Implementation committed locally as `d87e2b097d6345085f9aa3ea0412bef23775ce10`.
  No upstream publication; live installation is recorded below.
- Reproducible target patch: [patches/annotation-surfaces.patch](patches/annotation-surfaces.patch).
  SHA-256: `f0c33b7ed9e98043af5051cd06f3cc2d43d9b42bd2af397fd70027b8650845d0`.
  `git apply --check` passes against the clean upstream reference above. The
  patch includes new files, the generic interface documentation and its test.

## Responsibilities

Ink Away exposes document-surface API version 1. It discovers a visible widget's
`getAnnotationSurface()` and uses that surface for the background, page identity,
coordinate mapping, content clip, placement cache, navigation and repainting.
Tools, undo, erasing and sidecar persistence remain in Ink Away. There are no
Panels+ names or detection branches in the target patch and no runtime method
replacement. The native reader remains the fallback.

Panels+ implements that contract for fixed-page panels, calls the target's public
ink renderer after its own image paint, and releases the surface before closing.
Its adapter handles crop, zoom, pan, quarter rotations, removed folds and viewer
replacement during page crossings. Reading overlays split joined views into
clipped affine regions. Path vertices are inserted at fold discontinuities so
drawn strokes keep their native page coordinates.

When Ink Away is loaded, **More Config… → Ink-away Settings…** offers:

- Keep spread fold joined while annotating.
- Show original fold while annotating.

The preference is saved as `inkaway_join_spread_fold`, defaults to joined and is
independent of the normal reading fold preference. Closing annotation mode
restores the reading preference. No entry appears with Ink Away absent/disabled.
The paired development build is required for annotation-surface support; the
unmodified stable/rolling target has no such API.

## Verification

Host reference: KOReader `035e00b21d0286325ef2e8a7e3b6326f340e2ded`.
Environment: desktop Lua/LuaJIT with KOReader/UI/framebuffer fixtures, not a running
reader or a physical stylus. No installed KOReader version/device is claimed.

Run from the Panels+ root, stable first:

```sh
./run-tests.sh --compatibility-plugin=ink-away --compatibility-plugin-version=4.4.0
./run-tests.sh --compatibility-plugin=ink-away --compatibility-plugin-version=rollingrelease
./run-tests.sh --compatibility-plugin=ink-away --compatibility-plugin-version=rollingrelease --compatibility-reference="$PWD/.cache/plugin-compatibility/worktrees/ink-away-annotation-surfaces"
./run-tests.sh --quicker
```

- Original stable 4.4.0: **5 native fallback/coexistence smoke checks passed**.
- Original upstream rolling: **5 native fallback/coexistence smoke checks passed**.
- Patched target worktree: **18 integration checks passed**. Actual counterpart
  Book, Place, Canvas, Transform, ReaderInkView and plugin entry points are
  loaded. Canvas initialization, UI/framebuffer painting and persistence are
  fixtures. Covers native fallback, absence, annotation entry, coordinates at
  four rotations, crossing folds, existing-ink paint, cache invalidation,
  unchanged-item preservation, panel navigation, asynchronous page handoff,
  independent fold choices, clipping regions, release/cleanup, visibility
  settings and an unrelated generic surface provider.
- Panels+ general suite: **539 passed**; Go OCR tests also pass.
- In the target worktree, `luajit tests/readerview.lua`: **236 checks passed**;
  `luajit tests/bookink.lua`: **133 checks passed**;
  `luajit tests/annotation_surface.lua`: **11 checks passed**. The last test uses
  the real Ink Away canvas, touch/pan/release handlers, placement, sidecar save
  and ink painter with the target's host mocks, against a generic provider.
- Targeted Panels+ StyLua/Luacheck, target Luacheck and whitespace checks pass.

Stable results establish fallback behavior only, not feature integration. The
requested feature depends on the patched rolling pair; no future version range
or full live coexistence claim is made.

## Build

```sh
./tools/plugin-compatibility/deploy.sh --plugin=ink-away --mode=rolling --source="$PWD/.cache/plugin-compatibility/worktrees/ink-away-annotation-surfaces" --install
```

Built target artifact:
`.cache/plugin-compatibility/builds/ink-away/v4_4_0/build.FNL0eT8c/ink-away.koplugin/`.
It includes the new runtime module and normal upstream assets/licenses. The initial build used a dirty local feature branch. This first build was artifact-only.

The developer subsequently authorized installation and established that future
rolling-release build requests include installation unless explicitly declined.
The deployment helper rebuilt the same target source with `--install` and installed
it into `../ink-away.koplugin/` on 2026-10-31. Installed artifact:
`.cache/plugin-compatibility/builds/ink-away/v4_4_0/build.NdR55rUV/ink-away.koplugin/`.
The unchanged previous copy was moved to
`~/.config/koreader/.panelsplus-plugin-backups/ink-away.6or3ie4t/ink-away.koplugin/`.
KOReader was not running during installation. No second Panels+ was installed.

Shared scenarios and target loaders live in `tests/plugin-compatibility/shared/`;
versioned suite entry points select the reference and invoke those scenarios.

## Reading-overlay follow-up

The user confirmed annotation editor entry and drawing, then reported that ink
disappeared after closing the editor. KOReader registers the installed plugin
under its directory name, `ui["ink-away"]`, ignoring the metadata name `inkaway`.
Panels+ had used only the metadata spelling. The reading-overlay call, viewer
release hook and conditional settings lookup now use the canonical runtime key,
with the legacy alias retained. Ink Away's generic interface and installed build
are unchanged.

The shared fixtures now use the host's actual registration key. A new regression
saves a stroke, closes the annotation canvas and repaints the focused panel.
That check and the existing-ink paint check both failed before the correction;
the feature-worktree suite now passes **19 checks**. Original stable/upstream
rolling fallback suites pass **5 each**. Live validation of post-editor visibility
still requires restarting KOReader with the changed Panels+ source.

## No crop cross-panel annotation follow-up

The user reported that ink drawn beyond the focused panel was correct on the
ordinary page but shifted when another panel was focused in No crop. This mode
composites page content into a larger screen-shaped canvas, with padding at page
edges. The annotation adapter had treated the clipped page-content rectangle as
the complete canvas, changing the apparent scale and position of existing ink.

Panels+ now records the complete canvas's native bounds using the actual content
bitmap dimensions and blit offsets, and uses those bounds for annotation mapping.
The render/transition crop rectangle stays separate. This preserves out-of-panel
drawing and does not modify existing annotation data or the installed target.

Four new checks reproduce the fault before the fix and cover all page edges,
four rotations, zoom/pan and cross-panel navigation. They compare projected ink
with the actual compositor's placement rather than only testing inverse mapping.
The modified-target suite now passes **23 checks**; original stable/upstream
fallback checks pass **5 each**, and the general Panels+ suite passes **539**.
Live No crop validation requires restarting KOReader.

## Limits and live checks

The editable canvas maps strokes and shape outlines through joined folds. Text
boxes, pictures and pixel-run fills spanning the removed strip use a local
affine transform while editing. Choose **Show original fold while annotating**
for accurate editing of these objects across a fold. The reading overlay uses
the clipped native regions for their retained content.

Native reader highlight-erasure boxes describe the underlying viewport. The
external surface deliberately does not reuse those boxes; ink erasing remains
available. This is not a reflowing embedded-image annotation implementation.

Live validation remains required: enter annotation mode through the real menu
and configured gesture; draw with the actual finger/stylus; verify palm rejection,
eraser/undo, both fold options, both sides and rotations, next/previous panel and
page crossings, closing/reopening and ordinary-page alignment after saving. Also
check device rotation, interrupted navigation, book closure and plugin disabling.
Automated tests do not establish input-driver behavior or refresh quality.

## Local commit snapshots

- Generic target interface: `d87e2b097d6345085f9aa3ea0412bef23775ce10` on `feature/annotation-surfaces`.
- Panels+ runtime integration: `0af707c2b168da63ca37a10d06b9ae039a5b6ceb`.
- Panels+ fold settings: `c93912ab4d05e96e39a48c4b046b1fca492feb9e`.
- Source branch: `feat/ink-away-compatibility`. No commits were pushed.

## Smooth animation follow-up

The user reported that ink stayed at the starting position during Smooth motion,
then jumped at handoff. The animated page uses temporary bitmaps while the
annotation surface had retained the original panel's geometry.

Panels+ now supplies geometry tied to the actual animation image: native bounds
for each scaled viewport frame or shared Classic canvas, and separate clipped
page regions for a cross-page canvas. Ink uses the same viewport offsets and
zoom as the displayed pixels. Temporary fold metadata is not reused, and normal
panel geometry resumes at handoff or preview return. The No crop compositor and
animation paths share the same native-canvas calculation.

Three new checks failed before the fix. Expanded checks now validate intermediate
ink positions against the actual render/blit/scale call chain with framebuffer
and widget fixtures, including both pages, margin changes, No crop, reading
direction, preview return, failures and close cleanup. The target-worktree suite
passes **30 checks**, the original stable/rolling fallback suites pass **5 each**,
the general suite passes **539**, and Meguru stable/rolling geometry suites pass
**14 each**. Only Panels+ source changed; the installed target remains the
implementation preserved in `d87e2b097d6345085f9aa3ea0412bef23775ce10`.

Restart KOReader for live validation that annotations follow the page continuously
during Smooth navigation. The automated checks do not validate physical refresh
behavior or input drivers.

## Annotator navigation and reading direction — 2026-11-01

The annotator now uses Panels+'s Smooth panel/page navigation and paints the live
surface during movement, retaining its own stationary toolbar. Drawing and repeat
turns are blocked until handoff, when editable operations are loaded at the new
position. Closing the editor cancels its subscriptions and late completions cannot
reactivate it. Reading visibility preferences do not hide editable ink in motion.

Physical arrows and unbound navigation swipes follow the supplied reading flow:
Manga (RTL) uses `<` to advance and `>` to go back; Comic (LTR) uses `>` to advance
and `<` to go back. Named next/previous actions remain logical forward/backward.
Ink Away obtains this through optional `readingDirection()` and progress callbacks
on its generic surface contract; it has no Panels+ identifiers or panel logic.

The target delta against `d87e2b097d6345085f9aa3ea0412bef23775ce10` is preserved in
[patches/annotation-navigation.patch](patches/annotation-navigation.patch), SHA-256
`0d6490942dea41afe1c54bfbb6261c7d88c87a5b8067067f404d59092d091735`.
Apply it after the original surface patch when reconstructing from upstream.
The target worktree remains on `feature/annotation-surfaces`, with this follow-up
uncommitted. Original stable and rolling references are unchanged.

Verification: stable **5**, upstream rolling **5**, patched worktree **34** checks
pass. The real target canvas suites pass **236** and **49** checks; Panels+ general
tests pass **539**. The new cases cover arrow flow, named actions, live modal
editor frames, cross-page/No crop motion, repeated input, input blocking and late
completion after close. Physical reader refresh/input behavior requires live use.

Installed development build:
`.cache/plugin-compatibility/builds/ink-away/v4_4_0/build.n2v16RYh/ink-away.koplugin/`.
Previous managed copy backed up at
`~/.config/koreader/.panelsplus-plugin-backups/ink-away.8rAuMrL4/ink-away.koplugin/`.
Restart KOReader to load both current sources.


## Fixed-page export — 2026-11-01

Export is owned by Ink Away and uses KOReader's original document pages. No new
Panels+ runtime code or export interface was added. Native saved coordinates
place ink on full pages even when it was drawn across panels or joined folds.
Fixed-page dispatch is separated from actual-PDF eligibility; comic archives
cannot enter the editable-copy writer merely because MuPDF sets `is_pdf`.
The shared fixed-page PDF/PNG path offers Compact and Detailed raster quality,
independent of editor canvas size, retaining page-by-page streaming and scopes.
Comic annotations are flattened in the exported PDF; originals stay unchanged.

The independent [export patch](patches/fixed-page-export.patch), SHA-256
`e8ee5d332e91df477bcb0034d0e103e9c38eeb693e171bf4cd852d79e84bcc28`, applies
to original upstream rolling without requiring the integration patches. It also
contains target documentation, host-mock tests and synthetic native archive tests.
Existing integration work is retained separately and remains uncommitted in the
target worktree.

New host-mock export checks: **42**; annotation/export checks **21**; view checks
**1462**; reader checks **236**; generic-surface checks **49**. Original stable and
rolling fallback checks pass **5 each**, modified-target integration **34**.
Installed KOReader `v2026.07.1` native suites pass **15** PDF-edit, **18** streaming
PDF, **13** small comic and **17** large comic checks. Both synthetic 100-page,
144 MB archives export to valid PDFs with correctly placed ink. Desktop CPU time
was about 6.6 seconds each and sampled peak RSS below 47 MB for the large test.
The native suite adapts host UI/registry/cache behavior; compressed/solid RAR,
physical-reader timing and live toolbar export remain unverified.

Current installed artifact is `build.yGg8gD1F`. Previous installation backup:
`~/.config/koreader/.panelsplus-plugin-backups/ink-away.7fBmIc2j/`.
All 285 installed payload checksums were verified. Restart KOReader and export
from the annotation toolbar to validate real comics. The target's
`docs/fixed-page-export.md` documents quality limits, commands and remaining limits.

Other notes (added by KristanLaimon):
Implemented and installed, entirely in Ink Away.

- CBZ/CBR share full-page PDF/PNG export with correctly positioned annotations.
- Editable export requires an actual PDF.
- Export → Page quality offers Compact or Detailed, independently of panel zoom.
- Processing remains page by page, with progress and cancellation.

Both synthetic 144 MB, 100-page CBZ/CBR archives exported successfully. Desktop tests took about 6.6 CPU seconds each, with sampled peak memory below 47 MB. Integration checks also pass.

Restart KOReader to try toolbar export on your comics. Changes remain uncommit


## Filename prompt crash correction — 2026-11-01

The user's live export attempt crashed before rendering, on tapping the filename
field. A Lua traceback recovered from the 06:39:52 PST core dump reports
`inputtext.lua:161: attempt to call method 'getFocusableWidgetXY' (a nil value)`.
Ink Away's prompt sheet supplied an InputContainer parent where the desktop
InputText expected FocusManager methods. The core's final native Wayland-thread
SIGSEGV does not establish a PDF encoder fault.

IconMenu now uses the host FocusManager; text prompts register their input in
its layout and retain their Back/page bindings. Panels+ and KOReader are unchanged.
A regression loads actual host InputText/FocusManager code, reproduces the exact
failure before this correction, and passes **7 checks** afterward. Existing target
view/dialog **1462**, reader **236**, surface **49**, export **42**, and patched
compatibility **34** checks pass. Original stable/rolling fallback checks pass
**5 each**. Rendering, keyboard display and event delivery remain adapted in the
new test; live validation is still required.

Retained [focus patch](patches/prompt-focus.patch), SHA-256
`906b4e8c568235a3bd6d88de8742005d3daccaa2df1401a8bd64d84d80ed28f3`, applies
after the export patch. Current installation: `build.jOs0emGa`; previous build
backed up at `~/.config/koreader/.panelsplus-plugin-backups/ink-away.OJO4z7UN/`.
Installed-file and 285 payload checksums verified. Restart KOReader, tap the
export filename field, then submit to validate the full live path.


## Cropped Smooth row transitions — 2026-11-01

Panels+-only correction: Tight/Loose/Margin transitions now retain only the
source and destination crops, for both background pixels and annotation clips.
Previously the rectangular union exposed neighboring source-row panels, while
ink used the entire synthetic canvas as its clip. No crop keeps surrounding
page/ink context as requested. Disjoint clip regions avoid double-compositing
ink where Loose crops overlap; allocation estimates include the owned mask.

Both failures were reproduced before the correction. Final modified-target
integration checks pass **38**, original stable/rolling fallback checks **5 each**;
source regression tests pass **541**, including **30** focused transition/viewport
checks. Coverage includes eased and Classic motion, cropped modes, an open
annotator, gutters/unrelated rows, overlap and mask-allocation failure. Rendering
and host UI remain fixtures; live verification requires restarting KOReader.
The target implementation and installation (`build.jOs0emGa`) are unchanged.

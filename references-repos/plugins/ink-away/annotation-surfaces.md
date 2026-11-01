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

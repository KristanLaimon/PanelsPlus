# Panels+ → Ink Away — history and restart handoff

This is the durable development backlog for this integration. Read **Current
state** and **Test and deployment runbook** after `/clear`, then the relevant
versioned entries. Paths are relative to the Panels+ root unless stated otherwise.
The chronology preserves the original investigation prose and KristanLaimon's
notes; old test counts, builds and pending checks belong to their dated entries.
This migration adds documentation, not a new runtime release or fresh runtime
validation. Unknown historical facts are marked instead of reconstructed from
assumptions.

## Current state — as of 2026-11-01

**Latest outcome:** the Fit beside toolbar arrow-handoff crash was reproduced
against the exact previous installation and fixed in Ink Away. Corrected build
`build.1nDooCiZ` is installed. Real KOReader widget tests pass; confirmation from
live reader use after that last installation is still pending.

### Versions, repositories and writable scope

| Component | Version / exact identity | Location and state |
| --- | --- | --- |
| Panels+ source | **1.5.1 development**; HEAD `22ef1e3e62f6c53d2fc1ca49b76798db38fcbefd` | This live plugin project, `/home/kristanlaimon/.config/koreader/plugins/panels_plus_development.koplugin`; branch `feat/ink-away-compatibility`; viewport/runtime/test work is now committed. This documentation migration is uncommitted; no staged changes were present at the final check. Inspect status before editing. |
| Ink Away target working copy | **4.4.0 patched rolling**; HEAD `d87e2b097d6345085f9aa3ea0412bef23775ce10`, based on upstream `8dda5407e05446dddb20ba5d6fbac263955d0db3`, plus the ordered patches below | `.cache/plugin-compatibility/worktrees/ink-away-annotation-surfaces/`; branch `feature/annotation-surfaces`; generic follow-ups are uncommitted. This is the authorized writable target. |
| Original stable target | **4.4.0** | `references-repos/plugins/ink-away/stable/v4_4_0/`; immutable reference, surface feature absent. |
| Original rolling target | **4.4.0 metadata**, commit `8dda5407e05446dddb20ba5d6fbac263955d0db3` | `references-repos/plugins/ink-away/rolling.koplugin/`; clean reference, surface feature absent. This is the last pinned/synced upstream identity, not a claim about today's remote HEAD. |
| KOReader source reference | Commit `035e00b21d0286325ef2e8a7e3b6326f340e2ded` | `references-repos/koreader/`; read-only host reference. |
| Native test runtime | **v2026.07.1**, Linux x86_64 | `/usr/lib/koreader`; real widgets/blitter/MuPDF tested in isolated scratch homes. This is distinct from the source reference. |

Keep the existing source and target changes. Do not refresh references, recreate
the working copy, reapply patches to it, or overwrite staged work just to resume.
No upstream PR/push is recorded. Earlier user-authorized atomic commits are in
entry 04; source viewport commit `22ef1e3e62f6c53d2fc1ca49b76798db38fcbefd`
was observed while preparing this handoff. Target follow-ups remain uncommitted.
Version strings have not been bumped:
**4.4.0 patched rolling is not the unmodified 4.4.0 release**.

### Responsibilities and agreed behavior

Panels+ knows about Ink Away; Ink Away exposes a generic surface contract without
Panels+ identifiers or runtime method replacement. Panels+ owns panel crop,
centering, fold joining, reading order, animation and native/screen mappings.
Ink Away owns tools, toolbar, annotation operations, sidecars, export and the
editor's snapshot/reload lifecycle. KOReader opens/renders the source format.

- Settings: **More Config → Ink-away Settings…** appears when Ink Away is loaded.
  `inkaway_join_spread_fold = true` defaults to joined while annotating,
  independently of the reading fold setting. `inkaway_fit_viewport = true`
  defaults to **Fit beside toolbar**; its menu entry cycles with **Full viewport**.
- Fit mode follows left/right/top/bottom toolbar placement and collapse. Closing
  restores normal layout. Existing Panels+ controls and the free viewport are
  intersected, avoiding double subtraction of overlapping bottom bars.
- Manga: physical `<` advances and `>` returns; Comic reverses those physical
  directions. Named next/previous actions retain their logical meanings.
- No crop allows drawing outside the focused panel and retains surrounding page
  pixels/ink during motion. Tight/Loose/Margin motion retains only the source and
  destination crops. Saved annotations remain in original page coordinates.
- Smooth motion uses live snapshots and stationary opaque toolbar chrome, blocks
  editing/repeated turns during handoff, then reloads the canvas. A new content
  widget must be painted **before** its clip is read, even when toolbar geometry
  is unchanged; see entry 12 and the native regression.
- CBZ/CBR and other fixed-page books share Ink Away's full-page PDF/PNG exporter.
  Only actual PDFs qualify for editable-copy export. Compact/Detailed quality
  is independent of panel zoom; output streams one page at a time. No original
  archive is rewritten. See entry 07 for measurements and limitations.

Known limits: joined-fold text/pictures/pixel fills use a local affine mapping in
the editable canvas; original-fold mode avoids ambiguity. Reloading a canvas for
navigation/reflow replaces its local editing history while preserving saved ink.
Native reader highlight-erasure boxes are not reused in an external viewport.
Reflowing embedded-image annotation is outside this implementation. Physical
reader refresh/input, compressed/solid RAR performance and unusually large source
scans have not been established by the synthetic/native tests.

### Installed build and next action

- Live target: `../ink-away.koplugin/`.
- Current artifact: `.cache/plugin-compatibility/builds/ink-away/v4_4_0/build.1nDooCiZ/ink-away.koplugin/`.
- Previous managed copy: `~/.config/koreader/.panelsplus-plugin-backups/ink-away.0MgfotSR/`.
- Installer provenance and `SHA256SUMS` are in `.panelsplus-deployment/` inside
  the artifact and installed target. Last installation verified the changed
  runtime file and all **285** payload hashes; KOReader was closed first.
- Next live check: restart KOReader; keep Fit beside toolbar enabled; navigate
  with Ink Away's `<`/`>` on all toolbar sides, then verify hiding/reopening,
  closing the annotator, both reading flows and page crossings. Record the user's
  actual result in a new entry. Do not infer confirmation from an unrelated reply.

### Retained target patch order

A fresh writable copy of upstream `8dda5407e05446dddb20ba5d6fbac263955d0db3`
needs all patches below in order. A copy at `d87e2b097d6345085f9aa3ea0412bef23775ce10`
already contains the first one. The current working copy contains the full
stack: **do not apply it again**. Apply/reverse checks and stack reconstruction
passed when recorded; hashes identify exact retained deltas. Export was also
verified independently against original rolling source.

| Order | Patch | SHA-256 |
| --- | --- | --- |
| 1 | [annotation-surfaces.patch](patches/annotation-surfaces.patch) | `f0c33b7ed9e98043af5051cd06f3cc2d43d9b42bd2af397fd70027b8650845d0` |
| 2 | [annotation-navigation.patch](patches/annotation-navigation.patch) | `0d6490942dea41afe1c54bfbb6261c7d88c87a5b8067067f404d59092d091735` |
| 3 | [fixed-page-export.patch](patches/fixed-page-export.patch) | `e8ee5d332e91df477bcb0034d0e103e9c38eeb693e171bf4cd852d79e84bcc28` |
| 4 | [prompt-focus.patch](patches/prompt-focus.patch) | `906b4e8c568235a3bd6d88de8742005d3daccaa2df1401a8bd64d84d80ed28f3` |
| 5 | [surface-toolbar.patch](patches/surface-toolbar.patch) | `f1e68065380059eb79d1ec1d728f55bf9dafe8367fcd30e9366a0aca466f85cf` |
| 6 | [surface-viewport.patch](patches/surface-viewport.patch) | `024dd32bebb363fa72055a0d704f46ee5f5eb0aba40ed247fb740d9de85bd92e` |
| 7 | [surface-viewport-reload.patch](patches/surface-viewport-reload.patch) | `2e2f3d1f21782d5edecd6647afbc5791f437b77e0438816e1d3ca4166c0a80c3` |

### Latest recorded validation, with its scope

| Check | Last recorded result | What was actually exercised |
| --- | --- | --- |
| Original stable / original rolling | **5 / 5 passed**, entry 12 | Fallback/coexistence smoke behavior; neither reference has the surface API. |
| Patched pair integration | **41 passed**, entry 12 | Actual selected target modules and source camera/geometry; host/UI/raster fixtures. |
| Panels+ general + Go | **546 passed**, entry 11 | Source regression suite and Go checks; not rerun for target-only entry 12. Python annotator environment was not synced and those tests were skipped. |
| Target viewport / reader / generic surface | **42 / 236 / 49 passed**, entry 12 | Real target model/editor logic with host fixtures, including unchanged-rectangle widget replacement. |
| Native whole-widget navigation | **32 cases / 800 checks**, entry 12 | 128 real toolbar arrow callbacks; actual KOReader layout/widgets/blitter and both runtime modules; synthetic document pixels and timer delivery. Old installed artifact fails. |
| Native toolbar pixels | **160 passed**, entry 11 | Actual blitter and toolbar paint/theme; widget/provider fixtures. Not a full live-layout claim. |
| Export and prompt regression | See entries 07–08 | Prior native library and focus checks, not newly rerun for entry 12. |

## Test and deployment runbook

These commands explain the historical evidence and support the next relevant
change; they are not a request to rerun everything on every resume. Set paths in
the shell where commands will run. Baseline pins are never edited to reproduce a
failure. Use the exact source/target identities listed in the relevant entry.

```sh
PANELSPLUS_ROOT=/home/kristanlaimon/.config/koreader/plugins/panels_plus_development.koplugin
INKAWAY_SOURCE="$PANELSPLUS_ROOT/.cache/plugin-compatibility/worktrees/ink-away-annotation-surfaces"
```

### A — Source and version-pinned integration

From `$PANELSPLUS_ROOT`, run stable before original rolling, then select the
modified target explicitly. These are different tested tuples.

```sh
cd "$PANELSPLUS_ROOT"
./run-tests.sh --compatibility-plugin=ink-away --compatibility-plugin-version=4.4.0
./run-tests.sh --compatibility-plugin=ink-away --compatibility-plugin-version=rollingrelease
./run-tests.sh --compatibility-plugin=ink-away --compatibility-plugin-version=rollingrelease --compatibility-reference="$INKAWAY_SOURCE"
./run-tests.sh --quicker
```

Version wrappers load `tests/plugin-compatibility/shared/inkaway_surface.lua`
against the selected counterpart in isolated module environments. `shared/` is
not an independently discovered suite. The general suite uses its own KOReader
fixtures. For selected source specs use `lua tests/run_tests.lua PATH_TO_SPEC`.
Use targeted `stylua --check`, `luacheck` and `git diff --check`; do not run the
current global formatter over reference copies. A previous `check.sh` invocation
did so accidentally; those edits were restored. Runtime lifecycle changes also
need the real-widget run below: a fixture can supply dimensions too early.

### B — Target portable model/editor tests

```sh
cd "$INKAWAY_SOURCE"
luajit tests/readerview.lua
luajit tests/annotation_surface.lua
luajit tests/surface_viewport.lua
luajit tests/bookexport.lua
luajit tests/annots.lua
```

Run other target checks only when relevant: `tests/bookink.lua` covers sidecars;
`tests/view.lua` covers the wider editor/dialog behavior. Portable fixtures live
in the target's `tests/mock/`; actual selected runtime modules are still loaded.

### C — Real KOReader widget navigation and toolbar painting

The native script is a standalone cross-project regression, not part of the
ordinary fixture-based spec discovery. It requires a built runtime. Scratch
homes prevent changes to real reader settings.

```sh
mkdir -p /tmp/inkaway-native-viewport/library
cd /usr/lib/koreader
SDL_VIDEODRIVER=dummy SDL_RENDER_DRIVER=software SDL_AUDIODRIVER=dummy \
KO_HOME=/tmp/inkaway-native-viewport ./luajit \
  "$PANELSPLUS_ROOT/tests/plugin-compatibility/shared/inkaway_native_viewport.lua" \
  "$PANELSPLUS_ROOT" "$INKAWAY_SOURCE"
./luajit "$INKAWAY_SOURCE/tests/realbb/surface_toolbar.lua" "$INKAWAY_SOURCE"
./luajit "$INKAWAY_SOURCE/tests/realbb/promptfocus.lua" "$INKAWAY_SOURCE"
```

For the recorded failing-before navigation run, use a separate scratch home and
pass `.cache/plugin-compatibility/builds/ink-away/v4_4_0/build.7eiLxb4a/ink-away.koplugin`
as the absolute target instead of the corrected worktree. That artifact is
historical and buggy; do not install it as the current fix. The exact pre-fix
trace and successful matrix are preserved in entry 12.

### D — Native export checks and synthetic archive measurement

```sh
cd /usr/lib/koreader
./luajit "$INKAWAY_SOURCE/tests/realbb/pdfedit.lua" "$INKAWAY_SOURCE"
./luajit "$INKAWAY_SOURCE/tests/realbb/pdfexport.lua" "$INKAWAY_SOURCE"
python3 "$INKAWAY_SOURCE/tests/realbb/comic_fixtures.py" /tmp/inkaway-comic-export-small
./luajit "$INKAWAY_SOURCE/tests/realbb/comicexport.lua" "$INKAWAY_SOURCE" /tmp/inkaway-comic-export-small
```

The optional larger measurement adds `--large` to the fixture generator and uses
another scratch directory. It writes two ~144 MB synthetic archives plus output
PDFs; it is not a reader-hardware timing claim. Export tests use real native
libraries with adapted UI/document registry, not the full live toolbar flow.

### E — Build/install and provenance

A rolling build request includes installation unless explicitly artifact-only.
Check KOReader is closed, then run the helper from the source root:

```sh
cd "$PANELSPLUS_ROOT"
./tools/plugin-compatibility/deploy.sh --plugin=ink-away --mode=rolling --source="$INKAWAY_SOURCE" --install
```

Keep backups outside `plugins/`, preserve installer identity/hash checks, and
verify installed bytes against the tested source. Do not install another Panels+
beside this live development copy. Build artifacts and code backups do not replace
annotation sidecars/settings. Do not publish, merge or push based on this log.

## Versioned chronology

Every entry below identifies both metadata versions and the local patch state.
Test steps distinguish reproduction, implementation checks and deployment from
live confirmation. The recorded host source pin is
`035e00b21d0286325ef2e8a7e3b6326f340e2ded`; native-runtime tests explicitly name
v2026.07.1. Original prose and author notes are retained under their historical
entry, so a historical sentence saying “current” does not override Current state.

## 2026-10-31 — 01: Generic document annotation surfaces — Panels+ 1.5.1 dev / Ink Away 4.4.0 patched rolling

**Versions and provenance:** Panels+ **1.5.1 development**, source base `f5903ffaa29f5ce8f1bc223cdeb1d96f236f2264`; Ink Away **4.4.0 patched rolling**, upstream `8dda5407e05446dddb20ba5d6fbac263955d0db3` plus the original surface patch (later committed as `d87e2b097d6345085f9aa3ea0412bef23775ce10`). KOReader source reference `035e00b21d0286325ef2e8a7e3b6326f340e2ded`; host/UI/pixel fixtures, no native runtime verified at this step.

### Investigation, tests and outcome by step

1. Investigated source/target responsibilities and introduced the generic surface contract; no failing-before count was recorded for the initial implementation.
2. Ran runbook **A** stable first, original rolling second and patched worktree third: **5 / 5 / 18 passed**. The first two cover fallback only; the 18 checks load actual counterpart modules with the fixtures described below.
3. Ran source general checks (**539**), target reader (**236**), book storage (**133**) and generic canvas (**11**); style/lint passed. Build/install provenance follows below. Live entry/drawing validation was pending at this step.

### Recorded implementation and notes

Implemented on 2026-10-31 at the developer's request against both rolling
sources. The immutable stable pin and upstream rolling reference are unchanged.

### Working copies

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

### Responsibilities

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

### Verification

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

### Build

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

## 2026-10-31 — 02: Reading overlay survives editor closure — Panels+ 1.5.1 dev / Ink Away 4.4.0 patched rolling

**Versions and provenance:** Panels+ **1.5.1 development**, source base `f5903ffaa29f5ce8f1bc223cdeb1d96f236f2264` plus the runtime-key correction; Ink Away **4.4.0 patched rolling**, original surface implementation later identified by `d87e2b097d6345085f9aa3ea0412bef23775ce10`, unchanged for this fix.

### Investigation, tests and outcome by step

1. Reproduced **2 failing checks** with the actual host registration key.
2. Added save → close editor → paint coverage using the real selected target placement/paint entry points and host/pixel fixtures. Runbook **A** passed **5 stable / 5 original rolling / 19 patched**.
3. Target bytes were unchanged, so no target rebuild was required. User confirmation established editor entry/drawing, not a complete live validation of the follow-up.

### Recorded implementation and notes

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

## 2026-10-31 — 03: No crop ink retains native page placement — Panels+ 1.5.1 dev / Ink Away 4.4.0 patched rolling

**Versions and provenance:** Panels+ **1.5.1 development**, source base `f5903ffaa29f5ce8f1bc223cdeb1d96f236f2264` plus compositor-bound mapping; Ink Away **4.4.0 patched rolling**, original surface implementation `d87e2b097d6345085f9aa3ea0412bef23775ce10`, unchanged.

### Investigation, tests and outcome by step

1. Reproduced **4 edge-placement failures** before the source fix.
2. Compared ink with actual render/blit/scale placements, exercising all page edges, rotations, pan/zoom and cross-panel drawing through selected target modules. Runbook **A** passed **5 / 5 / 23**.
3. Source general suite passed **539**; formatter/linter/whitespace checks passed. The target was not rebuilt. The cross-cutting editing/live limitations below still apply.

### Recorded implementation and notes

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


### Limits and live checks (cross-cutting)

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

## 2026-10-31 — 04: Local implementation commits — Panels+ 1.5.1 dev / Ink Away 4.4.0 patched rolling

**Versions and provenance:** Panels+ **1.5.1 development**, integration commit `0af707c2b168da63ca37a10d06b9ae039a5b6ceb`, fold settings `c93912ab4d05e96e39a48c4b046b1fca492feb9e`; Ink Away **4.4.0 patched rolling**, implementation commit `d87e2b097d6345085f9aa3ea0412bef23775ce10`.

### Investigation, tests and outcome by step

1. Committed the already-tested source and target changes locally in separate commits.
2. No new test execution was recorded for this commit-only step. The preceding **23** patched integration and **539** source results apply to the unchanged runtime bytes. No new deployment or push was recorded.

### Recorded implementation and notes

- Generic target interface: `d87e2b097d6345085f9aa3ea0412bef23775ce10` on `feature/annotation-surfaces`.
- Panels+ runtime integration: `0af707c2b168da63ca37a10d06b9ae039a5b6ceb`.
- Panels+ fold settings: `c93912ab4d05e96e39a48c4b046b1fca492feb9e`.
- Source branch: `feat/ink-away-compatibility`. No commits were pushed.

## 2026-10-31 — 05: Annotations follow Smooth animation frames — Panels+ 1.5.1 dev / Ink Away 4.4.0 patched rolling

**Versions and provenance:** Panels+ **1.5.1 development**, source base `a51b870892b94aadb1932b7e1f968128e8d9f8dc` plus animated geometry; Ink Away **4.4.0 patched rolling**, `d87e2b097d6345085f9aa3ea0412bef23775ce10`, unchanged.

### Investigation, tests and outcome by step

1. Reproduced **3 failures**: interpolated pan/zoom, Classic canvas pan and cross-page movement.
2. Drove actual camera callbacks and selected target modules; expected positions came from the render/copy/blit/scale fixture chain at intermediate repaints. Runbook **A** passed **5 / 5 / 30**.
3. Source general suite passed **539**; Meguru stable/rolling geometry checks passed **14 each**. Only source changed; target build/install was not repeated. Physical refresh remained unverified.

### Recorded implementation and notes

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

## 2026-11-01 — 06: Smooth annotator navigation and reading flow — Panels+ 1.5.1 dev / Ink Away 4.4.0 patched rolling

**Versions and provenance:** Panels+ **1.5.1 development**, source base `a51b870892b94aadb1932b7e1f968128e8d9f8dc` plus source animation changes; Ink Away **4.4.0 patched rolling**, `d87e2b097d6345085f9aa3ea0412bef23775ce10` plus `annotation-navigation.patch`.

### Investigation, tests and outcome by step

1. Exercised real ReaderInkView arrow/action handlers and source camera timers, including both reading flows, modal live frames, No crop/page boundaries and close/repeat-input cleanup. A numeric failing-before result was not recorded for this feature.
2. Runbook **A** passed **5 stable / 5 original rolling / 34 patched**; source general suite **539** and target reader/surface suites **236 / 49** passed. UI/layout/pixel buffers remained fixtures.
3. Built/installed `build.n2v16RYh`; the following text records the backup and remaining live check. This build has since been superseded.

### Recorded implementation and notes

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

## 2026-11-01 — 07: Shared fixed-page comic export — Panels+ 1.5.1 dev / Ink Away 4.4.0 patched rolling

**Versions and provenance:** Panels+ **1.5.1 development**, unchanged runtime at source commit `49c4b1ce84fd340acadc5aa102c354e9412c69ee`; Ink Away **4.4.0 patched rolling**, `d87e2b097d6345085f9aa3ea0412bef23775ce10` plus navigation/export patches; native KOReader **v2026.07.1**, Linux x86_64, in addition to the pinned host source reference.

### Investigation, tests and outcome by step

1. Inspected format routing and streaming; found that MuPDF provider `is_pdf` also covers comic archives and that raster quality depended on editor dimensions.
2. Added host-fixture export checks (**42**) for routing, geometry, bounded quality, selection and failure cleanup; annotation checks **21**, view **1462**, reader **236**, surface **49** passed. Runbook **A** passed **5 / 5 / 34**.
3. Runbook **D** used native MuPDF/blitter/encoders with adapted host UI/registry: PDF-edit **15**, streaming PDF **18**, small comics **13**, large comics **17** passed. Both synthetic 100-page ~144 MB archives exported; measured CPU/RSS and remaining archive/device limits are below.
4. Installed `build.yGg8gD1F`, now historical. These native library tests did not cover the real filename input widget, which failed later and was fixed in the next entry.

### Recorded implementation and notes

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

## 2026-11-01 — 08: Export filename prompt owns keyboard focus — Panels+ 1.5.1 dev / Ink Away 4.4.0 patched rolling

**Versions and provenance:** Panels+ **1.5.1 development**, runtime unchanged by this target-only fix (a new source HEAD was not recorded for this step); Ink Away **4.4.0 patched rolling**, `d87e2b097d6345085f9aa3ea0412bef23775ce10` plus navigation/export/focus patches; native KOReader **v2026.07.1**, Linux x86_64.

### Investigation, tests and outcome by step

1. Recovered the actual `inputtext.lua:161` Lua traceback from the crash core.
2. Loaded real host InputText tap/FocusManager code with rendering/keyboard/event adapters; filename and range prompt taps reproduced the missing-method failure. After the fix, **7** native focus checks passed.
3. Target view **1462**, reader **236**, surface **49**, export **42** and runbook **A** **5 / 5 / 34** passed. Installed `build.jOs0emGa`, now superseded. Physical input and full live export confirmation remained separate.

### Recorded implementation and notes

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

## 2026-11-01 — 09: Crop-aware transition backgrounds and ink — Panels+ 1.5.1 dev / Ink Away 4.4.0 patched rolling

**Versions and provenance:** Panels+ **1.5.1 development**, source base `08b17741455d650a3528cd277fb149a496373f85` plus crop masking; Ink Away **4.4.0 patched rolling**, `d87e2b097d6345085f9aa3ea0412bef23775ce10` plus navigation/export/focus patches, unchanged for this source fix.

### Investigation, tests and outcome by step

1. Reproduced **2 independent integration failures**: unrelated ink clip coverage and neighboring source-row pixels; No crop was the passing control.
2. Used real selected target modules and source animation/compositor calls with raster/UI fixtures. Final runbook **A** passed **5 / 5 / 38**, including an open annotator and both motion paths.
3. Source focused tests passed **30**, full general suite **541**, including disjoint overlap coverage and allocation-failure cleanup. A global formatter touched references during an attempted default check; those incidental edits were restored and reference cleanliness verified. Target was not rebuilt.

### Recorded implementation and notes

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

## 2026-11-01 — 10: Opaque toolbar during live transitions — Panels+ 1.5.1 dev / Ink Away 4.4.0 patched rolling

**Versions and provenance:** Panels+ **1.5.1 development**, source runtime unchanged at `8d44bd7c9ee7c1ae5fed63a32323e5b22e22074f`; Ink Away **4.4.0 patched rolling**, `d87e2b097d6345085f9aa3ea0412bef23775ce10` plus navigation/export/focus/toolbar patches; native KOReader **v2026.07.1**, Linux x86_64.

### Investigation, tests and outcome by step

1. Native toolbar pixel comparisons reproduced **48 failures in 112 checks**.
2. Restored only the toolbar backing, then expanded the real-blitter/layout/theme checks to **160 passed** across four sides, light/dark, grayscale/color, changing frames, hidden bars and stale canvas geometry. Widget/icon/input details were adapted; actual SVG/device refresh was not established by this test.
3. Target reader/surface **236 / 49** and runbook **A** **5 / 5 / 38** passed. Source general tests were not repeated for this target-only runtime change. Installed `build.rgY5ggSs`, now superseded.

### Recorded implementation and notes

Target-only follow-up: the asynchronous live-page paint path now clears the
visible toolbar's full rectangle before drawing its transparent button cells,
icons, tool marks and dark-theme inversion. Previously page pixels showed
through between icons because this path skipped the normal opaque backing.
Only the toolbar rectangle is restored, so an old canvas clip cannot obscure
moving content. Hidden toolbars do not paint a backing. Panels+ runtime and the
generic surface contract are unchanged.

The original code failed 48 native toolbar-pixel comparisons; the expanded final
suite passes **160** checks across all four sides, light/dark, grayscale/color,
changing frames, hidden bars and stale canvas geometry. Uses the actual C blitter
and ReaderInkView layout/paint/theme, with host widgets/provider/input fixtures.
Reader **236**, generic-surface **49**, patched compatibility **38** checks pass;
original stable and rolling fallback suites pass **5 each**.

Retained [toolbar patch](patches/surface-toolbar.patch), SHA-256
`f1e68065380059eb79d1ec1d728f55bf9dafe8367fcd30e9366a0aca466f85cf`, follows
the navigation/export/focus patches. The full retained stack reconstructs the
current worktree. Installed build: `build.rgY5ggSs`; previous copy backed up at
`~/.config/koreader/.panelsplus-plugin-backups/ink-away.iwo1EpnM/`.
All 285 installed payload checksums match. Restart KOReader for live validation.


Notes: (by KristanLaimon)
Ink Away uses a special paint path during Smooth transitions: it draws the moving page, then draws its toolbar on top.

The toolbar’s button cells are intentionally transparent. Normal editor rendering paints an opaque background behind them, but the transition path skipped that step. That let the moving page show through between the icons.

The fix belongs in Ink Away because it owns the toolbar and that paint path. Panels+ supplies the moving page and its coordinates; it shouldn’t need to know the toolbar’s size, position, visibility or theme.

Ink Away now paints the toolbar’s background before its buttons and icons. The fix works for any viewer using the generic surface interface—there’s no Panels+ identification in it.

## 2026-11-01 — 11: Default fit beside annotator toolbar — Panels+ 1.5.1 dev / Ink Away 4.4.0 patched rolling

**Versions and provenance:** Panels+ **1.5.1 development**, source base `b682d9ac83be0fee2fd939d1def6051d34a464df` plus uncommitted fit-viewport changes; Ink Away **4.4.0 patched rolling**, `d87e2b097d6345085f9aa3ea0412bef23775ce10` plus navigation/export/focus/toolbar/viewport patches; native KOReader **v2026.07.1**.

### Investigation, tests and outcome by step

1. Added source viewport/settings tests and a generic-provider target test that rejects clip access before a fresh snapshot. The test caught a provider-preference refresh ordering problem during implementation; fixed before deployment.
2. Source full **546**, focused viewport/settings **41**, focused navigation/viewport **31**, target viewport **38**, reader **236**, surface **49**, native toolbar **160** passed. Runbook **A** passed **5 / 5 / 41**.
3. These animation integration tests supplied widget dimensions via fixtures and missed replacement of a real unpainted ImageWidget after handoff. Installed `build.7eiLxb4a`; the user subsequently reported the crash described in the next entry. Do not treat that build as the current fixed installation.

### Recorded implementation and notes

Panels+ now defaults to fitting panels into the space beside the annotator's
visible toolbar. More Config → Ink-away Settings… → **Panel viewport** cycles
**Fit beside toolbar** / **Full viewport**. The first follows left/right/top/bottom
placement and collapse; the second keeps the previous overlay framing. Closing
the annotator restores ordinary panel layout. Source controls and the annotator
viewport are intersected so overlapping bottom bars are not subtracted twice.

Ink Away's optional generic `setViewport(rect, refresh)` report supplies free
screen space; Panels+ owns fit/centering and Smooth camera geometry. No target
plugin identity or panel-specific behavior is added. Edits are anchored before
reflow; snapshot primes new widget bounds before clip lookup; editable operations
are then reloaded. Provider-side preference changes use the same transaction.
Saved native coordinates and untouched items are retained; local canvas editing
history is replaced when reloaded, as on a page load.

The [viewport patch](patches/surface-viewport.patch), SHA-256
`024dd32bebb363fa72055a0d704f46ee5f5eb0aba40ed247fb740d9de85bd92e`, follows
the navigation/export/focus/toolbar patches. The full stack reconstructs current
target source and tests. Stable/original rolling references remain unchanged.

Source regressions **546**, patched integration **41**, original stable/rolling
fallback **5 each** pass. Target generic viewport **38**, reader **236**, existing
surface **49**, native toolbar pixel **160** checks pass. Source integration
covers all edges, eased/Classic motion, No crop/margins, setting cycles while
open and page crossings. Host widgets/rasterization remain fixtures; physical
reader behavior requires live validation.

Installed artifact: `build.7eiLxb4a`. Previous copy:
`~/.config/koreader/.panelsplus-plugin-backups/ink-away.YON9nsjt/`.
Installed viewport code and 285 payload checksums verified. Restart KOReader.

## 2026-11-01 — 12: Prime replacement widgets before reading their clip — Panels+ 1.5.1 dev / Ink Away 4.4.0 patched rolling

**Versions and provenance:** Panels+ **1.5.1 development**, source base `b682d9ac83be0fee2fd939d1def6051d34a464df` plus the same pending viewport changes; Ink Away **4.4.0 patched rolling**, `d87e2b097d6345085f9aa3ea0412bef23775ce10` plus the complete patch chain through `surface-viewport-reload.patch`; native KOReader **v2026.07.1**, Linux x86_64.

### Investigation, tests and outcome by step

1. Inspected the 08:07:29 PST core: final native cursor-thread fault during exit, with no retained Lua traceback. Reproduced independently with real host widgets.
2. Runbook **C** against the exact old artifact `build.7eiLxb4a` failed on the first completed arrow turn at `_annotationsurface.lua:198` (`d` is nil). The same test against corrected target source passed **32 cases / 800 checks**, including **128 real arrow callbacks**. It uses real UI/layout/blitter code; document pixels and timer delivery are fixtures.
3. Target portable viewport **42**, reader **236**, generic surface **49** and runbook **A** **5 / 5 / 41** passed. Source general **546** was carried forward from the preceding source change, not rerun for this target-only correction.
4. Installed `build.1nDooCiZ`, verified all **285** payload hashes and the changed runtime file. Latest live confirmation is still pending.

### Recorded implementation and notes

The reported Fit beside toolbar crash was reproduced with real KOReader widgets:
a completed turn creates a fresh ImageWidget whose `.dimen` is still nil. Ink
Away's pre-snapshot placement queried its clip because the toolbar rectangle
had not changed. `loadBookPage` now always marks that preliminary phase pending,
paints the snapshot, then reads the landed widget's clip. This is a target-only
reload-order correction; the original viewport feature source remains intact.

The exact old artifact `build.7eiLxb4a` fails in this native reproduction at
`_annotationsurface.lua:198`; fixed code passes **32 cases / 800 checks**, covering
128 real arrow callbacks across four toolbar sides, Comic/Manga, eased/Classic
and Tight/Margin. The target portable viewport test adds the unchanged-rectangle
widget replacement and passes **42** checks; reader **236**, surface **49**, patched
integration **41**, original stable/rolling fallback **5 each** pass.

For layout/navigation changes, run the real-widget regression from a KOReader
runtime, with an existing isolated scratch home and library folder:

```
SDL_VIDEODRIVER=dummy SDL_RENDER_DRIVER=software SDL_AUDIODRIVER=dummy \
KO_HOME=/tmp/inkaway-native-viewport ./luajit \
  SOURCE/tests/plugin-compatibility/shared/inkaway_native_viewport.lua SOURCE TARGET
```

`SOURCE` is the Panels+ root; `TARGET` is the exact modified Ink Away source or
built artifact. The script uses real KOReader UI/layout/painting; document pixels
and timer delivery are fixtures. It does not test physical input/refresh behavior.

Retained [reload patch](patches/surface-viewport-reload.patch), SHA-256
`2e2f3d1f21782d5edecd6647afbc5791f437b77e0438816e1d3ca4166c0a80c3`, follows
the viewport patch. Current installed artifact: `build.1nDooCiZ`; backup:
`~/.config/koreader/.panelsplus-plugin-backups/ink-away.0MgfotSR/`.
Installed reload code and 285 payload checksums verified. Restart for live testing.

Notes: (KristanLaimon)
Reproduced and fixed. Ink Away was reading the new panel widget’s clip before its first paint. It now paints the snapshot before reading the clip.

Installed the corrected build. Passed 800 real KOReader widget checks, including 128 arrow turns across all toolbar positions and Manga/Comic flow.

Restart KOReader and try < / > again

## 2026-11-01 — 13: Durable workflow history standard — Panels+ 1.5.1 dev / Ink Away 4.4.0 patched rolling

**Versions and provenance:** Documentation-only change over Panels+ **1.5.1
development**, final observed HEAD `22ef1e3e62f6c53d2fc1ca49b76798db38fcbefd`
(the source viewport implementation is now committed); Ink Away **4.4.0 patched rolling**, HEAD
`d87e2b097d6345085f9aa3ea0412bef23775ce10` plus the seven retained patches.
This task changed no runtime version, source code, installation or Git staging.
The source commit observed during the task is recorded above; historical entry
versions and test executions retain their original bases.

The user requested this backlog as the standard for every cross-plugin task,
with versions and test evidence at each step so a new AI session can resume
from the file alone. The old per-feature backlog became `history-changes.md`.
The cross-plugin skill now requires creation/maintenance of the per-plugin
history, reading it when resuming, updating evidence during work and leaving
a current-state handoff before ending. Its supporting reference defines the
narrative style, per-entry fields and evidence boundaries.

### Investigation, tests and outcome by step

1. Read the original backlog, relationship evidence and actual metadata/repository
   state. Migrated **12 existing milestones**, preserving all **323 original
   non-heading, nonblank lines**, including KristanLaimon's notes. Added version
   provenance and step-level evidence from the existing records; unavailable
   historical facts are explicitly marked. Added current state, patch hashes,
   test commands, installation/backup and remaining live checks at the top.
2. Renamed the backlog, updated its two relationship links, and added discovery
   from `releases.md`. The target's generic API document
   `docs/annotation-surfaces.md` and retained runtime patches keep their names.
3. The bundled skill-creator checker could not run because its Python dependency
   PyYAML is not installed. Direct validation passed for this skill's simple
   two-scalar frontmatter, local Markdown links, code fences, every chronological
   entry's version/provenance/test fields, original-prose preservation, all seven
   patch hashes and unchanged Git staging. `git diff --check` passed. No runtime
   suite was rerun for this documentation-only work; runtime evidence remains
   dated in the preceding entries.
4. Applied the prepared rule and style reference to
   `.agents/skills/panelsplus-crossplugin-dev/`; the installed skill passed the
   same direct checks. Next session: read Current state, verify actual working
   copies/provenance, then continue the user's task. The last runtime fix still
   awaits live confirmation; this documentation task does not establish it.
5. Refreshed repository identities before handoff: source HEAD is now
   `22ef1e3e62f6c53d2fc1ca49b76798db38fcbefd`, with the viewport implementation
   committed. The target remains dirty over `d87e2b097d6345085f9aa3ea0412bef23775ce10`.
   This is an observed state update, not a commit made by this documentation task
   or a fresh runtime test result.


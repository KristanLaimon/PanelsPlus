## Current state — Draw handler-wrapper fix, 2026-11-07

Latest correction supersedes earlier summaries: Draw stayed hidden even after the rolling deployment because KOReader wraps onInkAwayAnnotate in a callable HandlerSandbox table. Panels+ now accepts the wrapped action after successful integration. The native test now loads the **actual installed plugin through KOReader PluginLoader**, reproduces the missing button before the fix, and passes 48 scenarios / 2592 checks afterward. Unit control/support 20, stable fallback 5 and rolling integration 44 pass. Full 579-unit run predates this one-condition correction.

Only one active Ink Away exists; no old copy was found to delete. Current install remains build.uCHGAckH from canonical rolling b5b83b2f6b67f2503e1fb4dada92dffc2a60d1c2; backup remains outside plugins at ink-away.3nm5FqK3. Panels+ 1.6.0 base d7b2f3408f8b4671e9afe2fd32f84d40e827b7e4, feat/ink-away-compatibility. Prior user staging preserved; gate fix/tests/history are unstaged. No target source changes or new installation. **Restart KOReader again to load the corrected Panels+ code**, then verify Draw after Inverted. Earlier history was not inspected. See final dated entry for exact failure and commands.

---

## Current state — installed rolling API, 2026-11-07

Latest user decision supersedes earlier summaries: **install current rolling Ink Away**, keeping the newer-API Draw implementation. Missing Draw was caused by the old installed plugin, which used surface discovery and lacked the registry API. The exploratory legacy fallback was removed. Panels+ task changes remain staged as left by the user; only this follow-up history/index is additionally unstaged. No commits or staging performed by the agent.

Installed canonical Ink Away 4.4.0-derived rolling b5b83b2f6b67f2503e1fb4dada92dffc2a60d1c2 (feature/plugin-integration), artifact build.uCHGAckH; 288 payload checksums verified. Backup: /home/kristanlaimon/.config/koreader/.panelsplus-plugin-backups/ink-away.3nm5FqK3/. Target's existing staged .foxnvim/pins.json preserved. Panels+ 1.6.0 base d7b2f3408f8b4671e9afe2fd32f84d40e827b7e4, feat/ink-away-compatibility. Host source 035e00b21d0286325ef2e8a7e3b6326f340e2ded; native runtime v2026.07.1.

Actual installed payload passes 48 native scenarios / 2592 checks, including opening through Draw. Stable fallback 5, rolling integration 44 and final control/support units 20 pass; preceding full 579-unit run retained. **Restart KOReader** before live validation. No newer remote sources fetched. Earlier large history was not inspected; final dated entry records deployment and exact validation details.

---

## Current state — latest task update, 2026-11-07

This update supersedes older current-state summaries below; historical evidence is preserved verbatim. Latest task: Smooth No crop now matches the padded canvas fit beside Ink Away's toolbar. Conditional **Draw (Ink-away)** follows Inverted and opens the existing Ink Away annotator after successful registration. All runtime changes belong to Panels+.

Panels+ 1.6.0 rolling: `feat/ink-away-compatibility`, base `d7b2f3408f8b4671e9afe2fd32f84d40e827b7e4`, new uncommitted runtime/tests/docs changes. Canonical Ink Away 4.4.0-derived rolling: `references-repos/plugins/ink-away/rolling.koplugin/`, `feature/plugin-integration`, base `b5b83b2f6b67f2503e1fb4dada92dffc2a60d1c2`; only its pre-existing staged `.foxnvim/pins.json` remains dirty. Stable `v4_4_0` unchanged. Host source `035e00b21d0286325ef2e8a7e3b6326f340e2ded`; native runtime v2026.07.1 Linux x86_64.

Latest checks: 579 Lua units, 5 stable fallback, 44 rolling integration, 48 native cases / 2592 checks; Go and targeted style/lint/whitespace checks pass. Native padded No crop reproduction fails with the old animation code and passes with the fix. No build/install/commit/push; prior artifact/backup identity not re-investigated. Restart the live development plugin and validate on the reader; physical input/refresh remains unverified. See the final dated entry for commands, fixtures, failures and next checks. Per user request, earlier history was not inspected during this task.

---

# Panels+ → Ink Away — history and restart handoff

This is the durable development backlog for this integration. Read **Current
state** and **Test and deployment runbook** after `/clear`, then the relevant
versioned entries. Paths are relative to the Panels+ root unless stated otherwise.
The chronology preserves the original investigation prose and KristanLaimon's
notes; old test counts, builds and pending checks belong to their dated entries.
The chronology includes documentation-only and runtime changes; their validation
belongs to the corresponding dated entry. Unknown historical facts are marked
instead of reconstructed from assumptions.

## Current state — as of 2026-11-07

**Rebase validation:** `feat/ink-away-compatibility` is rebased onto
`main-nightly` (`cbfe882`), with all tests passing. The 2026-11-07 rebase entry at the end records the
baseline, merge fixes and final checks. Earlier build/install information below
is historical; this task changes source only and leaves the target checkout and
its staged file untouched.

### State carried forward from 2026-11-02

**Documentation site:** new standalone Fumadocs/Bun submodule at
`references-repos/plugins/ink-away/Ink-away-documentation/`, origin
`https://github.com/KristanLaimon/Ink-away-documentation.git`. The former template
code is replaced with Fumadocs integration/API articles and an Ink-away.koplugin
landing page. Site changes through c19a2a7 (crayon animation) are pushed to
origin/main. A subsequent readability rewrite is local and uncommitted:
14 pages, beginner introduction, two guides and one page per public Ink Away
method/field (entry 31). Static build, Lua snippets and exported links pass.
Parent submodule registration/staging should be inspected before committing.

**Latest outcome:** the loading-order handshake is complete and validated in
`references-repos/plugins/ink-away/rolling.koplugin/`, local branch
`feature/plugin-integration`, now HEAD
`b5b83b2f6b67f2503e1fb4dada92dffc2a60d1c2` with unchanged ancestor base
`8dda5407e05446dddb20ba5d6fbac263955d0db3`. Four atomic commits were pushed
to the user fork (entry 25). The ready instance and
per-consumer method queue (`pending[consumer] = true`, then
`consumer:configureInkAway(ink)`) supports either loading order (entry 24); composite installs
are idempotent and return cleanup. Panels+ uses that protocol and preserves
handoffs. Tests and API/architecture docs are updated in the canonical checkout.
The former `.cache/.../ink-away-annotation-surfaces/` directory is a **frozen
backup**. Do not edit/build from it or create new retained patches/worktrees.
The skill now requires direct rolling development on a local feature branch,
without commits, staging, remote updates or rebase unless explicitly requested.
The obsolete generated patch archive has been removed; historical identities
remain below (entry 21). Stable 4.4.0 remains unchanged. Ink Away changes are committed/pushed; Panels+
changes remain uncommitted. This work is **not installed**;
the installed target remains `build.1nDooCiZ`. Next: review the working diffs;
only build/install or integrate upstream when the user requests those actions.

### Versions, repositories and writable scope

| Component | Version / exact identity | Location and state |
| --- | --- | --- |
| Panels+ source | **1.5.1 development**; HEAD `b648faf4ade09ea22b06716406ba2288a3389c0d` | This live plugin project, `/home/kristanlaimon/.config/koreader/plugins/panels_plus_development.koplugin`; branch `feat/ink-away-compatibility`; the provider registration, integration/native tests, history and patch-archive removal are uncommitted; no source staging was changed by this task. Inspect status before editing. |
| Ink Away active source | **4.4.0 patched rolling**, HEAD `b5b83b2f6b67f2503e1fb4dada92dffc2a60d1c2`, ancestor base `8dda5407e05446dddb20ba5d6fbac263955d0db3`, branch `feature/plugin-integration` | `references-repos/plugins/ink-away/rolling.koplugin/`; explicitly user-authorized writable checkout. Four commits pushed to kristanlaimonorigin; branch tracks that fork. Only .foxnvim remains untracked. Parent submodule pointer is unstaged. |
| Ink Away frozen backup | HEAD `d87e2b097d6345085f9aa3ea0412bef23775ce10`, plus refactor/docs/loading-order changes at migration | `.cache/plugin-compatibility/worktrees/ink-away-annotation-surfaces/`; preserved byte-for-byte, including user staging and `.foxnvim/pins.json`. Do not use for further development. |
| Original stable target | **4.4.0** | `references-repos/plugins/ink-away/stable/v4_4_0/`; immutable reference, surface feature absent. |
| Upstream rolling base | **4.4.0 metadata**, commit `8dda5407e05446dddb20ba5d6fbac263955d0db3` | Ancestor base of the now-writable rolling checkout. Historical original-rolling test results refer to this commit without local changes; current default rolling tests use the modified checkout. |
| KOReader source reference | Commit `035e00b21d0286325ef2e8a7e3b6326f340e2ded` | `references-repos/koreader/`; read-only host reference. |
| Native test runtime | **v2026.07.1**, Linux x86_64 | `/usr/lib/koreader`; real widgets/blitter/MuPDF tested in isolated scratch homes. This is distinct from the source reference. |

Keep the existing source and target changes. The ownership table above supersedes
historical worktree/immutable-rolling instructions below. Do not refresh references, recreate
the working copy, reapply patches to it, or overwrite staged work just to resume.
No upstream PR/push is recorded; the user fork branch push is recorded in entry 25. Earlier user-authorized atomic commits are in
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

### Historical change identities (patch files removed)

The generated Git patch archive was removed on 2026-11-02 by user request
(entry 21). This table preserves the original filenames, ordering and hashes as
provenance; it is not a list of available files or instructions to reapply them.
The historical base was `8dda5407e05446dddb20ba5d6fbac263955d0db3`; commit
`d87e2b097d6345085f9aa3ea0412bef23775ce10` already included the first change.
The dated chronology below retains the actual apply/reconstruction/test results
from when those artifacts existed. Current source is the uncommitted canonical
rolling checkout; the former worktree remains a frozen source backup.

| Order | Patch | SHA-256 |
| --- | --- | --- |
| 1 | `annotation-surfaces.patch` | `f0c33b7ed9e98043af5051cd06f3cc2d43d9b42bd2af397fd70027b8650845d0` |
| 2 | `annotation-navigation.patch` | `0d6490942dea41afe1c54bfbb6261c7d88c87a5b8067067f404d59092d091735` |
| 3 | `fixed-page-export.patch` | `e8ee5d332e91df477bcb0034d0e103e9c38eeb693e171bf4cd852d79e84bcc28` |
| 4 | `prompt-focus.patch` | `906b4e8c568235a3bd6d88de8742005d3daccaa2df1401a8bd64d84d80ed28f3` |
| 5 | `surface-toolbar.patch` | `f1e68065380059eb79d1ec1d728f55bf9dafe8367fcd30e9366a0aca466f85cf` |
| 6 | `surface-viewport.patch` | `024dd32bebb363fa72055a0d704f46ee5f5eb0aba40ed247fb740d9de85bd92e` |
| 7 | `surface-viewport-reload.patch` | `2e2f3d1f21782d5edecd6647afbc5791f437b77e0438816e1d3ca4166c0a80c3` |
| 8 | `annotation-extension-api.patch` | `6238cffd35f77e51be8f55e1f93f3a1f408a1bc318f7f252ceff9e08bb0d63d2` |

### Latest recorded validation, with its scope

| Check | Last recorded result | What was actually exercised |
| --- | --- | --- |
| Stable fallback / current modified rolling | **5 / 44 passed**, entry 20 | Actual pinned stable fallback; modified canonical rolling integration, including both loading orders and source cleanup. Historical original rolling fallback **5** remains entry 17 evidence. |
| Local pair integration | **44 passed**, entry 20 | Actual selected target modules and source camera/geometry; host/UI/raster fixtures. |
| Panels+ general + Go | **546 passed**, entry 17 | Source regression suite and Go checks. Python annotator environment was not synced and those tests were skipped. |
| Target viewport / reader / generic surface | **43 / 236 / 49 passed**, entry 14 | Real target model/editor logic with host fixtures, including unchanged-rectangle widget replacement. |
| Native whole-widget navigation | **32 cases / 800 checks**, entry 20 | 128 real toolbar arrow callbacks; actual KOReader layout/widgets/blitter and both runtime modules; synthetic document pixels and timer delivery. Old installed artifact fails. |
| Native toolbar pixels | **160 passed**, entry 14 | Actual blitter and toolbar paint/theme; widget/provider fixtures. Not a full live-layout claim. |
| Loading order / API / storage / export | **47 / 30 / 133 / 42 / 21 passed**, entry 20 | Actual Ink Away init/facade/registry/editor with host fixtures. Prior view/dialog **1462**, native toolbar **160** and focus **7** remain entry 14 evidence; not repeated for this handshake. |

## Test and deployment runbook

These commands explain the historical evidence and support the next relevant
change; they are not a request to rerun everything on every resume. Set paths in
the shell where commands will run. Baseline pins are never edited to reproduce a
failure. Use the exact source/target identities listed in the relevant entry.

```sh
PANELSPLUS_ROOT=/home/kristanlaimon/.config/koreader/plugins/panels_plus_development.koplugin
INKAWAY_SOURCE="$PANELSPLUS_ROOT/references-repos/plugins/ink-away/rolling.koplugin"
```

### A — Source and version-pinned integration

From `$PANELSPLUS_ROOT`, run stable fallback before the modified canonical
rolling source. Default rolling selection now loads the current local changes.
Historical original-rolling/worktree results are separate tuples, not current
source validation.

```sh
cd "$PANELSPLUS_ROOT"
./run-tests.sh --compatibility-plugin=ink-away --compatibility-plugin-version=4.4.0
./run-tests.sh --compatibility-plugin=ink-away --compatibility-plugin-version=rollingrelease
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
luajit tests/integration.lua
luajit tests/loading_order.lua
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
No build/install is authorized merely by source changes. When requested, check
KOReader is closed and run the helper against the canonical rolling source:

```sh
cd "$PANELSPLUS_ROOT"
./tools/plugin-compatibility/deploy.sh --plugin=ink-away --mode=rolling --install
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
- Reproducible target patch: `annotation-surfaces.patch`.
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
`annotation-navigation.patch`, SHA-256
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

The independent `fixed-page-export.patch`, SHA-256
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

Retained `prompt-focus.patch`, SHA-256
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

Retained `surface-toolbar.patch`, SHA-256
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

The `surface-viewport.patch`, SHA-256
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

Retained `surface-viewport-reload.patch`, SHA-256
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



## 2026-11-02 — 14: Explicit extension boundary — Panels+ 1.5.1 dev / Ink Away 4.4.0 patched rolling

**Versions and provenance:** Panels+ HEAD `b648faf4ade09ea22b06716406ba2288a3389c0d`,
branch `feat/ink-away-compatibility`; Ink Away worktree HEAD
`d87e2b097d6345085f9aa3ea0412bef23775ce10`, branch `feature/annotation-surfaces`,
with the existing seven-patch stack (staged before this task). Original stable
4.4.0 and rolling `8dda5407e05446dddb20ba5d6fbac263955d0db3` remain immutable.
Host reference remains `035e00b21d0286325ef2e8a7e3b6326f340e2ded`.

User authorized refactoring both working copies while preserving behavior and
consolidating only the target worktree's docs into FEATURES.md, Arquitecture.md
and Plugin-integration.md. Preserve unrelated export/focus fixes. No installation
or publication requested.

### Investigation, tests and outcome by step

1. Read-only review found a generic surface contract, but native behavior remained
   inline and lifecycle/provider registration were not public abstractions.
2. Before edits, created and reapplied one backup in each repository. Ink Away
   stash `12e139c5ef9e34d8bd9b23399f0ef31643776f9c` restored with `--index`.
   Panels+ was clean; normal stash reported no changes, so recorded its exact
   clean HEAD/index trees as stash `a039b65dd0fa791cc94234b1b01f1e4e21d23530`
   and applied it once. Both stash entries are retained. Initial sandbox attempts
   could not write Git metadata; approved escalation completed the backups.
3. Extracted the existing native placement/pages/layout implementation into a
   default viewer adapter. External providers implement the same internal
   viewer contract. Added widget-owned public registration with duplicate-owner
   rejection, visibility selection, lifecycle listeners and isolated callbacks.
   Panels+ registers once and unregisters on close; version-1 discovery remains
   available to existing consumers. Editor navigation now uses one callback path.
4. Initial stable-first/original-rolling checks passed **5 / 5**. Existing patched
   integration passed **41**, then **42** with explicit registered-provider
   selection and actual Panels+ close/unregister coverage. Initial native widget
   regression passed **32 cases / 800 checks**. New public API test passed **25**.
   First storage regression failed because its fixtures bypassed Book.new and
   injected the old private _doc field; updated those fixtures to construct Book
   normally and inject the native adapter's placement fixture. Storage **133**
   then passed. New facade test initially lacked the host Dispatcher module;
   added an explicit dispatcher fixture (dispatch itself is not exercised).
   Two early test invocations used the wrong cwd; no dependent files changed
   in those failed commands. Expanded tests and final native checks in progress.
5. Consolidated only the target docs directory into unchanged FEATURES.md,
   Arquitecture.md and Plugin-integration.md. Removed the five added feature/fix
   documents; consumer contract/viewport details were consolidated, while testing
   commands moved into tests/README.md. Existing detailed investigation/export
   evidence remains in this history and the retained historical patches/backups.
   Existing installed build `build.1nDooCiZ` is unchanged. No live result yet.

6. Final automated results from the source root, runbook A: original stable
   **5**, original rolling **5**, patched worktree **42**. Full source
   `./run-tests.sh --quicker`: **546**, Go OCR checks passed; Python tests skipped
   because that environment is not synced. Target cwd portable commands in B:
   reader **236**, storage **133**, generic surface **49**, viewport **43**,
   public integration API **30**, book export **42**, annots **21**, view **1462**
   passed. The final API checks include failed construction/show without fake
   events, duplicate owners, independent listeners, selection without discovery,
   late callbacks, wrong-document handoff and stale-editor ownership. The core
   and new API/editor use real selected modules; UI/document rendering is mocked.
7. Runbook C on installed KOReader **v2026.07.1**, Linux x86_64:
   `KO_HOME=/tmp/inkaway-refactor-native` plus dummy SDL variables, real-widget
   regression **32 cases / 800 checks** passed. It now registers the actual
   target facade on the reader UI, exercising explicit provider registration
   through real Panels+ widgets. Real blitter toolbar **160** and native focus
   **7** passed. Physical input/refresh and real user comics remain unverified;
   this task did not repeat native export/large-archive measurements.
8. Source targeted StyLua and Luacheck **3 files**, target Luacheck **11 files**
   and both whitespace checks passed. Original stable/rolling reference content
   and pointers remain unchanged. FEATURES.md and all unrelated export/focus
   runtime files are byte-identical to the pre-refactor stash. Target formatting
   retains its existing upstream style; no global formatter ran over references.
9. Retained patch 8, SHA-256
   `6238cffd35f77e51be8f55e1f93f3a1f408a1bc318f7f252ceff9e08bb0d63d2`,
   is the exact delta after the old seven-patch stack. An initial reconstruction
   using `git archive` omitted tests due to upstream export-ignore attributes;
   its apply check failed on missing test files, without changing either source.
   Reconstructing from Git blobs succeeded. All **eight** patches also apply in
   order to a scratch copy of original rolling source, and reconstruct every
   tracked/new current target file, including doc deletions. Scratch validation
   path: `/tmp/inkaway-extension-stack-temk9zmh/`. Do not reapply to the current
   worktree, which already contains the entire stack.
10. Final state: backups retained; source edits unstaged; pre-existing target
    staging preserved with new refactor edits unstaged/untracked. No metadata
    version bump, commit, push, build or installation. Existing installed build
    remains `build.1nDooCiZ`. Next review entry 14 and the target's
    `docs/Arquitecture.md` / `docs/Plugin-integration.md`; after an authorized
    installation run the existing live checklist. Do not interpret automated
    test success as physical-reader confirmation.


## 2026-11-02 — 15: Architecture diagram — Panels+ 1.5.1 dev / Ink Away 4.4.0 patched rolling

**Versions and provenance:** Same source HEAD `b648faf4ade09ea22b06716406ba2288a3389c0d`
and target worktree HEAD `d87e2b097d6345085f9aa3ea0412bef23775ce10` plus entry 14's
refactor. User requested an ASCII diagram in the target's `docs/Arquitecture.md`.
Documentation-only follow-up; existing runtime, staging and installation remain
unchanged. Added a consumer/public/private diagram showing registration, lifecycle events
and both viewer adapters. Corrected one initial box-width mismatch; verified
ASCII-only content, aligned boxes and closed Markdown fences. No runtime tests
rerun for this documentation-only edit. This follow-up is not included in retained
patch 8; apply it separately when reproducing the current documentation. The
runtime patch stack remains unchanged.


Entry 15 refinement: at the user's request, replaced the stacked overview with
a wide side-by-side ASCII diagram. It shows a **generic plugin** outside the
Ink Away PR scope, its private internals, event subscription/data arrows, viewer
registration/unregister arrows, and adjacent public API/private core areas with
the two adaptation scopes. Method names and return semantics match the actual
API; the diagram does not claim published PRs or generic-consumer test evidence.
Checked ASCII content, consumer naming, layout bounds and Markdown fences.
Documentation-only; no runtime tests, staging, build or installation changes.


## 2026-11-02 — 16: Consumer API reference — Panels+ 1.5.1 dev / Ink Away 4.4.0 patched rolling

**Versions and provenance:** Source HEAD `b648faf4ade09ea22b06716406ba2288a3389c0d`;
target worktree HEAD `d87e2b097d6345085f9aa3ea0412bef23775ce10` plus entry 14's
refactor and subsequent documentation edits. User requested REST-reference-style
documentation for the in-process Lua API: hookup example first, initialization
timing, all public methods, parameters, results, errors and edge cases.

Read the actual facade, registry, model/editor lifecycle and surface adapters
before writing. Recommended consumer timing is after obtaining the loaded
instance and before opening annotation; pre-init registration is supported but
not required. Rewrote the target reference with a beginning-to-end hookup example, recommended
initialization order, version/method index, parameter/result/error tables for
all six documented instance methods (including the existing annotate action),
and required/optional surface methods. Added a complete affine surface example,
asynchronous navigation/reflow examples, selection/cleanup edge cases and
persistence limits. Method names and actual return/error behavior were checked
against the current source; no HTTP endpoints or invented status codes added.

Verified all **16 Lua snippets compile**, every local link/heading anchor and
Markdown code fences. Executed the documented hookup and minimal surface in a
scratch harness: coordinate round-trip, callback hookup, release/unregister/
unsubscribe ordering, repeated disposal and unavailable/wrong-document guards
passed. The harness initially loaded its logger fixture after importing the
example; moved that fixture before import, with no example change required.
This uses a facade/logger fixture and is documentation-example evidence only,
not a new plugin compatibility or physical-reader result. Existing runtime
suites were not rerun for this documentation-only edit. Whitespace checks pass.

No code, staging, build or installation changed. Like entry 15, this documentation
follow-up is outside retained patch 8. The runtime patch stack and installation
remain unchanged.


## 2026-11-02 — 17: Loading-order handshake — Panels+ 1.5.1 dev / Ink Away 4.4.0 patched rolling

**Versions and provenance:** Panels+ HEAD `b648faf4ade09ea22b06716406ba2288a3389c0d`,
Ink Away worktree HEAD `d87e2b097d6345085f9aa3ea0412bef23775ce10` plus entry 14's
refactor and entries 15–16's documentation. User authorized the readiness-instance
handshake, per-widget pending configuration queue and composite integration
installation/cleanup, including both loading orders. Original pins are unchanged.

KOReader's actual ReaderUI creates each plugin instance before registerModule
publishes its directory-name UI key. Therefore deferred callbacks must receive
the ready Ink Away instance directly, rather than looking up that key during init.
Preserve existing staged user work (including newly staged documentation and
.foxnvim/pins.json); index snapshots and pre-edit target files are saved under
`/tmp/inkaway-loading-order-baseline/`. No additional stash was requested or made.
Implementation and validation completed in the canonical rolling source after
entry 18 migration; see entry 20 for final results. No installation/publication
was authorized.


## 2026-11-02 — 18: Move active changes to rolling checkout — Panels+ 1.5.1 dev / Ink Away 4.4.0 patched rolling

**Versions and provenance:** Panels+ HEAD `b648faf4ade09ea22b06716406ba2288a3389c0d`;
new active target HEAD/base `8dda5407e05446dddb20ba5d6fbac263955d0db3`, branch `main`,
at `references-repos/plugins/ink-away/rolling.koplugin/`. Frozen backup HEAD
`d87e2b097d6345085f9aa3ea0412bef23775ce10`, branch `feature/annotation-surfaces`,
in `.cache/plugin-compatibility/worktrees/ink-away-annotation-surfaces/`.

User explicitly rejected further worktree/patch maintenance and authorized direct
rolling-checkout edits. This overrides the generic skill's immutable-rolling rule
for Ink Away. Preserve the old worktree as a backup; no further source changes
or builds there. Stable release snapshots remain read-only.

1. Verified the rolling checkout was completely clean at the shared upstream
   base. Transferred the entire current diff, including the committed original
   surface feature, staged/unstaged changes and untracked loading-order test.
   Included the user's `.foxnvim/pins.json` exactly as present in the source.
   Used a transient `/tmp/inkaway-transfer-to-rolling.diff` solely to move bytes;
   no new retained Git patch or worktree was created. Transfer SHA-256
   `bb8fddb4cac5537b0b29c9e34d32f425b9590639da0d46f9c490789ad27559d2`.
2. Compared **509 files**, executable modes and deletions against the backup.
   All match. Both Git indexes remain unchanged, so original user staging stays
   in the frozen backup and new rolling changes are unstaged. No commit, branch
   switch, fetch, submodule-pointer change, build or installation. Frozen bytes
   manifest: `/tmp/inkaway-backup-frozen-manifest.json`.
3. Continue entry 17 in the active rolling checkout, including final docs/tests.
   Default rolling compatibility now exercises modified source. Historical clean
   rolling results remain historical evidence, not results for the changed tree.


## 2026-11-02 — 19: Direct rolling workflow skill — Panels+ 1.5.1 dev / Ink Away 4.4.0 patched rolling

**Versions and provenance:** Same source HEAD `b648faf4ade09ea22b06716406ba2288a3389c0d`;
active Ink Away HEAD/base `8dda5407e05446dddb20ba5d6fbac263955d0db3`. User clarified
that no repository update should occur while current work is ongoing and asked
to make the rolling/local-branch/no-commit rule permanent in the skill.

1. Created local branch `feature/plugin-integration` at the existing target HEAD
   with all current changes preserved. Git metadata required approved sandbox
   escalation; no commit, checkout to another revision, fetch, pull, sync, merge,
   rebase or push occurred. Future upstream integration needs an explicit request.
2. Used skill-creator guidance to update the cross-plugin skill and its workflow
   and history references. Target development always uses canonical rolling on a
   local feature branch; default worktrees, new laboratory copies and retained
   patch artifacts are removed. Existing backups remain intact. Builds/tests use
   canonical rolling, stable pins remain immutable and local changes/staging must
   be preserved. Branch creation does not authorize commits or remote updates.
3. The bundled quick validator still cannot import PyYAML. Direct checks passed
   for this skill's simple frontmatter, linked references and consistent ownership/
   Git rules. No dependencies were installed. Existing user Git staging unchanged.

## 2026-11-02 — 20: Handshake validation and handoff — Panels+ 1.5.1 dev / Ink Away 4.4.0 patched rolling

**Versions and provenance:** Source HEAD `b648faf4ade09ea22b06716406ba2288a3389c0d`
on `feat/ink-away-compatibility`, uncommitted consumer/test/history changes. Active
target HEAD/base `8dda5407e05446dddb20ba5d6fbac263955d0db3` on local branch
`feature/plugin-integration`, uncommitted transferred/refactored source and the
new handshake. Host reference `035e00b21d0286325ef2e8a7e3b6326f340e2ded`; native
runtime **v2026.07.1**, Linux x86_64. No metadata version bump.

The ready instance is `ui.inkAwayIntegrationAPI`. Before readiness, consumers put
independent `configure(ink)` requests in `ui.inkAwayPendingIntegrations[widget]`.
Ink Away publishes only after its reader setup is usable, drains/cancels safely
and isolates failures. Newly created composite installs are rolled back when a
configuration throws. Reader shutdown unpublishes and disposes consumer state.
`installPluginIntegration(widget, surface, options)` supplies one idempotent
provider/scoped-listener cleanup. Repeated same-widget/surface configuration
retains the original callbacks; a different surface requires prior cleanup.
`cleanup(false)` supports outgoing navigation handoffs without closing the
landing session. The low-level APIs and old discovery path stay compatible.

Panels+ queues setup from its viewer lifecycle, accepts the ready instance before
the directory key exists, removes pending setup when closed, and uses composite
cleanup while preserving in-flight handoffs. The new docs quick start can be used
in either order and cancels even when Ink Away never loads. Architecture and API
method/state/return/error references reflect the implemented behavior.

### Investigation, tests and outcome by step

1. Target `luajit tests/loading_order.lua` loads real Ink Away init, Book, public
   facade/registry/editor, with explicit host menu, pen/shelf, framebuffer/widget
   fixtures. **47 checks passed**: both orders, missing directory-key publication,
   multiple consumers, cancellation before/during drain, failed callback rollback,
   failed init without readiness, shutdown during drain, duplicate setup, cleanup
   and reinstallation. Against the pre-handshake modules saved in
   `/tmp/inkaway-loading-order-baseline`, the same test fails at
   `consumer-first: hookup completed`, establishing the missing behavior.
2. An early source edit left a trailing fragment of its previous registration
   lambda. Targeted StyLua and stable test loading caught the syntax error before
   execution; fixed the edit boundary and reran successfully. Source lint later
   caught a shadowed local pending variable; renamed it. No reference formatting
   or runtime adjustment was used to suppress those checks.
3. Stable-first compatibility command from runbook A: **5 passed**. Before the
   migration, original clean rolling fallback **5** and modified-worktree **44**
   passed. After migration, normal `rollingrelease` selection against canonical
   rolling **44 passed**, including actual Panels+ setup without directory-key
   lookup, both orders and cancellation on source close. These use real selected
   target/source modules with host/document/raster fixtures; not full loader or
   physical-reader evidence.
4. Target cwd runbook B: loading order **47**, existing public API **30**, generic
   surface **49**, viewport **43**, reader **236**, storage **133**, book export
   **42**, annots **21** passed. Source `./run-tests.sh --quicker`: **546 passed**
   and Go OCR passed; Python skipped because its environment is not synced.
   Unrelated target view/native-export benchmarks were not repeated.
5. Native runbook C selected the canonical rolling directory, with
   `KO_HOME=/tmp/inkaway-loading-native` and dummy SDL drivers: **32 cases /
   800 checks passed**, all toolbar sides, reading directions, eased/Classic
   transitions and Tight/Margin crops. Actual KOReader layout/widgets/blitter and
   both runtime modules execute; source bitmaps and timer delivery are synthetic.
6. Source targeted StyLua/Luacheck and target handshake/facade/test Luacheck pass;
   whitespace checks pass. All **17 API Lua examples compile**, internal links/
   anchors/fences validate. Executed the documented hookup and affine surface
   against actual Ink Away init/API in both orders, with the host fixtures from
   the 47-check suite: no directory-name key required, cancellation works.
7. No new retained patch, worktree, build or installation. Existing frozen backup
   remains at its migration snapshot; original stash backups stay retained. Git
   base and user staging are preserved. Next: review canonical rolling diffs and
   the updated skill/docs. A build/install and eventual upstream rebase remain
   separate explicit user actions; live input/refresh confirmation remains open.


Final entry 20 audit: canonical HEAD remains `8dda5407e05446dddb20ba5d6fbac263955d0db3`,
branch `feature/plugin-integration`; canonical index has no staged changes and
the parent gitlink was not staged/updated. Frozen backup payload and its original
index match the migration manifest exactly. Root-level unrelated staged additions
(CODE_OF_CONDUCT.md, SECURITY.md) and README.nightly.md deletion appeared during
the session; preserved as observed, without staging/resetting them. An initial
audit comparing the entire root index to its earlier snapshot stopped on that
concurrent staging difference; no source changes were rolled back. Final checks
verify ownership/base/backup independently of those unrelated edits. Wide diagram
alignment, documentation links/fences and both whitespace checks pass.


## 2026-11-02 — 21: Remove obsolete integration patch archives — Panels+ 1.5.1 dev / Ink Away 4.4.0 patched rolling

**Versions and provenance:** Panels+ HEAD `b648faf4ade09ea22b06716406ba2288a3389c0d`;
active Ink Away HEAD/base `8dda5407e05446dddb20ba5d6fbac263955d0db3`, branch
`feature/plugin-integration`. User explicitly authorized removing generated
integration patch archives now that development uses canonical rolling diffs.

Inventory found one such archive: Ink Away's eight `.patch` files. Their exact
filenames/hashes are preserved in the historical change-identity table above,
with original base commits, scope and test evidence in the dated entries. Kobo's
nested stable/rolling `patches/` contain shipped Lua code included by the existing
builder; those are plugin runtime inputs and remain unchanged. The frozen Ink
Away worktree remains a backup.

Removed all eight generated artifacts and the empty Ink Away `patches/` folder.
Converted artifact links in this history and relationships.md to historical
filename identifiers, preserving all eight hashes and original revision/test
records. Updated the skill and history reference to keep provenance in the
history instead of requiring patch archives; retained the frozen-worktree rule
and distinguished shipped runtime patch code.

Validation: no top-level plugin integration archives remain; all relevant
Markdown file links and code fences resolve; all eight removed identities remain
in the history; whitespace check passes. Compared pre/post Git HEADs/indexes and
all tracked/new active target and frozen backup file hashes: unchanged. Kobo's
three Lua runtime patch files remain in each stable/rolling location. No runtime
suite rerun because only obsolete artifacts/docs/skill instructions changed.
No staging, commit, remote update, source change, build or installation.


## 2026-11-02 — 22: Separate mock consumer entry points — Panels+ 1.5.1 dev / Ink Away 4.4.0 patched rolling

**Versions and provenance:** Panels+ HEAD `b648faf4ade09ea22b06716406ba2288a3389c0d`;
active Ink Away HEAD/base `8dda5407e05446dddb20ba5d6fbac263955d0db3`, local branch
`feature/plugin-integration`, existing uncommitted integration changes. User
requested replacing the long opening Markdown helper with two separate examples
beside the document: `main-connect-before.lua` and `main-connect-after.lua`.
Both must be illustrative mocks of YourPlugin, not functional/installable
plugins. Show coherent real API calls, event handling, painting, annotation
opening and cleanup; link/explain both files from Plugin-integration.md.
Added both illustrative files directly under the active target's `docs/`,
using a mock `YourPlugin` table with clearly omitted viewer/surface rendering.
The before-ready case queues a cancellable configure callback and uses composite
installation/scoped callbacks. The after-ready case uses explicit registration,
reader-wide event filtering and release/unregister/unsubscribe ordering. Both
show annotation action, background-first saved-ink painting, status changes,
error handling, repeated-setup guards and close lifecycle. No mock is loaded by
Ink Away or added to a runtime/test runner.

Replaced the opening inline helper with links, scenario comparison and lifecycle
walkthroughs. Clarified that composite versus manual ownership is independent
of loading order, and that the init arguments/methods are mock YourPlugin
interfaces. Updated stale helper references elsewhere in the API reference.

Validation: both Lua mock files and remaining inline snippets compile;
Luacheck passes for both files with zero warnings. Markdown links, local anchors,
code fences and whitespace checks pass; the old connectInkAway helper is gone.
One initial edit command used the wrong cwd and changed nothing; corrected it,
then addressed the unused mock arguments found by lint. No runtime suite rerun
or functionality claim for these nonfunctional examples. Runtime sources,
installation, staging and Git base remain unchanged; no commit/remote update.


## 23 — 2026-11-02 — Consumer-role documentation mocks

User requested event-only and rendering-consumer examples, each handling both
loading orders. Source Panels+ 1.5.1 remains at b648faf4ade09ea22b06716406ba2288a3389c0d
on feat/ink-away-compatibility; target Ink Away 4.4.0 modified rolling remains
at 8dda5407e05446dddb20ba5d6fbac263955d0db3 on feature/plugin-integration,
with the existing uncommitted diff. Stable and frozen backup are untouched.

Replaced the two before/after docs mocks with main-event-only.lua and
main-rendering-consumer.lua beside Plugin-integration.md. Event-only uses its
plugin table as a readiness-queue key and subscribes/unsubscribes without viewer,
surface, surface version check or surface release. Rendering keeps the viewer
and surface injection with optional scoped callbacks. Both handle ready and
queued paths, cancellation and disposal. Updated guide links, registration flow
and queue terminology; consumer roles may coexist in one plugin. The runtime
queue already accepts table keys, so no runtime change is needed.

Validation: both Lua mocks compile with LuaJIT; Luacheck reports zero warnings/errors.
Guide local file links, code fences and both repositories' diff whitespace checks
pass. Runtime suites were not rerun for this documentation-only change.
No runtime installation, staging, commits or remote updates.


## 24 — 2026-11-02 — Direct configureInkAway consumer method

User authorized replacing callback wrappers with consumer:configureInkAway(ink).
Lua method names cannot contain hyphens; configureInkAway names the integration
explicitly. Same source/target versions, branches and bases as entry 23; all
changes remain uncommitted in Panels+ and canonical rolling Ink Away.
Queue contract becomes pending[consumer] = true; publication invokes the method
with consumer as self. Updated Panels+ and documentation mocks, retaining queue
cancellation, initialization ordering, failure isolation and shutdown guards.
Validation from canonical rolling: `luajit tests/loading_order.lua` passes 57
checks (47 existing plus 10 event-only checks for both load orders, method self,
no provider registration, native event payload and unsubscribe);
`luajit tests/integration.lua` passes 30. These load actual Ink Away modules with
host menus/shelf/pen/UI fixtures; event-only checks emit native-style lifecycle
payloads through the actual registry rather than exercising physical input.
From Panels+ root, stable-first `./run-tests.sh --compatibility-plugin=ink-away
--compatibility-plugin-version=4.4.0` passes 5 fallback checks, followed by
`rollingrelease` passing 44 integration checks, including actual Panels+ ready,
deferred and cancellation paths. Target registry, both mocks and Panels+ viewer
Luacheck pass with zero warnings/errors; both repositories' whitespace checks
pass. No pre-change failure run or live/device validation claimed. No deployment,
staging, commits or remote operations. This replaces the unpublished callback-valued
queue contract; older queued callback values are rejected/logged. Installed build
and frozen backup remain unchanged.


## 25 — 2026-11-02 — Atomic Ink Away commits and fork branch push

User explicitly authorized commits and push to
`git@github.com:KristanLaimon/ink-away.koplugin-fork.git`, using another remote
`kristanlaimonorigin` as default. This overrides the usual no-commit/no-push
policy for the Ink Away task changes only. Panels+ remains uncommitted.
Same metadata versions and host/test provenance as entry 24.

Created four Conventional Commits, without co-author trailers:
- 704353b: feat(integration): expose annotation events and injectable rendering views
- d811eb8: fix(export): render fixed-page books at bounded native page dimensions
- 917ff54: fix(ui): restore text prompt focus on devices with directional keys
- b5b83b2: docs(integration): document consumer roles and the public extension API

Each code commit includes its tests and only its runner registrations. All
original modified/untracked file bytes were hashed before committing and verified
unchanged afterward. Local editor .foxnvim/pins.json was excluded and remains
untracked. No co-author trailers occur in the four commit messages.

Added the fork remote, set remote.pushDefault and branch pushRemote to it, then
`git push --set-upstream kristanlaimonorigin feature/plugin-integration` succeeded
as a new branch. HEAD and upstream tracking ref both resolve to
b5b83b2f6b67f2503e1fb4dada92dffc2a60d1c2. Existing origin still points to
EmirErtorer upstream. No fetch/pull/rebase/merge, main branch change or force push.
No source logic changed during commit preparation; entry 24 test evidence carries
forward, not claimed as rerun. Git staged-whitespace checks passed for each commit.
No installation. Frozen backup and retained stashes remain intact.


## 26 — 2026-11-02 — Standalone Fumadocs documentation submodule

User initially requested reusing their cloned WhatsBotCord documentation, then
explicitly replaced that plan with removing all template code and using Fumadocs.
Also requested integration guides and complete public API pages. Bun only, no
npx/pnpm. No commits or push authorized for this documentation work.

Renamed the clone to references-repos/plugins/ink-away/Ink-away-documentation,
registered it as a submodule, absorbed its gitdir, removed the old origin, and
added https://github.com/KristanLaimon/Ink-away-documentation.git. Registration
staged only .gitmodules and the new gitlink as Git requires, without commits.
The clone history is retained; all old site source/config/content was removed.
Used official create-fumadocs-app via bunx with static Next.js/MDX, local search,
no Git initialization; generated in /tmp and transferred into the submodule.
An earlier npx scaffold request was aborted before execution; Bun did the work.

Built 22 documentation articles from the canonical rolling public API text,
including guides and complete Lua mocks for both consumer roles, all public
methods with parameter/return/edge-case tables, surface contract and optional
methods, errors, compatibility and architecture. Added a new Ink-away.koplugin
landing page and Bun scripts. No WhatsBotCord runtime, chat playground, branding
or deployment workflow is retained. The frozen Ink Away backup is untouched.
Validation: `bun install` generated bun.lock using Bun 1.4.3. `bun run
types:check` passes. Initial `bun run build` (Turbopack) failed because this
environment blocks its local worker-port binding, including an escalated retry.
Changed the build script to supported `next build --webpack`; `bun run build`
then passed TypeScript, compilation and all 50 static route outputs (22 docs,
Markdown endpoints, search, homepage and support routes). Webpack reported
upstream dynamic-import cache-dependency warnings, with a successful exit.
Parsed generated HTML to verify cross-page documentation anchors; source links,
code fences, exported search and exact downloadable Lua bytes pass. Both site
and parent diff whitespace checks pass. No browser/device claim.

Standalone docs HEAD remains inherited template commit
733a00240c3141e504f9f985e0c984b0907a4844 on main. All replacement source is
uncommitted/deleted/new; no remotes were fetched or pushed. Runtime Ink Away
remains at b5b83b2; Panels+ runtime changes are untouched. To resume:
`cd references-repos/plugins/ink-away/Ink-away-documentation`, `bun run dev`.
Production output is out/; no deployment or GitHub Pages settings were changed.


## 27 — 2026-11-02 — Ink Away title artwork and green documentation theme

User requested the upstream ink-away-title.svg as homepage title, with
readme-divider.svg immediately underneath, and green documentation styling.
Same standalone docs HEAD 733a00240c3141e504f9f985e0c984b0907a4844 and
uncommitted replacement as entry 26. Downloaded both original SVGs unchanged
from raw.githubusercontent.com/EmirErtorer/ink-away.koplugin/main/assets/
into public/assets/. Recorded their origin links in that directory's README.
ink-away-title.svg SHA-256 751f0568a314d4025aa30e70c13c5f52eca211ba9a015f5d6b281729005f118e
readme-divider.svg SHA-256 8430ee9792ddd43f9108359287c7dd47577faaa3fc56a0c6b15129efe7f7720d

Replaced the homepage text heading with responsive local SVG artwork and
placed the decorative divider directly below it. Kept an accessible title
label and intrinsic image dimensions. Switched the Fumadocs preset to emerald
and customized primary colors to match Ink Away lime lettering, with forest
backgrounds in dark mode and green accents in light mode. No new packages.
First download attempt failed sandbox DNS; authorized escalation succeeded.
Validation: `bun run build` passes compilation, TypeScript and all 50 static
route outputs. Parsed SVGs successfully; exported assets match downloaded
bytes exactly. Generated homepage places title then divider then introduction.
Diff whitespace checks pass. No browser screenshot/visual-device claim.
No commits, push or deployment.


## 28 — 2026-11-02 — Restore homepage and publish atomic documentation commits

User rejected a homepage redesign and requested restoring the previous page.
Restored the original SVG title/divider layout, removed the added CSS module
and hero artwork, and rebuilt successfully with Bun. The resulting production
build passes compilation, TypeScript and all 50 static outputs; no rejected
design files are committed.

User then explicitly authorized atomic commits with no co-author trailers and
push. Documentation repo only: created three Conventional Commits:
- 0d8e78c chore(docs): replace legacy site with Fumadocs and Bun
- 7c2a17e docs(api): add integration guides and the complete public API reference
- 9df86c2 feat(home): add Ink Away title artwork and green documentation theme

The first commit has a minimal coherent homepage/docs index; the second adds
all guides/API content, and the third adds the final homepage/theme. Used staged
blob versions without modifying working-file bytes; SHA-256 manifest confirms
final working contents unchanged. All staged whitespace checks pass. Removed
the obsolete README statement that the documentation was intentionally uncommitted.
No co-author trailers occur in these commit messages.

Remote branch check found no heads. HTTPS push initially failed because no
interactive GitHub username could be read. Set only origin's push URL to
git@github.com:KristanLaimon/Ink-away-documentation.git and pushed main using
SSH; fetch URL remains the requested HTTPS URL. New branch push succeeded and
main tracks origin/main. Both refs resolve to
9df86c28ed4aa9acb6112877391a36a52feb5113. Documentation checkout is clean.
Updated only the documentation gitlink in the parent index to this pushed HEAD;
no parent commit or push. Preserve all other user staging. No runtime plugin
changes, deployment, rebase, or force push.


## 29 — 2026-11-02 — Entry-only crayon drawing animation

User requested three crayons (two left, one right) drawing randomized paths
on homepage entry while keeping the center clear. Documentation base remains
9df86c28ed4aa9acb6112877391a36a52feb5113 on main; no runtime plugin changes.
Added a small client component with original inline SVG crayons and scoped CSS.
Random cubic paths are generated only after mount to avoid hydration mismatch.
Each path and its moving crayon stay inside a bounded side rail; content has
reserved spacing. requestAnimationFrame synchronizes the wax tip and line
reveal, staggers the three drawings, then stops and lifts/fades the crayons.
Finished marks remain. There are no scroll/repeat triggers. Cleanup cancels
the frame and removes the media listener; reduced-motion preference suppresses
this decorative animation. Rails scale on mobile. No animation dependency added.

`bun run build` passes compilation, TypeScript and all 50 static outputs.
Headless Chromium desktop/mobile screenshots inspected. Browser timing checks
initially measured before hydration; corrected the verification wait. An initial
bounds selector also included the CTA arrow SVG; restricted it to the three
crayon SVGs. No production logic workaround was needed. Final browser checks pass:
all three crayons draw, finish with zero remaining line offset, and remain
stopped; mobile rails do not intersect the content or cause horizontal overflow;
reduced motion runs no path animation. Both diff whitespace checks pass.
Temporary localhost preview required permission after sandbox socket denial.
No commits, push, or deployment requested for this addition.


## 30 — 2026-11-02 — Larger crayons at outer viewport edges

User clarified that the drawing crayons were too small and too near the center.
Changed the homepage hero to span the available viewport rather than the narrow
max-width content container. Kept the title/text centered in a reserved column,
while guide cards retain their previous max-width container. Side rail widths
now grow to 240px (previously 148px), with viewport-edge insets; mobile uses
48–64px rails and protected content spacing. No change to timing, random path
generation, one-shot behavior or reduced-motion handling. Same documentation
base/main and uncommitted addition as entry 29.

`bun run build` passes compilation, TypeScript and all 50 static route outputs.
Headless Chromium verifies all three desktop rails lie within the outer
viewport quarters, at 228px width for a 1440px viewport (previous cap 148px).
Desktop screenshot inspected. Mobile rails remain outside the content, with
no horizontal overflow. One-shot completion and reduced-motion checks pass.
Diff whitespace check passes. No commits or push.


## 31 — 2026-11-02 — Push crayons and simplify developer onboarding

User explicitly requested commit/push of the animation, then a documentation
rewrite for developers unfamiliar with Ink Away. Created c19a2a7
feat(home): animate three crayons within the outer hero margins, without
co-author trailers, and pushed main to the documentation origin successfully.
This includes the size/placement adjustment from entry 30. No parent commit.

For the subsequent rewrite, read Panels+ docs/INTRO.md, WORD-LOOKUP.md and
EMBEDDED-IMAGES.md as writing references: define terms first, show concrete
behavior, then explain relevant details. Replaced 22 documentation articles
with 14: one introduction, two guided examples, seven public Ink Away methods
and four public version/readiness fields. Surface callback contracts are
kept with the rendering registration reference, not extra conceptual pages.
Removed architecture, duplicate indexes, generic loading-order/conventions,
standalone errors/persistence and surface essays; retained necessary rules on
the corresponding method/field pages.

Introduction defines Ink Away's user workflow and ui/ink/consumer/viewer/surface.
Examples explain objects before code, handle both loading orders, show teardown
and a complete minimal surface for a uniformly scaled fixed page. Renamed the
downloadable mock setup method to connectInkAway to avoid implying that its
arguments are a standard KOReader init signature. configureInkAway is unchanged.
Home/nav now lead beginners to the introduction; API links go to its member
index. Canonical runtime source and its existing docs are unchanged.

Validation: `bun run build` passes compilation, TypeScript and all 34 static
outputs (14 documentation articles, their Markdown exports and support routes).
All 22 inline Lua snippets and both downloadable mocks compile with LuaJIT;
Luacheck reports zero warnings/errors on both mocks. An initial lint command
used the parent cwd and found no files; reran in the site directory successfully.
Parsed exported HTML to verify every home/sidebar/article documentation link
and local anchor, exactly 14 articles, removal of the architecture route, both
native expandable surface-contract sections, and exact downloadable mock bytes.
Both whitespace checks pass. Later small wording/expandable-reference changes
triggered fresh final builds; no stale earlier build is used as final evidence.
No new runtime plugin tests or device validation claimed for prose changes.
The readability rewrite remains local and uncommitted after the separately
requested animation push. No parent commit/push or runtime source modification.


## 32 — 2026-11-02 — Explicit documentation index route

User reported Next 16.4.2 Turbopack's missing-generateStaticParams-param error
for the optional /docs/[[...slug]] page. Source's Fumadocs generator already
includes index slugs as []; production /docs was present and warm dev requests
succeeded. The existing dev log preserved the reported startup error. A second
temporary dev server refused to start because the user's server owns the
project lock; did not stop or modify that user process. Checked its existing
localhost:3000 endpoints instead.

Made /docs an explicit static app/docs/page.tsx. Named articles now use the
required app/docs/[...slug]/page.tsx route, exclude empty slugs from generated
params and set dynamicParams=false. Shared rendering/metadata moved into
components/documentation-page.tsx so both paths display identical Fumadocs
content. No disabling of static export, no dependency update, no new document
articles. Same c19a2a7 base and local readability rewrite as entry 31.

Validation: bun run build passes compilation, TypeScript and all 34 outputs;
route summary now lists /docs separately and 13 named article paths. On the
existing Turbopack dev server, /docs, an API article and both example guides
return 200 without the missing-param error; an unknown article returns 404.
Diff whitespace checks pass. The exact original cold-start failure was present
in the user log but not reproducible after warm-up; this change removes the
empty optional-catch-all case rather than claiming a dependency-level fix.
No commits/push, no parent or runtime-plugin source changes.

## 2026-11-07 — Rebase onto main-nightly — Panels+ 1.6.0 dev / Ink Away 4.4.0-derived rolling

User requested baseline tests, rebasing `feat/ink-away-compatibility` onto
`main-nightly`, conflict resolution and matching non-Ink Away results. Source
base: `cbfe8825f287c00b0a313b5e98b05f6b6ffb240a`; original feature tip:
`7a18a3325fb93a56298e6a21271a3d26c7df2e47`, retained in
`backup/ink-away-before-main-nightly-rebase-20261107`. Only Panels+ is changed.
Ink Away reference remains at `b5b83b2f6b67f2503e1fb4dada92dffc2a60d1c2`
with its original staged `.foxnvim/pins.json`; KOReader source pin remains
`035e00b21d0286325ef2e8a7e3b6326f340e2ded`. Runtime/device version was not
inspected; no build, installation or publication is authorized by this task.

Baseline from project root: `UV_CACHE_DIR=/tmp/panelsplus-uv-cache
./run-tests.sh --quick --strict` passes Python 101 (one skip), Go and all 13
Lua/dataset jobs, including 588 unit checks (three skips). Explicit owned-file
StyLua/Luacheck checks pass. Compatibility commands select Meguru and Kobo
(all pins: 14 and 2 checks per pin) and Ink Away rolling (12 checks). The
default check script formats reference trees; its formatting-only changes were
verified against StyLua output of Git originals and undone before rebasing.

Old reference-layout commits were superseded by main-nightly. Ink Away methods
were merged into the split panelviewer/controller modules, retaining other
plugin adapters and current rendering/resource fixes. The focused first run
exposed two regressions: transition masks used white instead of the current
night-mode background, and a page-less viewer stopped queuing optional Ink Away
readiness. Both are corrected without changing their existing tests. Original
Ink Away suites now pass stable fallback (5) and rolling integration (44),
using actual target modules with fixture host rendering/storage. Review also
retained the fixed-page-only registration guard: extracted reflow images never
install a fixed-page surface. Optional API version checks and painting/release
error containment remain covered.

Final validation from the project root on 2026-11-07:

- `UV_CACHE_DIR=/tmp/panelsplus-uv-cache ./run-tests.sh --quick --strict`:
  Python 101 (one skip), Go and all **13 jobs pass**. After the final registration
  guard, reran the same unit job with `tests/run_parallel.py`'s discovery/job
  functions: **600 passed, zero failed, three skipped**, versus 588 before.
- Compared passing-check names with the baseline: none removed or lost; all
  **12 additional checks** concern Ink Away. All **26 dataset metric lines**
  are identical, as are the skipped-check names. Dataset records, targets and
  detection algorithms remain unchanged from main-nightly.
- `./run-tests.sh --compatibility-plugin=ink-away`: **5 stable fallback** and
  **44 rolling integration** checks pass. Meguru/Kobo commands above still pass
  **14/2 per stable and rolling pin**.
- Owned-file `stylua --check` and `luacheck`: **146 files**, no warnings/errors.
  `bash tests/plugin_workflow_spec.sh`: **23 checks** pass.
  `GOCACHE=/tmp/panelsplus-go-build-cache go test -tags ocr_native
  ./tools/ocr_worker` passes. `git diff --check main-nightly` passes.

The original target staged diff was compared byte-for-byte and preserved. The
backup branch retains the original feature tip. Rebase conflict resolutions
and this validation are committed locally; no push, build or install was
performed. Physical reader/stylus validation was not rerun; prior device limits
remain. Next action, if desired, is live KOReader validation of annotation
navigation, toolbar fitting and night-mode transitions. Logs are retained under
`/tmp/panelsplus-*` for this session.


## 2026-11-07 — Smooth toolbar fit and Draw shortcut — Panels+ 1.6.0 dev / Ink Away 4.4.0-derived rolling

User requests keeping Smooth transitions beside the open annotation toolbar and adding a conditional Draw (Ink-away) action immediately after Inverted. Panels+ owns both changes. The user explicitly requested avoiding reads of this large history; no historical content was read for this task.

Source: Panels+ `d7b2f3408f8b4671e9afe2fd32f84d40e827b7e4`, branch `feat/ink-away-compatibility`, initially clean except target submodule dirty marker. Target: canonical `rolling.koplugin/`, `b5b83b2f6b67f2503e1fb4dada92dffc2a60d1c2`, branch `feature/plugin-integration`; pre-existing staged `.foxnvim/pins.json` preserved. Stable v4_4_0 remains read-only. Host source `035e00b21d0286325ef2e8a7e3b6326f340e2ded`. Investigation underway; no build/install or commit requested. Live validation pending.

### Investigation, implementation and validation

1. User confirmed the symptom is **No crop**. Existing viewport sizing already excludes toolbar space. The mismatch is in the camera zoom: No crop first renders its clipped content and pads it to a screen-aspect canvas. Smooth fit the clipped content directly into the available rectangle; the stationary image instead uniformly fits the padded canvas. `src/panelviewer/animations.lua` now uses the same canvas fit for both camera endpoints. Cropped modes keep their prior formula. Existing cross-page animation already fits the actual landing tile and required no runtime change.
2. Added **Draw (Ink-away)** after Inverted in the quick controls. `src/_quicktoolbar.lua` skips unavailable optional actions and sizes the row/rail by the actual control count. It reuses the existing pen icon. `controls.lua` exposes Draw only after a successful surface registration with a cleanup callback and an annotation action. The adapter rebuilds controls after registration so either readiness order works. Draw calls the target's existing `onInkAwayAnnotate`; tools/storage remain entirely owned by Ink Away. Absent, incompatible or failed registration hides the button. No target runtime changes.
3. Unit regression with mocked bitmaps: before the fix, the final crop width was **49 instead of 53** in the left-toolbar No crop case (28 passed / 1 failed in `panelviewer_navtransition_spec.lua`). It now passes for eased and bounded Classic frames. An earlier test draft read a nonexistent fixture field and failed with nil; corrected the fixture to use `getWidth()`/`getHeight()` before evaluating the real mismatch. Button tests cover hidden-before-registration, failed registration, annotation dispatch and all eight tiles fitting the portrait row; existing seven-action behavior remains covered.
4. Real-widget reproduction: extended `tests/compatibility_support/inkaway_native_viewport.lua` to include padded No crop panels at page edges, per-frame toolbar bounds, endpoint zoom, and opening through Draw. Initial native fixture needed KOReader's base document `_document:openPage`/`mod_time` fields; adding them fixed the fixture failure. The former tight/margin-only 32-case test passed before the fix but did not exercise padded No crop geometry. With the new geometry, loading the original HEAD animation module from `/tmp/panelsplus-before-animations.lua` fails case 3 (left / comic / ease / none): **Smooth lands at the stationary panel's toolbar-fit zoom**. The modified source passes **48 cases / 2592 checks**, including 192 physical-arrow callback turns. Real KOReader ImageViewer/ImageWidget/layout/blitter, Panels+, Ink Away Book/ReaderInkView and registry run; document pixels/native-page metadata and timer delivery remain fixtures. No physical stylus/device input was tested.

Commands run from the Panels+ project root:

```bash
./run-tests.sh --compatibility-plugin=ink-away --compatibility-plugin-version=4.4.0
./run-tests.sh --compatibility-plugin=ink-away --compatibility-plugin-version=rollingrelease
./run-tests.sh --quicker
```

Results: stable original 4.4.0 **5 passed**, current modified rolling reference **44 passed** (now dispatching Draw through the real target action in both readiness orders), general Lua suite **579 passed**, Go OCR worker tests passed. Python was skipped by the runner because its uv environment is not synced. Dataset/benchmark suites were intentionally skipped for this viewer/UI change. Targeted StyLua, Luacheck (9 changed Lua files), and `git diff --check` passed.

Native command, cwd `/usr/lib/koreader`, installed runtime **v2026.07.1**, Linux x86_64:

```bash
SDL_VIDEODRIVER=dummy SDL_RENDER_DRIVER=software SDL_AUDIODRIVER=dummy \
KO_HOME=/tmp/panelsplus-inkaway-after ./luajit \
/home/kristanlaimon/.config/koreader/plugins/panels_plus_development.koplugin/tests/compatibility_support/inkaway_native_viewport.lua \
/home/kristanlaimon/.config/koreader/plugins/panels_plus_development.koplugin \
/home/kristanlaimon/.config/koreader/plugins/panels_plus_development.koplugin/references-repos/plugins/ink-away/rolling.koplugin
```

All task changes remain uncommitted in Panels+. Ink Away's staged `.foxnvim/pins.json` is untouched. No build, installation, backup, fetch or publication performed; no prior artifact identity was investigated. This Panels+ project is the live development plugin, so restart KOReader to load it. Next live check: No crop with Fit beside toolbar, all toolbar sides, eased/Classic movement, Draw opening the current panel, and absence of Draw when Ink Away is disabled. Live validation remains pending.


## 2026-11-07 — Draw hidden with installed legacy surface API — Panels+ 1.6.0 dev / Ink Away 4.4.0-derived installed

User reports the new Draw icon is missing. Actual installed `/home/kristanlaimon/.config/koreader/plugins/ink-away.koplugin/` advertises document_surface_version=1 with paint/release/action methods, and `ink/reader/surface.lua` discovers Panels+ via getAnnotationSurface. It predates integration_api_version/installPluginIntegration and registerRenderingView. The initial Draw gate incorrectly required the newer registry's cleanup callback. Investigating a Panels+-only correction; no replacement of the installed plugin is needed. Source base remains d7b2f3408f8b4671e9afe2fd32f84d40e827b7e4 on feat/ink-away-compatibility. Prior task changes are now staged by the user; preserve staging and add follow-up changes unstaged. Canonical target b5b83b2f6b67f2503e1fb4dada92dffc2a60d1c2 and its staged pins.json remain untouched. Earlier history remains unread per user request.

User clarified that KOReader should use the current rolling API and explicitly selected **Install current rolling Ink Away**. The exploratory legacy-support runtime/test changes were removed by restoring only those files to their already-staged task contents; no user staging was changed. Final runtime code is the original newer-API Draw implementation and No crop Smooth fix. The missing button was a deployment mismatch, not failure of the current registry API.

The previously installed manifest identified a former frozen worktree build based on d87e2b097d6345085f9aa3ea0412bef23775ce10, with retained old patches. Its main.lua SHA256 was 99448e56d52da3d56a973a0fa1a6e41838e63ae15bf186d8b85e36a993f8074f. A temporary legacy-support experiment passed the portable unit and native checks but was discarded in favor of the user's requested current deployment.

Executed from Panels+ root, with filesystem escalation for the external installation:

```bash
./tools/plugin-compatibility/deploy.sh --plugin=ink-away --mode=rolling --install
```

Built canonical rolling b5b83b2f6b67f2503e1fb4dada92dffc2a60d1c2, branch feature/plugin-integration; only staged .foxnvim/pins.json makes its source dirty. Artifact `.cache/plugin-compatibility/builds/ink-away/v4_4_0/build.uCHGAckH/ink-away.koplugin/` installed at `/home/kristanlaimon/.config/koreader/plugins/ink-away.koplugin/`. Previous managed copy backed up at `/home/kristanlaimon/.config/koreader/.panelsplus-plugin-backups/ink-away.3nm5FqK3/`. All **288 payload checksums verified** with `sha256sum --quiet -c .panelsplus-deployment/SHA256SUMS`, cwd installed directory. Confirmed installed main.lua now has integration_api_version=1 and installPluginIntegration. Process lookup before installation was sandbox-limited; host process closure was not independently established. Restart KOReader before live testing to guarantee loaded modules match installed files.

Validation: stable fallback 5 and rolling integration 44 pass. Final restored Panels+ plugin-support/control units: **20 passed**. Native command from the preceding entry, with KO_HOME=/tmp/panelsplus-installed-current and TARGET=/home/kristanlaimon/.config/koreader/plugins/ink-away.koplugin, verifies the **actual newly installed payload**: **48 cases / 2592 checks passed**, including Draw opening annotation, all toolbar sides, eased/Classic, No crop/Tight/Margin, and Comic/Manga. Output `/tmp/panelsplus-installed-current.log`. The prior full 579-unit result still applies to unchanged final runtime sources; it was not rerun solely for installation. No fetch, commit or push. Next: restart KOReader, open Panels+ controls, confirm the pen icon/Draw (Ink-away) after Inverted and live No crop toolbar fitting.


## 2026-11-07 — Draw visibility with KOReader HandlerSandbox — Panels+ 1.6.0 dev / installed rolling Ink Away

User still cannot see Draw and suspects an old duplicate. Read-only inspection finds exactly one active Ink Away folder across /usr/lib/koreader/plugins and the configured extra_plugin_paths (/home/kristanlaimon/.config/koreader/plugins/). It is the verified current build.uCHGAckH; the former copy is already outside plugin discovery in ink-away.3nm5FqK3. No deletion is appropriate. Host reader process was started at 07:12:49, after the update.

Found an independent runtime gate bug: actual KOReader pluginloader.lua `_load` calls sandboxPluginEventHandlers, replacing onInkAwayAnnotate with a HandlerSandbox callable table. Panels+ tested type(handler)==function, hiding the button even with a successful modern registration. Earlier native tests directly loaded main.lua and missed this host wrapping. Correct the button gate and load the actual plugin through KOReader PluginLoader in the native regression. Versions/bases unchanged: Panels+ 1.6.0 d7b2f3408f8b4671e9afe2fd32f84d40e827b7e4, feat/ink-away-compatibility; target installed and canonical rolling 4.4.0-derived b5b83b2f6b67f2503e1fb4dada92dffc2a60d1c2, feature/plugin-integration. Existing staged task changes and target staged pins.json remain preserved; this follow-up is unstaged.

Changed only the action-presence gate in `src/panelviewer/controls.lua`: a successfully registered provider and its callable onInkAwayAnnotate handler enable Draw, whether the handler is a plain function or KOReader's callable table. The callback still invokes the target-owned action. No target change, replacement or deletion.

Failing-before evidence: native test now calls actual KOReader PluginLoader:_load on the installed Ink Away (rather than dofile), so sandboxPluginEventHandlers runs. The first scenario fails at **successful integration offers Draw**. With the gate fix, the same test passes **48 cases / 2592 checks** and invokes the sandbox-wrapped Draw callback to open annotation. Unit coverage now also models a callable-table action and verifies its dispatch. Existing presence/registration-failure coverage remains.

Validation commands: `lua tests/run_tests.lua tests/plugin_support_spec.lua tests/panelviewer_controls_spec.lua` (**20 passed**); stable-first `./run-tests.sh --compatibility-plugin=ink-away --compatibility-plugin-version=4.4.0` (**5 passed**), then rollingrelease (**44 passed**). Native command uses the earlier documented `/usr/lib/koreader` cwd/environment, KO_HOME=/tmp/panelsplus-loader-after and the actual installed target `/home/kristanlaimon/.config/koreader/plugins/ink-away.koplugin`; output `/tmp/panelsplus-loader-after.log`. Targeted StyLua, Luacheck (3 changed Lua files) and whitespace checks pass. Previous full 579-unit run predates this one-condition correction; full suite not rerun because focused failure-before/pass-after checks and native loader coverage exercise the issue directly. Live physical UI remains unverified.

No old active plugin was found to delete. Previous installed copy remains backed up outside `/plugins`. No new deployment, staging, commit or push; source fix and tests are unstaged alongside earlier user-staged work. Next action: fully restart KOReader to load the updated Panels+ action gate, then show controls and check Draw immediately after Inverted. The installation mismatch and this host-wrapper bug were separate causes; installation alone could not correct the wrapper gate.

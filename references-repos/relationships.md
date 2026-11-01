# Plugin relationships

Read this first at the start of a session using `panelsplus-crossplugin-dev`.
Arrows mean knowledge/support, not write permissions: `A → B` means A supports B.
Panels means Panels+ in the developer's original notes. KOReader is the host, not a plugin.

## Developer-declared relationships

These ranges reproduce developer knowledge; they are not independently verified promises about future releases. Visibility was not specified and must be established before marking Visual/Not visual.

| Relationship | Left plugin / declared range | Direction | Right plugin / declared range | Visibility | Evidence |
| --- | --- | --- | --- | --- | --- |
| OneWay Knowledge | Panels+ >= v1.3.0 | → | kobo.koplugin >= v0.4.1 | Unspecified | Developer's `promptt.md` |
| OneWay Knowledge | Meguru >= v1.7.0 | → | Panels+ >= v1.5.1 | Unspecified | Developer's `promptt.md`; identity clarified in conversation |
| Unknown Behavior Relationship | Panels+ >= v1.5.1 | ? | Ink Away >= v4.4.0 | N/A | Developer changed the original No relationship declaration to Unknown pending testing; Ink Away version corrected in conversation |
| Unknown Behavior Relationship | Ink Away >= v4.4.0 | ? | Meguru >= v1.7.1 | N/A | Developer explicitly requests coexistence testing; arrow direction is unestablished |

## Implemented relationships (limited to the evidence below)

| Relationship | Left plugin / scope | Direction | Right plugin / scope | Visibility | Evidence |
| --- | --- | --- | --- | --- | --- |
| OneWay Knowledge | Panels+ 1.5.1 development tree with spread touch patch | → | Meguru 1.7.1 and pinned rolling SHA below | Not visual (no added UI) | Calls Meguru `spreadPageAt` before panel collection/selection; reference-backed geometry integration checks pass. Together with the declared Meguru → Panels+ awareness above, this adds reciprocal knowledge; the reverse direction's visibility remains unspecified. No future version range claimed. |
| OneWay Knowledge | Panels+ 1.5.1 development tree with annotation-surface adapter, runtime lookup and No crop canvas mapping corrections | → | Ink Away rolling `8dda5407e054` plus local `feature/annotation-surfaces` patch | Visual: conditional More Config… → Ink-away Settings… | Generic document-surface API in Ink Away; no target knowledge of Panels+ identities. 23 reference-backed integration checks pass against the patched rolling worktree. Unmodified 4.4.0/rolling provide fallback only; no future range claimed. See exact tuples and linked development notes below. |

## Exact tested tuples

No new compatibility testing is claimed by creation of this file. Local reference availability is not evidence of a passing integration test.

Pinned stable results determine task completion. Rolling-only failures must be reported as separate upcoming compatibility issues; do not hide them or treat them as stable failures.

Add records here with exact versions/SHAs for both plugins, stable/laboratory/rolling provenance, patch identity if applicable, KOReader version, environment/device, scenario, automated command/result, live result and date. Keep untested combinations explicitly unknown. Record evidence and scope when asserting No relationship.

### 2026-10-31 — Meguru spread touch mapping

- Source: Panels+ metadata 1.5.1, rolling working tree based on `6da28429692b0eeb17afec99ce274db403389f0e`, with the uncommitted `src/viewer_controller.lua` spread touch patch. Only Panels+ is modified.
- Stable target: original, unmodified Meguru v1.7.1 pin. SHA-256: `meguru/doc/document.lua` = `6f02b927f18d428fba94a88d83b5954108e1713854caa3ef3937d31896eb0ed8`; `meguru/spread.lua` = `80fc2aabd81ba4001151051c3ee271b80a78a6171d2ecea1ffa3d026577357d7`.
- Rolling target: original, clean Meguru checkout `8f98bd28f89ce0e769fd71a9218a320577c81618`.
- Host reference: KOReader `035e00b21d0286325ef2e8a7e3b6326f340e2ded`. No running KOReader version/device verified; automated environment is desktop Lua with KOReader fixtures.
- Kind/scope: geometry integration, not a full coexistence/lifecycle test. Each suite loads the selected target's complete document module in an isolated dependency environment and its actual spread module, then exercises Panels+ `showPanelSequence` and actual panel index selection. Network, detection results, rendering and reader screen conversion are fixtures. This does not establish plugin load-order or cleanup compatibility.
- Scenarios: Always/Landscape, both page orders, both halves and panel rows, unequal page sizes, crop offsets, gutter on/off, differing fit/growth settings; spread off, portrait Landscape mode, continuous scroll, wide standalone page, missing partner dimensions, missing API/unrelated provider and off-page gestures.
- Commands/results: `./run-tests.sh --compatibility-plugin=meguru --compatibility-plugin-version=1.7.1` and the same with `rollingrelease`: **11 passed each**. Related native zoom, collector, rotation and reader gesture suites: **25 passed**. Targeted StyLua/Luacheck and whitespace checks pass.
- Live result: pending. Restart KOReader and open upper/lower panels on both halves with Always and Landscape, including RTL and the configured entry gesture. Automated evidence does not replace this check.

### 2026-10-31 — Bottom-right panel cutoff in No crop

- Same source base, original stable target, clean rolling target and host reference as the spread-touch tuple above; additional Panels+ patch: `src/_panelcollector.lua` uses `Document.getNativePageDimensions` (with the existing layout-dimension fallback) for image crop bounds. No Meguru changes.
- User clarified the observed cutoff is in **No crop**. Its viewport was clamped against Meguru's cropped combined spread dimensions instead of the selected page's native dimensions. This can truncate the bottom-right panel. Loose expansion uses the same bounds; Tight remains covered as a control.
- Added reference-backed geometry integration checks for complete bottom-right panel containment on both pages in No crop, Loose and Tight. Uses the actual selected Meguru base-dimension shim and document geometry, and real Panels+ image-rectangle construction; pixel rendering remains untested. Reproduced a failing bounds check before the fix.
- Stable-first and rolling commands above now pass **14 checks each**. Collector, viewport, viewer margins, fold joining, rotation and page rendering regression suites: **43 passed**. Targeted formatter/linter and whitespace checks pass.
- Relationship stays Panels+ → Meguru, Not visual, scoped to these exact references. Live No crop validation on the reported pages remains pending; no new load-order/lifecycle compatibility claim.

### 2026-11-07 — Per-plugin adapters and optional Ink Away surface API

- Source: Panels+ metadata 1.6.0, working tree based on `e1c52a1aad44a671871eebd0d183725ca34f16b7`, with the `src/plugins-support/` refactor. Only Panels+ source, tests and documentation were changed.
- Host reference: KOReader `035e00b21d0286325ef2e8a7e3b6326f340e2ded`; desktop Lua fixtures, not a live reader/stylus session.
- Meguru: unchanged stable v1.7.1 pin and rolling `8f98bd28f89ce0e769fd71a9218a320577c81618`; **14 geometry integration checks pass per pin**. The existing spread gesture behavior is now attached by `meguru.lua`.
- Kobo: unchanged stable v0.4.1 pin and rolling `baa133794c8567a68068c7337d68d2fbf05631c7`; **2 action integration checks pass per pin**. The selected target's actual Bluetooth action definitions dispatch through Panels+ navigation. Bluetooth hardware and Dispatcher discovery are fixtures; this does not establish device/load-order coexistence.
- Ink Away: rolling `b5b83b2f6b67f2503e1fb4dada92dffc2a60d1c2`, whose existing staged `.foxnvim/pins.json` change remains untouched. The tested runtime API sources are unchanged. Per user direction, 4.4.0 is excluded; no stable integration claim is made.
- Ink Away scope: **12 API integration checks pass**, loading the target's actual plugin facade and integration registry. Book painting/storage and the host UI are fixtures. Checks cover both readiness orders, absent/incompatible API, pending-request cancellation, duplicate configuration, close/error cleanup, painting/snapshots, rotations, panning, folded regions, padded No crop geometry, and refusal of reflow images, transition canvases and foreign documents. Absence/incompatible API also have ordinary Panels+ unit coverage.
- Implemented relationship: Panels+ → Ink Away's optional version-1 surface API, Not visual (no new controls). Saved ink can be painted and existing Ink Away actions can select a registered panel surface. There is no claim of cross-panel editor navigation, toolbar fitting, or pixel/storage correctness on a device.
- Commands: `./run-tests.sh --compatibility-plugin=meguru`, `./run-tests.sh --compatibility-plugin=kobo`, and `./run-tests.sh --compatibility-plugin=ink-away --compatibility-plugin-version=rollingrelease`.
- Existing Gestures and LiveLight routing was extracted to individual adapters and retains unit coverage; no new version-pinned compatibility evidence is claimed for either.
- Live validation remains pending. No target references were updated, no live plugins were installed, and no annotation data format was changed.

- Full validation: `./run-tests.sh --quick --strict` ran Python (101 tests, one skip), Go OCR worker tests, and all Lua/dataset jobs. Separate native Go `-tags ocr_native` tests pass. Both plain Lua and native-FFI LuaJIT complete the dataset run with 10 jobs passing and the same 3 jobs failing. The final unit-only run passes 564 tests; formatter and Luacheck pass for all 121 owned Lua files; the deployment workflow passes 23 checks.
- Remaining failures, explicitly retained at the user's direction: Horimiya Smart recall 92.63% versus its saved 93.03% record; Chainsmoker Smart coverage 979 frames versus 975 in the saved baseline; SHY Smart F1 72.31% versus the 90% production target. Thresholds, annotation data and historical records remain unchanged.
- Stable comparison: reran all three books with complete source snapshots of tags `v1.5.0` and `v1.6.0`, using the same current images, annotations and evaluator. Both reproduce the same Smart metrics/failures. Their Smart detector blob is identical (`a6473c15917b864bff6dc2681054018569db013b`). These failures predate the adapter refactor. Stable Chainsmoker Safe also fails its current target (83.92% F1); the current Safe implementation passes (94.21% F1).

### 2026-10-31 — Ink Away document annotation surfaces

- User explicitly selected changes to both rolling sources and a new local target branch after updating the target. Source: Panels+ metadata 1.5.1, working tree based on `f5903ffaa29f5ce8f1bc223cdeb1d96f236f2264`, with the annotation-surface adapter, viewer/render/lifecycle hooks and conditional fold settings. No source release/commit was created.
- Upstream target: original stable 4.4.0 and clean rolling reference `8dda5407e05446dddb20ba5d6fbac263955d0db3`; the requested sync fetched upstream and reported no new commits. Stable SHA-256: `ink/reader/book.lua` = `852b7376d50e7c2d188837d4afb7f312b0fb7256d1d42464cf10b0642bf61f99`; `ink/reader/place.lua` = `2c415ed6e934231af86c3a410efdaf70521034018bafd4203015c4d5a41ec1b8`.
- Modified target: isolated worktree `.cache/plugin-compatibility/worktrees/ink-away-annotation-surfaces/`, local branch `feature/annotation-surfaces`, same base SHA and uncommitted patch. [Retained patch](plugins/ink-away/patches/annotation-surfaces.patch) SHA-256 = `f0c33b7ed9e98043af5051cd06f3cc2d43d9b42bd2af397fd70027b8650845d0`; applies cleanly to the original rolling reference. Neither original reference is edited.
- Host: KOReader reference `035e00b21d0286325ef2e8a7e3b6326f340e2ded`; desktop Lua/LuaJIT with UI/render/input fixtures. Running KOReader version and physical device remain unverified.
- Stable-first results: `./run-tests.sh --compatibility-plugin=ink-away --compatibility-plugin-version=4.4.0`: **5 passed**. Same command with `rollingrelease`: **5 passed** against unmodified rolling. These establish native fallback/coexistence smoke behavior, not annotation-surface integration.
- Modified-rolling integration: same rolling command plus `--compatibility-reference` pointing to the worktree: **18 passed**, loading the actual target modules. Scope: entry, placement, existing-ink rendering, rotations, fold discontinuities, clipping regions, cache invalidation, unchanged-item preservation, panel navigation, asynchronous page handoff, independent annotation/reading fold choices, cleanup, absent/older target, hidden ink and an unrelated generic provider. Host UI, canvas initialization and pixel painting are fixtures; no full plugin-loading or physical input claim.
- Regression: Panels+ `./run-tests.sh --quicker`: **539 passed**; target `tests/readerview.lua`: **236 checks passed**; `tests/bookink.lua`: **133 checks passed**; new generic `tests/annotation_surface.lua`: **11 checks passed**, using the real target canvas/gesture handlers, sidecar save and painter with host mocks. Targeted formatting/lint and whitespace checks pass.
- Build: target worktree built with the compatibility deployment helper, **build-only**. No live installation/publication. Exact artifact and commands, interface responsibilities, editing limits and live checklist are in [development notes](plugins/ink-away/annotation-surfaces.md).
- Live result: pending. The requested integration exists only in the modified rolling pair. Stable remains unsupported for this feature. Text/picture/fill editing across removed folds uses a local affine transform; the new original-fold option avoids that ambiguity. Native reader highlight-erasure hit boxes are not reused in the external viewport. No future version range is asserted.
- Subsequent user-authorized deployment on 2026-10-31: rebuilt the same feature-worktree source with `--install`, artifact `build.NdR55rUV`, and installed it into the sibling `ink-away.koplugin/`. Previous unchanged copy backed up outside plugins at `~/.config/koreader/.panelsplus-plugin-backups/ink-away.6or3ie4t/ink-away.koplugin/`. KOReader was not running. Installed-file verification is separate from the still-pending live input/rendering validation.

### 2026-10-31 — Ink Away reading-overlay lookup correction

- User live observation: annotation editor opens over the focused panel and shows/draws annotations, but annotations disappear when the editor closes. This confirms editor entry in the user's environment; complete coexistence remains unverified.
- Root cause: the KOReader host reference's `PluginLoader:_load` sets the plugin name from its directory and ignores `_meta.lua.name`; `ReaderUI:registerModule` uses that directory name as the UI key. The installed `ink-away.koplugin` is therefore `ui["ink-away"]`. Panels+ incorrectly looked only for `ui.inkaway`, missing the renderer, surface-release handler and settings entry. The generic editor could still discover the panel surface independently.
- Source-only follow-up on the same Panels+ base and target/host tuple above: use the canonical runtime key, with the legacy `inkaway` alias retained, for all three lookups. The installed Ink Away branch and retained target patch are unchanged; no target rebuild/reinstallation was needed.
- Corrected the shared compatibility fixture to register under the actual runtime key, cleared the paint spy before checking it, and added a save → close editor → panel paint regression. Reproduced **2 failing checks** before the source fix; afterward **19 passed** against the feature worktree. Original stable and upstream rolling fallback suites pass **5 checks each**, run stable first. These remain module-level checks with the previously documented host/pixel fixtures.
- Live result after this correction: pending restart and user validation that both pre-existing and newly drawn ink stay visible on the panel after editor closure.

### 2026-10-31 — No crop annotations across panel boundaries

- User report: in No crop, a stroke may extend outside the focused panel into a neighboring panel. Its native-page placement is correct, but moving focus to the neighboring panel shifts its rendering. Drawing outside the focused panel is explicitly intended to remain allowed.
- Same source base `f5903ffaa29f5ce8f1bc223cdeb1d96f236f2264`, target branch/patch and KOReader reference as above. Panels+-only correction: the No crop compositor records a native rectangle for the complete displayed canvas from the actual content bitmap dimensions and rounded blit offsets. The annotation surface uses this rectangle; the clipped page rectangle is retained for rendering and transition calculations. Successful canvas compositions supply the metadata; raw-bitmap fallbacks keep the ordinary rectangle mapping. No renderer, target code or saved annotation data was changed.
- Four reference-backed checks reproduced misalignment before the fix (left/right/top/bottom page edges). Each runs all four quarter rotations, widget offsets, pan/display zoom, an out-of-panel stroke, and panel navigation. Expected screen positions come from actual `PanelCollector`/`PageRender` compositing calls using a framebuffer/rendering fixture, not from a transform round-trip. The actual selected Ink Away Book/Place/Canvas/Transform code saves and reprojects the stroke. Tests assert unchanged item identity and correct native coordinates.
- Stable-first fallback suites: original stable **5 passed**, original rolling **5 passed**. Modified target worktree: **23 passed**. Panels+ general suite: **539 passed**. Targeted StyLua/Luacheck and whitespace checks pass. The installed target remains unchanged, so no target build/install was needed.
- Live result: pending restart and validation of the reported No crop cross-panel drawing scenario. Physical-device pixel rendering remains outside automated coverage.

### 2026-10-31 — Local commit snapshots

- Generic target implementation committed as `d87e2b097d6345085f9aa3ea0412bef23775ce10` on local branch `feature/annotation-surfaces`; the original rolling reference remains pinned at `8dda5407e05446dddb20ba5d6fbac263955d0db3`. Retained patch and installed runtime bytes are unchanged by committing.
- Panels+ runtime integration committed as `0af707c2b168da63ca37a10d06b9ae039a5b6ceb`, with fold-settings UI in `c93912ab4d05e96e39a48c4b046b1fca492feb9e`, on `feat/ink-away-compatibility`. No upstream push or new deployment was performed.

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
| OneWay Knowledge | Panels+ 1.6.0 with per-plugin adapters | → | Ink Away optional version-1 surface API, rolling SHA below | Not visual (existing annotation action; no new controls) | Actual target facade/registry integration checks; 4.4.0 excluded by user direction. Live annotation validation pending. |

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

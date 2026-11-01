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

# Plugin support

Each plugin owns one Lua adapter with an `attach(class)` entry point. The owning
Panels+ class calls it once after defining its native behavior. Adapters extend
that class; connection state belongs to individual readers/viewers. Loading an
adapter never loads the other plugin's code or assumes it is installed.

| Adapter | Attaches to | Responsibility |
| --- | --- | --- |
| `meguru.lua` | ViewerController | Convert spread gestures to native page coordinates. |
| `kobo.lua` | PanelViewer | Page-turner event aliases. Standard KOReader `GotoViewRel` navigation remains in the viewer. |
| `gestures.lua` | PanelViewer | Recognize configured Gestures touch zones while retaining local pinch/spread. |
| `livelight.lua` | PanelViewer | Pass the complete edge-light slide through even while zoomed. |
| `ink-away.lua` | PanelViewer | Optional version-1 surface API registration, saved-ink painting, native coordinate mapping and disposal. |

Ink Away connects through `inkAwayIntegrationAPI` or its pending-consumer queue.
No API means normal Panels+ behavior. Its adapter supports fixed-page crops,
No crop padding, panning, quarter-turn rotations, and joined folds. Snapshotting
paints the background without ink; closing cancels pending registration and
releases the active surface before disposing viewer resources.

Extracted reflow images are not document surfaces. Fixed-page annotations follow
panel and page navigation, including retained regions during transitions. The
editor can fit the panel beside its toolbar or keep the full viewport. Surface
geometry lives in `src/_annotationsurface.lua`; the adapter owns readiness and
registration. Rendering and navigation hooks remain in the split viewer modules.

Run `./run-tests.sh --compatibility-plugin=meguru` and
`./run-tests.sh --compatibility-plugin=kobo` for their stable and rolling pins.
Run `./run-tests.sh --compatibility-plugin=ink-away --compatibility-plugin-version=rollingrelease`
for the optional surface API. Stable 4.4.0 has fallback-only coverage via
`--compatibility-plugin=ink-away --compatibility-plugin-version=4.4.0`.
Gestures and LiveLight retain their existing Panels+ unit coverage; this does not
claim new version-pinned compatibility testing for either plugin.

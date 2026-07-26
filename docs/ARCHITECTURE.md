# Architecture

How Panels+ is put together, and what happens between a long-hold on a page and
a panel appearing on screen.

See also: [DETECTION.md](DETECTION.md) for how panels are found,
[PERFORMANCE.md](PERFORMANCE.md) for what each step costs.

## What the plugin actually replaces

KOReader already detects comic panels. Long-holding a page runs
`ReaderHighlight:onPanelZoom`, which finds the one panel under your finger,
renders it, and opens a plain `ImageViewer`. Reading a page means repeating that
for every panel: hold, read, close, hold again.

Panels+ keeps the detection idea and replaces the flow. It finds *every* panel on
the page, orders them for manga or comic reading, and opens a viewer you can
swipe through — including across page boundaries.

It does this by patching one method rather than forking the reader:

```mermaid
flowchart LR
    HOLD["Long hold on page"] --> RH["ReaderHighlight:onHold"]
    RH --> PZ["onPanelZoom<br/><i>patched at init</i>"]
    PZ -->|Panels+ enabled| PP["PanelsPlus:showPanelSequence"]
    PZ -->|Panels+ disabled| NATIVE["Original KOReader<br/>single-panel zoom"]

    style PP fill:#2d6cdf,color:#fff
    style PZ fill:#8a5cf6,color:#fff
```

The original method is saved on the highlight module and restored on close, so
disabling the plugin returns KOReader to stock behaviour with no restart.

## Modules

`main.lua` is the KOReader plugin class. It owns settings, cache state and
lifecycle; everything else is a module of methods copied onto that class by
`include()`. The mixin shape exists so KOReader's event dispatch keeps working —
events arrive as `PanelsPlus:onSomething()` regardless of which file defines it.

One consequence is worth knowing before editing: **`include()` copies by name, so
two modules cannot both define the same method.** That is why teardown lives on
the class in `main.lua` rather than in the module that needs it.

```mermaid
flowchart TD
    subgraph pluginclass ["PanelsPlus class (main.lua)"]
        MAIN["main.lua<br/><i>settings, lifecycle, teardown</i>"]
        CACHE["cache.lua<br/><i>panel cache, prefetch</i>"]
        VC["viewer_controller.lua<br/><i>open, navigate, prerender</i>"]
        ACT["actions.lua<br/><i>gesture actions</i>"]
        MENU["menu.lua<br/><i>main menu</i>"]
        NPZ["native_panel_zoom.lua<br/><i>patch and restore</i>"]
    end

    subgraph plain ["Plain modules"]
        PC["_panelcollector.lua<br/><i>detector dispatch, crops</i>"]
        SEG["_segmenter.lua<br/><i>recursive X-Y cut</i>"]
        PB["_pagebitmap.lua<br/><i>low-res ink map</i>"]
        ND["_nativedetector.lua<br/><i>batched k2pdfopt probes</i>"]
        PV["_panelviewer.lua<br/><i>ImageViewer subclass</i>"]
        GEO["_geometry.lua"]
        SET["_settings.lua"]
        TIM["_timing.lua"]
    end

    MAIN -.->|include| CACHE
    MAIN -.->|include| VC
    MAIN -.->|include| ACT
    MAIN -.->|include| MENU
    MAIN -.->|include| NPZ
    CACHE --> PC
    VC --> PC
    VC --> PV
    PC --> SEG
    PC --> PB
    PC --> ND
    PC --> GEO
    SEG --> SET
    PB --> SET

    style MAIN fill:#2d6cdf,color:#fff
    style PC fill:#8a5cf6,color:#fff
```

| File | Responsibility |
| --- | --- |
| `main.lua` | Plugin class, settings setters, teardown |
| `src/cache.lua` | Per-page panel cache, prefetch scheduling and cancellation |
| `src/viewer_controller.lua` | Opening viewers, page-boundary crossing, panel prerender |
| `src/_panelcollector.lua` | Chooses a detector, builds lazy panel images and crop rects |
| `src/_pagebitmap.lua` | Renders a page small and binarizes it into an ink map |
| `src/_segmenter.lua` | Recursive X-Y cut over the ink map, plus its acceptance test |
| `src/_nativedetector.lua` | KOReader's k2pdfopt detector, batched over one rasterization |
| `src/_panelviewer.lua` | `ImageViewer` subclass: swipes, gestures, controls, screenshots |
| `src/native_panel_zoom.lua` | Patching and restoring `onPanelZoom` |
| `src/_geometry.lua` | Rectangle helpers and reading-order sorting |
| `src/_settings.lua` | Defaults, persistence and profile migration |
| `src/_timing.lua` | Opt-in timing spans |

## Opening a panel sequence

```mermaid
sequenceDiagram
    autonumber
    participant U as User
    participant RH as ReaderHighlight
    participant PP as PanelsPlus
    participant C as Cache
    participant PC as PanelCollector
    participant V as PanelViewer

    U->>RH: long hold on page
    RH->>PP: showPanelSequence(ges)
    PP->>RH: screenToPageTransform(pos)
    RH-->>PP: hold_pos {page, x, y}

    PP->>C: collectPanels(page, hold_pos)
    alt page already cached
        C-->>PP: cached panels
    else
        C->>PC: collect(...)
        PC-->>C: ordered panels
        Note over C: stored, LRU capped at<br/>panel_cache_pages
        C-->>PP: ordered panels
    end

    PP->>PC: startIndex(panels, hold_pos)
    PC-->>PP: index of held panel
    PP->>PC: buildImages(page, panels)
    Note over PC: lazy render functions,<br/>not rendered bitmaps
    PC-->>PP: images + crop rects

    PP->>V: new + UIManager:show
    V->>V: render panel, request prerender
    V-->>U: panel on screen
    PP->>C: preloadNextPanels(page)
```

Two things in that diagram carry most of the responsiveness:

- **`buildImages` returns functions, not bitmaps.** Opening a 9-panel page
  renders exactly one panel. The other eight render when you reach them.
- **Panels are cached, images are not.** Panel rectangles are a few hundred bytes
  and stay for `panel_cache_pages` pages; rendered tiles are left to KOReader's
  own `DocCache`, which already knows the device's memory budget.

## Navigating

Horizontal swipes move through the sequence. Which direction means "next" depends
on the reading mode and the invert setting; every other direction falls through
to `ImageViewer`, so pinch-zoom and panning still work.

```mermaid
stateDiagram-v2
    [*] --> Panel: hold opens viewer at held panel

    Panel --> Panel: swipe (next/previous within page)
    Panel --> Zoomed: pinch or spread
    Zoomed --> Zoomed: swipe pans the image
    Zoomed --> Panel: zoom back out

    Panel --> Boundary: swipe past first or last panel
    Boundary --> Panel: adjacent page had panels
    Boundary --> [*]: adjacent page had none<br/>(close, turn page normally)

    Panel --> [*]: tap outside frame, or Close
```

The button bar carries a mode button showing **Auto**, **Fast** or **Exact**.
Tapping it cycles detection mode, re-detects the page and reopens at the panel
you were reading, matched by its centre — so a page one mode handles badly can be
switched without leaving it. See [DETECTION.md](DETECTION.md) for what each mode
does.

When a swipe runs off the end of a page, `onPanelViewerBoundary` turns the
underlying reader page and reopens the viewer on the adjacent page — at panel 1
going forward, at the last panel going back, so reading order stays continuous.
A `_panels_plus_boundary_pending` flag makes a second swipe during the turn a
no-op, which otherwise opened two viewers.

Because the viewer is a fullscreen window, it would normally swallow your
configured reader gestures. `PanelViewer:onGesture` walks the reader's own touch
zones first and runs a matching *user-configured* gesture through the reader UI,
while leaving built-in zones such as page-turn taps alone — so a tap on a panel
still toggles the controls instead of turning the hidden page underneath.

## Lifecycle

```mermaid
flowchart TD
    INIT["PanelsPlus:init"] --> S["Settings.load + migrate"]
    S --> T["Timing.enabled = debug_timing"]
    T --> ST["empty cache, prefetch and prerender tables"]
    ST --> REG["register menu + gesture actions"]
    REG --> PATCH["patch onPanelZoom"]

    CLOSE["PanelsPlus:onCloseWidget"] --> CP["cancelPanelPrerender"]
    CP --> CC["clearPanelCache<br/><i>also unschedules prefetch</i>"]
    CC --> RESTORE["restoreNativePanelZoom"]

    style INIT fill:#2d6cdf,color:#fff
    style CLOSE fill:#d9534f,color:#fff
```

Both scheduled jobs — page prefetch and next-panel prerender — are tracked by
handle so they can be unscheduled. Without that, closing a document leaves
closures on `UIManager`'s queue that still hold the plugin and a document that is
going away.

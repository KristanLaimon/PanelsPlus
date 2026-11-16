# PR #18 observations

Review: Add configurable gesture zoom in panel view.

Record observations here during review. Do not implement them until the user
explicitly requests the batch; then address them together in one session.

## 1. Limit the viewer's access to gesture zoom settings

Status: recorded; implementation deferred.

`src/embedded_image.lua` passes `panel_zoom_settings = self.settings`, unlike
the surrounding options, which explicitly pass only the setting each option
needs. `src/viewer_controller/navigation.lua` passes the same unrestricted table.
This exposes unrelated settings to the viewer and weakens that explicit boundary.

Use a metatable-backed proxy exposing only:

- `panel_gesture_zoom`
- `panel_zoom_gesture`
- `panel_gesture_zoom_factor`

The proxy should contain no raw setting values. Its `__index` reads allowed
keys from the original settings table; its `__newindex` writes allowed keys
back to that table and rejects unsupported keys. Reading unrelated keys should
return `nil`.

This retains live synchronization: menu edits to the original settings are
visible through the proxy, and edits through the proxy update the original
settings. Persistence remains explicit through `saveSettings()`; the proxy
does not automatically save to disk.

Apply the same scoped interface to both embedded-image and fixed-page viewers.
Verify synchronization in both directions and that unrelated settings cannot
be read or written through the proxy.


# 2. Refactor UI Icon "Resize, fit | Actual Size"
Its misleading and hard to use.

When zooming, it converts into "Fit" legend, change that string to "Restore zoom" (only available when zoomed in)
When no zoom applied, keep the "Fit Panel" | "Original Size Panel" legends (yes, rename them, and current integrated i18n values for those)

When long pressed this option, it will open the Zoom Menu Config


# About Panel Gesture zoom

3. About the "Panel gesture zoom" menu, it should use the same window size/layout as the "More Config" uses, its using default koreader menu.

In option: "Enable Panel Gesture zoom", it should show if (Activated) or (Desactivated), theres no visual feedback for the actual boolean.
In option: "Zoom Gesture" ->
- "Long press"
- "Two-finger tap"

Add:

- "Spread Gesture"

these options are readiobuttons, like the crs menu, you know what, make this menu the same size and layout as the OCR menu yay
by default spread gesture selected (Pinch-To-Zoom)



--

We'll remove 1.25x, 1.5x, 1.75x, 2x

what i want is the following:

                                                                                                                   new feature
                                                                                                                  ┌───────────── Estará por encima del render del panel
                                                                                                                  │                 no creará otro margin extra o su
                                                                                                                  │                        propio espacio
┌─────────────────────────────────────────────────────────────────────────────────────────────────────────────────┼───┌─────────────┐
│                                                                                                                 │   │             │    deslizable y en tiempo real
│                                                                                                                 │   │             │     actualiza el zoom, con el dedo
│                                                                                                                 │   │             │ debo de ser capaz de hacer dragging
│                                                                                                                 │   │             │   from top to bottom bottom to top
│                                                                                                           x3  ┌─┴┐  │             │
│                                                                                                               │  │  │             │
│                                                                                                               │  │  │     UI      │
│                                                                                                               │  │  │   icons     │
│                                                                                                               │  │  │             │
│                                                                                                               │  │  │already      │
│                                                                                                               │  │  │implemented  │
│                                                                                                               │  │  │             │
│                                                                                                               │  │  │             │
│                                                                                                            1x │  │  │             │
│                                                                                                               │  │  │             │
│                                                                                                               │  │  │             │
│                                                                                                               │  │  │             │
│                                                                                                           0.4x└──┘  │             │
│                                                                                                                     │             │
│                                                                                                                     │             │
│                                                                                                                     │             │
│                                                                                                                     │             │
┌─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────└─────────────┘
│                                                                                                                                   │
│                                                                                                                                   │
│                                                  settings buttonshere                                                             │
│                                                  (already implemented)                                                            │
│                                                                                                                                   │
│                                                                                                                                   │
│                                                                                                                                   │
└───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘

in UI, of course, this setting is remembered globally, not along documen tsettings,

if I set x1.5 here, when I use my zoom gesture, automatically will use that zoom, by default.


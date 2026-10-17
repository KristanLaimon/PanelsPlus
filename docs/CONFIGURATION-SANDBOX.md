# Configuration organization sandbox

Status: initial recommendations accepted; implemented 2026-10-16. The inventory below records the menus before the refactor. Frequency classifications are design judgments, not measured usage data.

Implementation: More Config has eight common settings plus **Open advanced options**. Each row uses a matching black SVG icon on the left, its label in the middle, and the value on the right. Swipe inversion, tap inversion, and the panel-opening gesture were promoted to quick settings by user preference. The opening gesture deliberately remains in KOReader too, for access before entering the viewer. Advanced settings share KOReader's actual Panels+ submenu; holding Smooth/Animated opens its Animation section. Reading order keeps its dedicated viewer button. Text selection is unavailable for embedded-image viewers, matching their existing restriction.

## Goal

Give each configuration option a predictable home:

1. **Common:** a reading adjustment that needs fast access from **More Config...**, unless it already has a dedicated viewer control.
2. **Advanced:** a preference normally chosen once, device tuning, or troubleshooting. Put it in the **Panels+ submenu of KOReader's menu**.

Frequency means how often someone changes a setting, rather than how often its feature is used. An always-used gesture can still be a rarely changed preference.

Keep existing dedicated viewer controls fast. Avoid adding copies of them to More Config just to make that list longer. For this draft, remove common settings from the KOReader submenu when their viewer access is sufficient; reserve that submenu for advanced settings. Reading order is a tradeoff to revisit because it can also be useful before entering the viewer.

## What exists today

- **More Config:** 11 entries: six navigation/persistence preferences, three spread controls, pre-rendering, and text selection.
- **KOReader → Panels+:** nine top-level entries, including separate Manga and Comic radio choices and three submenus.
- **Overlap:** spread auto-rotation, spread rotation direction, and removing the spread fold line appear in both places.
- **Reading order:** KOReader's Manga/Comic choices also duplicate the dedicated viewer reading-mode button.
- **Other viewer controls:** rotation, OCR model, progress visibility, navigation mode, crop, panel finding, and profiles live outside both menus. Some have long-press settings.

The first two menus contain **16 distinct configuration choices** when the two reading-order radio entries count as one choice and duplicate spread entries count once.

## Complete inventory of the two menus

“Both” means More Config and the KOReader Panels+ submenu. Labels omit dynamic current-value suffixes. Proposed names can be shorter than the current labels.

| Option / stored setting | Current location and choices | Proposed class and home | Reason |
| --- | --- | --- | --- |
| Tap screen sides to navigate — `tap_navigation` | More Config; on/off | **Common → More Config** | Quickly switch between tapping for navigation and tapping for controls. |
| Swipe to navigate — `swipe_navigation` | More Config; on/off | **Common → More Config** | Switch input styles during reading. |
| Invert panel swipe direction — `invert_swipe` | More Config; on/off | **Common → More Config** | User preference: adjust swipe direction quickly while reading. |
| Invert tap screens direction — `invert_taps` | More Config; on/off | **Common → More Config** | User preference: adjust tap direction quickly while reading. Label: “Invert tap direction”. |
| Kobo-like edge vertical gesture — `kobo_vertical_gesture` | More Config; on/off | **Advanced → Navigation & gestures** | Enable or disable a preferred zoom gesture once. |
| Remember per-document settings — `remember_doc_settings` | More Config; on/off | **Advanced → Defaults & persistence** | A persistence policy, rather than an immediate reading adjustment. |
| Rotate spreads / Auto-rotate double-page spreads — `auto_rotate_double_pages`, `rotate_screen_for_double_pages` | Both; Off / Viewer / Reading / Viewer + reading | **Common → More Config** | Adapt double-page handling to the current book. One logical choice backed by two booleans. |
| Spread direction / Spread rotation direction — `spread_rotation_direction` | Both; KOReader / Clockwise / Counter-clockwise | **Advanced → Double-page spreads** | Usually follows device/holding preference; manual rotation already has a quick control. |
| Remove spread fold line / Remove the fold line from double-page spreads — `join_spread_fold` | Both; on/off | **Common → More Config** | Depends on scan quality; useful to compare immediately on a spread. |
| Pre-render next panel — `panel_prerender` | More Config; on/off | **Advanced → Performance** | Device performance and resource preference. |
| Touch & hold — `hold_text_selection` | More Config; on/off | **Common → More Config** | Quickly enable dictionary lookup or stop accidental text selections. Suggested label: “Touch & hold text selection”. |
| Disable plugin panel focusing — `enabled` (inverted checkmark) | KOReader only; disabled/enabled | **Advanced → Plugin** | Switch between Panels+ and native panel zoom; must remain accessible without entering the viewer. |
| Manga mode / Comic mode — `mode` | KOReader radio choices and dedicated viewer button; manga/comic | **Common → existing viewer reading-mode button** | Changes reading order by book and already has direct access. Do not add another More Config entry. |
| Open panels with — `panel_gesture` | KOReader submenu; Long press / Two-finger tap | **Common → More Config**, plus KOReader access before opening panels | User preference: change the opening gesture quickly. Both entry points share the same picker choices. Two-finger tap requires multitouch. |
| Prefer native-text layer in PDF files over Panels+ text recognition — `prefer_native_text_layer` | KOReader only; on/off | **Advanced → Text recognition** | Recognition strategy and fallback preference. Suggested label: “Prefer PDF native text”. |
| Enable debugging logs — `debug_mode` | KOReader only; on/off | **Advanced → Troubleshooting** | Diagnostic control. |

## Adjacent viewer options checked during the scan

These are included so that reorganizing the menus does not strand an existing option. Keeping an existing dedicated control is not a third configuration class.

| Option | Current access / choices | Proposed class and access |
| --- | --- | --- |
| Reading order — `mode` | Manga/Comic viewer button; also listed above | **Common:** keep dedicated button. |
| Device rotation | Rotate picker; four directions | **Common:** keep Rotate picker. |
| Image rotation — `image_rotation` | Rotate picker; four directions / Auto | **Common:** keep Rotate picker. |
| OCR model — `ocr_bundled_language` | OCR Model toolbar control; available bundled English/Spanish and installed user models | **Common:** keep model picker; language changes with the book. Unavailable models are not offered. |
| Progress bar — `progress_bar_visible` | Show Bar / Hide Bar toolbar control | **Common:** keep dedicated control. |
| Navigation mode — `nav_transition_mode` | Viewer button; Classic / Smooth / Animated | **Common:** keep dedicated control. Embedded images have a separate stored mode, `embedded_nav_transition_mode`. |
| Crop mode — `crop_mode` | Viewer button; Strict / Loose / With margin / No crop | **Common:** keep dedicated control. |
| Panel margin — `panel_margin_ratio` | Hold crop button in With margin mode | **Common:** keep contextual crop adjustment. |
| Loose crop bleed — `panel_bleed_ratio` | Hold crop button in Loose mode | **Common:** keep contextual crop adjustment. |
| Panels Finding — `panel_finding_mode` | Viewer button; Safe / Smart | **Common:** keep dedicated control for fixing detection on the current book. |
| Settings Profile | Viewer button; None / saved profiles / Create / Manage | **Common:** keep profile selection and its existing management workflow. |
| Pan animation duration — `nav_transition_duration` | Hold navigation button in Smooth mode; slider | **Advanced → Animation**; normally tune once. |
| Animate page-to-page transitions — `nav_transition_cross_page` | Same Smooth options popup; on/off | **Advanced → Animation**. Embedded-image limitations still apply. |
| Transition frames — `nav_transition_frames` | Same Smooth options popup; slider | **Advanced → Animation**; performance tuning. The current “fps” label describes a step count, so revise the label when implementing. |
| Animate between panels — `nav_animated_panels` | Hold navigation button in Animated mode; on/off | **Advanced → Animation**. |
| Animate between pages — `nav_animated_pages` | Same Animated options popup; on/off | **Advanced → Animation**. |

Profile management currently supports creating from current settings, selecting/applying, renaming, replacing with current settings, deleting, and draft editing with Save/Cancel. The draft editor exposes rotation, reading order, progress, OCR, navigation mode, and crop. Preserve that workflow; profile editing changes saved profile values, so it is not an extra global settings menu.

Screenshot, Fit/Actual Size, Close, Back, and Cancel are actions rather than persistent configuration. Keep them in their existing action controls. Internal defaults in `src/_settings.lua` (detector thresholds, cache sizes, memory limits, migration metadata, etc.) do not become new UI options through this reorganization.

## Proposed More Config layout

```text
More Config...
  Tap screen sides to navigate             [on/off]
  Swipe to navigate                        [on/off]
  Invert panel swipe direction              [on/off]
  Invert tap direction                      [on/off]
  Open panels with                         [Long press / Two-finger tap]
  Rotate spreads                           [current mode]
  Remove spread fold line                  [on/off]
  Touch & hold text selection              [on/off]
  ────────────────────────────────────────────────
  Open advanced options
```

Eight settings plus the requested final button, down from eleven settings. Small screens paginate the list while preserving icons and the final advanced entry. Show current values or checkmarks. Remove the repeated bracketed category prefixes if this short list makes them unnecessary.

The advanced Panels+ submenu contains the advanced rows above and the deliberate pre-viewer opening-gesture shortcut, grouped as Plugin, Navigation & gestures, Defaults & persistence, Double-page spreads, Text recognition, Performance, Animation, and Troubleshooting. These are organizational groups, not necessarily eight nested submenus; avoid replacing one long navigation path with another.

If animation tuning moves to KOReader, holding the navigation-mode button should jump directly to that same Animation group instead of keeping an independent settings popup. Crop adjustments remain contextual because they are useful while looking at the panel.

## “Open advanced options” behavior

Required label: **Open advanced options**. Place it after every setting as the final selectable row, with a separator.

1. Close the More Config popup.
2. Open KOReader's actual reader menu directly inside the **Panels+ submenu**. Opening only the top-level tools tab would leave the original navigation problem unresolved.
3. Use the same menu entries and setters as normal KOReader access. Do not build a second copy of advanced settings.
4. Back should follow KOReader's normal menu hierarchy. Closing the menu should return to the same reading page and panel when panel focusing remains enabled.
5. Apply changes to the active viewer as well as persistent settings. Rebuild only when needed for geometry or rotation, preserving the panel position. Disabling panel focusing should close the viewer and leave the native reader available.
6. Support fixed-layout pages and embedded-image viewers. Existing embedded-image text-selection and animation restrictions must remain reflected in behavior.

Implementation lead from the local KOReader source: `ReaderMenu:onShowMenu(tab_index, do_not_show)` can construct the menu without showing it; `TouchMenu:openMenu(path, with_animation)` can navigate to a submenu. Resolve the Panels+ entry from `reader_menu.menu_items.panels_plus` and the current sorted menu tree rather than hardcoding tab/item numbers or matching translated labels. Check keyboard-only `Menu` separately because `ReaderMenu` uses it on devices without touch or D-pad; it does not necessarily share TouchMenu's navigation API. The implementation traverses the sorted menu tree by stable markers and uses the native submenu-selection methods before showing the menu. Touch and keyboard navigation are covered by unit tests; visual device verification remains manual.

## Decisions to revisit together

- **Tap/swipe toggles:** are these changed often enough to keep quick? If they are set-once preferences for your use, move them into advanced Navigation & gestures too.
- **Fold removal:** keep quick for scan-dependent adjustments, or advanced if it is effectively always enabled?
- **Text selection:** keep quick to suppress accidental holds, or advanced if you rarely change it?
- **Reading order before opening panels:** retain Manga/Comic in KOReader as a deliberate exception, or rely on the existing viewer button?
- **Animation:** move fine tuning to advanced as proposed, or retain the existing long-press shortcut into the shared advanced controls?

## Implementation checklist after the categorization is settled

- [x] Agree on common/advanced placement and any deliberate shortcuts.
- [x] Share option definitions/setters across menu entry points; retain stored keys and values.
- [x] Reduce More Config to the agreed common controls.
- [x] Organize the KOReader Panels+ submenu and remove accidental duplicates.
- [x] Add the final Open advanced options row and direct navigation.
- [x] Ensure advanced changes update the open viewer, including after rotation/rebuilds.
- [x] Update existing More Config tests that currently assert 11 entries and fixed indices.
- [x] Test direct submenu opening, Back/Close behavior, and active-viewer synchronization.
- [ ] Manually verify touch and keyboard access, fixed-layout and embedded images, and supported/unsupported animation devices.

## Source map

- [More Config and transition/OCR popups](../src/viewer_controller.lua): `showMoreConfigMenu`, `showNavTransitionOptionsMenu`, `showOcrLanguageMenu`.
- [KOReader Panels+ entries](../src/menu.lua): `addToMainMenu`.
- [Viewer buttons and contextual settings](../src/_panelviewer.lua): `replaceButtonTable`, crop sliders, navigation options.
- [Quick toolbar](../src/_quicktoolbar.lua) and [rotation picker](../src/_rotationpicker.lua).
- [Profiles UI](../src/profile_menu.lua) and [profile storage](../src/profiles.lua).
- [Defaults](../src/_settings.lua) and [document persistence / setters](../main.lua).
- [Existing More Config tests](../tests/spec/viewer_controller_more_config_spec.lua).
- Local ignored KOReader reference: `koreader/frontend/apps/reader/modules/readermenu.lua` and `koreader/frontend/ui/widget/touchmenu.lua`.

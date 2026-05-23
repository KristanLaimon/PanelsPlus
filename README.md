# Read manga and comics panel by panel, without losing the page.

<p align="center">
  <img src=".github/manga_fullscreen.png" alt="Panels+ running in KOReader" width="420">
</p>

# Panels+

Panels+ is a KOReader plugin that improves manga and comic reading by replacing the default single-panel zoom flow with a direction-aware panel reader.

It keeps KOReader's native panel detection, then adds ordered panel navigation, manga/comic reading modes, swipe tuning, and gesture-friendly actions so pages feel smoother on e-readers.

<p align="center">
  <video src=".github/2026-05-20%2020-25-02.mp4" controls width="420"></video>
</p>

## Highlights

- Panel-focused reading for manga, comics, manhwa, and other image-heavy books.
- Manga mode for right-to-left panel order.
- Comic mode for left-to-right panel order.
- Optional inverted swipe direction when navigation feels reversed on your device.
- KOReader gesture actions for toggling the plugin and switching modes quickly.
- Lightweight panel cache and prefetch settings tuned for e-reader performance.
- Built on KOReader's existing native panel detector instead of replacing it entirely.

## Installation

Clone or download this repository, then build the plugin folder:

```bash
./build.sh
```

The script creates:

```text
dist/panels_plus.koplugin
```

Copy that folder into your KOReader plugins directory.

On Kindle, the target path is usually:

```text
/mnt/us/koreader/plugins/panels_plus.koplugin
```

Restart KOReader after copying the folder.

## Usage

Open a document in KOReader, then go to the main menu and select:

```text
Panels+
```

From there you can:

- Enable or disable panel focus.
- Choose Manga mode for right-to-left reading.
- Choose Comic mode for left-to-right reading.
- Invert panel swipe direction if needed.
- Assign plugin actions from KOReader's gesture manager.

## Gesture Actions

The plugin registers these KOReader actions:

- `Panels+: toggle`
- `Panels+: manga/comic mode`
- `Panels+: set manga mode`
- `Panels+: set comic mode`

Use KOReader's gesture manager to bind them to taps, swipes, or other gestures.

## Notes

This plugin is document-only and works inside KOReader's reader view. It is intended for image-based manga and comics where panel-by-panel navigation is more comfortable than repeatedly zooming and dragging around the full page.


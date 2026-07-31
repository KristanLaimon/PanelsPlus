







<p align="center">
  <img src=".github/panels+_logo.png" alt="Panels+ logo" width="250">
  <br>
  <strong>Panels+</strong>
  <br>
  <span style="display:block;font-size:1.25rem;">Read manga and comics panel by panel, without losing the page and other panel zooming utilities with no setup required!. Install and forget</span>
</p>



<table>
  <tr>
    <td align="center" width="30%">
      <video src="https://github.com/user-attachments/assets/23353a47-4038-4361-8536-a907c25b981e" controls width="420"></video>
      <br>
      <sub>Do not like the cropping and want to see the surroundings as well?, Want to see the panels flow fully animated from one panel to another?, granted and
        fully customizable. (Works better in non e-ink based devices)</sub>
    </td>
    <td align="center" width="40%">
      <video src="https://github.com/user-attachments/assets/446c71c6-a8f7-47ce-ae44-0fc885ed3241" controls width="420"></video>
      <br>
      <sub>Core feature: Panel by panel smooth travelling. Battle-tested for performance on low-specs e-readers and old Koreaders versions support.</sub>
    </td>
    <td align="center" width="30%">
      <video src="https://github.com/user-attachments/assets/aa34d5db-8e47-4b68-bd5b-fc90d3da6493" controls width="420"></video>
      <br>
      <sub>Additional Features: Manga/Comic direction, cropping, precision, and much more!. Margin and Loose cropping are configurable by just long-pressing those buttons.</sub>
    </td>
  </tr>
</table>







Panels+ is a KOReader plugin that improves manga and comic reading by replacing the default single-panel zoom flow with a direction-aware panel reader, fully automatized and scans in-live your
mangas layouts. No complex pre-mangas-scanning setup required, install and works for everything.

It keeps KOReader's native panel detection, then adds ordered panel navigation, manga/comic reading modes, swipe tuning, and gesture-friendly actions so pages feel smoother on e-readers, plus:

- Zoom-friendly screenshot support while reading panels.
- Panels finding on dark-background pages, where KOReader's own detector sees nothing.
- Pre-fetching the next panels while you read the current one, so swiping is instant (or at least very fast).

## Download

Download the latest release from the [releases page](https://github.com/KristanLaimon/BetterPanels/releases/latest), unzip it, then follow the [installation steps](#installation).

If you want to build the plugin yourself instead, follow [building from source](#building-from-source).

## Config
Configuration is as easy as just using the plugin itself!

<table>
  <tr>
    <td align="center" width="30%">
      <video src="https://github.com/user-attachments/assets/b66a725e-a8f2-42a4-933e-dc9d625f660b" controls width="420"></video>
      <br>
      <sub>All your important config, straight in the zooming view!. No more looking over many hidden config screens.</sub>
    </td>
    <td align="center" width="30%">
      <video src="https://github.com/user-attachments/assets/9368e8f4-a898-446f-bf8a-c084147dfbc1" controls width="420"></video>
      <br>
      <sub>If you still need more advanced config, you can find it here</sub>
    </td>
  </tr>
</table>

* You can customize:
    - The swipe direction
    - Cropped panel? No cropped? Margin?, already got in.
    - Smooth animations (Recommended in no ink-devices)
    - Included KOReader gesture actions for toggling the plugin and switching modes quickly.


## Documentation (For developers and contributions)

- [Introduction](docs/INTRO.md) — a first read: what the plugin replaces, how a page turns into a panel sequence, and the module map.
- [Architecture](docs/ARCHITECTURE.md) — how the plugin is put together, and what happens between a long hold and a panel on screen.
- [Panel detection](docs/DETECTION.md) — how panels are found, why there are two detectors, and every tuning knob.
- [Viewer modes](docs/MODES.md) — what Auto, Gutter and Outline mode mean for the reader, and where to change them.
- [Performance](docs/PERFORMANCE.md) — what each step costs, the memory budget, and how to measure it on your own device.
- [Known Limitations](docs/KNOWN-LIMITATIONS.md) — current edge cases and known-behaviour (a todo-list to fix at the same time).

## Installation

After downloading or building the plugin, you should have this folder:

```text
panels_plus.koplugin
```

Copy the whole folder into your KOReader `plugins` directory. Do not copy only the files inside it.

Common plugin paths:

| Device | KOReader plugins directory |
| --- | --- |
| Kindle | `/mnt/us/koreader/plugins/` |
| Kobo | `.adds/koreader/plugins/` |
| Android | `/sdcard/koreader/plugins/` |
| Linux Flatpak | `~/.var/app/rocks.koreader.KOReader/config/koreader/plugins/` |

The final path should look like this:

```text
<koreader plugins directory>/panels_plus.koplugin
```

Restart KOReader after copying the folder.

## Building From Source

Clone or download this repository, then run:

```bash
./build.sh
```

On Windows PowerShell, run:

```powershell
.\build.ps1
```

The script creates:

```text
dist/panels_plus.koplugin
```

Copy that generated folder into your KOReader plugins directory, then restart KOReader.

## Gesture Actions

Panels+ registers these KOReader actions:

- `Panels+: toggle`
- `Panels+: manga/comic mode`
- `Panels+: set manga mode`
- `Panels+: set comic mode`

Use KOReader's gesture manager to bind them to taps, swipes, or other gestures.

## Why This Exists

I'm a manga fan and I read a lot in my e-reader and found out some panels are too small to read comfortably on the full page, then I tried using ko-reader native zoom, but then I need to zoom out, change panel, zoom-in, read the panel, zoom-out, zoom-in, read, and so on... (ugh!).

KOReader can detect panels, but the native flow often means zooming into one panel, leaving zoom, moving to the next panel, and repeating that cycle.

I wanted to create `Panels+` so (we manga-comic readers) could have the panel navigation we deserve with a normal reading flow!. 

This supports screenshots while zoomed into panels, so you can capture the exact panel view instead of only taking full-page screenshots, and use them as screen savers, book covers, anything you want.


# Contributions?
Project is actually stable, and personally tested in:
  - Kindle 12th Gen

I don't see any more options to include, but contributions are welcome for:
  - edge-cases bugs fixes
  - performance improvements
  - device-specific bugs fixes (this would help a lot)

Thanks for using the plugin or at least, taking a look into this repo.

## License
MIT License, check "LICENSE" file in this repository.

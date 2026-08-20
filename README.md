<p align="center">
  <img src=".github/panels+_logo.png" alt="Panels+ logo" width="250">
  <br>
  <strong>Panels+</strong>
  <br>
  <span style="display:block;font-size:1.25rem;">Read manga and comics panel by panel, without losing the page and other panel zooming utilities with no setup required!</span>
  <br><br>
  <a href="https://github.com/KristanLaimon/BetterPanels/releases/latest"><img src="https://img.shields.io/github/v/release/KristanLaimon/BetterPanels?color=blue&style=flat-square" alt="Latest Release"></a>
  <a href="https://github.com/KristanLaimon/BetterPanels/releases"><img src="https://img.shields.io/github/downloads/KristanLaimon/BetterPanels/total?color=brightgreen&style=flat-square" alt="Downloads"></a>
  <a href="https://koreader.rocks"><img src="https://img.shields.io/badge/KOReader-v2025.04%20--%20v2026.03%20%26%20Newer-006699?style=flat-square" alt="KOReader Compatibility"></a>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/KristanLaimon/BetterPanels?color=informational&style=flat-square" alt="MIT License"></a>
  <a href="https://github.com/KristanLaimon/BetterPanels/stargazers"><img src="https://img.shields.io/github/stars/KristanLaimon/BetterPanels?style=flat-square" alt="GitHub Stars"></a>
  <a href="https://github.com/sponsors/KristanLaimon"><img src="https://img.shields.io/badge/Sponsor-GitHub%20Sponsors-ea4aaa?logo=github&style=flat-square" alt="Sponsor on GitHub"></a>
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
 


### Developer's Tip: The Cinematic Experience

For a more fluent and immersive navigation, my personal recommendation is to set KOReader to **landscape (horizontal) rotation** and enable **strict-crop mode** in Panels+ with classic navigation for e-ink based devices and smooth navigation for android and non-e-ink devices. 
In my opinion, this is hands down the most cinematic way to experience your manga. Here is a quick look at how it runs on an actual Kindle:

<div align="center">
  <video src="https://github.com/user-attachments/assets/ca4de34b-c9e4-4045-932a-8831cea1a2b4" controls width="420"></video>
  <br>
  <em>🎥 Real footage of the landscape strict-crop setup on a Kindle.</em>
</div>

### OCR Word Lookup Setup (Experimental)

Panels+ introduces experimental OCR support, allowing you to touch & hold text inside a zoomed-in panel to look up words in the dictionary—even in comics/manga! Works across `.CBZ`, `.CBR`, and `.PDF`.

<strong>IMPORTANT:</strong> To use this feature, you'll need to set up a couple of things first:
<ul>
  <li><em>Install an OCR engine in KOReader by <a href="https://koreader.rocks/user_guide/#L2-ocr">following the official KOReader guide</a>.</em></li>
  <li><em>Install at least one dictionary. You can do this by <a href="https://www.youtube.com/watch?v=fthGMdpUfR0">following this tutorial for manual installation</a>, or by using KOReader's built-in online dictionary installer.</em></li>
</ul>

<em>(Note: Word detection is tricky on hand-lettered or stylized comic text and might not always get it exactly right. As a workaround, I recommend binding a comfortable multi-swipe gesture to "Open dictionary lookup" as a fallback!)</em>

## Documentation (For developers and contributions)

- [Introduction](docs/INTRO.md) — a first read: what the plugin replaces, how a page turns into a panel sequence, and the module map.
- [Architecture](docs/ARCHITECTURE.md) — how the plugin is put together, and what happens between a long hold and a panel on screen.
- [Panel detection](docs/DETECTION.md) — how panels are found, why there are two detectors, and every tuning knob.
- [Viewer modes](docs/MODES.md) — what Smart, Quick and Deep mode mean for the reader, and where to change them.
- [Performance](docs/PERFORMANCE.md) — what each step costs, the memory budget, and how to measure it on your own device.
- [Known Limitations](docs/KNOWN-LIMITATIONS.md) — current edge cases and known-behaviour (a todo-list to fix at the same time).

## Compatibility

### KOReader versions

This plugin is compatible with KOReader across the following version range:

| Environment | Supported Version |
| --- | --- |
| **Oldest Supported Version** | KOReader `v2025.04` *"Full Moon"* |
| **Newest Tested Version** | KOReader `v2026.03` *"SnowFlake"* & Newer |

### File types formats supported
<ul>
  <li><em>.cbr (digital comic book archive):</em> Usual standard format for western comics</li>
  <li><em>.cbz (Comic Book Zip Archive):</em> The standard for mangas, usually found in this format when downloading from internet or in (.cbr). I strongly recommend using <a href="https://github.com/manga-download/hakuneko">Hakuneko (Downloader)</a> and <a href="https://github.com/ciromattia/kcc">KCC (Kindle Comic Converter)</a> to adapt hakuneko downloads to .cbz for mangas. This is the top priority format I give support/compatibility with this plugin</li>
  <li><em>.pdf (Portable Document Format):</em> Another common format when downloading mangas/comics.</li>
</ul>

<strong>File types formats NOT tested/supported (They could/could not work)</strong>
<ul>
  <li><em>.mobi</em></li>
  <li><em>.epub</em></li>
  <li><em>.any_other</em></li>
</ul>
The main reason is because these <strong>are not meant to be used</strong> for documents heavy in images, 'cause, well, every page of a comic/manga is an image, and one image per page. These are text-only formats, with some images occasionally.
If you have your mangas/comics in one of these formats, change them to more standard ones. Check <a href="https://github.com/ciromattia/kcc">KCC (Kindle Comic Converter)</a> and the <strong>File types formats supported</strong> previous section. <br><br>

<em>I might add them to the support list in a future update, but since those formats aren't really built for comics, it's not a top priority on the Panels+ roadmap right now. (That said, if you want to tackle it and submit a PR, you're more than welcome to!)</em>

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

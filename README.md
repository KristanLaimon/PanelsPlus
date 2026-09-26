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
  <a href="https://github.com/AnthonyGress/zen_ui.koplugin"><img src="https://img.shields.io/badge/ZEN%20Package%20Manager-Available-purple?style=flat-square" alt="ZEN Package Manager"></a>
</p>

<table>
  <tr>
    <td align="center" width="50%">
      <video src="https://github.com/user-attachments/assets/fff9ba07-565e-4f48-b016-1466bb74a609" controls width="420"></video>
      <br>
      <sub>Core feature: Panel by panel smooth travelling. Battle-tested for performance on low-specs e-readers and old KOReader versions support. (Starting from 2025 versions)</sub>
    </td>
    <td align="center" width="50%">
      <video src="https://github.com/user-attachments/assets/4ee8e78c-77a4-4432-a6e3-f841912c864b" controls width="420"></video>
      <br>
      <sub>Comics showcase: Reading comic books panel by panel with custom panel flow and navigation.</sub>
    </td>
  </tr>
</table>

Panels+ is a KOReader plugin that improves manga and comic reading by replacing the default KOReader single-panel zoom flow with a custom direction-aware panel reader with in-live panel scanning. No complex pre-mangas-scanning setup required, install Panels+ and *it just works*.

### Features
- Includes 3 reading modes: 
<table>
  <!-- Videos (mismo alto y centrados) -->
  <tr valign="middle">
    <td width="25%" align="center">
      <video height="180" src="https://github.com/user-attachments/assets/7200f3e1-74d8-4b24-bd64-c775600d35ed"></video>
    </td>
    <td width="25%" align="center">
      <video height="180" src="https://github.com/user-attachments/assets/c247ed18-57db-4748-9205-7a50035096a3"></video>
    </td>
    <td width="25%" align="center">
      <video height="180" src="https://github.com/user-attachments/assets/e5be3a1a-9f97-407e-acac-e2033af7f912"></video>
    </td>
    <td width="25%" align="center">
      <video height="180" src="https://github.com/user-attachments/assets/54ce079c-176b-420e-acb6-d6f9738b6f70"></video>
    </td>
  </tr>

  <!-- Títulos -->
  <tr>
    <td align="center"><b>1. Animated mode</b></td>
    <td align="center"><b>2. Smooth mode</b></td>
    <td align="center"><b>3. Classic mode</b></td>
    <td align="center"><b>Trained to work in non-standard panels</b></td>
  </tr>

  <!-- Subtítulos -->
  <tr>
    <td align="center"><em>Swipe through your manga with fade-in/fade-out transitions. (Only available in e-ink devices).  You can swipe or tap on edges, configurable in "More Config" button.</em></td>
    <td align="center"><em>Make the current zoom view to move smoothly between panels (Duration and FPS between panels customizable). (Works better in non-eink devices, like Android and Desktop)</em></td>
    <td align="center"><em>Move between panels with no transitions at all, simply and classic.</em></td>
    <td align="center"><em>Panels+ has improved panel recognition for non-perfect rectangles panels. In case it can't find panel, it shows the whole page or selects 2+ panels, to avoid losing panels or wrong order.</em></td>
  </tr>
</table>

- Zoom-friendly screenshot support while reading panels.
- Open panels with a long press or, if you prefer, a two-finger tap.
- Panels finding on dark-background pages.
- Animated panel transitions (or even pages transition, optional)
- Comics & Mangas support
- Customizable and performant in low-end e-ink devices.
- Move between panels with swipes and/or taps on edges.
- And much more.

> Currently we're looking for translators. If you'd like to help us translate this plugin to your native language, check our [Translation Quick Guide](docs/translations/README.md).

## 🧩 Compatibility

### KOReader versions

This plugin is compatible with KOReader across the following version range:

| Environment               | Supported Version                         |
| ------------------------- | ----------------------------------------- |
| **Oldest Tested Version** | KOReader `v2025.04` *"Full Moon"*         |
| **Newest Tested Version** | KOReader `v2026.03` *"SnowFlake"* & Newer |

This could work with even older versions, but not personally tested. If any issues with versions outside the previous range, open a github issue in this repo.

<table>
  <tr>
    <td width="50%" valign="top">
      <h3>File types formats supported</h3>
      <ul>
        <li><em>.cbr (digital comic book archive):</em> Usual standard format for western comics</li>
        <li><em>.cbz (Comic Book Zip Archive):</em> The standard for mangas, usually found in this format when downloading from internet or in (.cbr). I strongly recommend using <a href="https://github.com/manga-download/hakuneko">Hakuneko (Downloader)</a> and <a href="https://github.com/ciromattia/kcc">KCC (Kindle Comic Converter)</a> to adapt hakuneko downloads to .cbz for mangas. This is the top priority format I give support/compatibility with this plugin</li>
        <li><em>.pdf (Portable Document Format):</em> Another common format when downloading mangas/comics.</li>
        <li><em>.epub / .kepub / .mobi:</em> Panels+ automatically opens embedded raster images under a long press and detects panels inside them. This includes Kobo-synced <code>.kepub.epub</code> books and directly named <code>.kepub</code> files when KOReader opens them. Text remains handled by KOReader's normal reader.</li>
      </ul>
    </td>
    <td width="50%" valign="top">
      <h3>Kobo Compatibility (kobo.koplugin >= 0.4.1)</h3>
      <p>This plugin works well with:</p>
      <ul>
        <li>Physical buttons (Page-turning)</li>
        <li>Bluetooth devices with page-turning features</li>
      </ul>
      <p>Tested against 0.4.1 version thanks to users feedback.If any problems, create a github issue in this repo.</p>
    </td>
  </tr>
</table>

## 📦 Installation

### 🛍️ Package Managers

Panels+ is structured for installation via KOReader package and plugin managers:

| Package Manager                                                                                                    | Search / Package Name                                                                              | Installation Method                                                                                                                                                                                                                                                                                                                                                                           |
| ------------------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [**Plugin Appstore**](https://github.com/omer-faruq/appstore.koplugin) (`appstore.koplugin`)                       | [`Panels+`](https://omer-faruq.github.io/appstore.koplugin/?q=panels+plus) (`panelsplus.koplugin`) | Search and install directly inside the KOReader Plugin Appstore (or view on the [Appstore Web Catalog](https://omer-faruq.github.io/appstore.koplugin/?q=panels+plus))                                                                                                                                                                                                                        |
| [**ZEN Package Manager**](https://github.com/AnthonyGress/zen_ui.koplugin) (`zen_ui.koplugin` or `zenos.koplugin`) | (`panelsplus`)                                                                                     | Available directly in the ZEN package manager catalog.<br><br><div class="flex h-auto w-full flex-row gap-4"><img width="220" alt="zenpm_plugin_showcase" src="https://github.com/user-attachments/assets/334afd85-9260-446e-861e-c5d7d4bec515" /><img width="220" alt="search_zenpm_showcase" src="https://github.com/user-attachments/assets/218ac4b5-4c68-4806-a802-14db4e93e218" /></div> |

### 🛠️ Manual Installation

1. Download `panels_plus.koplugin.zip` from the [releases page](https://github.com/KristanLaimon/PanelsPlus/releases/latest) and unzip it.
2. You should now have this folder: `panelsplus.koplugin`

> [!NOTE]
> **GUI zip extractors note:** Some desktop GUI archive managers (such as GNOME Archive Manager, Ark, or Windows Explorer "Extract All") may create an extra parent folder level matching the zip filename (e.g. `panels_plus.koplugin/panelsplus.koplugin/`). Take this into account when extracting: make sure you copy the actual `panelsplus.koplugin` folder (the one directly containing `_meta.lua` and `main.lua`) into your KOReader `plugins/` directory.

3. Copy the **whole `panelsplus.koplugin` folder** into your KOReader `plugins` directory. (Do not copy only the files inside it).

Common plugin paths:

| Device / OS                      | KOReader plugins directory                                    |
| -------------------------------- | ------------------------------------------------------------- |
| Kindle                           | `/mnt/us/koreader/plugins/`                                   |
| Kobo                             | `.adds/koreader/plugins/`                                     |
| Android                          | `/sdcard/koreader/plugins/`                                   |
| Linux (Native / Arch / AppImage) | `~/.config/koreader/plugins/`                                 |
| Linux Flatpak                    | `~/.var/app/rocks.koreader.KOReader/config/koreader/plugins/` |

The final path should look like this:

```text
<koreader plugins directory>/panelsplus.koplugin
```

4. Restart KOReader after copying the folder.

## ⚙️ Configuration & Usage

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

### 🎬 Developer's Personal Tip: The Cinematic Experience

For a more fluent and immersive navigation, my personal recommendation is to set KOReader to **landscape (horizontal) rotation** and enable **strict-crop mode** in Panels+ with classic navigation for e-ink based devices and smooth navigation for android and non-e-ink devices. <br>
While playing and testing this pluging from months of usage I found this setup the most convenient way to experience your manga (and probably the way it was intended).

<div align="center">
  <video src="https://github.com/user-attachments/assets/ca4de34b-c9e4-4045-932a-8831cea1a2b4" controls width="420"></video>
  <br>
  <em> Here is a quick look at how it runs on an actual Kindle</em>
</div>
<br>
Of course if you prefer vertical, with margin, loose cropped or even animated, then use it that way!. I've made all this config fully customizable to make this plugin `adapt to you`, not you to the plugin. Your manga, your rules.

### 🔍 OCR Word Lookup Setup (Experimental)

Panels+ introduces experimental OCR support, allowing you to touch & hold text inside a zoomed-in panel to look up words in the dictionary—even in comics/manga! Works across `.CBZ`, `.CBR`, and `.PDF`.

For English lettering, try **Panels+ → Lightweight English OCR**, then open a
panel. This optional 3.92 MiB model is included and works offline through
KOReader's existing OCR engine. It applies only when the document OCR language
is English and is off by default. It improved the current manga dataset with
KOReader's desktop OCR library; accuracy and speed still need device testing.
See [OCR_REPORT.md](OCR_REPORT.md) for results and remaining limitations.

<strong>IMPORTANT:</strong> To use this feature, you'll need to set up a couple of things first:

<ul>
  <li><em>Install an OCR engine in KOReader by <a href="https://koreader.rocks/user_guide/#L2-ocr">following the official KOReader guide</a>.</em></li>
  <li><em>Install at least one dictionary. You can do this by <a href="https://www.youtube.com/watch?v=fthGMdpUfR0">following this tutorial for manual installation</a>, or by using KOReader's built-in online dictionary installer.</em></li>
</ul>

<em>(Note: Word detection is tricky on hand-lettered or stylized comic text and might not always get it exactly right. As a workaround, I recommend binding a comfortable multi-swipe gesture to "Open dictionary lookup" as a fallback!)</em>

## 🎯 Why This Exists

I'm a manga fan and I read a lot in my e-reader and found out some panels are too small to read comfortably on the full page, then I tried using ko-reader native zoom, but then I need to zoom out, change panel, zoom-in, read the panel, zoom-out, zoom-in, read, and so on... (ugh!).

KOReader can detect panels, but the native flow often means zooming into one panel, leaving zoom, moving to the next panel, and repeating that cycle.

I wanted to create `Panels+` so (we manga-comic readers) could have the panel navigation we deserve with a normal reading flow!.

This supports screenshots while zoomed into panels, so you can capture the exact panel view instead of only taking full-page screenshots, and use them as screen savers, book covers, anything you want.

---

## 🌐 For Translators (We Need Your Help!)

Starting from version **v1.4.0**, Panels+ includes localization support, and we'd love to translate the plugin into as many languages as possible!

Rather than relying on machine or AI translation slop, we are looking for community collaborators to help craft authentic, high-quality human translations.

If you're interested in contributing:

- Check out our [Translations Quick Guide](./docs/translations/README.md) to get started.

Currently there is only ***English*** and ***Spanish*** support.

---

## 🛠️ Pull Requests\Developer Setup

You would need the following to start developing in Panels+

1. [KOReader](https://github.com/koreader/koreader). Can be obvious, but needed. My recommendation is to set a WSL environment if windows, or directly use a linux distro.

2. [LuaJIT](https://luajit.org/install.html) or [Lua 5.1](https://www.lua.org/download.html). It's the main language of this plugin. So your PR code must run without errors in both of them (Compatibility with KOReader emmbeded lua runtime).

3. [uv](https://docs.astral.sh/uv/getting-started/installation/) (not python3). Is the python manager used in this repo and used for dataset tools extraction, also needed to run the tests with `./run-tests.sh`.

4. [Stylua](https://github.com/JohnnyMorganz/StyLua) (Codebase's Formatter). Used to have a consistent code style (indentation, tabs, etc...)

5. [Luacheck](https://github.com/mpeterv/luacheck) (Codebase's Linter). Used to have consistent code patterns (Which globals are available in intelissense, function declaration styles, etc...)

From the repository root, create the development environment and install the Python dependencies using the following command:

```bash
uv sync
```

With Lua, LuaJIT, StyLua, and Luacheck installed, run the full test suite through uv so `run-tests.sh` uses the synced Python environment with the following:

```bash
# Unix environment
./run-tests.sh
```

Now you're ready, now go to [CONTRIBUTING.md](CONTRIBUTING.md) for the rest of the contribution guidelines, project documentation, linting, building, guides, etc...

---

### 🏗️ Building From Source

Clone or download this repository, then run:

```bash
./build.sh
```

On Windows PowerShell, run:

```powershell
.\build.ps1
```

The script creates `dist/panels_plus.koplugin`. Copy that generated folder into your KOReader plugins directory, then restart KOReader.

---

## 🤝 Contributions

Project is actually stable, and personally tested in:

- Kindle 12th Gen

And thanks to users, works in:

- Kobo e-reader

Contributions are welcome for:

- Edge-cases bugs fixes
- Performance improvements
- Device-specific bugs fixes (this would help a lot)
- New features
- Datasets Mangas

Thanks for using the plugin or at least, taking a look into this repo.

---
## 📜 License

MIT License, check "LICENSE" file in this repository.

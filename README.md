<p align="center">
  <img width="99%" height="auto" alt="PanelsPlus_Cover" src="https://github.com/user-attachments/assets/16887793-0bd2-4712-9b1e-75d832152b55" />
  <br>
  <strong>Panels+</strong>
  <br>
  <span style="display:block;font-size:1.25rem;">Read manga and comics <strong>panel by panel</strong>, without losing the page and other panel zooming utilities with no setup required. Read them the way they were intended: <strong>Panel by Panel</strong></span>
  <br><br>
  <a href="https://github.com/KristanLaimon/PanelsPlus/releases/latest"><img src="https://img.shields.io/github/v/release/KristanLaimon/PanelsPlus?color=blue&style=flat-square" alt="Latest Release"></a>
  <a href="https://github.com/KristanLaimon/PanelsPlus/releases"><img src="https://flat.badgen.net/github/assets-dl/KristanLaimon/PanelsPlus/total?color=green&label=downloads" alt="Downloads"></a>
  <a href="https://koreader.rocks"><img src="https://img.shields.io/badge/KOReader-v2025.04%20--%20v2026.07.1%20%26%20Newer-006699?style=flat-square" alt="KOReader Compatibility"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-informational?style=flat-square" alt="MIT License"></a>
  <a href="https://github.com/KristanLaimon/PanelsPlus/stargazers"><img src="https://img.shields.io/github/stars/KristanLaimon/PanelsPlus.svg?style=flat-square&cacheSeconds=300" alt="GitHub Stars"></a>
  <a href="https://github.com/sponsors/KristanLaimon"><img src="https://img.shields.io/badge/Sponsor-GitHub%20Sponsors-ea4aaa?logo=github&style=flat-square" alt="Sponsor on GitHub"></a>
  <a href="https://github.com/AnthonyGress/zen_ui.koplugin"><img src="https://img.shields.io/badge/ZEN%20Package%20Manager-Available-purple?style=flat-square" alt="ZEN Package Manager"></a>
</p>

<table>
  <tr>
    <td align="center" width="49%">
      <video src="https://github.com/user-attachments/assets/25a1068f-4e4f-42cb-8dde-26466f53c21a" controls width="420"></video>
      <br>
      <sub>Core feature: Panel by panel reading. Battle-tested for performance on low-specs e-readers and old KOReader versions support. (From Koreader-2025 and newer). </sub>
    </td>
    <td align="center" width="49%">
      <video src="https://github.com/user-attachments/assets/4ee8e78c-77a4-4432-a6e3-f841912c864b" controls width="420"></video>
      <br>
      <sub>Comics showcase: Reading comic books panel by panel with custom panel flow and navigation.</sub>
    </td>
  </tr>
</table>

Panels+ is a KOReader plugin that improves manga and comic reading by replacing the default KOReader single-panel zoom flow with a custom direction-aware panel reader with in-live panel scanning. No complex pre-mangas-scanning setup required, install Panels+ and *it just works*.

### Features

- Includes 3 panel transition modes:
<table>
  <!-- Videos (mismo alto y centrados) -->
  <tr valign="middle">
    <td width="33%" align="center">
      <video height="180" src="https://github.com/user-attachments/assets/7200f3e1-74d8-4b24-bd64-c775600d35ed"></video>
    </td>
    <td width="33%" align="center">
      <video height="180" src="https://github.com/user-attachments/assets/895f3fec-1168-40ba-b477-84d9cecad3f8"></video>
    </td>
    <td width="33%" align="center">
      <video height="180" src="https://github.com/user-attachments/assets/54ce079c-176b-420e-acb6-d6f9738b6f70"></video>
    </td>
  </tr>





  <tr>
    <td align="center"><b>1. Animated mode</b></td>
    <td align="center"><b>2. Smooth mode</b></td>
    <td align="center"><b>3. Classic mode</b></td>
  </tr>

  <tr>
    <td align="center"><em>Swipe through your manga with fade-in/fade-out transitions. (Only available in e-ink devices).  You can swipe or tap on edges, configurable in "More Config" button, and rotate only the panel view or whole device from the same place. So you can read your panels even in landscape mode.</em></td>
    <td align="center"><em>Make the current zoom view to move smoothly between panels (Duration and FPS between panels customizable). (Works better in non-eink devices, like Android and Desktop)</em> <br></br> In the video i was using <- and -> arrow keys to move between panels ("A" and "D" keys also compatible!), In case you use a keyboard along your koreader.</td>
    <td align="center"><em>Move between panels with no transitions at all, simple...classic.</em></td>
  </tr>
</table>

- Zoom-friendly screenshot support while reading panels.
- Open panels with a long press or, if you prefer, a two-finger tap.
- Panels finding on dark-background pages.
- Animated panel transitions (or even page transitions, optional).
- Configurable reading order, progress, OCR language, navigation, and crop, transitions & more.
- Comics & Mangas support.
- Customizable and performant in low-end e-ink devices.
- Move between panels with swipes and/or taps on edges.
- And much more.

> Currently we're looking for translators. If you'd like to help us translate this plugin to your native language, check our [Translation Quick Guide](docs/translations/README.md).

## 🧩 Compatibility

<div align="center">
<img width="100%" height="auto" alt="image" src="https://github.com/user-attachments/assets/9a1643e5-1b29-40f8-8eea-2ce1950972b2" />
</div>


### KOReader versions

This plugin is compatible with KOReader across the following version range:

| Environment               | Supported Version                         |
| ------------------------- | ----------------------------------------- |
| **Oldest Tested Version** | KOReader `v2025.04` *"Full Moon"*         |
| **Newest Tested Version** | KOReader `v2026.07.1` *"Sailing Walrus"* & Newer |

This could work with even older versions, but not personally tested. If any issues with versions outside the previous range, open a github issue in this repo.

<table>
  <tr>
    <td width="50%" valign="top">
      <h3>File types formats supported</h3>
      <ul>
        <li><em>.cbr (digital comic book archive):</em> Usual standard format for western comics</li>
        <li><em>.cbz (Comic Book Zip Archive):</em> The standard for mangas, usually found in this format when downloading from internet or in (.cbr). I strongly recommend using <a href="https://github.com/manga-download/hakuneko">Hakuneko (Downloader)</a> and <a href="https://github.com/ciromattia/kcc">KCC (Kindle Comic Converter)</a> to adapt hakuneko downloads to .cbz for mangas. This is the top priority format I give support/compatibility with this plugin</li>
        <li><em>.pdf (Portable Document Format):</em> Another common format when downloading mangas/comics.</li>
        <li><em>.epub / .kepub / .mobi:</em> Recognizes embbeded images from these file-formats. Normal text remains handled by KOReader's normal reader.</li>
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

### Choose your edition

Both editions include the same panel-reading features. Choose **one**—do not install both, because KOReader treats them as the same plugin.

| Edition | Choose this if… | Plugin folder |
| --- | --- | --- |
| **Panels+ Vanilla** | You do not use OCR, or you need an OCR language other than English or Spanish. You can add Tesseract language data later. | `panelsplus.koplugin` |
| **Panels+ with bundled OCR models** | You want bundled OCR ready immediately for English or Spanish manga and comic text. | `panelsplus.koplugin` |

> **Recommendation:** Choose **Panels+ with bundled OCR models** if you read English or Spanish and want to use word lookup. Otherwise, choose **Panels+ Vanilla**.

### 🛍️ Package managers

Panels+ is structured for installation via KOReader package and plugin managers:

| Package Manager                                                                                                    | Search / Package Name                                                                              | Installation Method                                                                                                                                                                                                                                                                                                                                                                           |
| ------------------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [**Plugin Appstore**](https://github.com/omer-faruq/appstore.koplugin) (`appstore.koplugin`)                       | [`Panels+`](https://omer-faruq.github.io/appstore.koplugin/?q=panels+plus) (`panelsplus.koplugin`) | Search and install directly inside the KOReader Plugin Appstore (or view on the [Appstore Web Catalog](https://omer-faruq.github.io/appstore.koplugin/?q=panels+plus))                                                                                                                                                                                                                        |
| [**ZEN Package Manager**](https://github.com/AnthonyGress/zen_ui.koplugin) (`zen_ui.koplugin` or `zenos.koplugin`) | (`panelsplus`)                                                                                     | Available directly in the ZEN package manager catalog.<br><br><table><tr><td><img width="220" alt="zenpm_plugin_showcase" src="https://github.com/user-attachments/assets/334afd85-9260-446e-861e-c5d7d4bec515" /></td><td><img width="220" alt="search_zenpm_showcase" src="https://github.com/user-attachments/assets/218ac4b5-4c68-4806-a802-14db4e93e218" /></td></tr></table> |

> **Appstore:** installs the Vanilla edition only. To use the bundled OCR-model edition, download it from the releases page and install it manually. **ZEN Package Manager** lets you choose the edition to install.

### 🛠️ Manual Installation

1. Open the [latest release](https://github.com/KristanLaimon/PanelsPlus/releases/latest) and download **one** ZIP file:

   | If you chose… | Download | Extracted folder |
   | --- | --- | --- |
   | **Panels+ Vanilla** | `panels_plus.koplugin.zip` | `panelsplus.koplugin` |
   | **Panels+ with bundled OCR models** | `panelsplus_with_ocrmodels.koplugin.zip` | `panelsplus.koplugin` |

2. Extract the ZIP. You should have the folder shown in the last column above.

> [!NOTE]
> **GUI zip extractors note:** Some desktop GUI archive managers (such as GNOME Archive Manager, Ark, or Windows Explorer "Extract All") may create an extra parent folder level (for example, `panelsplus.koplugin/panelsplus.koplugin/`). Copy the actual `.koplugin` folder—the one directly containing `_meta.lua` and `main.lua`—into KOReader's `plugins/` directory.

3. Copy the **whole extracted `.koplugin` folder** into your KOReader `plugins` directory. Do not copy only the files inside it.

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
  <em>Panels+ running on a Kindle</em>
</div>
<br>
Of course if you prefer vertical, with margin, loose cropped or even animated, then use it that way!. I've made all this config fully customizable to make this plugin `adapt to you`, not you to the plugin. Your manga, your rules.

### 🔍 OCR Word Lookup Setup

Panels+ introduces OCR support, allowing you to touch & hold text inside a zoomed-in panel to look up words in the dictionary—even in comics/manga! Works across `.CBZ`, `.CBR`, `.PDF`, `.MOBI`, `.EPUB`,  `.KEPUB`.

***Phrase grouping is experimental*** and may miss unusual bubble layouts.

<strong>IMPORTANT:</strong> To use dictionary lookup, install a dictionary first:

<ul>
  <li><em>Install at least one dictionary. You can do this by <a href="https://www.youtube.com/watch?v=fthGMdpUfR0">following this tutorial for manual installation</a>, or by using KOReader's built-in online dictionary installer.</em></li>
</ul>

- **Panels+ Vanilla** (`panelsplus.koplugin`) includes no OCR language data. To use OCR, install the language files you need in KOReader's `data/tessdata` directory, then select that language in KOReader.
- **Panels+ with bundled OCR models** (`panelsplus_with_ocrmodels.koplugin.zip`) includes a fine-tuned English model and an unmodified Spanish model. English is selected by default for zoomed-panel word lookup.

Open **KOReader menu → Panels+ → OCR language** to select a bundled language or **Use KOReader's**, which uses KOReader's current OCR language. The active choice is marked **(Selected)** and applies only inside Panels+.

<em>(Note: Word detection is tricky on hand-lettered or stylized comic text and might not always get it exactly right, there are many variations of text and fonts across all mangas/comics... it's not 100% perfect, and never will be)</em>

## 🎯 Why This Exists

I'm a manga fan and I read a lot in my e-reader and found out some panels are too small to read comfortably on the full page, then I tried using ko-reader native zoom, but then I need to zoom out, change panel, zoom-in, read the panel, zoom-out, zoom-in, read, and so on... (ugh!).

KOReader can detect panels, but the native flow often means zooming into one panel, leaving zoom, moving to the next panel, and repeating that cycle.

I wanted to create `Panels+` so (we manga-comic readers) could have the panel navigation we deserve with a normal reading flow!.

This supports screenshots while zoomed into panels, so you can capture the exact panel view instead of only taking full-page screenshots, and use them as screen savers, book covers, anything you want.

---

## 🌐 For Translators

Panels+ includes localization support, and we'd love to translate the plugin into as many languages as possible!

Rather than relying on machine or AI translation slop, we are looking for community collaborators to help craft authentic, high-quality human translations.

If you're interested in contributing:

- Check out our [Translations Quick Guide](./docs/translations/README.md) to get started.

Currently supported languages are ***English***, ***Spanish***, and ***Simplified Chinese***.

---

## 🛠️ Pull Requests\Developer Setup

See [CONTRIBUTING.md](CONTRIBUTING.md) for development setup, testing instructions, project documentation, and contribution guidelines.

---

### 🏗️ Building From Source

You don't need to do any of the setup from [CONTRIBUTING.md](CONTRIBUTING.md), just clone or download this repository, then run:

```bash
./build.sh
```

On Windows PowerShell, run:

```powershell
.\build.ps1
```

The script creates both editions: Vanilla in `dist/panelsplus.koplugin` and bundled OCR models in `dist/with_ocrmodels/panelsplus.koplugin`. Copy **one** of these `panelsplus.koplugin` folders into your KOReader plugins directory, then restart KOReader.

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
## 📜 License (MIT)

Check "LICENSE" file in this repository.

---

<h3 align="center">Sponsors</h3>

![sponsors_tier_gold_actual](https://raw.githubusercontent.com/KristanLaimon/StaticStuff/refs/heads/main/sponsors.part1.png)

![sponsors_bakers_actual](https://raw.githubusercontent.com/KristanLaimon/StaticStuff/refs/heads/main/sponsors.part2.png)

![past_sponsors_not actual](https://raw.githubusercontent.com/KristanLaimon/StaticStuff/refs/heads/main/sponsors.past.png)


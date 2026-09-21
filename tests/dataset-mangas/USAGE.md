# Manga Panel Annotator & Private Dataset Guide

This guide explains how to use the Manga Panel Annotator desktop application to create your own ground-truth panel datasets by hand from real manga and comic books.

---

## Table of Contents
1. [Overview](#overview)
2. [Dataset Structure & DMCA Protection](#dataset-structure--dmca-protection)
3. [Supported Formats](#supported-formats)
4. [Launching the Annotator](#launching-the-annotator)
5. [Recent Projects Library (KOReader Style)](#recent-projects-library-koreader-style)
6. [Step-by-Step Workflow](#step-by-step-workflow)
7. [Keyboard & Mouse Controls](#keyboard--mouse-controls)
8. [Dataset Storage & Schema](#dataset-storage--schema)
9. [Running Benchmarks with Your Private Dataset](#running-benchmarks-with-your-private-dataset)
10. [Automated Tests](#automated-tests)

---

## Overview

Automated panel detectors can struggle with edge cases such as:
- Speech bubbles bridging across panel borders.
- Irregular, diagonal, or borderless panel layouts.
- Full-page splash panels misidentified as multiple pieces or missed entirely.
- Random ghost panels caused by background textures.

The **Manga Panel Annotator** allows you to search your system for comic and book archives, extract them into ordered page sequences, and hand-annotate panel bounding boxes with live progress tracking, book covers, and reading-order sequence numbers.

---

## Dataset Structure & DMCA Protection

Datasets are stored in:
```text
tests/dataset-mangas/dataset/<bookfriendlyname>/
├── 00.png             # Cover / Page 1 (git included)
├── 01.png             # Page 2         (git included)
├── 02.png             # Page 3         (git included)
├── 03.png             # Page 4+        (GIT-IGNORED)
├── ...
├── metadata.json      # Book type, progress & finished status
└── annotation.json    # Book panel annotations
```

> [!IMPORTANT]
> **DMCA Protection Rule**:
> To allow sharing annotations publicly while respecting copyright, the repository's `.gitignore` automatically **includes only the first 3 preview pages** (`00.png`, `01.png`, and `02.png`) so people know which volume/edition the dataset belongs to. All subsequent pages from `03.png` forward are **strictly gitignored**.

---

## Supported Formats

The annotator handles all popular comic and digital book formats:
- **Comic Archives**: `.cbz`, `.cbr` (unrar / bsdtar extraction)
- **E-Books & Documents**: `.pdf`, `.epub`, `.kepub.epub`, `.mobi` (PyMuPDF high-DPI rendering)
- **Image Collections**: Folders containing `.png`, `.jpg`, `.jpeg`, `.webp` images

---

## Launching the Annotator

From the repository root:

```bash
# General launcher (opens to Recent Projects library)
python3 tests/dataset-mangas/annotator.py

# Open a specific file directly
python3 tests/dataset-mangas/annotator.py /path/to/manga.cbz

# Or launch directly from tests/dataset-mangas/dataset/
python3 tests/dataset-mangas/dataset/app.py
```

---

## Recent Projects Library (KOReader Style)

When launched, the application presents the **📚 Recent Projects** tab:
- **Book Cards**: Shows each comic book in your dataset folder.
- **Cover Thumbnail**: Automatically renders `00.png` with book aspect ratio and shadow.
- **Progress Bar & Percentage**: Shows current annotation progress (e.g. `65% (13 of 20 pages annotated)`).
- **Status Badges**: Displays `[FINISHED]` in vibrant green or `[IN PROGRESS]` in orange.
- **Finished Shortcut**: Press **`Ctrl+M`** (or click the checkmark button) to toggle a book's finished state.
- **Quick Continue**: Click **▶ Continue** (or double-click the card) to immediately jump into annotation mode at your last read page.
- **Filter Bar**: Type in the search box to filter books by title.

---

## Step-by-Step Workflow

### 1. Open a File
- Click **File -> Open Comic File...** (or `Ctrl+O`) and choose your comic file (`.cbz`, `.cbr`, `.pdf`, `.epub`, etc.).
- Or click **File -> Open Image Folder...** if you have a folder of loose page images.

### 2. Verify Book Title & Output Folder
- In the right sidebar under **Dataset & Book**:
  - Check the **Book Title** field. It defaults to the file name stem (e.g. `naruto_ch01`). You can edit it if needed.
  - The **Output Folder** defaults to `tests/dataset-mangas/dataset-private`. Click **Change Output Folder...** if you want to store it elsewhere.

### 3. Navigate Pages
- Use **Next (D)** and **Prev (A)** or the left/right arrow keys to flip pages.
- Use the slider or number box at the bottom to jump to a specific page.

### 4. Annotate Panels
- **Draw Rectangles**: Click and drag with the left mouse button across each panel in the exact order you want them read.
- **Sequential Badges**: Each box displays its sequence number (`[1]`, `[2]`, `[3]`...).
- **Single-Page Illustration**: If the entire page is one splash image, press **`F`** (or click **Set Single-Page Illustration (F)**). It replaces the page's annotations with one box covering `(0, 0, width, height)`.
- **Already-Combined Double-Page Illustration**: If a two-page spread is stored as one wide image (not split across two reader pages), press **`S`**. It creates the same full-page box and saves `"illustration_type": "double_page"` for future spread-rotation support.
- **Legacy One-Frame Pages**: Existing annotations with one frame are treated as single-page illustrations automatically and are saved with `"illustration_type": "single_page"` on their next export.
- **Special Panels with Speech Bubbles**: You can draw boxes that encompass the artwork and speech bubbles without being constrained by grid lines.

### 5. Adjust, Fine-Tune & Reorder Panels
- **Undo / Redo**: Press **`Ctrl+Z`** to undo any panel placement, resize, or deletion. Press **`Ctrl+Y`** (or `Ctrl+Shift+Z`) to redo.
- **🎯 Precision Fine-Tuning & 4× Loupe**: When working on tight margins or corner pixels, check **🎯 Precision Fine-Tuning** (or press **`P`**).
  - **100% Cursor Alignment**: The rectangle and handles track the cursor directly with zero divergence or lag.
  - **🎯 4× Precision Loupe HUD**: While drawing or dragging handles, a floating 4× magnified HUD displays in the canvas corner with a central crosshair and native coordinates, letting you view individual manga border pixels clearly.
  - **Magnetic Edge Snapping**: Coordinates magnetically snap to page boundaries and neighboring panel edges within 8 pixels.
  - **Keyboard Arrow Nudging**: When a panel is selected, use **Arrow keys** to nudge by 1 pixel (or **`Shift + Arrow`** by 5 pixels). Hold **`Alt + Arrow`** to adjust width and height down to the exact pixel.
- **Resize**: Click any box to select it. Eight handles appear on the corners and edges; drag any handle to adjust down to the pixel.
- **Move**: Click and drag inside a selected box to reposition it.
- **Reorder**: If you drew panels out of order, select a panel in the sidebar list and click **▲ Move Up** or **▼ Move Down** to adjust its reading sequence.
- **Delete**: Select a panel and press `Delete` (or `Backspace`), or click **Delete (Del)**.
- **Clear**: Click **Clear Page** to remove all panels on the current page.

### 6. Save the Dataset & Mark Finished
- Click **💾 Save Dataset (Ctrl+S)**.
- The annotator will:
  1. Save individual pages (`00.png`, `01.png`, `02.png`...) and metadata inside `dataset/<bookfriendlyname>/`.
  2. Maintain `metadata.json` with progress % and status.
  3. Compile the master `annotation.json` compatible with PanelsPlus benchmarks.
- Press **`Ctrl+M`** when you've finished annotating all panels in the book to mark it as **`[FINISHED]`**.

---

## Keyboard & Mouse Controls

| Action | Control / Shortcut | Description |
|---|---|---|
| **Draw Panel** | `Left Click + Drag` | Draw bounding box in reading order (100% aligned with cursor) |
| **Undo** | `Ctrl + Z` | Undo last panel draw, resize, move, or delete |
| **Redo** | `Ctrl + Y` or `Ctrl + Shift + Z` | Redo previously undone action |
| **🎯 Precision Fine-Tuning** | `P` or toggle checkbox | Magnetic snap **outside black panel borders**, edge guidelines, & 4× Loupe HUD |
| **Disable Snap (Freeform)** | Hold `Alt` while dragging | Bypasses magnetic snapping to place or resize boxes with complete freedom |
| **Nudge Panel Position** | `Arrow Keys` (`Shift` = 5px) | Pixel-precise movement (1px step) |
| **Nudge Panel Dimensions** | `Alt + Arrow Keys` (`Shift` = 5px) | Pixel-precise width/height expansion or reduction |
| **Single-Page Illustration** | `F` | Replace annotations with one full-page illustration |
| **Double-Page Illustration** | `S` | Mark an already-combined wide spread for future rotation support |
| **Panel Rectangle Mode** | `1` | Draw and edit panel rectangles |
| **Phrase Rectangle Mode** | `2` | Draw phrase fragments; multiple fragments may share one phrase ID |
| **Word Rectangle Mode** | `3` | Draw word boxes and assign them to phrases by overlap |
| **Previous / Next Phrase ID** | `[` / `]` | Select an existing phrase ID or start the adjacent ID |
| **Select Panel** | `Left Click` | Select a panel to view handles and details |
| **Deselect** | `Right Click` or `Escape` | Clear selection or cancel active drag |
| **Resize Box** | Drag border handles | 8 handles (corners and edges) |
| **Move Box** | Drag inside selected box | Reposition the rectangle |
| **Delete Panel** | `Delete` or `Backspace` | Remove selected panel |
| **Mark Finished** | `Ctrl + M` | Toggle book status between `[IN PROGRESS]` and `[FINISHED]` |
| **Next Page** | `D` or `Right Arrow` | Go to next page |
| **Prev Page** | `A` or `Left Arrow` | Go to previous page |
| **Scroll Canvas (Y-Axis)** | `Mouse Wheel` (up/down) | Pan vertically up and down the page |
| **Zoom In / Out** | `Ctrl + Wheel` or `Ctrl +` / `Ctrl -` | Zoom centered on cursor (tracks live during drags) |
| **Fit Full Container Width**| `View -> Fit Width` | Scale page to 100% width of renderer container (default on open) |
| **Fit Window** | `View -> Fit Window` | Scale entire page height and width to fit window |
| **Zoom 100%** | `View -> Zoom 100%` | Reset to 1:1 pixel scale |
| **Pan Canvas** | `Middle Click + Drag` or `Space + Left Drag` | Move freely around zoomed page |
| **Save Dataset** | `Ctrl + S` | Export pages and save `annotation.json` |

---

## Dataset Storage & Schema

The output directory (default: `tests/dataset-mangas/dataset`) will contain:

```text
dataset/
├── <bookfriendlyname>/
│   ├── 00.png             # Cover / Page 1 (git-tracked)
│   ├── 01.png             # Page 2         (git-tracked)
│   ├── 02.png             # Page 3         (git-tracked)
│   ├── 03.png             # Page 4+        (git-ignored for DMCA protection)
│   ├── ...
│   ├── metadata.json      # Book type, progress % & finished status
│   └── annotation.json    # Book panel annotations (automatically scanned by PanelsPlus)
```

Every `metadata.json` must include a dataset `type`. Use `"manga"` for
top-to-bottom, right-to-left reading order, or `"comic"` for top-to-bottom,
left-to-right reading order:

```json
{
  "book_title": "my_book",
  "type": "manga",
  "annotation_schema_version": 2,
  "annotation_layers": ["panel", "phrase", "word"],
  "text_direction": "ltr"
}
```

Comic datasets can also carry `color_mode`: `"true_b/w"` for artwork created
in black and white, `"colorless_b/w"` for color artwork desaturated for reading,
or `"color"` for artwork that retains its color. This field is only valid for
`"type": "comic"`; it records provenance and does not select detector settings.
Scott Pilgrim uses `"colorless_b/w"`. Missing values in older comic metadata
remain unspecified. The import dialog asks for this value when importing comics.

### `annotation.json` Schema
The output uses PanelsPlus's `dataset_manifest.lua` format, plus optional illustration metadata:

```json
[
  {
    "book_title": "my_manga",
    "annotation_schema_version": 2,
    "pages": [
      {
        "page_index": 1,
        "image_paths": {
          "en": "my_manga/00.png"
        },
        "frame": [
          { "x": 50, "y": 60, "w": 400, "h": 300 },
          { "x": 50, "y": 380, "w": 400, "h": 500 }
        ],
        "phrase": [
          { "x": 80, "y": 90, "w": 180, "h": 32, "phrase_id": 1 },
          { "x": 80, "y": 126, "w": 150, "h": 32, "phrase_id": 1 }
        ],
        "word": [
          { "x": 82, "y": 92, "w": 45, "h": 28, "phrase_id": 1 },
          { "x": 132, "y": 92, "w": 54, "h": 28, "phrase_id": 1 }
        ]
      }
    ]
  }
]
```

Coordinates (`x`, `y`, `w`, `h`) are saved in the native pixel resolution of the page image.
`phrase_id` is local to a page. Any positive overlap assigns a word to a phrase; when
several phrases overlap a word, the largest intersection wins. Words are stored by phrase,
then top-to-bottom line and left-to-right position. Saving is blocked if a phrase has no
word or a word has no overlapping phrase. Older files containing only `frame` remain valid.
For a full-page illustration, `illustration_type` is either `"single_page"` or `"double_page"`.
The double-page value is only for a spread already stored as one wide image; split spreads remain out of scope. Missing metadata on a legacy one-frame page defaults to `"single_page"`.

---

## Running Benchmarks & Tests

PanelsPlus provides convenient root executable scripts to run benchmarks and test suites:

### 1. Running Benchmarks (`./run-benchmark.sh`)

```bash
# Benchmark default human-annotated dataset (Bloom_Into_You_Vol_8)
./run-benchmark.sh

# Benchmark all discovered manga datasets
./run-benchmark.sh --all

# Benchmark and auto-update bestbenchmark.json when accuracy improves
./run-benchmark.sh --update-best

# Benchmark a specific book
./run-benchmark.sh --book Bloom_Into_You_Vol_8

# Inspect a single page with full box coordinates & IoU breakdown
./run-benchmark.sh --book Bloom_Into_You_Vol_8 --page 1

# Only report pages with detection discrepancies (F1 < 1.0)
./run-benchmark.sh --failures-only
```

### 2. Regression Tracking with `bestbenchmark.json`

Each manga dataset directory (`tests/dataset-mangas/dataset/<manganame>/`) contains a `bestbenchmark.json` file recording the highest precision, recall, F1 score, and mean IoU ever achieved.

- **Regression Protection**: Tests in `<manganame>_spec.lua` enforce that results are **never worse** than `bestbenchmark.json`. If a refactor causes accuracy to drop, the test fails with a `REGRESSION` alert.
- **Record Updates**: Tests do not rewrite their baselines. Use `--update-best`
  explicitly after reviewing an improvement. Records for the reader's detector
  use `components_full_volume`, separate from the legacy segmenter's `full_volume`.
  Both `--all` and individual-book runs check the selected detector's records
  and exit unsuccessfully on regressions. Non-default IoU thresholds are not
  compared with or written into the default-threshold records.

### 3. Automated Test Suite (`./run-tests.sh`)

```bash
# Run everything: linters, Python annotator tests, and Lua test specs
./run-tests.sh

# Quick mode: run Lua test specs directly (skipping check.sh)
./run-tests.sh --quick

# Code style and linter checks only
./run-tests.sh --check-only

# Run a specific spec file
./run-tests.sh tests/dataset-mangas/dataset/Bloom_Into_You_Vol_8/bloom_into_you_spec.lua
```

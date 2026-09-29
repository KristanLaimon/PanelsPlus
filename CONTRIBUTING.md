# Contributing to Panels+


Thank you for your interest in contributing to Panels+! Whether you are fixing bugs, improving performance, or adding new features, your help is welcome!

# 🧰 Setup
Panels+ is the combination of 3 little proyects here in same repo:

1. Plugin itself (Lua)
2. Manga/commic annotator (Python)
3. OCR Testing (golang)

You would need the following to start developing a PR in Panels+:

### 1. Panels+: Plugin itself (Lua) (NEEDED)
In case you're messing only with Lua code and the plugin itself, this is far enough to install. (Not python or golang)
The following needs to be installed in your path/system:

1. [KOReader](https://github.com/koreader/koreader). Can be obvious, but needed. My recommendation is to set a WSL environment if windows, or directly use a linux distro.

2. [LuaJIT](https://luajit.org/install.html) or [Lua 5.1](https://www.lua.org/download.html). It's the main language of this plugin. So your PR code must run without errors in both of them (Compatibility with KOReader emmbeded lua runtime)

3. [Stylua](https://github.com/JohnnyMorganz/StyLua) (Codebase's Formatter). Used to have a consistent code style (indentation, tabs, etc...)

4. [Luacheck](https://github.com/mpeterv/luacheck) (Codebase's Linter). Used to have consistent code patterns (Which globals are available in intelissense, function declaration styles, etc...)

###  2. Panels+: Manga Annotator (Python/uv) (OPTIONAL but PREFFERED)
In case you're only interested in Panels+ Manga Annotator GUI app. It's made in python (is easier to make GUI apps here for this kind of purposes) but this repo uses `uv` instead of plain python3, for best practices.
The following needs to be installed in your system/path:

1. [uv](https://docs.astral.sh/uv/getting-started/installation/) (not python3). Is the python manager used in this repo and used for dataset tools extraction. Not essential for the plugin to work, used for the Panels+ internal manga annotator GUI app, to get datasets and improve the internal panel finding and OCR algorythm.

2. Datasets.... For obvious copyright reasons, full volume mangas can't be uploaded to this repo for easy share testing (also to avoid DMCA takedown of this repo). You would need to download them manually. I can't give you instructions about how to have locally your legal bought mangas. If only you [could know where to find them](./tests/dataset-mangas/dataset/mangas_datasets_reference.md) and [download them somehow](https://hakuneko.download/) , [package them in CBZ file](https://github.com/ciromattia/kcc), and import them from the Manga-annotator tool, maybe you would be able to create yourself your datasets or have the current tested datasets, but, who-knows.

From the repository root, create the development environment and install the Python dependencies using the following command:

```bash
uv sync
```

Then you can start the annotator tool with:

```bash
./start-manga-annotator.sh &
```

#### Some screenshots

<table>
  <tr>
    <td width="50%">
        <img width="auto" height="auto" alt="show-case manga annotator" src="https://github-production-user-asset-6210df.s3.amazonaws.com/114274872/660782069-27b3c9d8-7505-4936-bd77-0b4f24d0616c.png?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=AKIAVCODYLSA53PQK4ZA%2F20260929%2Fus-east-1%2Fs3%2Faws4_request&X-Amz-Date=20260929T004527Z&X-Amz-Expires=300&X-Amz-Signature=5bc1775df4e3f79d9511fd44e1e7fbf3c484f03d0e4c6033845b81ccea56fad1&X-Amz-SignedHeaders=host&response-content-type=image%2Fpng"></img>
    </td>
    <td width="50%">
        <img width="auto" height="auto" alt="show-case manga annotator-2" src="https://github-production-user-asset-6210df.s3.amazonaws.com/114274872/660785842-610597fe-8bc6-4ff7-9ede-179571023e04.png?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=AKIAVCODYLSA53PQK4ZA%2F20260929%2Fus-east-1%2Fs3%2Faws4_request&X-Amz-Date=20260929T005126Z&X-Amz-Expires=300&X-Amz-Signature=1ad382c7e472290a210e101075a2ef5502431e90d8d0892f8579fc5fc8b20db1&X-Amz-SignedHeaders=host&response-content-type=image%2Fpng"></img>
    </td>
  </tr>
  <tr>
    <td align="center">
        Main menu, with all the git commited datasets in this repo, and some progress bar as candy-eye feature.
    </td>
    <td align="center">
        Mapping panels, phrases and words, for internal algorythm training and testing. This is how v1.4.0 panels finding was improved! and soon in v1.5.0 OCR will be improved this way.
    </td>
  </tr>
</table>

### 3. Panels+: Panels & OCR Testing (OPTIONAL but PREFERRED)
If you used Manga annotator for OCR, then you will need to have installed golang in your system.
I'm taking advantage of golang's goroutines to make OCR tests run faster, because, due to their nature it would need
to scrapp all the .pngs pages from the datasets and look for each word and test it against whats expected (thanks to
the hand-made data from the Manga Annotator).

1. Install [golang compiler](https://go.dev/doc/install) in your system.

2. Install [ImageMagick CLI](https://github.com/imagemagick/imagemagick), is needed to run all PANELS and OCR
tests. Its a CLI tool, should be available in your path, and runnable from your terminal with `magick`.


---

### Testing
You only need at least the lua dependencies to start developing but you won't have the tooling for OCR and Panels testing.

Tests automatically check if you have python or golang dependencies, if not found it won't run them,
but if you want to run 100% of tests you need to have `uv`, `go`, `magick` installed in your path.

You can run the whole test with:

```bash
# ==============================================================================
# run-tests.sh - Test runner for PanelsPlus and manga dataset specifications
# ==============================================================================
# Usage:
#   ./run-tests.sh                  # Runs linters, Lua unit tests, and dataset specs
#   ./run-tests.sh --graceful       # Gracefully omits tests if compiler/tool/uv not synced (by default)
#   ./run-tests.sh --strict         # Run all tests but if compilers/tools/uv not found, throws error.
#   ./run-tests.sh --quick          # Runs Lua test suite directly (skips check.sh)
#   ./run-tests.sh --quicker        # Skips lint/style checks and dataset Lua tests
#   ./run-tests.sh --check-only     # Runs only code style and linter checks
#   ./run-tests.sh <spec-path>      # Runs a specific spec file
#   ./run-tests.sh --panels         # Runs panel tests only
#   ./run-tests.sh --ocr            # Runs OCR tests only
# ==============================================================================
```

```bash
# Unix environment
./run-tests.sh
```
---

### 📂 Documentation

- [Introduction](docs/INTRO.md) — a first read: what the plugin replaces, how a page turns into a panel sequence, and the module map.
- [Architecture](docs/ARCHITECTURE.md) — how the plugin is put together, and what happens between a long hold and a panel on screen.
- [Panel detection](docs/DETECTION.md) — how Deep mode turns pixels into panels, including heuristics, fallbacks, and tuning.
- [Deep mode](docs/MODES.md) — the single panel-detection mode and how it differs from reading, crop, and navigation modes.
- [Embedded EPUB/KEPUB/MOBI images](docs/EMBEDDED-IMAGES.md) — how panel reading works inside reflowable books, including the detector and smooth-navigation limits.
- [Word lookup](docs/WORD-LOOKUP.md) — touch-and-hold text selection, dictionary lookup, and the OCR debug review mode.
- [Performance](docs/PERFORMANCE.md) — what each step costs, the memory budget, and how to measure it on your own device.
- [Known Limitations](docs/KNOWN-LIMITATIONS.md) — current edge cases and known-behaviour (a todo-list to fix at the same time).
- [Testing](docs/TESTING.md) — running the dependency-free test suite.

### 🔗 Development & Reference Repositories

When developing on Panels+, it is recommended to clone the [`koreader`](https://github.com/koreader/koreader) base codebase and `kobo.koplugin` repository directly into your local project root folder:

```bash
git clone https://github.com/koreader/koreader.git
git clone https://github.com/koreader/kobo.koplugin.git
```

These folders are ignored via `.gitignore` and are not committed into this repository. Keeping them locally is purely for documentation and remaining KOReader internals aware during development; they are not involved in the plugin's final release code though.
Useful if you use AI agents, so they would have good-quality context for your PR!.

### 🧹 Linting & Formatting

This project enforces a standard code style to maintain consistency across developers. We use:

- **StyLua**: For automatic code formatting (`.stylua.toml`).
- **Luacheck**: For static analysis and linting (`.luacheckrc`).
- **lua_ls**: We also include a `.luarc.json` for developers using the Lua Language Server in their editors so that KOReader global variables are recognized properly.

If you don't have these tools integrated directly into your editor, you can run the provided check scripts to automatically format your code and run the linter:

> Note: In case you have golang dependencies, it will run gofmt as well for golang code!, useful isn't it?

**Linux/macOS:**

```bash
./check.sh
```

**Windows (PowerShell):**

```powershell
.\check.ps1
```

---

If you feel this documentation can be improved, go ahead and modify these docs, as long as it makes clearer the information and usage instructions, it's ok.

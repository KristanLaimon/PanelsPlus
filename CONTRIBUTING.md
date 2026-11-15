# 🤝 Contributing to Panels+

Thank you for your interest in contributing to Panels+! Whether you're fixing a
bug, improving panel detection, or making your own KOReader plugin work alongside
it, your help is welcome.

This repo has **three little projects** living together. You can work on one
without setting up everything else:

| Project | What you'll be working on | Needed? |
| --- | --- | --- |
| 📖 **Panels+ plugin** · Lua | Panel reading, gestures, settings, and plugin support | **Start here** |
| 🖍️ **Manga Annotator** · Python/uv | Mapping panels and words for our datasets | Optional |
| 🔎 **Panel & OCR testing** · Lua/Go | Checking detection and recognition against those mappings | For dataset/OCR work |

**Jump to:** [Setup](#-setup) · [KOReader launcher](#launching-and-testing-koreader-versions) ·
[Testing](#-testing) · [Reference repos](#-development--reference-repositories) ·
[Formatting & PRs](#-formatting--pull-requests) · [Documentation](#-documentation)

---

## 🧰 Setup

### First of all: a Linux environment

The development workflow below uses Linux tooling. A Linux distro, a VM, or WSL
will do. Windows also has PowerShell helpers for formatting and packaging, but
use a Linux environment for the shell scripts and desktop KOReader launcher.

You'll need to be comfortable with the terminal and Git. We're on GitHub at the
end of the day, so I'll assume you know your way around a branch and a PR.

```bash
git clone https://github.com/KristanLaimon/PanelsPlus.git
cd PanelsPlus
```

### 1. 📖 Panels+: the Lua plugin — REQUIRED

**Only changing the plugin? This is enough to get started.** You don't need the
Python annotator or Go OCR worker for a focused Lua test.

Have these available in your system/PATH:

1. **Lua** (`lua`) for the local tests, and **LuaJIT** for checks against
   KOReader's runtime. Production code needs to stay compatible with LuaJIT;
   passing on your desktop Lua alone doesn't tell us it works in the reader.
2. **StyLua** for formatting and **Luacheck** for linting. The repo includes
   their settings, so you don't need to invent a new code style.
3. **KOReader** for trying the actual behavior. The script below can install an
   isolated desktop release if you don't want to use your everyday setup.

> 💡 **A little test detail:** plain Lua uses a small FFI substitute in the test
> helper. LuaJIT can use real FFI arrays, closer to what KOReader runs. Both
> checks are useful, but they exercise different memory representations.

<a id="launching-and-testing-koreader-versions"></a>

### 🌓 KOReader: a little dev trick — OPTIONAL, but recommended

I've included a launcher so you can try different KOReader releases without
replacing the one you normally use:

```bash
./koreader.sh                         # your system KOReader
./koreader.sh menu                    # choose, install, or launch a release
./koreader.sh install 2025.04          # download once
./koreader.sh run 2025.04              # run with this checkout linked
./koreader.sh run 2025.04 /absolute/path/to/test.cbz
```

<details>
<summary><strong>Why 2025.04, you may ask?</strong></summary>

That's the version I installed on my first e-reader. As Panels+ grew, keeping it
working there also helped people who couldn't update their own installation.
An older reader shouldn't lose panel reading just because newer host APIs exist.
It's great when a plugin still works on your older setup, right?

I eventually had to update KOReader to use other plugins, but I still want to
keep that backward compatibility in Panels+. So I'd appreciate it if you check
your changes against **2025.04 as well as your current version**, especially
when touching KOReader APIs.

</details>

> **Your global KOReader stays separate.** Downloaded releases have their own
> runtime and profile, and the profile links directly to this checkout. Edit
> here, launch there; no need to copy the plugin after every change.

So you can try your changes on an older KOReader without messing with your
everyday installation. That's good, right?

```text
~/.config/koreader-_2025.04/
├── runtime/                         # downloaded KOReader
└── profile/                         # isolated KO_HOME
    └── plugins/panelsplus.koplugin   # symlink to this checkout
```

The launcher needs **Bash, curl, tar, and xz**; the desktop runtime needs **SDL2**.
Listing available releases also uses **Python 3** and internet access. It picks
an official Linux archive for x86_64, aarch64, or armv7l when the release provides
one. Set `KOREADER_INSTALL_ROOT` if you want a parent directory other than
`~/.config`.

If that profile already contains a different Panels+ copy, the launcher stops
so you can inspect it first. Other plugins aren't installed into these isolated
profiles automatically; add the ones you need for your live check.

### 2. 🖍️ Manga Annotator — OPTIONAL

Want to help improve panel detection or OCR? This is where the hand-mapped
panels and words come from. The annotator is a Python GUI, managed with **uv**:

```bash
uv sync
./start-manga-annotator.sh

# Or open a book directly
./start-manga-annotator.sh /path/to/book.cbz
```

You'll need **Python 3.9+** for the development environment. See the
[annotator README](tools/manga_annotator/README.md) and
[dataset guide](tests/dataset-mangas/USAGE.md) for the actual mapping workflow.

**About the books:** full volumes are local inputs. Use copies you have
permission to use; public fixtures only include part of the image corpus.
A fresh clone won't reproduce every full-volume benchmark, so mention missing
pages when reporting a run.

### Some demos about how it looks/works



https://github.com/user-attachments/assets/2d6805ba-07f0-4d4d-b470-d0eb41c657e0

<em>This is how Panels+ internal algorithm got tested. Manually mapping over 1500+ panels across many mangas</em>

<em>Manga-Annotator can create datasets of: <strong>Panels</strong>, <strong>Phrases</strong>, <strong>and words!</strong></em>



https://github.com/user-attachments/assets/13af8304-b0be-40ec-95f4-ca3d15ba76f1

<em>A normal Manga's panel dataset is created like this. (Me working, wuoooh so fun)</em>

***When pressing ctrl + s, datasets are saved in***
<table>
  <tr>
    <td align="center" valign="top" width="49%">
      <img src="https://github.com/user-attachments/assets/c0baf571-fc92-44b0-8ba3-1987b25243f7"></img>
      <br>
      <em>From Panels/, all datasets are stored in their corresponding folder.</em>
    </td>
    <td align="center" valign="top" width="49%">
      <img src="https://github.com/user-attachments/assets/78d0fb06-2d9b-4eb0-bcff-c2921ca03431" controls width="420"></img>
      <em>All annotations are stored in .json.</em>
    </td>
  </tr>
</table>

> Probably I need to separate this into another github repo and make it generic, it could be used for any generic dataset creation..... (nevermind)

### 3. 🔎 Panel & OCR testing — FOR DATASET/OCR WORK

Those mappings let us compare what Panels+ found against what should be there.
The Go OCR worker processes the image work concurrently, which helps when a
run has a whole volume's worth of words to check.

| Tool | Used for |
| --- | --- |
| **Go** | OCR worker and its tests |
| **ImageMagick** (`magick`) | Image decoding and dataset processing |
| **Tesseract / native libraries** | The OCR backend you're exercising |
| **Python 3.9+** | Parallel Lua scheduling; no annotator packages needed for the scheduler |

The [test-suite README](tests/README.md) explains the backend dependencies and
benchmark limits. You only need these tools when your change reaches that work.

---

## 🧪 Testing

Start with the test closest to your change, then run the wider checks before
sending a PR. All commands below run from the project root.

### A quick Lua check

```bash
lua tests/run_tests.lua tests/geometry_spec.lua
```

### The project runner

| Command | What it runs |
| --- | --- |
| `./run-tests.sh` | Formatting/lint, available Python and Go tests, Lua specs and datasets |
| `./run-tests.sh --quick` | Same tests, skipping formatting/lint |
| `./run-tests.sh --quicker` | Also skips dataset/benchmark Lua specs |
| `./run-tests.sh --quick -j 2` | Limits the Lua scheduler to two workers |
| `./run-tests.sh --strict` | Fails when required tooling/environment is missing |
| `./run-tests.sh --check-only` | Formatting and lint only |
| `./run-tests.sh --python` | Python/annotator tests |
| `./run-tests.sh --panels` | Panel specs and datasets |
| `./run-tests.sh --ocr` | OCR specs and datasets |

> 📝 **Check the skips, too.** Default graceful mode can omit unavailable tools
> or an unsynced Python environment. `--quick` and `--quicker` still run available
> Python and Go tests. Use the direct Lua command above for a Lua-only check.

For LuaJIT with native FFI arrays, without the dataset specs:

```bash
PANELSPLUS_LUA="luajit -l ffi" python3 tests/run_parallel.py --skip-datasets
```

Set `PANELSPLUS_REQUIRE_DATASETS=1` when missing dataset pages should fail.

### Adding or changing a test

- **Panels+ regression?** Add `tests/*_spec.lua`; discovery is automatic. Load
  the production module and use `tests/helper.lua` for KOReader fixtures.
- **Another plugin involved?** Use the separate versioned compatibility runner
  when the test loads that plugin's actual reference. The normal test command
  doesn't discover these suites. Follow the [compatibility guide](docs/PLUGIN-COMPATIBILITY.md).
- **Detection or OCR change?** Keep baseline history and report regressions.
  Lowering a target to get a green run hides the behavior we're trying to catch.

See [Testing](docs/TESTING.md) for test architecture and live checks, and the
[test-suite README](tests/README.md) for datasets and benchmark metrics.

---

## 🔗 Development & Reference Repositories

Need to look at KOReader internals or another plugin's API? The references now
live under **`references-repos/`**. KOReader and rolling plugin sources are Git
submodules; stable plugin releases are kept as exact version pins. These are
development inputs, separate from the Panels+ release package.

### Working on an existing plugin

Initialize just the recorded references you need. For Kobo work, for example:

```bash
git submodule update --init -- references-repos/koreader references-repos/plugins/kobo/rolling.koplugin
```

> **Keep the recorded version.** Leave out `--remote` during setup: moving to
> upstream HEAD changes what you're testing. Inspect existing submodule edits
> before initializing or updating anything. Ordinary Panels+ unit tests don't
> need these checkouts.

Then read these in order:

1. [Relationship index](references-repos/relationships.md): what support is
   declared and what has actually been tested.
2. The target's **`releases.md`**: where the stable pin came from.
3. Its **`history-changes.md`**: current work, results, limits, and where to resume.

### Developing another plugin? Start here

The [plugin compatibility guide](docs/PLUGIN-COMPATIBILITY.md) walks through
adding your reference, registering it in the tooling, and writing stable and
rolling tests. It also explains which checkout to edit and how to record the
results, so the next contributor doesn't have to reconstruct the whole story.

Using an AI agent? There's a project
[cross-plugin development skill](.agents/skills/panelsplus-crossplugin-dev/SKILL.md)
for that workflow as well.

---

## 🧹 Formatting & Pull Requests

### Formatting

The repo already carries the settings for **StyLua**, **Luacheck**, and
**lua_ls** in `.stylua.toml`, `.luacheckrc`, and `.luarc.json`.

**Linux:**

```bash
./check.sh
```

**Windows (PowerShell):**

```powershell
.\check.ps1
```

> If Go is installed, `check.sh` also runs **gofmt** for the Go code. Useful,
> isn't it? These scripts write formatting changes before linting, so have a
> look at the diff afterward.

Documentation contributions are welcome too. If a step was confusing while you
were following it, that's a good place to improve the guide.

---

## 📂 Documentation

| Guide | What's inside |
| --- | --- |
| [Introduction](docs/INTRO.md) | Entry points and module map |
| [Architecture](docs/ARCHITECTURE.md) | Controller, viewer, and lifecycle |
| [Panel detection](docs/DETECTION.md) | Heuristics, fallbacks, and tuning |
| [Detection modes](docs/MODES.md) | Detection and reading-mode choices |
| [Embedded images](docs/EMBEDDED-IMAGES.md) | EPUB/KEPUB/MOBI behavior |
| [Word lookup](docs/WORD-LOOKUP.md) | Selection, dictionary, and OCR review |
| [Performance](docs/PERFORMANCE.md) | Memory and measurement |
| [Known limitations](docs/KNOWN-LIMITATIONS.md) | Current edge cases |
| [Testing](docs/TESTING.md) | Automated and live validation |
| [Plugin compatibility](docs/PLUGIN-COMPATIBILITY.md) | References, versioned tests, and adding your plugin |

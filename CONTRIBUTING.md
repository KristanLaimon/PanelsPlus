# Contributing to Panels+

Thank you for your interest in contributing to Panels+! Whether you are fixing bugs, improving performance, or adding new features, your help is welcome.

---

## 🛠️ For Developers

### Documentation

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

### 🧹 Linting & Formatting

This project enforces a standard code style to maintain consistency across developers. We use:

- **StyLua**: For automatic code formatting (`.stylua.toml`).
- **Luacheck**: For static analysis and linting (`.luacheckrc`).
- **lua_ls**: We also include a `.luarc.json` for developers using the Lua Language Server in their editors so that KOReader global variables are recognized properly.

If you don't have these tools integrated directly into your editor, you can run the provided check scripts to automatically format your code and run the linter:

**Linux/macOS:**

```bash
./check.sh
```

**Windows (PowerShell):**

```powershell
.\check.ps1
```


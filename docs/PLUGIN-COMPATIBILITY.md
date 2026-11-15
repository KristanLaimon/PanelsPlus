# 🔌 Plugin Compatibility & Reference Repositories

Developing another KOReader plugin? This is where you set it up to work with
Panels+. You can also use this guide to update an existing compatibility test
without having to figure out the reference layout from scratch.

Start with the behavior you want: **running together**, **routing an existing
action**, or **sharing a new API**. Each needs different code and evidence.

Panels+ owns panel reading. Prefer connecting to another plugin's feature over
copying its implementation. A plugin being present in this tree means we have
a reference; the recorded tests establish what actually works.

**Jump to:** [References](#-find-the-references) · [Working copies](#-keep-release-evidence-reproducible) ·
[Existing tests](#-change-an-existing-compatibility-suite) · [Your plugin](#-add-compatibility-for-your-plugin) ·
[Evidence](#-record-what-was-established) · [Live checks](#-build-and-live-validation)

---

## 📂 Find the references

Read [relationships.md](../references-repos/relationships.md) first, then the
selected plugin's `releases.md` and `history-changes.md`. The first records
release provenance; the second records investigation, changes, test results,
and the current handoff. Verify its dated summary against the actual checkout.

```text
references-repos/
├── koreader/                         # host source submodule
├── relationships.md                 # relationship/evidence index
├── LICENSES.md                      # shared attribution
└── plugins/<plugin>/
    ├── rolling.koplugin/             # canonical development submodule
    ├── stable/v1_2_3/                # unchanged release payload
    ├── releases.md                   # release URLs, checksums, provenance
    └── history-changes.md            # cumulative history across versions
```

Canonical plugin identifiers are `kobo`, `meguru`, `ink-away`, and `livelight`.
Panels+ uses this project root, with tooling identifier `panels_plus`; it has no
reference snapshot under `plugins/`. KOReader is the host, rather than a row
in the plugin relationship matrix. LiveLight's rolling runtime is nested inside
`rolling.koplugin/livelight.koplugin/`; the tooling handles that layout.

Stable payloads are tracked in this repository. Rolling sources and KOReader
are submodules declared in [`.gitmodules`](../.gitmodules). To initialize an
existing reference at the recorded commit, run from the project root:

```bash
git submodule update --init -- references-repos/koreader references-repos/plugins/meguru/rolling.koplugin
git submodule status -- references-repos/koreader references-repos/plugins/meguru/rolling.koplugin
```

Select only the references you need. Do not clone extra repositories into the
project root or use a sync as test setup. If a stable pin is missing, resolve
that with the maintainer before treating rolling as a substitute.

---

## 🧭 Keep release evidence reproducible

> **Stable means unchanged.** Keep the release payload intact so another
> contributor can reproduce the same check.

Develop Panels+ in this project and counterpart changes in its canonical
`rolling.koplugin/`, on a local feature branch at its
existing HEAD. Before editing a target, inspect its state:

```bash
git -C references-repos/plugins/meguru/rolling.koplugin rev-parse HEAD
git -C references-repos/plugins/meguru/rolling.koplugin branch --show-current
git -C references-repos/plugins/meguru/rolling.koplugin status --short
git -C references-repos/plugins/meguru/rolling.koplugin diff
git -C references-repos/plugins/meguru/rolling.koplugin diff --cached
```

Preserve existing work and record the base SHA, branch, and local changes.
Reuse the task's feature branch or create one at that HEAD before target edits.
Do not move to another commit merely to start work. Former worktrees and
`laboratory/` copies are historical experiments; normal development and tests
use the canonical checkout. Keep the working diff for review instead of
generating integration patch archives.

A local rolling checkout can be older than upstream or contain uncommitted
changes. Record that state separately from its metadata version. When a
maintainer explicitly requests an upstream refresh, the helper supports scoped
selectors:

```bash
./run-sync-submodules.sh --meguru
```

This follows the configured upstream branch and **stages the selected submodule
pointer** in Panels+. It does not commit. With no selector it updates all
references, including documentation submodules. Inspect branches, local edits,
and staging before using it; review the resulting diff afterward. A later
merge/rebase or publication is a separate decision.

---

## 🧪 Change an existing compatibility suite

Ordinary mocked Panels+ tests belong in `tests/*_spec.lua`. For example,
`panelviewer_kobo_bluetooth_spec.lua` supplies representative actions without
loading Kobo, so it remains a unit test. It is useful regression coverage but
does not establish compatibility with a Kobo release.

Reference-backed specs belong in these directories:

```text
tests/plugin-compatibility/<plugin>__v1_2_3/*_spec.lua
tests/plugin-compatibility/<plugin>__rollingrelease/*_spec.lua
```

Version directory names use underscores. CLI versions may be dotted. Keep each
stable suite tied to its exact release, plus one rolling suite per plugin.
Shared assertions can live in `tests/compatibility_support/` when they apply to
multiple references; each wrapper must still exercise its selected reference.
Do not relabel an old suite as coverage for a new release.

Run the corresponding stable suite first, then rolling. For Meguru 1.8.7:

```bash
./run-tests.sh --compatibility-plugin=meguru --compatibility-plugin-version=1.8.7
./run-tests.sh --compatibility-plugin=meguru --compatibility-plugin-version=rollingrelease
./run-tests.sh --compatibility-plugin=meguru
```

**Want to run every retained version?** The last command selects all existing
stable suites in version order, then rolling. It stops on a failure; run rolling
separately if an earlier stable failure prevented it from running. Missing or
empty requested suites are errors.
Compatibility selection runs separately from the normal test/lint workflow and
cannot be combined with positional spec paths or other suite selectors.

### What your spec receives

Each suite runs in a separate Lua process, loads `tests.helper`, and executes
its specs with `loadfile`. The selector exports:

| Environment variable | Value |
| --- | --- |
| `PANELSPLUS_COMPATIBILITY_PLUGIN` | Canonical plugin identifier |
| `PANELSPLUS_COMPATIBILITY_VERSION` | Dotted stable version or `rollingrelease` |
| `PANELSPLUS_COMPATIBILITY_REFERENCE` | Absolute path to the selected runtime source |
| `PANELSPLUS_COMPATIBILITY_COMMIT` | Rolling HEAD SHA; empty for stable |

### What to exercise

Read the reference from the environment and load the actual counterpart code
or action definitions. Use KOReader fixtures where needed, and explain their
limits. Assert meaningful behavior rather than just metadata or file presence.
Cover absence/disabled behavior, readiness/load order, and cleanup where the
interaction depends on them. Existing suites include feature integration;
new coexistence coverage should stay within that scope unless the contribution
also proposes an interaction.

An explicitly selected historical comparison may use
`--compatibility-reference=/absolute/path` alongside the plugin and exact
version selectors. Record that override in the result. A pass against a modified
copy is evidence for that copy, not upstream stable. Normal rolling tests need
no override.

Pinned stable results determine supported-release completion. Still run and
report rolling: a rolling-only failure is an upcoming issue, with its own
result. Keep failing exit statuses and describe which reference failed.

---

## 🛠️ Add compatibility for your plugin

Here's the path from an unlisted plugin to a contribution someone else can
review and reproduce. Work through the parts your integration needs.

### 1. Agree on the behavior

Describe the pair, requested behavior, and ownership in the contribution.
Identify which plugin needs to know about the other and whether that support
appears in the UI. Discuss an unlisted plugin and the intended relationship
with the maintainer before implementation. If both projects need changes,
make that dependency clear.

### 2. Bring in the references

Choose a canonical directory identifier. Add the rolling repository as a
submodule at `references-repos/plugins/<plugin>/rolling.koplugin/` and retain
an exact upstream stable release under `stable/vX_Y_Z/`. Record release and
artifact URLs, checksum verification, metadata identity, and license notices
in `releases.md` and the attribution index. Preserve the release payload.
If metadata lacks a version, provide explicit provenance/checksum validation;
do not invent an upstream version field.

### 3. Start the history

Create `history-changes.md` before dependent investigation. Keep a current
summary at the top and dated, versioned entries below. Add the proposed
relationship to the index with untested behavior marked unknown.

### 4. Register the tooling

Register the identifier/aliases in `tools/plugin-compatibility/common.sh`.
Adjust `plugin_rolling_source` for a nested runtime and `plugin_folder` if
the installed name differs. Add a runtime file list in `build.sh` and a
`builders/<plugin>.sh` helper accepting `SOURCE EMPTY_OUTPUT`. Follow the
upstream release recipe and preserve required assets/licenses. The current
tooling has an explicit plugin registry: creating directories alone will
still produce an unknown-plugin error.

### 5. Add versioned tests

Add stable and rolling `*_spec.lua` suites in the layout above. The current
stable selector expects `main.lua` and matching `_meta.lua` version metadata,
with a specific checksum exception for LiveLight. An unusual release layout
needs a corresponding validated selector change. Deployment also requires
version metadata; passing reference tests does not imply installer support.

### 6. Connect the behavior

Implement the agreed behavior at the appropriate boundary. Panels+ adapters
live in `src/plugins-support/` and expose `attach(class)`; wire a new adapter
into the owning viewer/controller and keep state per reader. Loading it must
tolerate the other plugin being absent. See [the adapter guide](../src/plugins-support/README.md).

### 7. Check it and leave a handoff

Run stable, rolling, related Panels+ regressions, and relevant counterpart
tests. Validate in KOReader and on the target device for input/rendering
behavior. Update the relationship and history with the actual evidence,
pending checks, and any companion PR needed in the other project.

### Keeping stable references manageable

Retain at most **five stable releases per target**, each with its exact suite.
When a requested stable refresh adds a sixth, retire the oldest by version,
its suite, and pin-specific checksum/provenance sidecars. Keep shared fixtures
used by retained suites, rolling sources, and historical outcomes. Update active
release/license/relationship indexes and record the retirement in the history.

---

## 📝 Record what was established

Use these relationship terms consistently:

| Term | Meaning |
| --- | --- |
| Minimal | Observed coexistence in the exercised scenarios |
| OneWay Knowledge (`A → B`) | A knows about/supports B |
| BothWays Knowledge (`A ↔ B`) | Each plugin knows about/supports the other |
| Visual / Not visual | Whether that awareness appears in the UI; record each direction if different |
| No relationship | An established finding of no relevant interaction for the recorded scope |
| Unknown Behavior Relationship | Coexistence or interaction has not been established |

Arrows describe awareness, not edit permissions. A declared range such as
`>= 1.3.0` expresses intent; an exact tested tuple identifies the versions/SHAs,
host, environment, scenario, and result actually verified.

In each history entry, explain the problem, which plugin owns the change, and
the resulting behavior. Include source/target metadata versions, stable
provenance or full rolling base SHAs, branches, working/staged changes, commands
and working directory, results, real modules versus fixtures, failures that
changed the approach, and skipped/live checks. Keep build, installation, and
backup paths if used. Update the current summary so another contributor can
resume without chat history. The
[history standard](../.agents/skills/panelsplus-crossplugin-dev/references/history-changes.md)
provides the full handoff format.

---

## 📦 Build and live validation

`tools/plugin-compatibility/deploy.sh` previews by default. For example:

```bash
./tools/plugin-compatibility/deploy.sh --plugin=meguru --mode=rolling
./tools/plugin-compatibility/deploy.sh --plugin=meguru --mode=rolling --build-only
./tools/plugin-compatibility/deploy.sh --plugin=meguru --mode=rolling --install
```

Use the canonical rolling source. Generated artifacts live under
`.cache/plugin-compatibility/builds/`; they are separate from references.
In this project's agent workflow, a rolling build request includes installation
unless the request is explicitly for an artifact only; the CLI itself still
defaults to a preview.

Close KOReader before installation. The installer requires this project to sit
directly in a recognized KOReader `plugins/` directory, rejects ambiguous or
locally changed installed copies, and moves recognized old copies to
`KOReader/.panelsplus-plugin-backups/<transaction>/`. Inspect conflicts rather
than bypassing those checks. Never install a second Panels+ beside a live
development copy. Stable/historical experiment deployment needs its own agreed
scope. See [deployment details](../.agents/skills/panelsplus-crossplugin-dev/references/workflow-details.md)
for the full plan/build/install behavior.

> 📝 **Still needs a real reader check.** Automated fixtures don't establish
> physical input, framebuffer rendering, native-library suitability, or device
> memory behavior. Record live validation separately, even when it is pending.

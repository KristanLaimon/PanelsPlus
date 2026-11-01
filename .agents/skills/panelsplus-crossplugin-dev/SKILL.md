---
name: panelsplus-crossplugin-dev
description: Develop and test Panels+ compatibility or integration with other KOReader plugins, using pinned stable references before rolling sources and limiting changes to the appropriate plugin.
---

# Panels+ cross-plugin development

At the start of each session using this skill, read `references-repos/relationships.md` first, relative to the Panels+ project root. Then read the selected plugin's `references-repos/plugins/<plugin>/releases.md` and the relevant pinned sources. Do not infer compatibility from a plugin's presence alone.

Panels+ owns panel-related features. Prefer integration with existing plugins over duplicating their functionality or copying their implementation. KOReader is the host source, not a plugin or a relationship-matrix entry.

## Nomenclature

| Term | Meaning |
| --- | --- |
| Minimal | Coexistence without conflicts or KOReader crashes; no integration or plugin awareness is implied. |
| OneWay Knowledge | A knows about/supports B; B need not know about A. Write `A → B`. |
| BothWays Knowledge | Each plugin knows about/supports the other. Write `A ↔ B`. |
| Not visual | Awareness/support has no UI cue. |
| Visual | Awareness/support appears in the UI; it may offer related settings or options. |
| No relationship | The developer has established no relevant interaction for the recorded versions and scope. This is a positive finding, not a missing test. |
| Unknown Behavior Relationship | Coexistence or interaction has not been established; test the pair before classifying it. Often concerns two plugins other than Panels+. |
| Source Plugin | Plugin being modified for the task; its authorized working copy is writable. Usually Panels+. |
| Target Plugin | Plugin the source is being made compatible with; its reference sources are read-only. Relationship arrows do not identify edit permissions. |
| Stable Release | Upstream release artifact retained locally under an exact version pin; the local pin is not automatically today's latest upstream release. |
| Git Rolling Release | Local checkout of upstream development source, identified by commit SHA and dirty state. A submodule is pinned until explicitly updated; do not silently fetch/update it. |
| Laboratory modified stable | Writable copy of a pinned stable target under the plugin's `laboratory/<version>/<experiment>/`; the original remains untouched. |
| Build artifact | Installable output in `.cache/plugin-compatibility/builds/`, separate from source and pinned references. |
| Declared range | Developer's intended compatibility range, such as `>= 1.3.0`; it is not proof for every future release. |
| Tested tuple | Exact source/target versions or SHAs, KOReader version, environment, scenario and result actually verified. |
| Coexistence test | Checks that the selected plugin pair can operate together without conflicts or crashes in the exercised scenarios; does not establish feature integration. |
| Integration test | Exercises an actual interaction between the selected plugins, such as counterpart-defined actions reaching Panels+ handlers. |

Visual/Not visual qualifies knowledge relationships. For BothWays, record visibility per direction if asymmetric. Minimal and No relationship differ: Minimal records observed coexistence; No relationship additionally asserts no relevant interaction in a stated scope. Do not collapse Unknown into either.

## Start and classify

1. Identify the requested behavior, pair, source and target, desired relationship and visibility. Ask the user about an unlisted plugin or unclear relationship before integration work. If source/target is unclear, explain those terms and ask which is writable.
2. Look for the target's exact stable pin in `references-repos/plugins/<plugin>/stable/`. If missing, report what is absent and stop dependent integration work until the user supplies or authorizes establishing the pin. Do not substitute rolling source silently.
3. Describe material edge cases or flaws in the proposed design and ask focused questions where answers change behavior. Continue independent investigation while awaiting answers; do not treat silence as approval.

## Change priority

1. Inspect the relevant Panels+ source first. Prefer fulfilling the request using only Panels+ changes.
2. If that cannot fulfill the behavior, explain the limitation and copy the exact target stable pin to `references-repos/plugins/<plugin>/laboratory/v<underscored-version>/<experiment>/`. Modify only this named laboratory experiment. Record its base pin and patch; never edit the original stable reference.
3. If minimal stable-target changes are insufficient, explain why, create a local branch in an isolated target worktree, then make the smallest rolling-target change. Keep the reference submodule unchanged. Build that worktree with the corresponding build helper.

At steps 2–3, changes to Panels+ plus the target are allowed when necessary. Prefer changing one side; modifying both is the last resort. Source-only/target-only here describes the changed code, not knowledge direction. The target becomes writable only in the designated experimental copy/worktree, within the requested task. Do not publish upstream changes without authorization.

## Paths and version conventions

Use underscores in all version-bearing directory names: `v1_7_1`, never `v1.7.1`. Test suite directories retain their plugin prefix, e.g. `meguru__v1_7_1`. CLI versions may be dotted (`1.7.1`) and are normalized for lookup.

- Stable pins: `references-repos/plugins/<plugin>/stable/v1_7_1/`.
- Rolling references: `references-repos/plugins/<plugin>/rolling.koplugin/`; Panels+ rolling source is this project itself. KOReader source is `references-repos/koreader/`.
- Experimental stable copies: `references-repos/plugins/<plugin>/laboratory/v1_7_1/<experiment>/`.
- Generated builds: `.cache/plugin-compatibility/builds/<plugin>/v1_7_1/<build-id>/<plugin>.koplugin/` (ignored).
- Stable tests: `tests/plugin-compatibility/<plugin>__v1_7_1/**/*_spec.lua`; multiple pins may coexist.
- Rolling tests: `tests/plugin-compatibility/<plugin>__rollingrelease/**/*_spec.lua`; one rolling suite per plugin.
- Plugin-specific Bash build helpers: `tools/plugin-compatibility/builders/<plugin>.sh`; shared tooling lives beside `deploy.sh` in `tools/plugin-compatibility/`.
- Release links and provenance: `references-repos/plugins/<plugin>/releases.md`. Shared attribution: `references-repos/LICENSES.md`.
- Panels+ uses the project root as its source and has no folder under `references-repos/plugins/`; those folders are for other plugins. Do not recreate a Panels+ reference snapshot as part of ordinary cross-plugin work. Laboratory copies and generated builds are ignored; installation backups remain outside `plugins/`.

Canonical directory identifiers: `panels_plus`, `kobo`, `meguru`, `ink-away`. Panels, Panels+, PanelsPlus and panelsplus refer to Panels+ here. Ink Away's metadata identifier is `inkaway`; do not derive its directory identifier from that spelling.

## Sync rolling submodules

Use the project-root `run-sync-submodules.sh` when the user requests updating rolling plugin sources or KOReader. With no flags it updates all reference submodules; select one or more with `--kobo`, `--meguru`, `--ink-away`, or `--koreader`. For example, `./run-sync-submodules.sh --meguru --koreader` updates only those two. `--help` lists available selectors.

The script initializes missing submodules and follows each configured remote branch, or remote HEAD when no branch is configured. Nested dependencies stay pinned. It reports commit and file/line changes and stages the selected submodule pointers; review `git diff --cached` before committing. It does not commit automatically. Failures stop the sync and preserve any earlier completed updates. Stable snapshots and laboratory experiments are not refreshed by this tool. Do not run a sync merely to inspect or test the currently pinned rolling version.

## Verify and record

Current scope: new suites under `tests/plugin-compatibility/` are coexistence tests. Add feature-integration coverage only when requested; existing Panels+ unit/regression tests remain in `tests/`. In particular, `tests/panelviewer_kobo_bluetooth_spec.lua` uses mocked KOReader APIs and hard-coded input/actions without loading `kobo.koplugin`, so it stays a unit suite and is not version-pinned Kobo compatibility evidence. A future test using the actual selected Kobo reference belongs in its versioned compatibility suite and must identify whether it tests coexistence or an integration.

Test the corresponding pinned stable release first, then rolling source. Read the actual counterpart's code/API in each suite; a mock-only assertion does not establish cross-plugin compatibility. Include absence/disabled-plugin behavior, load order, lifecycle cleanup and the requested interaction where relevant. Do not change runtime behavior solely to satisfy an invented compatibility scenario.

Pinned stable results determine completion. Still run and report rolling results: a rolling-only failure is a separate upcoming compatibility issue and does not block completion when the stable behavior passes. The test command retains a nonzero exit status for any failed selected suite; distinguish which suite failed in the report instead of suppressing failures.

Run `./run-tests.sh --compatibility-plugin=<plugin> --compatibility-plugin-version=1.7.1`, then the same command with `rollingrelease`. Omitting the version runs all existing stable suites first and rolling last. A missing requested suite is an error. Each suite runs separately to prevent module/mock state leaking between pins. Read `references/workflow-details.md` for suite context and deployment commands.

Update the relationship matrix with direction, visibility, version range and evidence. Record exact tested tuples separately; distinguish upstream stable, laboratory patches and rolling SHAs. Unit tests do not replace the developer's live KOReader validation. Preserve uncertainty and report remaining live checks.

Use `tools/plugin-compatibility/deploy.sh` for build/install planning. Select a named laboratory experiment with `--experiment=<name>`. Preview by default; `--install` changes live plugins only when that installation is authorized. Back up outside the plugins directory and stop on local changes or ambiguous identities. Never remove the working project or reference checkout. Do not install a second Panels+ beside this live development copy.

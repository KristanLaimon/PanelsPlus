---
name: panelsplus-crossplugin-dev
description: Develop and test Panels+ compatibility or integration with other KOReader plugins, using pinned stable references before rolling sources, limiting changes to the appropriate plugin, and keeping versioned per-plugin history for session handoff.
---

# Panels+ cross-plugin development

At the start of each session using this skill, read `references-repos/relationships.md` first, relative to the Panels+ project root. Then read the selected plugin's `references-repos/plugins/<plugin>/releases.md` and **`history-changes.md`** before investigating or editing its sources. Use the history's current-state summary to resume after a cleared chat; verify its repository/build state before acting. If the history does not exist, create it as described below. Do not infer compatibility from a plugin's presence alone.

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
| Target Plugin | Plugin the source is being made compatible with; stable pins are read-only, while its canonical rolling checkout is the working source when target changes are required. Relationship arrows do not identify edit permissions. |
| Stable Release | Upstream release artifact retained locally under an exact version pin; the local pin is not automatically today's latest upstream release. |
| Git Rolling Release | Local checkout at its existing commit SHA, identified by local branch and dirty state. Develop directly here on a separate local branch; never fetch/update/rebase it without an explicit request. |
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

## Working copy and Git policy

Target-plugin development always uses
`references-repos/plugins/<plugin>/rolling.koplugin/`, on a separate **local
feature branch**. Panels+ itself remains this project. Before editing, inspect
HEAD, branch, working changes and staging; preserve them and record the base SHA.
Create a new branch at the current HEAD when needed, or reuse the task's existing
feature branch. Do not move to another commit just to begin work.

- Keep changes uncommitted. Do not stage, commit, push, reset or discard existing
  work unless the user explicitly requests that action.
- Do not fetch, pull, sync submodules, merge or rebase as session setup. Remote
  commits stay out of the task until the user explicitly requests integrating
  them. Passing tests is not permission to perform a later rebase.
- Edit the canonical rolling checkout directly. Do not create new target
  worktrees, laboratory copies or retained Git patch files as the normal workflow.
  Use the working diff and per-plugin history for review and handoff.
- Keep existing stable pins unchanged. Retain former worktrees as frozen source
  backups; do not resume development there. Record historical patch filenames,
  hashes, base revisions and evidence in the plugin history instead of keeping
  generated integration patch archives. Update file links when removing obsolete
  artifacts. Directories named `patches/` inside a plugin can contain shipped
  runtime code; do not confuse those with generated Git `.patch` archives.
- Tests and builds use the canonical rolling source. Historical clean-rolling
  results do not describe a checkout that now contains local changes.

## Change priority

1. Inspect the relevant Panels+ source first. Prefer fulfilling the request using
   only Panels+ changes when that matches the requested responsibility boundary.
2. When target changes are needed, explain the limitation and make the smallest
   appropriate change in its canonical `rolling.koplugin/`, on the task's local
   feature branch at the existing base. Preserve all prior local work.
3. Changes to both plugins are allowed when required by the authorized integration.
   Prefer clear ownership to duplicating counterpart functionality in Panels+.

Source/target describes the changed code, not knowledge direction. Stable pins
remain read-only; the task's rolling source is writable within the requested
scope. Publishing and Git commits require explicit user instructions.

## Paths and version conventions

Use underscores in all version-bearing directory names: `v1_7_1`, never `v1.7.1`. Test suite directories retain their plugin prefix, e.g. `meguru__v1_7_1`. CLI versions may be dotted (`1.7.1`) and are normalized for lookup.

- Stable pins: `references-repos/plugins/<plugin>/stable/v1_7_1/`.
- Rolling working sources: `references-repos/plugins/<plugin>/rolling.koplugin/`; Panels+ rolling source is this project itself. KOReader source is `references-repos/koreader/`.
- Historical experimental stable copies (preserve, do not develop here): `references-repos/plugins/<plugin>/laboratory/v1_7_1/<experiment>/`.
- Generated builds: `.cache/plugin-compatibility/builds/<plugin>/v1_7_1/<build-id>/<plugin>.koplugin/` (ignored).
- Stable tests: `tests/plugin-compatibility/<plugin>__v1_7_1/**/*_spec.lua`; multiple pins may coexist.
- Rolling tests: `tests/plugin-compatibility/<plugin>__rollingrelease/**/*_spec.lua`; one rolling suite per plugin.
- Plugin-specific Bash build helpers: `tools/plugin-compatibility/builders/<plugin>.sh`; shared tooling lives beside `deploy.sh` in `tools/plugin-compatibility/`.
- Required per-plugin backlog and restart handoff: `references-repos/plugins/<plugin>/history-changes.md`. Keep a single cumulative file across versions; version every chronological entry.
- Release links and provenance: `references-repos/plugins/<plugin>/releases.md`. Shared attribution: `references-repos/LICENSES.md`.
- Panels+ uses the project root as its source and has no folder under `references-repos/plugins/`; those folders are for other plugins. Do not recreate a Panels+ reference snapshot as part of ordinary cross-plugin work. Laboratory copies and generated builds are ignored; installation backups remain outside `plugins/`.

Canonical directory identifiers: `panels_plus`, `kobo`, `meguru`, `ink-away`. Panels, Panels+, PanelsPlus and panelsplus refer to Panels+ here. Ink Away's metadata identifier is `inkaway`; do not derive its directory identifier from that spelling.

## Updating upstream (only on explicit request)

Do not update repositories during ordinary development, testing or resumption.
Keep the existing local base even when newer remote commits are known to exist.
A final rebase/merge is a separate user-requested step after review; never infer
permission from a plan to do it eventually.

If the user explicitly requests updating rolling sources or KOReader, use the
project-root `run-sync-submodules.sh` with only the requested selectors, such as
`--ink-away`, `--meguru`, `--kobo` or `--koreader`. With no flags it selects all
references, so do not omit selectors for a scoped request. The helper follows
configured upstream branches and stages selected pointers; it does not commit.
Inspect and preserve local feature branches, changes and staging before any
update, and do not run a sync that would overwrite or bypass ongoing work.
Review any resulting pointer changes without committing them unless requested.
Stable snapshots and frozen backups are not refreshed by this tool.

## Verify and record

Current scope: new suites under `tests/plugin-compatibility/` are coexistence tests. Add feature-integration coverage only when requested; existing Panels+ unit/regression tests remain in `tests/`. In particular, `tests/panelviewer_kobo_bluetooth_spec.lua` uses mocked KOReader APIs and hard-coded input/actions without loading `kobo.koplugin`, so it stays a unit suite and is not version-pinned Kobo compatibility evidence. A future test using the actual selected Kobo reference belongs in its versioned compatibility suite and must identify whether it tests coexistence or an integration.

Test the corresponding pinned stable release first, then rolling source. Read the actual counterpart's code/API in each suite; a mock-only assertion does not establish cross-plugin compatibility. Include absence/disabled-plugin behavior, load order, lifecycle cleanup and the requested interaction where relevant. Do not change runtime behavior solely to satisfy an invented compatibility scenario.

Pinned stable results determine completion. Still run and report rolling results: a rolling-only failure is a separate upcoming compatibility issue and does not block completion when the stable behavior passes. The test command retains a nonzero exit status for any failed selected suite; distinguish which suite failed in the report instead of suppressing failures.

Run `./run-tests.sh --compatibility-plugin=<plugin> --compatibility-plugin-version=1.7.1`, then the same command with `rollingrelease`. Omitting the version runs all existing stable suites first and rolling last. A missing requested suite is an error. Each suite runs separately to prevent module/mock state leaking between pins. Read `references/workflow-details.md` for suite context and deployment commands.

Update the relationship matrix with direction, visibility, version range and a link to the plugin history. Record exact tested tuples, detailed steps and outcomes in `history-changes.md`; distinguish upstream stable, the rolling base SHA, local feature branch and uncommitted diff. New APIs absent from stable need separate stable-fallback and modified-rolling feature evidence. Unit tests do not replace the developer's live KOReader validation. Preserve uncertainty and report remaining live checks.

Use `tools/plugin-compatibility/deploy.sh` for build/install planning. Normal development builds use the canonical rolling checkout. Historical stable/laboratory builds are reproduced only when explicitly requested; a named existing laboratory experiment uses `--experiment=<name>`. In this project, a user request to build a rolling release also authorizes installing that build: use `--install` against the canonical rolling checkout, without selecting a former worktree. Use `--build-only` only when the user explicitly requests an artifact without installation. Read-only planning still previews; stable/laboratory installation requires authorization. Close KOReader before installation, back up outside the plugins directory and stop on local changes or ambiguous identities. Never remove the working project or reference checkout. Do not install a second Panels+ beside this live development copy.


## Required versioned history and restart handoff

For every plugin touched by this workflow, create or maintain
`references-repos/plugins/<plugin>/history-changes.md`, including investigation-only
work. This is the durable backlog, not a final-response transcript. Start its
entry before dependent work, update it after meaningful investigation, changes,
tests and deployment, and finish the handoff before ending the task. Do not defer
all recording until the final successful result.

Use the narrative style and required fields in
[references/history-changes.md](references/history-changes.md). Keep a concise
**Current state** at the top and dated chronological entries below. Every entry
must name source/target metadata versions, release/rolling provenance and exact
base revisions, local branches and working-diff state. Retain historical patch
identities only for earlier evidence; do not generate new patch files for handoff. Local changes do not invent a new release version.
Record each step's test method, command/working directory/environment, what was
real versus mocked, failing-before and passing-after results, skipped/not-rerun
checks, and live-validation status. Keep material failed approaches and why the
next check changed; do not replace earlier failures with a final green total.

A reader with no chat history must be able to recover the objective, ownership,
authorized working copies, behavior/defaults, implementation decisions, local branch/base and working changes,
current build/install/backup, tests and their limits, and the next action
from this file alone. Preserve author notes and historical evidence when
migrating older logs; mark unknowns instead of inventing dates, SHAs or results.
Keep `relationships.md` as the cross-plugin index. Rename a legacy per-feature
backlog to this canonical name and fix its links; counterpart API documentation
such as a target's `docs/Plugin-integration.md` remains separate.

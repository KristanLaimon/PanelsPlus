# Per-plugin history standard

Use `references-repos/plugins/<plugin>/history-changes.md` for every workflow task.
A single cumulative file covers all versions and features for that target. Create
it before dependent investigation/changes when absent; open a dated entry at the
start and update the entry as evidence arrives. A task that ends with findings,
a failure, a blocked dependency or no code changes still needs its actual outcome.
A version bump starts another entry, not another history file.

## Style

Follow the Ink Away history's narrative approach: lead with the user's concrete
symptom or request, explain the observed cause and which plugin owns the fix,
then describe the resulting behavior and supporting evidence. Use short connected
paragraphs, executable command blocks, and flat steps/tables when they clarify
parallel checks. Preserve useful author notes and label their authorship. Avoid
chat transcripts, repeated status messages and large raw log dumps; retain the
key error, why it mattered, and enough commands/artifacts to reproduce it.

## Current-state summary at the top

Keep this updated; historical builds and pending statements must not look current.
Include the latest outcome and whether it is installed, tested, or still awaiting
live confirmation. State:

- Source/target names, metadata versions and stable/rolling/laboratory provenance;
  full SHAs/base pins, branches, paths, dirty/staged/uncommitted state, immutable
  references and installed KOReader version separately from the host source pin.
- Agreed scope/authorization, responsibility boundary, user-facing defaults,
  relevant settings, invariants and known limitations. A history records granted
  scope; it does not itself authorize unrelated mutations or publication.
- Active worktree, ordered retained patches with hashes and applicability, latest
  artifact/install/backup, and whether changes were committed/published. Say when
  the working copy already contains the patch stack so it is not reapplied.
- Latest checks with dates/entry references, actual-versus-fixture scope, skipped
  or carried-forward results, and exact run commands with their working directory
  and required environment. A shared runbook in the same file avoids duplication.
- Open issues, unverified behavior and the next concrete action. Re-read live
  repository/provenance state before resuming; the summary is a dated handoff.

## Each chronological entry

Use a heading such as:

```markdown
## YYYY-MM-DD — NN: Concrete change — Source VERSION dev / Target VERSION patched rolling

**Versions and provenance:** Source metadata version, SHA/base and branch;
target metadata version, pin/SHA/worktree and patch identity; host source pin
and native runtime/device when exercised. Mark unavailable facts explicitly.

Describe the trigger, observed behavior and evidence. Explain which side changed,
why it owns the behavior, relevant files/API, and the resulting user behavior.

### Investigation, tests and outcome by step

1. Reproduction/investigation: method or command, cwd/environment, real modules
   and fixtures, observed failure/result, and what the evidence ruled in/out.
2. Implementation/check: what changed and why; exact test invocation (or named
   same-file runbook section with parameters), scenarios, results/counts and scope.
3. Follow-up validation: intermediate failure or changed test method, final
   results, checks skipped/not rerun and why, and any remaining uncertainty.
4. Build/install if performed: source identity, command, artifact, destination,
   backup, payload verification, and live result or pending manual check.

Record the final state, known limits, and next action. Link the retained patch
or relevant code when useful; preserve decision context needed to resume.
```

Adapt the number of steps to the actual work. An investigation-only entry has no
invented implementation/deployment; a commit-only entry explicitly says tests
were not rerun. Metadata version plus a precise local patch/revision distinguishes
a patched rolling build from an unchanged release with the same version string.

## Evidence rules

Record tests at each meaningful step, including failures that changed the design
or exposed a fixture gap. State what actually loaded/ran: mocked host geometry,
real selected counterpart modules, native libraries, real widgets, or physical
reader input. A source mock alone is not counterpart integration, and native
library checks alone are not live UI/device validation. Record exact failing
errors and failing-before counts only when observed; use “not recorded” otherwise.

Separate stable fallback, original rolling and patched-worktree results. Keep
performance measurements tied to input size/page count, environment and metric
(CPU time versus elapsed time, resident memory versus Lua heap). Preserve a
failed old artifact's identity if it demonstrates a regression. Do not silently
relabel a historical passing result as a test of later code.

When later evidence contradicts a conclusion, append the correction and update
Current state. Preserve the earlier observation with its original scope. Before
ending, check that the file alone explains what is currently true, how it was
established, what remains uncertain and how to continue. Validate local links
and version/provenance fields; writing a log does not rerun runtime tests.

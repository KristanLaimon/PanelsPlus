# Ink Away release references

- [GitHub repository](https://github.com/EmirErtorer/ink-away.koplugin)
- [Latest upstream release](https://github.com/EmirErtorer/ink-away.koplugin/releases/latest) — moving discovery link.
- [Pinned release v4.5.0](https://github.com/EmirErtorer/ink-away.koplugin/releases/tag/v4.5.0) — local reference: [`stable/v4_5_0/`](stable/v4_5_0/).

Stable 4.4.0 and its versioned fallback-only suite were removed on 2026-11-15
at the developer's request: it has no Panels+ integration compatibility.
Historical fallback smoke results are not integration compatibility evidence.

`rolling.koplugin/` is the local development Git submodule, pinned by the parent repository. It is not automatically today's upstream HEAD.

Release-tag links are provenance candidates, not evidence of completed compatibility testing. Verify artifact provenance/checksums when refreshing pins; do not silently replace a local pin with today's latest release. Version directory names use underscores.

See [relationships](../../relationships.md) for declarations and exact tested tuples, and [licenses and attribution](../../LICENSES.md) for retained notices. A local reference alone does not establish a passing coexistence or integration test.

Development backlog and restart handoff: [history-changes.md](history-changes.md).
It records exact modified versions, test methods/results, installation and open live checks.

## Current local reference — verified 2026-11-15

Canonical `rolling.koplugin/` is clean upstream `main` at
`0015691669e74baeb4b0d3e13f61f3e629279fb7`, metadata 4.5.0, exactly local tag
`v4.5.0`. It includes PR #80's upstream merge `0e63969` and integration rework
`4a8568a5dd0413442588aa095a502e106a7ef0f2`. No fetch/update was performed in this
audit. [Upstream v4.5.0](https://github.com/EmirErtorer/ink-away.koplugin/releases/tag/v4.5.0)
was additionally pinned from its release ZIP on 2026-11-15.
Asset `ink-away.koplugin-v4.5.0.zip` SHA-256:
`c9b0f707d9e93aa6cea0f01b22f21e8d72f98e714449bb9dca954e5459203f92`,
verified against the GitHub release API digest. Stable 4.5.0 and rolling each
pass 44 public surface integration cases each.
Panels+'s current runtime works
with the public facade without adaptation; exact tests and limits are in the
[2026-11-15 history](history-changes.md#2026-11-15--audit-merged-pr-80-against-upstream-ink-away-450).

## Historical local development — superseded by the reference above

As explicitly requested on 2026-11-02, `rolling.koplugin/` is now the writable
Ink Away source, based on `8dda5407e05446dddb20ba5d6fbac263955d0db3` on local branch `feature/plugin-integration`. Integration changes are now committed through
`b5b83b2f6b67f2503e1fb4dada92dffc2a60d1c2` and pushed to
`kristanlaimonorigin/feature/plugin-integration` (history entry 25). It is no longer an unmodified upstream reference. Preserve
its local changes; do not sync/reset it as routine reference maintenance. The
former `.cache/.../ink-away-annotation-surfaces/` worktree remains a frozen backup.
New work uses direct source diffs rather than retained patch files. See history
entries 17–18 for ownership, migration and loading-order validation.

Keep that base unchanged during development. Fetch/pull/sync/rebase and commits
require explicit instructions; newer remote commits are deliberately deferred.


## Documentation working copy

[Ink-away-documentation/](Ink-away-documentation/) is a separate submodule for
the Fumadocs/Bun site, with origin
https://github.com/KristanLaimon/Ink-away-documentation.git. Its site is committed through c19a2a7 and pushed to origin/main. A newer
14-page beginner-focused documentation rewrite remains local for review;
see history entry 31. It is independent
of the runtime plugin and contains integration guides and the full public API.

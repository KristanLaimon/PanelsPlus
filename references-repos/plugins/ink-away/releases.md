# Ink Away release references

- [GitHub repository](https://github.com/EmirErtorer/ink-away.koplugin)
- [Latest upstream release](https://github.com/EmirErtorer/ink-away.koplugin/releases/latest) — moving discovery link.
- [Pinned release v4.5.4](https://github.com/EmirErtorer/ink-away.koplugin/releases/tag/v4.5.4) — local reference: [`stable/v4_5_4/`](stable/v4_5_4/).

Stable 4.4.0 and its versioned fallback-only suite were removed on 2026-11-15
at the developer's request: it has no Panels+ integration compatibility.
Historical fallback smoke results are not integration compatibility evidence.

`rolling.koplugin/` is the local development Git submodule, pinned by the parent repository. It is not automatically today's upstream HEAD.

Release-tag links are provenance candidates, not evidence of completed compatibility testing. Verify artifact provenance/checksums when refreshing pins; do not silently replace a local pin with today's latest release. Version directory names use underscores.

See [relationships](../../relationships.md) for declarations and exact tested tuples, and [licenses and attribution](../../LICENSES.md) for retained notices. A local reference alone does not establish a passing coexistence or integration test.

Development backlog and restart handoff: [history-changes.md](history-changes.md).
It records exact modified versions, test methods/results, installation and open live checks.

## Current local reference — verified 2026-11-27

Stable 4.5.4 replaces 4.5.0. The unchanged
[release ZIP](https://github.com/EmirErtorer/ink-away.koplugin/releases/download/v4.5.4/ink-away.koplugin-v4.5.4.zip)
matches GitHub's published SHA-256
`fedff788f6b66e90f30875901f49879bbd90827d948bb37d6a5f34f6cd7c5b87`.
Canonical rolling follows `origin/main`, checked out at
`9c3574fbad5f18853f5bd37f63d5c7e5cc070f1b` (exact `v4.5.4` tag).
Both references passed 44 integration cases and 48 native headless KOReader
scenarios. See [history](history-changes.md).

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

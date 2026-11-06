# Ink Away release references

- [GitHub repository](https://github.com/EmirErtorer/ink-away.koplugin)
- [Latest upstream release](https://github.com/EmirErtorer/ink-away.koplugin/releases/latest) — moving discovery link.
- [Pinned release v4.4.0](https://github.com/EmirErtorer/ink-away.koplugin/releases/tag/v4.4.0) — local reference: [`stable/v4_4_0/`](stable/v4_4_0/).

The tag is present in local Git references; remote release-page retrieval was unavailable during initial setup. The developer corrected the original folder's 4.4.4 label to 4.4.0 to match `_meta.lua`; release contents were preserved.

`rolling.koplugin/` is the local development Git submodule, pinned by the parent repository. It is not automatically today's upstream HEAD.

Release-tag links are provenance candidates, not evidence of completed compatibility testing. Verify artifact provenance/checksums when refreshing pins; do not silently replace a local pin with today's latest release. Version directory names use underscores.

See [relationships](../../relationships.md) for declarations and exact tested tuples, and [licenses and attribution](../../LICENSES.md) for retained notices. A local reference alone does not establish a passing coexistence or integration test.

Development backlog and restart handoff: [history-changes.md](history-changes.md).
It records exact modified versions, test methods/results, installation and open live checks.

## Active local development

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

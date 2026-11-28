# Meguru release references

- [GitHub repository](https://github.com/Craftwork2720/meguru)
- [Latest upstream release](https://github.com/Craftwork2720/meguru/releases/latest) — moving discovery link.
- [Pinned release v1.7.1](https://github.com/Craftwork2720/meguru/releases/tag/v1.7.1) — local reference: [`stable/v1_7_1/`](stable/v1_7_1/).
- [Pinned release v1.8.10](https://github.com/Craftwork2720/meguru/releases/tag/v1.8.10) — local reference: [`stable/v1_8_10/`](stable/v1_8_10/).

The 1.7.1 tag was present in local Git references; remote release-page retrieval was unavailable during initial setup.

On 2026-11-27, stable 1.8.10 replaced 1.8.7. The unchanged
[release ZIP](https://github.com/Craftwork2720/meguru/releases/download/v1.8.10/meguru.koplugin.zip)
matches GitHub's published SHA-256
`f09780dcb7cfffb36b8b9e7e08e7ae4b81b36547bff96da4f7c7f86e6a261f20`.
Tag commit: `29306313c34090040aeffdbac7583fa6aaa1a8fb`. Rolling follows
`origin/main` at `4d5f5fc2fa0ffa69160b4cc21e1b85ab16904e55`, one manifest
bump after the stable tag. Both stable pins and rolling pass 14 geometry
integration cases per reference. See [history](history-changes.md).

`rolling.koplugin/` is the local development Git submodule, pinned by the parent repository. It is not automatically today's upstream HEAD.

Release-tag links are provenance candidates, not evidence of completed compatibility testing. Verify artifact provenance/checksums when refreshing pins; do not silently replace a local pin with today's latest release. Version directory names use underscores.

See [relationships](../../relationships.md) for declarations and exact tested tuples, and [licenses and attribution](../../LICENSES.md) for retained notices. A local reference alone does not establish a passing coexistence or integration test.

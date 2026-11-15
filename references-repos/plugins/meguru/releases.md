# Meguru release references

- [GitHub repository](https://github.com/Craftwork2720/meguru)
- [Latest upstream release](https://github.com/Craftwork2720/meguru/releases/latest) — moving discovery link.
- [Pinned release v1.7.1](https://github.com/Craftwork2720/meguru/releases/tag/v1.7.1) — local reference: [`stable/v1_7_1/`](stable/v1_7_1/).
- [Pinned release v1.8.7](https://github.com/Craftwork2720/meguru/releases/tag/v1.8.7) — local reference: [`stable/v1_8_7/`](stable/v1_8_7/).

The 1.7.1 tag was present in local Git references; remote release-page retrieval was unavailable during initial setup.

On 2026-11-15, the 1.8.7 pin was extracted unchanged from the upstream
[`meguru.koplugin.zip` release asset](https://github.com/Craftwork2720/meguru/releases/download/v1.8.7/meguru.koplugin.zip),
published 2026-11-15. SHA-256:
`877757d520d31b3fd8a2021f85b01268c984e37ab23c96549fe7221faee307ac`,
verified against GitHub's release API digest. Tag commit:
`c4d623b1b53583b2178046ba0f85b463c57baa27`.
The rolling reference was updated to
`7a6e9b8033c228c187855af8fcd4c4580018ac4b`; its only change after the tag is
the manifest version bump. See [compatibility history](history-changes.md).

`rolling.koplugin/` is the local development Git submodule, pinned by the parent repository. It is not automatically today's upstream HEAD.

Release-tag links are provenance candidates, not evidence of completed compatibility testing. Verify artifact provenance/checksums when refreshing pins; do not silently replace a local pin with today's latest release. Version directory names use underscores.

See [relationships](../../relationships.md) for declarations and exact tested tuples, and [licenses and attribution](../../LICENSES.md) for retained notices. A local reference alone does not establish a passing coexistence or integration test.

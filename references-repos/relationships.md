# Plugin relationships

Read this first at the start of a session using `panelsplus-crossplugin-dev`.
Arrows mean knowledge/support, not write permissions: `A → B` means A supports B.
Panels means Panels+ in the developer's original notes. KOReader is the host, not a plugin.

## Developer-declared relationships

These ranges reproduce developer knowledge; they are not independently verified promises about future releases. Visibility was not specified and must be established before marking Visual/Not visual.

| Relationship | Left plugin / declared range | Direction | Right plugin / declared range | Visibility | Evidence |
| --- | --- | --- | --- | --- | --- |
| OneWay Knowledge | Panels+ >= v1.3.0 | → | kobo.koplugin >= v0.4.1 | Unspecified | Developer's `promptt.md` |
| OneWay Knowledge | Meguru >= v1.7.0 | → | Panels+ >= v1.5.1 | Unspecified | Developer's `promptt.md`; identity clarified in conversation |
| Unknown Behavior Relationship | Panels+ >= v1.5.1 | ? | Ink Away >= v4.4.0 | N/A | Developer changed the original No relationship declaration to Unknown pending testing; Ink Away version corrected in conversation |
| Unknown Behavior Relationship | Ink Away >= v4.4.0 | ? | Meguru >= v1.7.1 | N/A | Developer explicitly requests coexistence testing; arrow direction is unestablished |

## Exact tested tuples

No new compatibility testing is claimed by creation of this file. Local reference availability is not evidence of a passing integration test.

Pinned stable results determine task completion. Rolling-only failures must be reported as separate upcoming compatibility issues; do not hide them or treat them as stable failures.

Add records here with exact versions/SHAs for both plugins, stable/laboratory/rolling provenance, patch identity if applicable, KOReader version, environment/device, scenario, automated command/result, live result and date. Keep untested combinations explicitly unknown. Record evidence and scope when asserting No relationship.

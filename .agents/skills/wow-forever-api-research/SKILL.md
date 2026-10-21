---
name: wow-forever-api-research
description: 'Use when verifying WoW Forever API declarations, runtime claims, restrictions, updating pinned API evidence, or documenting client compatibility.'
---

# WoW Forever API research

Use this workflow to verify API claims against high-trust primary sources and keep evidence boundaries explicit. The current source pin is **1.60.1 (70374)** at commit **`735496de78ebd30ce816a0637982c556987f258c`**, collected **2026-10-14**. It is not a runtime test of the installed client.

## References

- [Focused API reference](../../../docs/wow-forever-api/API-REFERENCE.md) contains selected signatures, native-caller notes, and compatibility boundaries.
- [Selected declaration index](../../../docs/wow-forever-api/api-symbols.jsonl) contains pinned source links for a deliberately small set of relevant symbols.

## Evidence boundaries

| Evidence | Establishes | Does not establish |
|---|---|---|
| Pinned generated source declaration | Signature, payload/field definitions, declared restrictions | Availability or successful addon execution on a current client |
| Pinned Blizzard Lua/XML caller | Implementation, template/load usage at that revision | Server caps, throttles, or every security context |
| Historical report from another build | A report tied to its recorded context | A permanent current-client rule |
| Mocked/static test | Local logic under supplied assumptions | In-game permission, rendering, persistence, or actual event behavior |
| Named-build runtime probe | Measured behavior in that specific context | Universal behavior across builds and states |

## Research workflow

1. Record actual `GetBuildInfo()` results, project/game type, locale, and relevant client state when runtime behavior is involved.
2. Search the selected declaration index by exact `lookup`, then follow its immutable source link.
3. Inspect the generated declaration together with the native Lua/XML caller and load manifest when signatures alone do not establish usage or availability.
4. Add only relevant source-backed records and concise reference notes. Keep declarations, historical reports, addon policy, mocks, and measured results distinct.
5. Do not infer API absence from a missing selected record, infer addon permission from a declaration alone, or replace a pinned revision with a moving branch.
6. Label mocked/static validation separately from in-game measurements. Never describe one evidence level as another.

This repository's evidence has not been collected by launching or instrumenting WoW. Do not relabel the pin as build 70450 or current without matching evidence.
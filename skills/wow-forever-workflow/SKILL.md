---
name: wow-forever-workflow
description: 'Develop and diagnose Batata Scanner startup, SavedVariables, dependencies, packaging, debugging, and performance on WoW Forever.'
---

# WoW Forever addon workflow

Read the [API baseline](../wow-addon-api/SKILL.md), actual [TOC](../../Batata%20Scanner.toc), [Core.lua](../../Core/Core.lua), and [evidence boundaries](../../docs/wow-forever-api/README.md). Source **1.60.1 (70374)** collected **2026-10-14** is not a current-client measurement.

## Loading and persistence

- Check TOC order, dependency availability, XML includes, and game-type manifests before declaring a missing API removed. Interface compatibility alone does not port code.
- Initialize persisted state in this addon's `ADDON_LOADED` handler. Keep database readiness separate from world/character context. Account for load-on-demand consumers loading after `PLAYER_LOGIN`.
- Preserve account-wide `Batata_Scanner_DB` and existing records/default values, including false, zero, and empty strings. Changes require explicit compatible migrations; do not import GuildHQ data or reset the user's database during diagnostics.
- `LoadSavedVariablesFirst` is an alternate lifecycle feature, not a generic repair. Do not add historical beta workarounds without a reproduction on the named build.
- Test `/reload`, logout/login, and a full process restart separately. Record raw pre-default state when diagnosing restoration. Successful reload persistence does not prove full-restart persistence.

## Public consumers and packages

Consumers should declare Batata Scanner as a dependency or optional dependency, check API readiness/version, and use fetchers or callbacks. Keep implementation modules local and out of the public facade. Preserve the copy-returning contract for nested data.

Check addon folder layout, manifest order, existing optional dependencies, licenses, and documentation before packaging. Development skills/tests must stay outside TOC runtime loads. A local package is not authorization to publish a release or write to another addon.

## Debugging and performance

1. Record addon version from metadata, build/project/locale, dependencies, trigger, first useful error/event, and expected result.
2. Separate exceptions, unavailable capabilities, blocked operations, inaccessible data, loading defects, and missing server responses. A successful `pcall` does not confirm response delivery.
3. Use the smallest diagnostic: script errors, `/eventtrace`, `/fstack`, API declarations, or available profiling tools. Do not dump secret values, real player names, or unrelated SavedVariables into research notes.
4. Compare performance on the same workload. Prefer existing bounded work and virtualized row mechanisms before introducing frameworks or caches. Mock benchmarks cannot establish live server behavior.
5. Run relevant [tests](../../tests) and the [formatting checks](../wow-addon-api/references/lua-formatting.md). Record remaining in-game checks, including native Who restoration, restrictions, UI rendering, and actual process persistence.

Timers do not confer fresh hardware input. Do not blindly retry after timeout or a denied action; preserve the scanner's late-response/ownership state and report incomplete coverage.

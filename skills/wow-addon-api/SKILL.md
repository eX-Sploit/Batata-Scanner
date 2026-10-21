---
name: wow-addon-api
description: 'Implement, review, or debug BatataScanner Lua, TOC loading, API compatibility, lifecycle, persistence, and its read-only consumer contract on WoW Forever.'
---

# WoW addon API baseline

Use this baseline for all BatataScanner Lua work, then select the focused UI, social, or workflow skill. Read [AGENTS.md](../../AGENTS.md) and [the API contract](../../docs/API.md) before changing public behavior.

## Target and evidence

[BatataScanner.toc](../../BatataScanner.toc) targets Interface **16001**. The migrated [research](../../docs/wow-forever-api/README.md) records source **1.60.1 (70374)** at commit `735496de78ebd30ce816a0637982c556987f258c`, collected **2026-10-14**. It establishes declarations and source implementation, not installed-client behavior. The directory name does not establish Classic Era APIs. Record `GetBuildInfo()`, project/game type, locale, and capability when runtime behavior matters.

## Project conventions

- Follow [release versioning](../../AGENTS.md#release-versioning). Keep `## Version` in the TOC as the single release source; never hardcode it in Lua.
- Read [Lua formatting](references/lua-formatting.md) and [.stylua.toml](../../.stylua.toml). Use descriptive bindings, Lua 5.1, four spaces, CRLF, multiline bodies, and aligned related assignments. Preserve multiple-return semantics when laying out declarations.
- Keep the shared namespace supplied by `...` local and modules internal. Expose only the documented read-only `BatataScanner` facade, SavedVariables, named frames, and slash registration globals needed by the client. Ordinary Lua `require` does not replace TOC loading.
- Keep persisted readiness separate from world/context readiness. Preserve false, zero, and empty defaults. Do not replace `BatataScanner_DB` or import another addon's database.
- Return copies from fetchers, summaries, status, and callbacks. Do not expose internal tables or public mutators. A read-only facade is an integration contract in a shared Lua environment.
- Reuse existing bounded work, state transitions, and widgets. Keep timers idle when unnecessary. Treat server work as asynchronous and confirm it through events/results.

## Verify API use

1. Search [api-symbols.jsonl](../../docs/wow-forever-api/api-symbols.jsonl) by exact `lookup`. This is a selected subset, not a complete inventory.
2. Follow the immutable source link. Inspect Lua/XML callers and Camelot load manifests when signatures alone cannot answer load, permission, or template questions.
3. Capability-check APIs before use. Missing snapshot records do not prove removal; source declarations do not prove runtime permission. `HasRestrictions` alone is not a hardware-event specification.
4. Check table/value access before indexing, normalizing, comparing, sorting, logging, or persisting externally supplied data. A readable table does not establish readable fields; `pcall` does not declassify values or confirm server success.
5. Run relevant mocks/static checks, then identify remaining named-build in-game verification. Never present one evidence level as another.

## Focused skills

- [Who, observation, and identity](../wow-forever-social/SKILL.md)
- [UI, tables, and settings](../wow-forever-ui/SKILL.md)
- [Loading, persistence, and debugging](../wow-forever-workflow/SKILL.md)

The formatting helpers were migrated from GuildHQ. Check their CLI before use; run base formatting, [declaration layout](scripts/split_lua_locals.py), then [assignment alignment](scripts/align_lua.py), followed by the [naming audit](scripts/check_lua_names.py). Their pinned dependencies are in [requirements.txt](scripts/requirements.txt).

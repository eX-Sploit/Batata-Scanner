# BatataScanner contributor guidance

BatataScanner is a standalone Lua addon for WoW Forever. Its manifest targets Interface **16001**. The `_classic_beta_` directory does not establish Classic Era API compatibility. Migrated source evidence is pinned to **1.60.1 (70374)**, collected **2026-10-14**; verify current runtime behavior separately.

## Scope and skills

Before relevant changes, read the matching skill. Skills apply to Codex and Copilot; [.github/copilot-instructions.md](.github/copilot-instructions.md) points to the same canonical guidance.

| Task | Skill |
|---|---|
| Lua, API selection, compatibility, TOC | [wow-addon-api](skills/wow-addon-api/SKILL.md) |
| Census, Who queries, passive observations, player identity | [wow-forever-social](skills/wow-forever-social/SKILL.md) |
| Frames, tables, scrolling, settings, restricted displays | [wow-forever-ui](skills/wow-forever-ui/SKILL.md) |
| Loading, persistence, packaging, debugging, performance | [wow-forever-workflow](skills/wow-forever-workflow/SKILL.md) |

## Ownership and public contracts

- Work only in this addon unless the user explicitly requests another repository. GuildHQ is a separate addon and source reference; do not import its SavedVariables or edit its files.
- Preserve account-wide `BatataScanner_DB`. Initialization and observation ingestion belong to this addon. Never expose public database insertion, update, deletion, reset, settings mutation, scan control, or raw-table access methods.
- The `BatataScanner` global is a versioned fetch/filter API. Read [docs/API.md](docs/API.md) before changing it. Return copies of data, including nested source maps and callback payloads. Preserve the read-only facade and prevent consumers from reaching internal modules through it.
- Shared Lua globals and SavedVariables are accessible to other addon code. A read-only API is a supported contract, not security isolation. Do not claim otherwise.
- Preserve `nil` guild as unknown, empty string as confirmed unguilded, and a nonempty string as guilded. Do not replace reliable Who guild evidence with an uncertain passive absence.
- Keep collection separate from consumers' recruitment or contact logic. BatataScanner only observes and provides census data; it does not whisper, invite, synchronize, or manage guild membership.
- Confirm asynchronous requests by supported events/results. A nonthrowing `SendWho` call does not confirm delivery or a complete population count. Maintain one outstanding query, late-response quarantine, cancellation, and native UI restoration.

## API evidence and Lua conventions

Start with [the evidence index](docs/wow-forever-api/README.md). Search the focused [symbol snapshot](docs/wow-forever-api/api-symbols.jsonl) by `lookup`; follow pinned source links for signatures and restrictions. This is deliberately a subset. An absent record does not prove an API is absent, and a declaration does not prove addon permission or current runtime availability.

Before Lua edits, read [formatting conventions](skills/wow-addon-api/references/lua-formatting.md) and [.stylua.toml](.stylua.toml). Use Lua 5.1, descriptive names, CRLF, four spaces, multiline bodies, and the shared addon namespace from `...`. Use TOC loading rather than `require`. Preserve public/saved identifiers and load order. Keep formatting scoped.

## Release versioning

`## Version` in [BatataScanner.toc](BatataScanner.toc) is the only release version source. Runtime displays and the API must read metadata. Initial release is 1.0.0. Every later bugfix or feature requires one version bump before completion: patch for compatible fixes; minor with patch reset for compatible features; major with minor/patch reset when continued operation or compatibility requires consumers to upgrade. Apply the highest required bump once per completed change. `## X-API-Version` in the TOC is the only consumer API version source; increment it when the public API contract changes incompatibly.

## Validation

Run relevant existing mocked tests from the addon root, for example:

```powershell
python -m unittest discover -s tests
python skills/wow-addon-api/scripts/check_lua_names.py
python skills/wow-addon-api/scripts/split_lua_locals.py --check
python skills/wow-addon-api/scripts/align_lua.py --check
```

For skill/document-only changes, validate frontmatter, local references, and manifest consistency with `python -m unittest discover -s tests -p 'test_guidance.py'`; gameplay tests are unnecessary. Formatting helpers require the pinned parser dependencies in [requirements.txt](skills/wow-addon-api/scripts/requirements.txt).

Distinguish mocks/static inspection from in-game tests. Client restrictions, server caps/throttles, Who routing coexistence, surname behavior, visual layout, and full-process persistence require named-build runtime evidence. Never describe them as verified by mocks. Preserve unrelated working-tree changes.

# Focused WoW Forever API evidence

This is a deliberately small migration from GuildHQ's research, collected **2026-10-14** against Blizzard-authored UI source mirrored at commit **`735496de78ebd30ce816a0637982c556987f258c`**, labeled **1.60.1 (70374)**. It covers Batata Scanner's scanning, identity, lifecycle, UI, and access-check boundaries. It is not a full copy of GuildHQ's generated inventory or a runtime test of the installed client.

[Batata Scanner.toc](../../Batata%20Scanner.toc) declares Interface **16001**. `_classic_beta_` is an installation directory, not evidence that Classic Era API contracts apply. The pinned Camelot source sets `WOW_PROJECT_CAMELOT = 18`: [project constants](https://github.com/Gethe/wow-ui-source/blob/735496de78ebd30ce816a0637982c556987f258c/Interface/AddOns/Blizzard_ProjectConstants/Camelot/ProjectConstants.lua).

Read [API-REFERENCE.md](API-REFERENCE.md) for focused implementation notes. Search [api-symbols.jsonl](api-symbols.jsonl) by exact `lookup` to find the selected declaration, signature, metadata, and immutable source link:

```powershell
rg -n 'C_FriendList.SendWho|C_FriendList.GetWhoInfo|WHO_LIST_UPDATE' docs/wow-forever-api/api-symbols.jsonl
rg -n 'canaccessvalue|canaccesstable|UnitFullName' docs/wow-forever-api/api-symbols.jsonl
```

The subset retains original JSONL records byte-for-byte. It omits unrelated guild management, recruitment, chat, spells, talents, and expansion systems. Missing records do not establish API absence: Lua utilities, XML templates, legacy globals, and engine behavior may be outside generated declarations.

## Evidence boundaries

| Evidence | Establishes | Does not establish |
|---|---|---|
| Pinned generated source declaration | Signature, payload/field definitions, declared restrictions | Availability or successful addon execution on a current client |
| Pinned Blizzard Lua/XML caller | Implementation, template/load usage at that revision | Server caps, throttles, or every security context |
| Historical report from another build | A report tied to its recorded context | A permanent current-client rule |
| Mocked/static test | Local logic under supplied assumptions | In-game permission, rendering, persistence, or actual event behavior |
| Named-build runtime probe | Measured behavior in that specific context | Universal behavior across builds and states |

This migration did not launch or instrument WoW. The source snapshot must not be silently relabeled as build 70450 or current simply because GuildHQ later recorded other observations.

## Refreshing evidence

Record actual `GetBuildInfo()` results, project/game type, locale, and relevant client state. Select a matching immutable source revision and inspect the actual generated declaration plus native Lua/XML caller and Camelot load manifest. Add only relevant records and source-backed notes. Keep declarations, historical reports, addon policy, and measured results explicitly distinct; do not replace the pin with a moving branch link.

The parent source collection was GuildHQ `docs/wow-forever-api/`, particularly its research index, API reference, social integration, and development workflow. Batata Scanner's [skills](../../skills/wow-addon-api/SKILL.md) and formatting helpers were adapted from that repository. The runtime addon is independent and neither imports nor writes GuildHQ data.

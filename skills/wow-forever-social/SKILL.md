---
name: wow-forever-social
description: 'Implement or debug BatataScanner Who queries, census coverage, passive observations, guild-state evidence, and Forever player identity; excludes recruitment and social mutations.'
---

# WoW Forever scanning and census

Apply the [API baseline](../wow-addon-api/SKILL.md) and read [the focused evidence](../../docs/wow-forever-api/API-REFERENCE.md). Inspect [Scanner.lua](../../Scanner.lua), [Passive.lua](../../Passive.lua), and [Store.lua](../../Store.lua) for ownership and current behavior.

## Keep the observation boundary

Collection must include guilded and unguilded players. Consumer filtering must not silently narrow census coverage. All observation ingestion stays internal; the [public API](../../docs/API.md) only fetches, filters, and subscribes.

Preserve guild tri-state: `nil` unknown, `""` confirmed unguilded, nonempty guild name guilded. Passive `GetGuildInfo` returning nil does not by itself establish absence. Preserve reliable Who guild evidence when a passive observation has unknown guild state. Track first/last seen and observation sources without exposing source-map references.

A census is a summary of locally observed records, not an authoritative population or membership total. Preserve timestamps, scope, revision, and incomplete sweep reporting. Avoid replacing an entire population with one partial response.

## Who requests and ownership

The pinned schema declares `C_FriendList.SendWho(filter, origin?, filters?)`, table-returning `GetWhoInfo(index)`, and delivered/total returns from `GetNumWhoResults()`. The native inspected UI interprets structured class/race arrays as excluded choices and map arrays as included choices. Do not guess inclusion semantics from field names or deploy structured filters without testing locale, empty arrays, and combinations.

Keep query dispatch attached to an explicit UI/slash action. Timers may advance local cooldown/timeout state but do not inherit a click's execution context and must never autonomously dispatch queries. This is BatataScanner policy pending named-build verification, not a universal rule inferred from `HasRestrictions`.

Maintain one outstanding query. `WHO_LIST_UPDATE` is untagged: cancellation/timeout cannot safely attribute a later response to a new request. Preserve the late-response quarantine and stop unsafe retries. Detect external Who ownership conflicts and prefer a visible incomplete/blocked state over misattributing observations. Restore only native event registrations the scanner suspended, on every completion, pause, cancellation, failure, or conflict exit. Do not replace native scripts.

Delivered rows and server total are different facts. A local saturation threshold is conservative policy, not a measured server cap. Preserve level/race/class subdivision, the bounded query ceiling, and incomplete reasons when a query cannot be exhausted. Do not present saturation, inaccessible rows, timeouts, or partial results as a complete sweep.

## Identity and restricted values

Check access before reading table fields and before any name/string transformation or persistence. Secret text is not made readable by an event, a custom frame, or `pcall`. Skip unreadable observations rather than computing keys or logging them.

Forever's Camelot name helper interprets the second unit-name return as a surname even though the generated schema labels it `unitServer`. Do not discard surnames or treat every separator as a realm delimiter. Preserve distinct full display identity and realm scope. Inspect the native `NameUtil` caller before changing identity keys; mock tests do not establish actual-client surname behavior.

## Verification

Cover empty/saturated results, missing records, duplicate observations, guild tri-state, same name across scopes, cancellation, late response, cooldown, timeout, blocked calls, native UI restoration, and external Who conflicts. Use relevant existing mocked tests. Restrictions, localization, server throttles/caps, visibility rules, and event attribution require in-game verification recorded with build/project/locale and expected versus observed behavior.

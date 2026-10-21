---
name: wow-forever-ui
description: 'Implement or debug Batata Scanner frames, scan controls, census tables, scrolling, tooltips, settings, and secret-aware displays on WoW Forever.'
---

# WoW Forever scanner UI

Read the [API baseline](../wow-addon-api/SKILL.md), [window shell](../../../UI/UI.lua), [shared widgets](../../../UI/Widgets.lua), and the affected [Scanner](../../../UI/Panels/ScannerPanel.lua) or [Census](../../../UI/Panels/CensusPanel.lua) panel before editing presentation. Consult the [focused evidence](../../../docs/wow-forever-api/API-REFERENCE.md) for API details. The baseline is source **1.60.1 (70374)**, not an in-game test. Preserve the right-side icon navigation, combined scanner browser/details, compact playback controls, settings dialog, Census subsections, and native scrolling tables.

## Compose and bind

- Reuse existing construction, row binding, controls, and update paths. Keep state and records outside transient widgets; bind controls to the actual scanner state rather than a second UI-only model.
- Inspect template intrinsic type, inheritance, mixins, inherited scripts, child `parentKey` fields, and TOC availability. Generated documentation owner names are not necessarily valid `CreateFrame` type names.
- `BackdropTemplate` supplies backdrop support; `SetBackdrop` is not universal. Preserve inherited scripts when adding behavior. Use an addon-specific named frame and escape handling.
- Check supported artwork/atlas contracts before using them. Atlas names, texture file IDs, and spell icons are distinct inputs. Confirm dimensions, crop, font metrics, scale, and actual template availability in game.
- Apply [Lua conventions](../wow-addon-api/references/lua-formatting.md). Avoid importing an unrelated UI framework just because it is familiar.

## Lists and scan controls

Keep row reuse complete: rebind text, color, record, tooltip, hover, selection, enabled state, visibility, and callbacks. Alternate row shading by absolute record index. Preserve bounded visible-row rendering, stable sort ties, scroll bounds, and filters. Do not add a second unbounded UI copy of the database.

Bind scan controls to the existing state machine. A click dispatches one permitted query; timers only update local status. Make readiness, cooldown, waiting, paused, incomplete, conflict, and unavailable states understandable. A progress bar cannot establish authoritative population coverage. Keep passive collection and world-click dispatch clearly distinct; both are always on, and world clicks dispatch only while a sweep is running and unpaused.

## Restricted values and settings

Check accessibility before formatting/sorting external data. A supported setter may accept a secret value without permitting Lua computations on it; reading text back from a widget is not declassification. Batata Scanner's stored ordinary records must come through the observation access checks.

Register settings after SavedVariables initialization and bind the loaded table or explicit internal accessors. Keep settings changes internal to the addon UI; the public consumer API must not gain setters. Use stable addon-specific menu/popup identities and reset tooltips on row reuse/hide.

## Verification

Use relevant mocks for binding, filtering, sorting, and state callbacks. Check layout, resizing, paging and mouse-wheel navigation, long names/guilds, empty state, mixed class colors, filter focus, settings persistence, and native Who coexistence in game when available. Report mocked checks separately from client rendering and restrictions.

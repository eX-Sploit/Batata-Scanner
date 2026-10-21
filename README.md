# BatataScanner

A standalone WoW Forever addon for collecting player observations and providing a local census to other addons. It targets Interface **16001** and uses GuildHQ's portrait window, right-side icon navigation, native scrolling tables, and Professions surfaces. Its two main pages are **Scanner** and **Census**.

BatataScanner stores its own account-wide `BatataScanner_DB`, partitioned by realm and faction. It has no GuildHQ dependency or data import. It does not recruit, send messages, invite players, or manage guilds.

## Use

The folder must be installed as `Interface/AddOns/BatataScanner`. Enable it in the addon list and reload the UI. Use `/batatascanner` or `/bs` to open the window.

| Command | Action |
|---|---|
| `/bs` | Toggle the window |
| `/bs scan` | Start a sweep using the saved level range |
| `/bs next` | Send the next queued query or resume a paused sweep |
| `/bs pause` | Pause dispatch and retain the queue |
| `/bs stop` | Discard the queue; keep collected observations |
| `/bs status` | Print scan state and stored player count |

The Scanner page combines the searchable player table, playback buttons, status, and an **Entry details** pane. Click Play to start scanning. With world-click dispatch off, click Play again after each response and cooldown to send the next query. While a query is pending or world-click dispatch is armed, the same button pauses scanning. Stop clears queued queries and keeps observations. Timers never send queries.

The footer **Settings** button opens the scan options: levels **1-60** by default, query interval, optional custom Who query, passive collection, and world-click dispatch. World-click dispatch is off by default; enabling it allows game-world clicks to send the next eligible query. Pause competing active Who scans, including GuildHQ world-click scanning, through their own controls while using BatataScanner. Passive observations can coexist; BatataScanner does not change another addon's settings.

Broad sweeps split saturated level ranges, then use native race and class choices where available. The conservative 50-row subdivision trigger and five-second default interval are addon policies, not measured server guarantees. Saturated queries that cannot be subdivided, missing/inaccessible records and the bounded query ceiling mark the sweep incomplete. Timeouts pause the sweep until the untagged response drains and the query can be retried; stopping a pending sweep leaves it incomplete.

Passive collection is enabled by default. It observes readable same-faction players available through player, target, mouseover, nameplate, party, and raid units, using a bounded queue. Passive observations supplement Who results without requesting server queries. Unknown passive guild data does not erase reliable stored guild evidence.

Enter words in Scanner's Search field and press Enter to match stored names, classes, races, guilds, zones, levels, and observation dates. Every word must match; punctuation is literal. Click a column heading to sort, repeat to reverse, and select a row to see its stored details. The native scrollbar covers all matches while only visible records are copied. Searches refresh at most every 30 seconds while visible; pressing Enter refreshes immediately. The title-bar button switches between compact and expanded window sizes.

Census uses the same **Classes**, **Races**, and **Guilds** subsections as GuildHQ. Classes shows class-colored population bars; Races selects a race and shows its class breakdown; Guilds provides guild-name search. Column headings sort the charts, and the footer shows population totals. Observations persist across sessions; a census is a history of locally observed players, not an authoritative online population total. The consumer API retains exact filters, pagination, and timestamp filtering for freshness.

## Consumer addons

The global `BatataScanner` API provides fetching, filtering, paginated results, census summaries, status, and callbacks. Every returned table is detached from internal data. It exposes no database mutators, settings setters, or scan controls. See [the complete API contract and examples](docs/API.md).

```lua
if BatataScanner and BatataScanner.IsReady() then
    local result = BatataScanner.FindPlayers(
        { class = "MAGE", minLevel = 20 },
        { sort = "lastSeen", descending = true, limit = 100 }
    )
    print("Observed mages:", result.total)
end
```

The read-only facade is a supported integration contract. WoW addons share Lua globals and SavedVariables, so it cannot isolate data from deliberately invasive addon code.

## Compatibility and verification

The focused [API evidence](docs/wow-forever-api/README.md) was migrated from GuildHQ's source research for **1.60.1 (70374)**, collected **2026-10-14**. The installation directory does not establish Classic Era API behavior. Current-client restrictions, source availability, surnames, server caps/throttles, event routing, and persistence require separate runtime verification.

Local mocked/static checks can be run from this folder:

```powershell
python -m unittest discover -s tests
python skills/wow-addon-api/scripts/check_lua_names.py
python skills/wow-addon-api/scripts/split_lua_locals.py --check
python skills/wow-addon-api/scripts/align_lua.py --check
```

The tests use mocked WoW APIs through a Lua runtime; see [test requirements](tests/requirements.txt). Formatting helpers use [their pinned parser requirements](skills/wow-addon-api/scripts/requirements.txt). No in-game verification was performed while creating this addon.

For a focused in-game check, record `GetBuildInfo()`, project, locale, and addon metadata version, then:

1. Open both main pages and all three Census subsections, switch compact/expanded sizes, scroll, search and sort, and check long player/guild names and empty results.
2. Run a narrow sweep and confirm each user action sends at most one query; verify cooldown, pause/resume, and the completed/incomplete status.
3. Check a saturated range and compare delivered rows with the reported total. Confirm subdivisions and incomplete reasons remain visible.
4. Stop or time out a pending request. Confirm another request waits until the old untagged response drains. If another addon/native Who overlaps an outstanding request, scanning blocks until `/reload` to prevent attributing ambiguous results.
5. Verify native Who behavior after completion, pause, cancellation, and errors. Compare surname-bearing names and guild unknown/empty/named states.
6. Observe target/mouseover/nameplates/group units with passive collection on and off. Confirm same-faction filtering and that unknown guild observations preserve previous reliable evidence.
7. Verify data and preferences across `/reload`, logout/login, and a full client restart separately. Exercise another addon's API reads/callbacks and confirm editing a returned table changes no stored record.

## Contributor guidance

[AGENTS.md](AGENTS.md) contains the release policy and canonical contributor guidance. Focused [Codex skills](.agents/skills) and [Copilot skills](.github/skills) point to the same four maintained WoW skills under `skills/`. Formatting helpers and focused source declarations were adapted from GuildHQ; runtime storage and behavior are independent.

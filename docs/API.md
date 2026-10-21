# Batata Scanner consumer API

The `Batata_Scanner` global exposes API version **1**. Call functions using dot syntax: `Batata_Scanner.GetCensus()`. Runtime modules, observation ingestion, settings, scan controls, and database tables are private implementation details. There are no public database mutation methods.

Every returned data structure is a fresh copy, including census maps/context. Changing a result cannot change stored data. The facade rejects ordinary assignment and hides its metatable. This is an integration contract, not security isolation: WoW addons share Lua globals and SavedVariables.

## Loading and readiness

Use `## Dependencies: Batata Scanner` in a consumer's TOC when required, or `## OptionalDeps: Batata Scanner` and handle its absence. A loaded API can exist before character context is ready. Check `IsReady()` before data reads; `GetPlayer`, `FindPlayers`, `CountPlayers`, and `GetCensus` raise an error before readiness.

| Function | Result |
|---|---|
| `IsReady()` | Boolean: persisted state and faction context are initialized |
| `GetVersion()` | Addon release version read from TOC metadata |
| `GetAPIVersion()` | Integer `1` read from the TOC `X-API-Version` field, independent from the addon release version |
| `GetContext()` | Copy of the current character's `{ faction, key }`, or nil before context is ready |
| `GetPlayer(name)` | Copy of one player or nil if no matching record |
| `FindPlayers(filters?, options?)` | Paginated copy of matching records and result metadata |
| `CountPlayers(filters?)` | Number of matching stored records |
| `GetCensus(filters?)` | Detached aggregate for matching records |
| `GetScanStatus()` | Detached scanner status; `state = "initializing"` before ready |
| `RegisterCallback(event, callback)` | Subscription token |
| `UnregisterCallback(token)` | Boolean indicating whether a subscription was removed |

Invalid filter/option values and unknown keys raise descriptive Lua errors. Only nil selects pagination defaults; `limit = false`, `offset = false`, and `sort = false` are invalid, while `descending = false` is valid. Faction filters must be `"Alliance"` or `"Horde"`. `GetPlayer` returns nil for an unusable or absent name. Consumers should check API availability/version once and supply validated arguments.

Saved-data schema 1 is the initial format. Existing databases from pre-1.0.0 development builds are reset to defaults on load; player records and settings are not migrated.

## Context and player records

WoW Forever is realmless, so Batata Scanner does not record or partition by realm. All recorded players, of either faction, share one collection, and reads include every faction unless a `faction` filter is supplied. Faction values are `"Alliance"` or `"Horde"`. Use `GetContext().faction` to filter to the current character's faction. Treat context `key` as opaque.

`GetPlayer` tidies whitespace and uses Lua's ordinary case folding for lookup. It preserves full surname/hyphen identity and does not infer a realm suffix from the name.

The initial API has no realm or observation-source fields. All recorded players share one collection with a faction field, and classes use localized names.

| Player field | Meaning |
|---|---|
| `name` | Full observed player identity |
| `faction` | Faction of the character that observed the player |
| `level` | Known observed level; may be absent |
| `class` | Localized class name, such as `"Priest"`, when known |
| `race` | Observed localized race string, when known |
| `guild` | nil = unknown; `""` = confirmed unguilded; nonempty = named guild |
| `firstSeen`, `lastSeen` | Unix timestamps for the local observation history |
| `zone` | Last known observed zone, when available |

Fields unavailable from the observation may be absent. A passive unknown guild does not erase an existing reliable guild state. Observation sources (Who versus passive) are not recorded.

## Filters and pagination

`FindPlayers`, `CountPlayers`, and `GetCensus` accept the same optional filter table. Filters combine with AND.

| Filter | Matching |
|---|---|
| `name` | ASCII case-insensitive plain substring; no Lua pattern interpretation |
| `class`, `race`, `guild`, `zone` | Exact observed string after trimming surrounding input whitespace |
| `minLevel`, `maxLevel` | Inclusive integer bounds, 1-255; unknown levels do not match |
| `seenAfter`, `seenBefore` | Inclusive `lastSeen` lower/upper thresholds, nonnegative integer Unix timestamps |
| `guildStatus` | `"guilded"`, `"unguilded"`, or `"unknown"` |
| `faction` | Exact faction, `"Alliance"` or `"Horde"`; omitted includes every faction |

Use `guild = ""` for confirmed unguilded records. Omitting a guild filter includes all guild states. Use `guildStatus = "unknown"` for unknown guild records; their count is also available as census `unknownGuild`. Class/race/guild/zone matching is case-sensitive; name matching is the stated exception.

`FindPlayers` options:

| Option | Default and values |
|---|---|
| `sort` | `"name"`; also `"level"`, `"firstSeen"`, `"lastSeen"`, `"guild"`, `"class"`, `"race"`, `"zone"`, `"faction"` |
| `descending` | `false`; boolean |
| `offset` | `0`; nonnegative whole number of matching records to skip |
| `limit` | `100`; whole number from 1 through 500 |

String sorting uses case-folded values; numeric sorting treats unknown values as zero. Names break ties. A result has `{ players, total, offset, limit, revision, hasMore }`. `total` is the full match count, while `players` contains only the requested page. `revision` is the global database revision, advanced by observation changes and retention cleanup. Results from separate calls are not a transaction: if revision changes while paging, restart pagination when a consistent view matters.

```lua
local page = Batata_Scanner.FindPlayers(
    { guild = "", minLevel = 30, seenAfter = time() - 86400 },
    { sort = "lastSeen", descending = true, offset = 0, limit = 200 }
)
for playerIndex, player in ipairs(page.players) do
    print(player.name, player.level)
end
```

## Census summaries

`GetCensus(filters?)` returns `{ total, byClass, byRace, byGuild, byLevel, guilded, unguilded, unknownGuild, oldestSeen, newestSeen, revision }`.

`byClass`, `byRace`, `byGuild`, and `byLevel` map field values to counts. Unknown class/race use `"Unknown"`; unknown level uses numeric key `0`. Confirmed unguilded uses the empty-string key in `byGuild`. Unknown guild records are counted only in `unknownGuild`, so a real guild named `"Unknown"` remains distinct. Empty result sets have `total = 0`, empty count maps, zero guild counters, and nil `oldestSeen`/`newestSeen`. `oldestSeen` is the earliest first observation and `newestSeen` the latest last observation among matches.

Counts summarize stored observations; they are not a current online count, complete population census, or guild membership total. Query freshness and scan status separately.

History retention is disabled by default. Users can opt into age-based deletion in the addon settings; cleanup runs on load, Settings Save, and logout/reload, and can reduce counts or make previously known players unavailable. Unknown last-seen timestamps are preserved. Runtime cleanup advances revision and coalesces `DATA_UPDATED`; startup cleanup is reflected in `READY`. Retention settings and deletion remain internal, with no public mutation methods.

## Scanner status

After readiness, `GetScanStatus()` returns:

- `state`: `"idle"`, `"ready"`, `"waiting"`, `"paused"`, `"complete"`, `"stopped"`, or `"unavailable"`. The former `"blocked"` state is no longer produced.
- `running`, `paused`, `awaiting`: current state flags.
- `completedQueries`, `plannedQueries`, `remainingQueries`: sweep progress; planned count can grow during subdivision.
- `newPlayers`: identities first stored during the sweep.
- `returned`, `total`: last response's delivered-row and server-total counts; both reset to `0` after a reload.
- `incomplete`, `reason`: coverage warning and human-readable state detail.
- `currentQuery`, `cooldown`: current/next query text and seconds until the dispatch cooldown permits another action.
- `pendingLateResponse`: replies are being discarded during a bounded retry cooldown; this clears when that cooldown expires, even without a reply.
- `externalQueryPending`: an external Who request is waiting for a recognized reply, rejection, or response timeout.
- `blockedUntilReload`: retained for compatibility and always `false`; recovery no longer requires a reload.
- `nativeWhoOpen`: whether a supported native Who list is currently visible, including its parent window. This transient flag is also available when no sweep is running.
- `inCombat`: a readable player-combat or combat-lockdown getter reports true.
- `inBattleground`: a readable instance type is `"pvp"`. Arenas, dungeons, and raids are not battleground holds.
- `environmentUnavailable`: a combat or instance getter is missing, fails, or returns unreadable/malformed data. Dispatch stays held; false combat/battleground flags do not establish safety while this is true.

While `nativeWhoOpen` or `externalQueryPending` is true, the scanner holds new requests without changing the meaning of `running`, `paused`, or `state`. These flags must be checked separately from the sweep's phase. Closing the Who view or receiving an external reply only removes the corresponding hold; the next query still requires an eligible user action. Manual pauses remain paused. Visibility changes publish `SCAN_STATUS_CHANGED`, and the visibility flag is recomputed rather than persisted.

Combat, battleground, and unavailable-environment flags are also automatic dispatch holds, independent of manual `paused` state. They are recomputed from guarded live getters rather than saved, even when no sweep is running. Combat transitions, world entry, and zone changes publish `SCAN_STATUS_CHANGED`; dispatch always rechecks the current environment. All holds must clear before an eligible user action can send. An already-owned reply can still be ingested or time out under existing rules, and passive observation keeps running. `reason` includes the highest-priority environmental hold while a sweep is running. These fields are part of the initial API contract.

Timeouts, failed or blocked calls, cancellation, and overlapping requests begin a bounded reply-discard cooldown of at least the greater of the configured interval and response timeout. Unfinished chunks stay queued without duplication; only accepted replies advance progress. A running, unpaused sweep retries on its next eligible input after the cooldown, still respecting native Who and environment holds. Stopping remains stopped, and manual pauses remain paused.

Who replies have no request ID, so expiry is a retry policy, not confirmation of completion. Interrupted sweeps are marked `incomplete`; a sufficiently late reply may still be ambiguous after retry. `complete` describes the local sweep's terminal state; always inspect `incomplete`. Passive observations can update stored data while no sweep runs. Scanner state, queued queries, and cooldowns persist across reloads; a fresh installation reports a running `"ready"` sweep before any query is sent.

When coverage is incomplete, `reason` retains its coverage warning alongside the current phase message. Pausing, retrying successfully, completing the sweep, or reloading does not discard that warning. A new sweep starts its own coverage assessment.

Reloading with an outstanding request also marks a resumed sweep incomplete and restores `pendingLateResponse` for the remaining discard cooldown. Once that hold expires, it clears without removing the incomplete-coverage warning. Reload does not extend the saved hold.

Saved active sweeps include their faction. Logging into the other faction rebuilds the sweep from current settings and resets its progress, while preserving manual pause and any remaining cooldown. Restoration never dispatches a query.

## Callbacks

Supported events are `"READY"`, `"DATA_UPDATED"`, and `"SCAN_STATUS_CHANGED"`. Callbacks receive `(eventName, revision)`; `revision` is a number, never an internal table. Fetch fresh copies inside the callback. `DATA_UPDATED` notifications are coalesced for approximately 0.2 seconds, so do not expect one event per player. Callback failures are caught and forwarded to the client's error handler without interrupting other subscribers.

`READY` is not replayed to late subscribers. Subscribe, then inspect `IsReady()` for already-loaded state. Store subscription tokens and unregister when your module stops.

```lua
local censusProvider = Batata_Scanner
local function RefreshFromScanner(eventName, revision)
    if censusProvider.IsReady() then
        local census = censusProvider.GetCensus()
        print("Observed players:", census.total)
    end
end

if censusProvider and censusProvider.GetAPIVersion() == 1 then
    local readyToken = censusProvider.RegisterCallback("READY", RefreshFromScanner)
    local dataToken = censusProvider.RegisterCallback("DATA_UPDATED", RefreshFromScanner)
    if censusProvider.IsReady() then
        RefreshFromScanner("READY", 0)
    end
    -- Keep readyToken/dataToken in your module; unregister them when it shuts down.
end
```

See [the README](../README.md) for user controls, limitations, and runtime verification. See [contributor guidance](../AGENTS.md) before changing this contract.

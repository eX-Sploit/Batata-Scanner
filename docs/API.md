# BatataScanner consumer API

The `BatataScanner` global exposes API version **1**. Call functions using dot syntax: `BatataScanner.GetCensus()`. Runtime modules, observation ingestion, settings, scan controls, and database tables are private implementation details. There are no public database mutation methods.

Every returned data structure is a fresh copy, including player source maps and census maps/context. Changing a result cannot change stored data. The facade rejects ordinary assignment and hides its metatable. This is an integration contract, not security isolation: WoW addons share Lua globals and SavedVariables.

## Loading and readiness

Use `## Dependencies: BatataScanner` in a consumer's TOC when required, or `## OptionalDeps: BatataScanner` and handle its absence. A loaded API can exist before character context is ready. Check `IsReady()` before data reads; `GetPlayer`, `FindPlayers`, `CountPlayers`, and `GetCensus` raise an error before readiness.

| Function | Result |
|---|---|
| `IsReady()` | Boolean: persisted state and realm/faction context are initialized |
| `GetVersion()` | Addon release version read from TOC metadata |
| `GetAPIVersion()` | Integer `1`, independent from the addon release version |
| `GetContext()` | Copy of `{ realm, faction, key }`, or nil before context is ready |
| `GetPlayer(name, scope?)` | Copy of one player or nil if no matching record |
| `FindPlayers(filters?, options?)` | Paginated copy of matching records and result metadata |
| `CountPlayers(filters?)` | Number of matching stored records |
| `GetCensus(filters?)` | Detached aggregate for matching records |
| `GetScanStatus()` | Detached scanner status; `state = "initializing"` before ready |
| `RegisterCallback(event, callback)` | Subscription token |
| `UnregisterCallback(token)` | Boolean indicating whether a subscription was removed |

Invalid filter/option/scope values raise descriptive Lua errors. `GetPlayer` returns nil for an unusable or absent name. Consumers should check API availability/version once and supply validated arguments.

## Context and player records

Reads default to the current realm and faction. `scope` on `GetPlayer` and `realm`/`faction` in filters select a different saved scope; omitted fields use current context. Faction values are `"Alliance"` or `"Horde"`. A scope without saved observations returns no records. There is no implicit all-realms/all-factions query. Treat context `key` as opaque.

`GetPlayer` tidies whitespace and uses Lua's ordinary case folding for lookup. It preserves full surname/hyphen identity and does not infer a realm suffix from the name. Realm selection belongs in the separate scope argument.

| Player field | Meaning |
|---|---|
| `name` | Full observed player identity |
| `realm`, `faction` | Storage scope |
| `class` | Stable uppercase class token, such as `"MAGE"`, when known |
| `className` | Localized observed class name, when known |
| `race` | Observed localized race string, when known |
| `level` | Known observed level; may be absent |
| `guild` | nil = unknown; `""` = confirmed unguilded; nonempty = named guild |
| `zone` | Last known observed zone, when available |
| `firstSeen`, `lastSeen` | Unix timestamps for the local observation history |
| `sources` | Copy of a map with source-name keys and `true` values |

Fields unavailable from the observation may be absent. A passive unknown guild does not erase an existing reliable guild state. Source keys are informational provenance and may expand in later compatible releases.

## Filters and pagination

`FindPlayers`, `CountPlayers`, and `GetCensus` accept the same optional filter table. Filters combine with AND.

| Filter | Matching |
|---|---|
| `name` | ASCII case-insensitive plain substring; no Lua pattern interpretation |
| `class` | Exact class token, normalized to uppercase |
| `race`, `guild`, `zone` | Exact observed string after trimming surrounding input whitespace |
| `minLevel`, `maxLevel` | Inclusive integer bounds, 1-255; unknown levels do not match |
| `seenAfter`, `seenBefore` | Inclusive `lastSeen` lower/upper thresholds, nonnegative integer Unix timestamps |
| `guildStatus` | `"guilded"`, `"unguilded"`, or `"unknown"` |
| `source` | `"who"` or `"passive"`; matches a recorded observation source |
| `realm`, `faction` | Saved scope selection, defaulting to current values |

Use `guild = ""` for confirmed unguilded records. Omitting a guild filter includes all guild states. Use `guildStatus = "unknown"` for unknown guild records; their count is also available as census `unknownGuild`. `source = "passive"` includes any of the passive unit observation paths. Race/guild/zone matching is case-sensitive; class token and name matching are the stated exceptions.

`FindPlayers` options:

| Option | Default and values |
|---|---|
| `sort` | `"name"`; also `"level"`, `"lastSeen"`, `"guild"`, `"class"`, `"race"`, `"zone"` |
| `descending` | `false`; boolean |
| `offset` | `0`; nonnegative whole number of matching records to skip |
| `limit` | `100`; whole number from 1 through 500 |

String sorting uses case-folded values; numeric sorting treats unknown values as zero. Names break ties. A result has `{ players, total, offset, limit, revision, hasMore }`. `total` is the full match count, while `players` contains only the requested page. `revision` is the global database observation revision. Results from separate calls are not a transaction: if revision changes while paging, restart pagination when a consistent view matters.

```lua
local page = BatataScanner.FindPlayers(
    { guild = "", minLevel = 30, seenAfter = time() - 86400 },
    { sort = "lastSeen", descending = true, offset = 0, limit = 200 }
)
for playerIndex, player in ipairs(page.players) do
    print(player.name, player.level)
end
```

## Census summaries

`GetCensus(filters?)` returns `{ total, byClass, byRace, byGuild, byLevel, guilded, unguilded, unknownGuild, oldestSeen, newestSeen, revision, context }`.

`byClass`, `byRace`, `byGuild`, and `byLevel` map field values to counts. Unknown class/race use `"Unknown"`; unknown level uses numeric key `0`. Confirmed unguilded uses the empty-string key in `byGuild`. Unknown guild records are counted only in `unknownGuild`, so a real guild named `"Unknown"` remains distinct. Empty result sets have `total = 0`, empty count maps, zero guild counters, and nil `oldestSeen`/`newestSeen`. `oldestSeen` is the earliest first observation and `newestSeen` the latest last observation among matches. `context` is a detached `{ realm, faction, key }`.

Counts summarize stored observations; they are not a current online count, complete realm census, or guild membership total. Query freshness and scan status separately.

## Scanner status

After readiness, `GetScanStatus()` returns:

- `state`: `"idle"`, `"ready"`, `"waiting"`, `"paused"`, `"complete"`, `"stopped"`, `"blocked"`, or `"unavailable"`.
- `running`, `paused`, `awaiting`: current state flags.
- `completedQueries`, `plannedQueries`, `remainingQueries`: sweep progress; planned count can grow during subdivision.
- `observed`, `newPlayers`: distinct observed sweep identities and newly stored identities.
- `returned`, `total`: last response's delivered-row and server-total counts.
- `incomplete`, `reason`: coverage warning and human-readable state detail.
- `currentQuery`, `cooldown`: current/next query text and seconds until the dispatch cooldown permits another action.
- `pendingLateResponse`, `externalQueryPending`, `blockedUntilReload`: untagged-response ownership safeguards.

Stopping or timing out an outstanding query can leave a response pending; the addon waits for it before another send. An overlapping external Who request can block scanning until UI reload because its results cannot be reliably attributed. `complete` describes the local sweep's terminal state; always inspect `incomplete`. Passive observations can update stored data while no sweep runs.

## Callbacks

Supported events are `"READY"`, `"DATA_UPDATED"`, and `"SCAN_STATUS_CHANGED"`. Callbacks receive `(eventName, revision)`; `revision` is a number, never an internal table. Fetch fresh copies inside the callback. `DATA_UPDATED` notifications are coalesced for approximately 0.2 seconds, so do not expect one event per player. Callback failures are caught and forwarded to the client's error handler without interrupting other subscribers.

`READY` is not replayed to late subscribers. Subscribe, then inspect `IsReady()` for already-loaded state. Store subscription tokens and unregister when your module stops.

```lua
local censusProvider = BatataScanner
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

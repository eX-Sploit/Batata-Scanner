# Batata Scanner consumer API

The `Batata_Scanner` global exposes API version **1**. Call functions using dot syntax: `Batata_Scanner.GetCensus()`. Runtime modules, observation ingestion, settings, scan controls, and database tables are private implementation details. There are no public database mutation methods.

Every returned data structure is a fresh copy, including census maps/context. Player cursor tokens are opaque identities with no data fields; their internal state is never returned. Changing a result cannot change stored data. The facade rejects ordinary assignment and hides its metatable. This is an integration contract, not security isolation: WoW addons share Lua globals and SavedVariables.

## Loading and readiness

Use `## Dependencies: Batata Scanner` in a consumer's TOC when required, or `## OptionalDeps: Batata Scanner` and handle its absence. A loaded API can exist before character context is ready. Check `IsReady()` before data reads; `GetPlayer`, `FindPlayers`, cursor opening/advancement, `CountPlayers`, and `GetCensus` raise an error before readiness.

| Function | Result |
|---|---|
| `IsReady()` | Boolean: persisted state and faction context are initialized |
| `GetVersion()` | Addon release version read from TOC metadata |
| `GetAPIVersion()` | Integer `1` read from the TOC `X-API-Version` field, independent from the addon release version |
| `GetContext()` | Copy of the current character's `{ faction, key }`, or nil before context is ready |
| `GetPlayer(name)` | Copy of one player or nil if no matching record |
| `FindPlayers(filters?, options?)` | Paginated copy of matching records and result metadata |
| `OpenPlayerCursor(filters?, options?)` | Opaque exhaustive snapshot/change-feed token |
| `AdvancePlayerCursor(cursor, budgetMilliseconds?)` | Bounded detached snapshot page, changes, and progress metadata |
| `ReadPlayerChanges(cursor, budgetMilliseconds?)` | Bounded changes, also available during initial enumeration |
| `ClosePlayerCursor(cursor)` | Releases read resources; false if already closed or unknown |
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

## Bounded retrieval and continuous updates

The cursor functions were added in release 1.1.0 without changing API version 1. Feature-detect `OpenPlayerCursor` before using them. `FindPlayers` remains synchronous and compatible; its `limit` bounds copied results, not execution time. Consumers experiencing synchronous query stalls must adopt the cursor path.

Open one long-lived cursor with the same filters and options as `FindPlayers`. Opening does no population traversal, sorting, or copying. The cursor captures the current revision and a session-local change position atomically. Its initial snapshot includes exactly those matching records/values at creation, in the documented order, starting at `offset`. `limit` bounds each returned array, not the complete result set: there is no browser-style 1,000-record cap. The browser retains its own cap.

Advance once per scheduled slice. Preparation, comparison/merge sorting, filtering, page copying, and change replay share one deadline. `budgetMilliseconds` defaults to 1 and accepts any positive finite number through 2, including fractions. Work stops at record/comparison/state boundaries, with a small allowance reserved for completion/publication. Creation, completion, and closure do not materialize a full result array. Every call returns at most `limit` snapshot records and `limit` changes, and results may contain fewer than `limit` even when more remain.

The target is at most 2 ms plus a measured indivisible operation, subject to actual client clock, allocation/GC, and scheduling behavior. This is cooperative work, not a hard real-time guarantee. A readable, monotonic `debugprofilestop` supplies the millisecond deadline. Without it, or if it fails/resets, advancement falls back to at most 64 work operations plus constant publication work and reports `timed = false`; it cannot establish a millisecond bound in that mode. Even with a clock there is a 4,000-operation cap. No coroutine support is required. Consumers must also budget their own imports and combined cursor calls within their frame scheduler.

`AdvancePlayerCursor` prepares the fixed snapshot, emits detached pages, then follows its change journal. Mutations never restart the snapshot. `ReadPlayerChanges` independently drains that same journal position, including while snapshot preparation is running, so fresh discoveries/updates need not wait for initial sorting. Calls on the same cursor share a feed position and never replay an already-read entry. Different cursors have independent positions.

An advancement returns these fields:

| Field | Meaning |
|---|---|
| `players` | Detached initial-snapshot page; empty during preparation and for `ReadPlayerChanges` |
| `changes` | Detached ordered transition entries, described below |
| `state` | `"preparing"`, `"snapshot"`, `"changes"`, or `"resetRequired"` |
| `total` | Exact full snapshot match count once preparation finishes; nil before then |
| `offset`, `limit` | Snapshot offset before this advancement and the configured array-size bound |
| `revision` | Fixed initial-snapshot revision; never relabeled with a newer live revision |
| `snapshotSequence` | Fixed initial boundary; use as the version of every snapshot record |
| `snapshotComplete`, `hasMore` | Whether all requested snapshot rows were delivered, and whether snapshot work remains |
| `sequence` | Last examined feed position, including changes irrelevant to these filters |
| `throughSequence`, `throughRevision` | Fixed endpoint of the current feed pass |
| `caughtUp` | Feed reached that endpoint; does not imply initial snapshot completion or a permanent live endpoint |
| `timed`, `elapsedMs`, `maxOperationMs`, `workUnits` | Per-call profiling and work diagnostics; timing fields are nil when untimed |
| `reason` | `"historyExpired"` or `"collectionReloaded"` when reset is required |

A feed pass captures a finite endpoint. Writes arriving during the pass belong to a subsequent pass, so sustained writes do not move the completion boundary indefinitely. Complete initial synchronization requires `snapshotComplete` and a caught-up feed; retain the cursor and continue draining later passes for freshness. Callback coalescing does not coalesce journal entries: each stored record change is sequenced, including equal-timestamp edits and each retention deletion. No-op observations do not create changes.

An entry is `{ kind, name, player?, sequence, revision }`. `kind = "upsert"` carries a detached complete player record that matches the fixed filters. `kind = "remove"` carries no player and removes an identity that was deleted or changed out of the filters. Changes irrelevant both before and after are examined but not returned. Ordering is by change sequence rather than the snapshot sort. Guild unknown/named/confirmed-unguilded and inclusive timestamp matching retain their ordinary meanings. Filters stay fixed for a cursor's lifetime; reopen to change a rolling timestamp window.

When draining changes before snapshot completion, keep a per-identity applied sequence, including removals. Apply a snapshot row only if its `snapshotSequence` is newer than that identity's applied sequence; apply each change with its own `sequence`. This prevents a late old snapshot row from overwriting fresh state or resurrecting a removed record. Use the full name's case-folded identity. Sequence values belong to the current client session and are not persisted resume tokens or Unix timestamps. Do not advance a timestamp watermark to snapshot completion time; cursor sequencing closes the gap without that assumption.

At most eight cursor tokens may remain open. Close them when a consumer stops; closure changes no observations, settings, or scan controls. Active readers share a ring retaining the latest 16,384 transitions (including other factions). Normal observation ingestion has no journal allocation or cursor copy-on-write cost when no public reader is active. Initial snapshots retain old record versions while needed; keep one cursor per consumer and release unused ones promptly.

If a reader falls behind the retained history, it enters `resetRequired` instead of claiming successful completion. Discard that call's payload, close the token, and start a new incremental full snapshot with the same filters. Reconcile the consumer's existing state incrementally, including identities absent from the replacement snapshot; never merge a new snapshot into an old cache without removing missing identities. Keep the new snapshot generation's sequence tracking separate. Recovery restores current stored state; overwritten intermediate historical transitions cannot be reconstructed. A permanently stalled consumer cannot be guaranteed lossless replay with bounded memory. Size/rate stress and recovery must be validated for the intended workload. Reload invalidates all tokens; no feed data is persisted and no SavedVariables migration/reset is required.

```lua
local provider = Batata_Scanner
local cursor
if provider and provider.IsReady() and provider.OpenPlayerCursor then
    cursor = provider.OpenPlayerCursor(
        { faction = provider.GetContext().faction },
        { sort = "name", limit = 100 }
    )
end

-- Call from the consumer scheduler; import the returned batch in bounded slices.
local function ReadSlice()
    if cursor then
        return provider.AdvancePlayerCursor(cursor, 0.5)
    end
end

-- Schedule separately during initial loading to keep new discoveries fresh.
local function ReadFreshSlice()
    if cursor then
        return provider.ReadPlayerChanges(cursor, 0.5)
    end
end

-- Call on shutdown or before opening a replacement after resetRequired.
local function StopReading()
    if cursor then
        provider.ClosePlayerCursor(cursor)
        cursor = nil
    end
end
```

The example illustrates call ownership, not a scheduler implementation. Import work and recovery reconciliation also need bounded slices. See [the synthetic profiling script](../tests/benchmark_player_read.py) and [cursor tests](../tests/test_player_read.py); neither substitutes for named-build live consumer captures with collection and discovery enabled.

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

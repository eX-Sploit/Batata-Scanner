# Batata Scanner

Batata Scanner is a simple addon for WoW Forever that keeps track of players you see and helps you build a local player census.

Think of it like a personal notes board for the world around you: who you’ve seen, what class they are, their guild, their level, and when you last spotted them.

It is made for players who want a cleaner, easier way to track people nearby without needing to be a developer or understand addon internals.

## What it does

- Tracks players you observe while playing
- Shows level, class, guild, and first- and last-seen times
- Lets you search and filter your saved data
- Builds a local census so you can quickly see class and guild trends
- Saves progress between sessions so your data stays useful over time

## Install

1. Put the addon in your WoW folder as:
   `Interface/AddOns/Batata Scanner`
2. Enable it in the addon list
3. Reload the UI
4. Open it with `/batata-scanner`, `/bs`, or the minimap button

You can drag the minimap button to a different spot if you want it easier to reach.

## Quick commands

| Command | What it does |
|---|---|
| `/bs` | Open or close the window |
| `/bs scan` | Start a scan sweep |
| `/bs next` | Send the next queued query |
| `/bs pause` | Pause scanning while keeping the queue |
| `/bs stop` | Stop the current queue but keep collected data |
| `/bs status` | Show current scan status and saved player count |
| `/bs debug` | Toggle Who query and response-size diagnostics |

## The main pages

### Scanner

This is your live player list. It automatically shows only players from your current character's faction.

Here you can:

- Search by name, class, guild, zone, level, and date
- Sort the table by clicking a column header
- Filter by level range, class, guild status, and recency
- Start and pause scans
- View a player’s guild, last seen time, and more

The scan controls let you sweep players in a controlled way. You can choose which levels and classes to include, and adjust the query interval if needed.

Accepted Who replies are stored immediately, but the Scanner table waits for its normal 30-second refresh interval, just like passive updates. Automatic searches wait at least 30 seconds after the previous search started, including after a manual search, and preserve your filters, sort, and scroll position. Search, filter, and sort actions still respond immediately, as do scan-status controls. If a search is already running, it finishes before a queued refresh starts. Reopening a dirty cached table respects any remaining refresh interval. An explicitly cancelled search stays cancelled until you submit another search. Invalid submissions cancel in-flight work and leave the last completed results visible until you submit valid input.

Opening Batata Scanner starts a background player search, even if you stay on Welcome or Census, so Scanner is ready when you open it. Search results refresh every 30 seconds while the window is open, including recency filters; closing the window stops these refreshes.

Large searches prepare their ordering and filter records in bounded steps across frames so they do not block the UI in one large sort.

Visible first- and last-seen ages also refresh every 30 seconds without rerunning the search. Each search uses a consistent snapshot of the identities and record values present when it starts. Ongoing observations cannot restart or starve it; later refreshes include those updates. Snapshot preparation remains bounded across frames and reuses unchanged records rather than copying the whole database up front.

The Scanner browser retains at most 1,000 matching results and shows a notice when more may exist; narrow your search to find a smaller set. This limit only affects the browser view: your account-wide collection and the read-only API still include all recorded players.

Switching tabs keeps warm results. Closing the whole window keeps completed results for up to five minutes so a quick reopen can reuse them; after that, search snapshots, matches, and visible row copies are released. Reopening during the grace period restores the cached filters, sort, and scroll position. Cancelled or superseded work releases its snapshots immediately. The store keeps at most two reusable sort indexes, and observations update records in place when no search needs an older version.

Crowded queries split by level, then by your faction's races, then by the classes each race can be. The scanner uses Forever's nine classes and ten races, including both Skyborne races, Dwarf Shamans, and Undead Paladins. It skips impossible race/class combinations.

The world-click listener and send path both check the configured query interval. The full interval starts when the previous Who call returns, so dispatch preparation cannot shorten it.

Opening the Group Finder's Who tab automatically holds new census queries and shows **Paused: Who**. Other Group Finder tabs do not hold scanning. Closing the window or switching away from Who lets a playing sweep continue on the next eligible click, after any remaining cooldown. It does not send immediately or clear a manual pause. You can still pause or stop the sweep while this temporary hold is active.

Combat and battlegrounds also hold new Who queries, showing **Paused: Combat** or **Paused: Battleground**. Passive observation keeps running, and replies to already-sent queries follow the normal ownership and timeout rules. Leaving combat or a battleground never sends a query automatically: all holds and cooldowns must clear, then the next eligible click continues the sweep. Manual pauses and stopped scans stay paused or stopped.

Battleground detection uses the `pvp` instance type, not arenas, dungeons, or raids; combat still holds scanning in any location. If combat or instance state cannot be read safely, the scanner shows **Paused: Unavailable** and waits for readable state. Detection is refreshed on combat/world/zone events and rechecked before dispatch, without a new polling timer. These controls have source and mocked-test coverage; detection, transition timing, and label layout still require in-game verification on the installed build.

Your own `/who` requests also hold scanning until a recognized reply, rejection, or response timeout, even if the Who tab stays closed. Their recognized results are not added to the census. Overlapping requests and missing replies trigger a bounded retry cooldown instead of requiring a UI reload.

When a recognized `/who` throttle message arrives, the scan stays playing through a longer local cooldown, even if that rejection arrives after the response timeout. Once the countdown ends, the next world click retries the unfinished query without needing Play. Manual pauses remain paused. Reload preserves the queue, remaining cooldown, and playing or manually paused state. Timers never send queries. Hover over the scan status for the current reason.

After a timeout, failed send, or overlap, the unfinished chunk stays queued and the status shows **Retry in Ns**. The retry cooldown lasts at least the greater of the configured query interval and response timeout, normally 15 seconds with Balanced speed. Replies received during that cooldown are discarded. The next eligible world click retries the queued work after the countdown ends; no Play action is needed unless you manually paused. Stop still stops the sweep, and collected players are preserved.

Who replies have no request ID. A reply arriving after the retry cooldown can still be ambiguous, so interrupted sweeps remain marked incomplete even if a later retry succeeds. A cooldown is a recovery policy, not proof that the server finished an earlier request.

Reloading with an outstanding request preserves the remaining reply-discard cooldown and marks the resumed sweep incomplete. Retrying successfully does not remove that warning. Coverage warnings remain available alongside the current scanner status through pauses, retries, completion, and reloads.

An active sweep saved by another faction is rebuilt for the current character's faction, preserving manual pause and cooldown state without sending automatically. Older saved queues without a faction marker retain an incomplete-coverage warning.

### Census

This page turns your saved observations into a quick overview.

It shows things like:

- Most common class
- Most common race
- Guild totals
- Counts for your current character's faction
- Population summaries

It helps you see patterns in your local observations without digging through a giant table manually.

The Census tabs are **Overview**, **Levels**, and **Guilds**. Levels shows a histogram of players at each level, with hover details for counts and percentages. Unknown levels are reported separately. The chart shows levels 1-60 together and extends the range when higher levels have been observed.

Census always uses your current character's faction. Population statistics, class and race charts, level distribution, guild counts, percentages, and the footer summary all follow that faction automatically. There is no faction selector, and any previously saved scope choice is ignored. Observations from both factions stay in your account-wide collection for your other characters; this does not change the read-only API's filtering options.

Census counts and race/class breakdowns are maintained as observations arrive. Opening the census does not rescan the player collection, and scanner-status-only updates leave unchanged charts and tooltips alone.

Overview, Levels, and Guilds share one display snapshot, prepared when the main window opens and refreshed every 30 seconds while it stays open, even on another page. Unchanged data skips copying and chart updates. Closing the window stops periodic Census work; reopening brings changed data up to date. Displayed statistics can lag new observations by up to 30 seconds, but collection and the read-only API stay current. Switching sections, searching or sorting guilds, resizing, and hovering remain responsive using the cached data. A character-faction change refreshes the displayed scope immediately.

Donut charts reuse unchanged slice artwork. Hovering repaints only the affected slices; changes to size, distribution, or colors update the cached artwork as needed.

## How it works

Batata Scanner watches both:

- Direct scans you trigger in-game
- Passive observations while you play (like nearby players you can read from units, party members, raid members, and similar sources)

This means it can build a useful local database without constantly spamming queries.

Passive collection processes bounded batches only while observations or delayed guild rechecks are queued. Unit events restart processing when needed; no passive polling timer remains active while idle.

Your data is saved locally and remains available across reloads and logins. The addon keeps track of the people you’ve seen so you can revisit the information later.

Pre-1.0.0 development databases are reset on load to establish the initial saved-data schema; their player records and settings are not migrated.

Saved player fields are validated when loaded. Malformed fields become unknown, and rows without a usable name are skipped. Valid fields, zero timestamps, and confirmed-unguilded empty guild strings are preserved.

## Settings that matter

From the main window, open the Settings panel.

You can:

- Set your level range
- Limit which classes are scanned
- Choose **Fast**, **Balanced** (default), or **Slow** scan speed
- Choose **Random** (default, query chunks in random order without repetitions), **In Order** (lowest to highest level), or **Reversed** (highest to lowest) scan behavior
- Choose whether to use the default sweep settings or override them
- Set **Delete unseen after** to **Never** (default), **30 days**, **90 days**, **180 days**, or **365 days**

The scan speeds use intervals of 6, 15, and 30 seconds, respectively. Balanced is used when no valid interval is saved; existing saved choices are preserved across reloads and logins, with the former 5-second Fast setting upgraded to 6 seconds on load. Older custom intervals select the next slower preset, capped at Slow, when opening Settings, but are not changed until saved.

Changes are held until you click **Save**. Closing Settings without saving discards staged changes. Existing saved scan behavior is preserved.

History retention is account-wide and opt-in. Saving a finite period permanently removes players of either faction whose last observation is older than that period. Cleanup also runs when the addon loads and at logout/reload, without a background polling timer. Records with an unknown last-seen time are kept, as are observations exactly on the cutoff. Changing back to Never does not restore deleted history. Seeing a removed player again creates a new history record. Retention changes census totals but does not narrow Who collection or alter the scan queue.

## Important notes

- Batata Scanner is for tracking and local census data.
- It is not a recruitment or guild management tool.
- It keeps its own local data, separate from other addons.
- It is meant to work as a read-only helper for your own information and addon use.

## Compatibility

This addon is built for WoW Forever and targets Interface version 16001.

Use it as a local player-tracking tool, not as a guarantee of live server-wide population data. It is best understood as a history of what you’ve observed locally.

## For addon developers

If you are building another addon and want to read Batata Scanner’s data, see [docs/API.md](docs/API.md).

That API is intentionally read-only and designed to return copies of data instead of exposing internal storage directly.

## Simple summary

If you want a quick answer: Batata Scanner helps you notice who is around, remember what you saw, and build a clean local census without turning your game into a bot or a spam tool.

It is a practical helper for players who like tracking, scouting, and understanding what is happening around them.

## License

Batata Scanner is licensed under the [Creative Commons Attribution-NonCommercial 4.0 International license](LICENSE) (CC BY-NC 4.0).

You may share and adapt this project for noncommercial purposes with appropriate credit, a link to the license, and an indication of any changes.

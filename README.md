# Batata Scanner

<p align="center">
   <img src="Assets/batata-scanner-icon.png" alt="Batata Scanner mascot holding a magnifying glass" width="192">
</p>

**A friendly field journal for WoW Forever.** Keep a record of the players you meet, find familiar names later, and see what your own adventures add up to.

Batata Scanner saves local observations from your characters and turns them into a searchable player list and a personal census. It is not a live or server-wide population count; it reflects what you have observed.

## Get started

1. Place the addon folder in your WoW AddOns directory:
   `Interface/AddOns/Batata Scanner`
2. Enable **Batata Scanner** and reload the UI.
3. Open it with `/bs`, `/batata-scanner`, or the minimap button. Drag the minimap button to move it.

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

## Your field journal

### Scanner

Browse what you have recorded, search by name or details, and sort or filter the list to find someone again. Scanner shows players from your current character's faction. The browser displays up to 1,000 matches at a time; this limit does not cap your saved collection.

Start a `/who` sweep with Play or `/bs scan`. Choose a level range, classes, and scan speed to shape your search. A sweep is bounded and click-driven: requests wait for an eligible action and never fire from a timer. Combat, battlegrounds, the native Who window, and cooldowns can pause requests. If results are incomplete, Scanner tells you rather than presenting them as a complete census.

### Census

See your sightings summarized by class, race, level, and guild. The Overview, Levels, and Guilds views make it easy to spot patterns without paging through every record. Census follows your current character's faction; observations from both factions remain saved for your other characters.

## How it works

Some sightings are recorded automatically from targets and group members when their details are available. You can also run a controlled `/who` sweep when you want to explore further. Your collection is stored locally in your account's SavedVariables and remains available across reloads and logins.

Pre-1.0.0 development databases are reset on load to establish the initial saved-data schema; their player records and settings are not migrated.

Who results are not guaranteed to represent everyone online. Server limits, timeouts, and inaccessible results can leave a sweep incomplete. Player details reflect observations, so some fields may be unknown or out of date.

## Settings that matter

Open Settings to choose:

- Set your level range
- Limit which classes are scanned
- Choose **Fast**, **Balanced** (default), or **Slow** scan speed
- Choose **Random** (default, query chunks in random order without repetitions), **In Order** (lowest to highest level), or **Reversed** (highest to lowest) scan behavior
- Choose whether to use the default sweep settings or override them
- Set **Delete unseen after** to **Never** (default), **30 days**, **90 days**, **180 days**, or **365 days**

Fast, Balanced, and Slow use 6-, 15-, and 30-second query intervals. Settings changes take effect when you save. History cleanup is optional and account-wide; choosing a finite retention period permanently deletes older observations.

Made for personal discovery, Batata Scanner keeps your observations on your account; it doesn't contact players or manage guilds. It targets WoW Forever Interface **16001**.

## For addon developers

If you are building another addon and want to read Batata Scanner’s data, see [docs/API.md](docs/API.md).

That API is intentionally read-only and designed to return copies of data instead of exposing internal storage directly.

## License

Batata Scanner is licensed under the [Creative Commons Attribution-NonCommercial 4.0 International license](LICENSE) (CC BY-NC 4.0).

You may share and adapt this project for noncommercial purposes with appropriate credit, a link to the license, and an indication of any changes.

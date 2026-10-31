# mobparser

Combat parser addon for **Ashita v4** (Final Fantasy XI), built for the AscensionXI private server.
It reads the combat packets your client already receives and never sends anything to the server.

## What it does
- **Live GUI**: a damage / accuracy / DPS table for every party member, with per-stat display and tracking toggles.
- **Isolation**: click **Iso** on a row to see that player's breakdown. It covers:
  - physical swings, one line per weaponskill
  - per-enemy totals, magic, job abilities, additional effects and skillchains
  - TP moves and damage taken
  - Main / Sub / Ranged / Ammo filters (your own character only)
  - a **Monster** filter, by name or by individual spawn, which stacks with the weapon filters
- **All-time database**: every event is also appended to `db\events.jsonl` and `db\gear.jsonl`. **All time** shows your whole history, and **Session** shows only what has been recorded since load or the last Clear data.
- **Party saves**: every time the session is cleared (zoning with Clear on zone on, **Clear data**, `/mobparser wipe`, or unloading), a snapshot of it is saved to `db\saves\`. Pick one from the **Party saves** dropdown next to Session / All time to view it like a session: main table, Iso, Per enemy and all filters. Delete files in `db\saves\` by hand to remove saves.
- **Gear stamping**: equipped gear is read from client memory, with the [dlac](https://github.com/henkpoa/dlac) gear stream as a fallback.
- **JSON export** for downstream tools.

## Install
1. Copy this folder to `Ashita\addons\mobparser\`, so `mobparser.lua` sits directly inside it.
2. In game, type `/addon load mobparser`.

## Commands
| Command | What it does |
|---|---|
| `/mobparser gui` | Show or hide the window |
| `/mobparser report [say\|party\|linkshell]` | Post the damage table to chat |
| `/mobparser export` | Write a timestamped snapshot JSON (the session is kept) |
| `/mobparser wipe` | Clear the running session. The all-time database is kept. |
| `/mobparser status` | Session, live export and database status |
| `/mobparser setchatlogs <path>` | Chat log folder used to correlate unknown messages |

## Files written while playing
These files are git-ignored: `db\`, `debug_log.txt`, `live_export.json`, `mobparser_snapshot_*.json` and `mobparser_export.json`.
Settings are saved to `Ashita\config\addons\mobparser\settings.lua`.
To reset the all-time database, delete the `db` folder.

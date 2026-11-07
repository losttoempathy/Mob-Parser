# mobparser

A combat parser for **Final Fantasy XI** on **Ashita v4**, built for the AscensionXI private server.

mobparser reads the combat packets your game client already receives and shows them as a live damage, accuracy and DPS table for you and your party. It keeps every fight in a local database, so you can look back over everything you've parsed.

> **Read-only.** mobparser never sends anything to the server. It only reads what your client already gets.

---

## Install

1. Download this repository (green **Code** button → **Download ZIP**) and unzip it.
2. Rename the unzipped folder to `mobparser` and put it in your Ashita addons folder:
   ```
   Ashita\addons\mobparser\mobparser.lua
   ```
   `mobparser.lua` has to sit directly inside `addons\mobparser\`, not in a subfolder.
3. In game, type:
   ```
   /addon load mobparser
   ```
4. To load it every time, add `/addon load mobparser` to your Ashita startup script (for example `Ashita\scripts\default.txt`).

The window opens on load. Press **Ctrl+M** to show or hide it.

### Optional: dlac
If you use [dlac](https://github.com/henkpoa/dlac), mobparser uses its gear stream as a backup. You don't need it, because mobparser reads your equipped gear straight from the client.

---

## Using the window

### Main table
One row per party member: damage, DPS, accuracy, crits, weaponskills, magic, job abilities and more.

- **Pets count toward their owner.** An avatar's, wyvern's or automaton's damage goes on the owner's row, like a spell. Pet swings don't change the owner's own accuracy or hit counts.
- **Enemy rows** (damage mobs did to you) are off by default. Turn them on in **Settings**.

### Session, All time and Party saves
Use the selector at the top of the window:

| Choice | Shows |
|---|---|
| **Session** | Everything since you loaded the addon, zoned (when Clear on zone is on) or clicked **Clear data** |
| **All time** | Your whole history from the database. Large histories load over a few seconds. |
| **Party saves** | A snapshot of an earlier session. Pick one from the dropdown. |

Every time a session is cleared (zoning, **Clear data**, `/mobparser wipe` or unloading), mobparser saves it as a party save first, so nothing is lost.

### Isolation (Iso)
Click **Iso** on any row to see that player's full breakdown:

- **Physical**: melee swings, with one line per weaponskill
- **Per enemy**: totals against each mob, including pet damage
- **Magic**, **Job abilities**, **Additional effects** and **Skillchains**
- **TP moves** and **Damage taken**
- **Pets**: one line per pet, or tick **By summon** to break it out by pet (Ifrit, Garuda and so on), each with its blood pacts and TP moves. When a pet move matches one of the owner's job abilities (a blood pact, say), the Job abilities table also shows its **Pet dmg**, **Pet avg** and **Pet high**.

**Filters** in Iso (stack them together):
- **Main / Sub / Ranged / Ammo**: only swings made with a given weapon (your own character only)
- **Monster**: one mob by name, or one specific spawn of it
- **Reset filters** clears them all

Click **< Full list** to go back.

### Buttons
| Button | What it does |
|---|---|
| **Save export** | Writes a timestamped JSON snapshot of the session. The session stays in place. |
| **Clear data** | Clears the session (click twice to confirm). It's kept as a party save. |
| **Settings** | Opens the settings window |

### Settings
- How many player rows to show (1–18)
- Show the job column
- Show enemies (damage mobs did to you)
- Open the window when mobparser loads
- Clear session data on zone
- Chat channel for reports (say, party or linkshell)
- Per-stat display and tracking toggles
- Row colors (color editor, or reset to black and grey)

Settings are saved in `Ashita\config\addons\mobparser\settings.lua`.

---

## Commands

| Command | What it does |
|---|---|
| `/mobparser gui` | Show or hide the window |
| `/mobparser bind <key>` | Change the window key (see below) |
| `/mobparser report [say\|party\|linkshell]` | Post the damage table to chat. With no channel it uses the one set in Settings. |
| `/mobparser export` | Write a timestamped JSON snapshot. The session is kept. |
| `/mobparser wipe` | Clear the session. It's kept as a party save, and the all-time database isn't touched. |
| `/mobparser status` | Session size, database and party-save status |
| `/mobparser debug [on\|off]` | Turn the debug log on or off until the next reload |
| `/mobparser help` | List the commands and show the current window key |

### Window key
The default is **Ctrl+M**. Change it with `/mobparser bind`:

```
/mobparser bind ^p     Ctrl+P
/mobparser bind !p     Alt+P
/mobparser bind +f9    Shift+F9
/mobparser bind none   no key (use /mobparser gui instead)
/mobparser bind        back to Ctrl+M
```

Prefixes: `^` Ctrl, `!` Alt, `+` Shift, `@` Win. Keys: a letter, a digit or F1–F12.
mobparser never takes a key another addon already uses. If the key is taken, it tells you and leaves it alone. The key does nothing while the chat line is open.

---

## Where your data goes

Everything stays in the addon folder on your PC:

| Path | Contents |
|---|---|
| `db\events.jsonl` | All-time database of every combat event |
| `db\gear.jsonl` | The gear you had on, matched to those events |
| `db\saves\` | Party saves, one file per cleared session |
| `mobparser_snapshot_*.json` | Files written by **Save export** or `/mobparser export` |
| `debug_log.txt` | Only written while `/mobparser debug on` is set |

- **To reset everything:** unload the addon, then delete the `db` folder.
- **To remove a party save:** delete its file in `db\saves\`.
- **To update mobparser:** replace the `.lua` files and leave `db\` alone. Your history carries over.

---

## Troubleshooting

- **The window doesn't open:** type `/mobparser gui`. If the GUI hit repeated errors, it turns itself off, and `/mobparser gui` turns it back on.
- **Ctrl+M does nothing:** another addon may already use it. Pick another key with `/mobparser bind <key>`.
- **All time looks empty:** it loads over a few seconds. `/mobparser status` shows whether it's still loading.
- **Something looks wrong in the numbers:** turn on `/mobparser debug on`, reproduce it, and include `debug_log.txt` and the party save from `db\saves\` with your report.

---

## License

MIT. See [LICENSE](LICENSE).

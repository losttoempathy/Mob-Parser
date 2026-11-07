--[[
mobparser.lua -- Ashita v4 addon entry point.

STATUS (2026-07-28, SCOPE PIVOT): mobparser is now a capture/export
tool, not a stat-estimation tool -- see mobparser_PROJECT.md's "SCOPE
PIVOT" section for the full user-directed change. This file wires in
export_log.lua (the real data pipeline: gear-stamped events, JSON
export, wipe, and save-to-master-and-wipe) alongside the existing
capture layer (combat_router, dlac_listener) and the still-useful
debug_log.lua diagnostic.

Capture-layer status (packet parsing, offense/defense classification,
dlac gear tracking) is real, live-tested, and working against real
CatsEyeXI/dlac data -- see the project file's live-test-results
sections for exactly what's confirmed. Export-layer status
(json_encode/json_decode/export_log) is offline-tested only (179+
checks across the whole project as of this write) -- the slash commands
below that trigger export/wipe/save are UNTESTED IN-GAME, same caveat
as every other `*.ashita.*`-facing piece before its first live test.
Ashita's `command` event registration pattern used below is written
against the generally-documented Ashita v4 SDK surface, not verified
against a live client by this project specifically -- treat the first
`/mobparser` command actually run in-game as a real test, not an
assumed-working feature.

Still unverified from before the pivot (unaffected by it):
  1. packet_action.lua's field layout -- CONFIRMED for melee category 1
     via live-test cross-check against Metrics (see project file).
  2. combat_router.ashita.*'s entity-index bound (MAX_ENTITY_INDEX) --
     still unverified but has worked correctly in every live test so
     far via a confirmed-safe fallback.
  3. dlac_listener transport -- CONFIRMED working via live test (see
     project file's dlac live-test-results sections). Gear-tag TIMING
     correctness -- CONFIRMED for both single-slot and multi-slot
     mid-fight swaps via live test.
Category expansion beyond melee (abilities, resting, healing, magic --
the actual "capture EVERYTHING" goal) is NOT YET DONE -- see project
file "Open work under the new scope" item 2. This file currently only
captures melee (combat_router.V1_SCOPED_CATEGORIES), same as before the
pivot; the pivot changes WHERE captured data goes (export_log.lua's
JSON, not just debug_log.lua's diagnostic text) and the eventual GOAL
(capture everything), not yet what gets captured.

TEMPORARY TESTING DEFAULT REMAINING BELOW: debug log output path
(debugLogPath, computed from addon.path) -- see debug_log.lua for its
own retirement status.
]]

addon.name    = 'mobparser';
addon.author  = 'mobparser project';
addon.version = '0.3.0-capture-export-pivot';
addon.desc    = 'Combat/action capture and JSON export tool. See file header for scope-pivot status and what remains unverified.';

-- NOTE (2026-07-28, corrected after first real /addon load attempt):
-- the ORIGINAL version of this comment claimed the "module 'classify'
-- not found" error was caused by package.path missing the addon's own
-- folder, and that this extension fixed it. THAT WAS WRONG -- the real
-- error log showed Ashita's default search list already includes
-- `\addons\mobparser\classify.lua` natively; the actual root cause was
-- simply that classify.lua (and every other sibling module) had never
-- been copied into the live addon folder at all -- they only existed
-- as chat outputs, never actually placed on disk alongside
-- mobparser.lua. Confirmed directly by the user checking the folder.
-- Real fix: copy every non-test .lua file (chatlog, classify,
-- combat_router, debug_log, formula, mobparser, packet_action,
-- packets_bitreader, unknownlog) into the actual addon folder.
-- This package.path extension is being LEFT IN regardless -- it's
-- harmless (redundant with Ashita's own default search path, not
-- wrong) and cheap insurance in case a different install/Ashita
-- version ever needs it -- but it was never the fix for THIS error,
-- and claiming it was would have been misleading. Lesson: an error
-- message can look like it confirms a hypothesis (both said
-- "not found") while actually pointing somewhere else entirely --
-- worth rereading the FULL search list next time, not just the first
-- line, before writing a fix.
if addon.path ~= nil then
    -- Same doubled-backslash issue as debug_log's path below (addon.path
    -- already ends in a trailing separator) -- fixed 2026-07-28 for
    -- consistency, though this specific line was already noted as
    -- non-load-bearing (Lua's package.path search tolerates redundant
    -- separators far better than a raw io.open call does).
    package.path = package.path .. ';' .. addon.path .. '?.lua';
end

require('common');

-- BUGFIX (2026-07-28, caught by SECOND real /addon load attempt --
-- addon now loads and gets past the require-chain issue from the
-- first attempt, confirming that fix/diagnosis; this is a genuinely
-- new, unrelated error): `chat.header(...)`/`chat.message(...)` calls
-- below failed with "attempt to index global 'chat' (a nil value)".
-- `chat` is NOT an ambient global the way `print` is -- it's a real
-- Ashita library module that must be explicitly required, confirmed
-- via real addon source (m4thmatic/hticks: `local chat =
-- require('chat');`, alongside its own `require('common')` and other
-- explicit requires). This project's earlier code had been assuming
-- `chat` was ambient, same category of mistake as assuming
-- sibling-module requires would just resolve -- neither offline test
-- could have caught this, since no test file exercises mobparser.lua's
-- load event handler at all (nothing in the offline harness simulates
-- Ashita's real global environment for `chat`, `ashita.events`, etc).
local chat = require('chat');

local combat_router = require('combat_router');
local debug_log     = require('debug_log');
local dlac_listener = require('dlac_listener');
local export_log    = require('export_log');
local mobparser_settings = require('mobparser_settings');
-- (2026-11-07) Tell perfmon this addon's memory grows on purpose: the running
-- session keeps every event (wiped on zone, capped at 50k events, ~65 MB worst
-- case). perfmon shows it as "expected" and only flags it past 80 MB.
-- pcall'd so mobparser runs fine without perf.lua installed.
pcall(function () require('perf').expect_growth('session log, cleared on zone, capped at 50k events', 81920); end);
-- (2026-11-07) GUI window key, default Ctrl+M. pcall so a failure here
-- never stops capture from loading.
local kbOk, mobparser_keybind = pcall(require, 'mobparser_keybind');
if not kbOk then mobparser_keybind = nil; end
-- All-time database (2026-10-30): every recorded event is also appended to
-- <addon>\db\events.jsonl. pcall'd so a missing/broken module never stops
-- capture.
local dbOk, alltime_db = pcall(require, 'alltime_db');
if not dbOk then
    print(chat.header('mobparser') .. chat.message(
        'all-time database module failed to load (non-fatal): ' .. tostring(alltime_db)));
    alltime_db = nil;
end
-- Party saves (2026-10-31): a snapshot of the session is written to
-- <addon>\db\saves\ every time it is cleared (zone, Clear data, wipe,
-- unload). pcall'd like the database -- never stops capture.
local psOk, party_saves = pcall(require, 'party_saves');
if not psOk then
    print(chat.header('mobparser') .. chat.message(
        'party saves module failed to load (non-fatal): ' .. tostring(party_saves)));
    party_saves = nil;
end

-- Snapshot the running session into a party save, then wipe it. Every
-- path that clears the session goes through here. Returns the save's
-- meta (nil if the session was empty or saves are unavailable).
local function saveAndWipe(reason)
    local meta = nil;
    if party_saves ~= nil and export_log.snapshot ~= nil then
        local ok, res = pcall(party_saves.capture, export_log.snapshot(), reason);
        if ok then meta = res;
        else print(chat.header('mobparser') .. chat.message('party save failed (non-fatal): ' .. tostring(res))); end
    end
    export_log.wipe();
    return meta;
end
-- REMOVED (2026-10-29): mobparser_probe (the /check + /checkparam
-- packet-sending probe, T1 on CatsEyeXI). Retired at user request on
-- moving to AscensionXI: mobstats is retired (dlac covers its stat
-- display), so nothing consumes the probe's acc/accAux any more, and
-- dropping it keeps mobparser strictly read-only -- it sends the server
-- nothing. Every call site below was removed with it; history for the
-- probe design lives in the project archive.

-- In-game stat display window (2026-07-30, T2 Information Display per
-- ServerRules.txt -- read-only, sends nothing to the server). Wrapped
-- in pcall at load time the same way dlac_listener's own setup is (see
-- the `load` handler below) -- a GUI failure must not stop combat
-- capture, which does not depend on this module at all.
local guiOk, mobparser_gui = pcall(require, 'mobparser_gui');
if not guiOk then
    print(chat.header('mobparser') .. chat.message(
        'GUI module failed to load (non-fatal -- capture/export still ' ..
        'works without it): ' .. tostring(mobparser_gui)));
    mobparser_gui = nil;
end

-- Session state for the dlac gear-tracking listener (2026-07-28, first
-- wiring-in). This is NOT started/registered until the `load` handler
-- below actually calls dlac_listener.ashita.register(dlacState) --
-- creating the state table here is cheap and side-effect-free (no
-- Ashita calls), matching this project's pattern of keeping
-- construction separate from registration (see combat_router.lua's own
-- route() vs. handlePacket() split). If dlac_listener.lua is ever
-- absent (addon not installed, require fails) this whole file should
-- still load and mobparser should still work WITHOUT gear tagging --
-- per the project's stated one-way, no-load-dependency relationship
-- with its data sources. NOT YET GUARDED that way -- see load handler
-- comment below for why this is flagged, not silently assumed safe.
local dlacState = dlac_listener.newState();

-- ---------------------------------------------------------------------------
-- Error throttle (2026-10-30, perf). The per-frame (d3d_present) and
-- per-packet handlers used to print EVERY error to chat -- a GUI or
-- database error that repeats prints ~60 lines a second, which alone can
-- tank FPS. Now: each distinct message prints once; repeats are counted
-- and summarised at most every ERROR_REPEAT_SECONDS.
-- ---------------------------------------------------------------------------
local ERROR_REPEAT_SECONDS = 10;
local errorSeen = {}; -- message -> { suppressed = n, lastPrint = t }
local errorSeenCount = 0;

local function reportError(prefix, err)
    local msg = prefix .. tostring(err);
    local now = os.clock();
    local s = errorSeen[msg];
    if s == nil then
        errorSeenCount = errorSeenCount + 1;
        if errorSeenCount > 200 then errorSeen = {}; errorSeenCount = 1; end -- bound memory
        errorSeen[msg] = { suppressed = 0, lastPrint = now };
        print(chat.header('mobparser') .. chat.message(msg));
        return;
    end
    s.suppressed = s.suppressed + 1;
    if (now - s.lastPrint) >= ERROR_REPEAT_SECONDS then
        print(chat.header('mobparser') .. chat.message(string.format(
            '%s (repeated %d more time(s))', msg, s.suppressed)));
        s.suppressed = 0;
        s.lastPrint = now;
    end
end

-- GUI is switched off after this many render errors in a row, so a broken
-- window can't keep costing frames. /mobparser gui turns it back on.
local GUI_MAX_CONSECUTIVE_ERRORS = 5;
local guiErrorStreak = 0;
local guiSuspended = false;

ashita.events.register('load', 'mobparser_load', function()
    mobparser_settings.load();

    -- (2026-10-29) probeEnabled / autoRefreshEnabled restore removed
    -- with the probe. An old settings file may still carry those keys;
    -- mobparser_settings.load() keeps them as inert scalars and nothing
    -- reads them.

    -- DIAGNOSTIC (2026-07-29, added before this was ever tested):
    -- mobparser_settings.load() returning cleanly looks IDENTICAL
    -- whether AshitaCore:GetInstallPath() worked and just found no
    -- settings file yet (normal first run), or GetInstallPath() itself
    -- failed/returned nil and installDir() bailed out early -- both
    -- print the same thing with no visible difference. Same trap
    -- already documented once in this file for addon.path/debug_log --
    -- print the actual resolved path directly rather than inferring it
    -- indirectly from later save/load behavior.
    -- (2026-10-30) The three load-time DIAGNOSTIC prints (settings path,
    -- addon.path, addon.name) were removed from chat -- they now print
    -- only when the player runs `/mobparser debug on` (see printPaths).

    -- DIAGNOSTIC (2026-07-28, added preemptively after the SECOND
    -- consecutive silent debug_log.txt failure, before waiting for a
    -- third): rather than guess again at where files are landing,
    -- print the raw values this whole path saga has been built on top
    -- of, so the NEXT attempt produces real data instead of another
    -- assumption. `addon.path` is the value the current debug_log fix
    -- depends on entirely -- if IT'S wrong/nil/unexpected, that
    -- explains everything downstream without needing to guess further.
    -- `ashita.fs.get_ashita_install_path()`-equivalent isn't called
    -- here since that specific API surface was never confirmed this
    -- session (would be a THIRD assumption stacked on the first two) --
    -- deliberately limited to values already in scope/already used,
    -- not reaching for new unverified API calls to diagnose a problem
    -- caused by unverified API assumptions in the first place.

    -- BUGFIX (2026-07-28, caught after TWO clean-combat test runs
    -- produced no log file at all -- not even a created-but-empty
    -- folder): the relative path 'config/addons/mobparser/...' never
    -- resolved anywhere -- confirmed by the user directly checking
    -- Ashita/config/addons and finding nothing, not even the directory
    -- our own debug_log.lua mkdir fix should have created. Real addon
    -- examples researched this session (onimitch/minimapcontrol,
    -- ThornyFFXI/tCrossBar, GetAwayCoxn's LuAshitacast profiles) DO
    -- confirm Ashita/config/addons/<name>/ is a real, conventional
    -- location other addons use -- but every one of them writes there
    -- through Ashita's own `ashita.settings` API, not raw io.open()
    -- with a bare relative path. That strongly suggests a relative
    -- path like the one used here doesn't resolve against the Ashita
    -- folder at all (most likely the game process's own working
    -- directory instead, which is a different location entirely) --
    -- this was an unverified assumption from the start, not something
    -- actually confirmed against real Ashita behavior, and it was
    -- wrong. Fixed by building an ABSOLUTE path from `addon.path`
    -- (already confirmed real, already used elsewhere in this file)
    -- and writing into the addon's own installed folder instead of
    -- guessing at config/'s location -- less conventional than the
    -- real config/addons/ pattern other addons use, but addon.path is
    -- the one path source in this whole file that's actually confirmed
    -- to resolve correctly (the require-chain fix earlier this session
    -- proved it works). Revisit using the real ashita.settings API
    -- properly, or confirming config/addons/'s real resolution, once
    -- past this immediate testing need -- this is scaffolding, not the
    -- final answer.
    -- BUGFIX (2026-07-28, caught by first real in-game load -- user's
    -- own diagnostic output showed addon.path ALREADY ends in a
    -- trailing backslash: "...Ashita\addons\mobparser\", not
    -- "...mobparser"). The previous version of this line unconditionally
    -- appended '\\debug_log.txt', producing a doubled separator
    -- ("...mobparser\\debug_log.txt"). Confirmed harmless on its own --
    -- Windows path APIs and io.open collapse a redundant mid-path
    -- backslash fine, this is NOT the same thing as a leading UNC-style
    -- "\\\\server\\share" prefix -- but it was still wrong and worth
    -- fixing outright rather than leaving an unexplained cosmetic bug
    -- in a path used for diagnostics. NOT, on its own, a sufficient
    -- explanation for a missing debug_log.txt -- see the load message
    -- itself, which never showed debug_log.lua's own one-time
    -- write-failure warning either. That warning firing would mean
    -- record() was CALLED and failed; it never firing points at
    -- record() never being called in the first place (no 0x028 traffic
    -- reached handlePacket yet, or something upstream errored silently
    -- despite the pcall wrapper) -- check for combat having actually
    -- happened after load, and check chat for ANY
    -- "packet handler error" message from the packet_in handler below,
    -- before assuming this path fix alone resolves the missing file.
    local debugLogPath = (addon.path or '.\\') .. 'debug_log.txt';
    debug_log.setOutputPath(debugLogPath);

    -- dlac gear-tracking listener (2026-07-28, first wiring-in for the
    -- live-test verification step). Per integration-guide.md §2.6:
    -- "you do not get an automatic greeting" -- ask once at load, and
    -- tolerate no reply (the stream may be off, or dlac may not be
    -- installed/loaded at all -- both are normal, not errors). Per
    -- §2.1: the player must separately type `/dl stream on` for
    -- anything to arrive at all -- mobparser cannot turn this on, and
    -- silence is a configuration state, not a bug. Wrapped in the same
    -- pcall discipline as combat_router.handlePacket's own packet_in
    -- registration below -- dlac_listener.ashita.register/askWorn are
    -- UNTESTED IN-GAME (same caveat as combat_router.ashita.* and
    -- unknownlog.ashita.* were before their own first live tests), and
    -- a failure here must not prevent the rest of mobparser (the
    -- primary combat-parsing pipeline, which does not depend on dlac at
    -- all) from loading and working.
    local dlacOk, dlacErr = pcall(function()
        dlac_listener.ashita.register(dlacState);
        dlac_listener.ashita.askWorn();
    end);
    if not dlacOk then
        print(chat.header('mobparser') .. chat.message(
            'dlac_listener setup failed (non-fatal -- combat parsing ' ..
            'still works without gear tagging): ' .. tostring(dlacErr)));
    end

    -- All-time database (2026-10-30). Injected into export_log so its own
    -- offline tests don't need it.
    if alltime_db ~= nil then
        local okDb, dbErr = pcall(alltime_db.init, (addon.path or '.\\') .. 'db\\');
        if okDb then
            export_log.setPersist(alltime_db);
        else
            print(chat.header('mobparser') .. chat.message(
                'all-time database init failed (non-fatal): ' .. tostring(dbErr)));
        end
    end

    -- Party saves (2026-10-31): db\saves\ (db\ created first in case
    -- create_directory doesn't make nested folders).
    if party_saves ~= nil then
        local base = (addon.path or '.\\') .. 'db\\';
        local okPs, psErr = pcall(party_saves.init, base .. 'saves\\', base);
        if not okPs then
            print(chat.header('mobparser') .. chat.message(
                'party saves init failed (non-fatal): ' .. tostring(psErr)));
        end
    end

    -- (2026-10-30) One short line instead of the long path dump. The
    -- paths are still available via `/mobparser debug on` and
    -- `/mobparser status`.
    -- (2026-11-07) Window key (default Ctrl+M; dlac has Ctrl+K, Nexus
    -- Ctrl+Z). Only speaks up if the key couldn't be bound.
    if mobparser_keybind ~= nil then
        local okB, bindOk, bindMsg = pcall(mobparser_keybind.apply,
            mobparser_settings.data.keybind or mobparser_keybind.DEFAULT);
        if not okB then
            print(chat.header('mobparser') .. chat.message('window key failed: ' .. tostring(bindOk)));
        elseif not bindOk then
            print(chat.header('mobparser') .. chat.message(tostring(bindMsg)));
        end
    end

    print(chat.header('mobparser') .. chat.message('loaded -- /mobparser help'));
end);

ashita.events.register('packet_in', 'mobparser_packet_in', function(e)
    -- combat_router.ashita.* is now real, not a guaranteed-error stub --
    -- still wrapped in pcall since packet_action.lua's field-layout
    -- correctness against real CatsEyeXI bytes is exactly what this
    -- first test is trying to determine; an error here is real,
    -- useful information, not an expected/designed outcome anymore.
    --
    -- dlacState is now passed through (2026-07-28) so combat_router can
    -- tag each debug_log line with a gear signature -- see
    -- combat_router.lua's own buildGearTag comment for what this does
    -- and does not verify yet. Passing dlacState here does NOT create a
    -- new dependency on dlac being present/loaded: dlacState is always
    -- a valid (possibly empty) table from dlac_listener.newState()
    -- regardless of whether dlac itself is installed, streaming, or
    -- even running -- combat_router.buildGearTag's own nil-checks
    -- handle "nothing received yet" the same way whether that's because
    -- dlac isn't installed or just hasn't sent anything yet this
    -- session (per the guide, both look identical from mobparser's side
    -- -- silence either way -- which is exactly why the design doesn't
    -- try to tell them apart).
    local ok, err = pcall(combat_router.handlePacket, e.id, e.data, dlacState);
    if not ok then
        -- (2026-10-30) throttled -- see reportError
        reportError('packet handler error (note what triggered it): ', err);
    end

    -- Clear on zone (2026-10-30, user setting, on by default): 0x00A is
    -- the incoming zone-in packet (the same ID the removed probe used for
    -- its zone-change reset). Wipes only the in-memory session -- the
    -- all-time database already has every event. Silent, no chat line.
    if e.id == 0x00A then
        -- (2026-10-30, perf) entity indexes are per zone: drop the cache.
        -- Always, whatever the Clear-on-zone setting.
        pcall(combat_router.onZone);
        if mobparser_settings.data.clearOnZone ~= false then
            saveAndWipe('zone'); -- (2026-10-31) party save first
        end
    end

    -- (2026-10-29) The probe's packet branches that used to follow here
    -- -- zone-change reset (0x00A/0x00B), auto-refresh on own status
    -- change (0x037), and /check + /checkparam reply parsing / blocking /
    -- 'check' event stamping (0x029) -- were removed with the probe.
    -- mobparser no longer blocks or alters any incoming packet.
end);

-- ===========================================================================
-- Slash commands -- exposes export_log.lua's three lifecycle operations
-- (2026-07-28, scope pivot). UNTESTED IN-GAME -- Ashita v4's `command`
-- event registration pattern used below is written against the
-- generally-documented SDK surface (ashita.events.register('command',
-- name, function(e) ... e.command, e.injected ... end), matching the
-- shape 'load'/'packet_in'/'unload' already use elsewhere in this
-- file), NOT independently re-derived from Ashita's own SDK header
-- source this session, and NOT yet run against a live client -- same
-- caveat as every other *.ashita.* surface in this project before its
-- first live test. Treat the first real `/mobparser` command as a
-- genuine test of this registration working at all, not an assumption.
--
-- `e.injected` (true if the command came from another addon/script
-- rather than the player's own chat input) is checked and IGNORED here
-- deliberately -- these are player-facing session-management commands
-- (export/wipe/save data), not something another addon should be able
-- to trigger unasked. If this needs revisiting (e.g. a future
-- companion addon wanting to trigger a save programmatically), that's
-- a new decision, not an oversight to silently work around.
-- ===========================================================================
-- ---------------------------------------------------------------------------
-- Shared export / wipe actions (2026-10-29). Used by both the slash
-- commands below and the GUI's 'Save export' / 'Clear data' buttons, so
-- the two paths can never drift apart. Each returns ok, message.
-- ---------------------------------------------------------------------------
local function doExport()
    -- Pure snapshot -- per export_log.exportSession's own contract,
    -- does NOT wipe or touch the master file. Written to a SEPARATE,
    -- timestamped file (not the master file) so repeated exports don't
    -- collide with each other or with the master-file workflow.
    local json = export_log.exportSession();
    local snapshotPath = (addon.path or '.\\') ..
        'mobparser_snapshot_' .. os.date('%Y%m%d_%H%M%S') .. '.json';
    local file, openErr = io.open(snapshotPath, 'w');
    if file == nil then
        return false, 'export failed -- could not open "' .. snapshotPath .. '": ' .. tostring(openErr);
    end
    file:write(json);
    file:close();
    local eventCount = export_log.stats();
    return true, string.format(
        'exported %d event(s) to %s (running session NOT wiped).',
        eventCount, snapshotPath);
end

local function doWipe()
    local eventCount, gearStateCount = export_log.stats();
    local meta = saveAndWipe('clear'); -- (2026-10-31) party save first
    return true, string.format(
        'wiped running session (%d event(s), %d gear state(s))%s.',
        eventCount, gearStateCount,
        meta and (' -- kept as party save ' .. meta.file) or '');
end

if mobparser_gui ~= nil and mobparser_gui.setActions ~= nil then
    mobparser_gui.setActions({ export = doExport, wipe = doWipe });
end

ashita.events.register('command', 'mobparser_command', function(e)
    local args = {};
    for word in e.command:gmatch('%S+') do
        table.insert(args, word);
    end
    if args[1] ~= '/mobparser' then
        return;
    end
    -- (2026-11-07) `/mobparser toggle` is what the window key sends. It
    -- only shows/hides the window, so it is let through even if Ashita
    -- marks a keybind-issued command as injected; everything else stays
    -- player-only (see comment above).
    if e.injected and args[2] ~= 'toggle' then
        return; -- see comment above -- player-facing commands only
    end
    e.blocked = true; -- consume the command, don't let it fall through to the game client

    local sub = args[2];

    if sub == 'wipe' then
        local _, msg = doWipe();
        print(chat.header('mobparser') .. chat.message(msg));

    elseif sub == 'status' then
        local eventCount, gearStateCount = export_log.stats();
        print(chat.header('mobparser') .. chat.message(string.format(
            'running session: %d event(s)%s, %d gear state(s). Clear on zone: %s. Debug log: %s',
            eventCount,
            (export_log.trimmed ~= nil and export_log.trimmed() > 0)
                and string.format(' (%d oldest trimmed, still in database)', export_log.trimmed()) or '',
            gearStateCount,
            (mobparser_settings.data.clearOnZone ~= false) and 'on' or 'off',
            debug_log.isEnabled() and 'on' or 'off')));
        if alltime_db ~= nil then
            local st = alltime_db.status();
            print(chat.header('mobparser') .. chat.message(string.format(
                'database: %s, %d written this session, %d gear state(s), %d pending write(s), %d bad line(s) skipped%s. Folder: %s%s%s',
                st.loaded and (tostring(st.events) .. ' event(s) loaded')
                    or (st.loading and 'loading all time...' or 'events not loaded yet (click All time)'),
                st.writtenThisSession, st.gearStates, st.pending, st.badLines,
                ((st.dropped or 0) > 0) and string.format(', %d UNWRITTEN line(s) dropped (writes failing)', st.dropped) or '',
                tostring(st.dir),
                st.lastError and ('. Last error: ' .. st.lastError) or '',
                export_log.persistError() and ('. Record error: ' .. export_log.persistError()) or '')));
        end
        if party_saves ~= nil then
            local ps = party_saves.status();
            print(chat.header('mobparser') .. chat.message(string.format(
                'party saves: %d on disk, %d being written. Folder: %s%s',
                ps.saves, ps.pending, tostring(ps.dir),
                ps.lastError and ('. Last error: ' .. ps.lastError) or '')));
        end

    elseif sub == 'export' then
        -- See doExport() above (shared with the GUI 'Save export' button).
        local _, msg = doExport();
        print(chat.header('mobparser') .. chat.message(msg));

    -- REMOVED (2026-10-30, at Brad's request): `/mobparser save`. It read,
    -- decoded and rewrote the whole mobparser_export.json on the game thread
    -- (a freeze that grew with the file), and the all-time database (db\)
    -- plus `/mobparser export` now cover what it did. `/mobparser save` now
    -- just shows the usage line. An existing mobparser_export.json is left
    -- on disk untouched.

    elseif sub == 'report' then
        -- 2026-10-29: print the Player view to chat. /mobparser report
        -- [say|party|linkshell|s|p|l]; no argument = the Settings choice.
        if mobparser_gui == nil then
            print(chat.header('mobparser') .. chat.message('report unavailable -- GUI module failed to load.'));
        else
            local _, msg = mobparser_gui.report(args[3]);
            print(chat.header('mobparser') .. chat.message(msg));
        end

    elseif sub == 'debug' then
        -- (2026-10-30) Session-only toggle for debug_log.txt. Off on
        -- every load; never wipes the existing file (it only appends).
        local arg = args[3];
        local on;
        if arg == 'on' then on = true;
        elseif arg == 'off' then on = false;
        else on = not debug_log.isEnabled(); end
        debug_log.setEnabled(on);
        if on then
            print(chat.header('mobparser') .. chat.message(
                'debug log ON (until reload) -- appending to ' ..
                tostring(debug_log.settings.outputPath)));
            -- The former load-time diagnostics, shown on demand only.
            print(chat.header('mobparser') .. chat.message(
                'settings file: ' .. tostring(mobparser_settings.path()) ..
                ' | addon.path: ' .. tostring(addon.path)));
        else
            print(chat.header('mobparser') .. chat.message('debug log OFF.'));
        end

    elseif sub == 'gui' then
        -- Toggles the live stat-table window (mobparser_gui.lua,
        -- 2026-07-30). No-op with a clear message if the module failed
        -- to load, rather than a raw "attempt to index nil" error.
        if mobparser_gui == nil then
            print(chat.header('mobparser') .. chat.message(
                'GUI unavailable (failed to load at /addon load time -- check the ' ..
                'earlier chat message for the error).'));
        elseif guiSuspended then
            -- (2026-10-30) turned off after repeated render errors -- retry
            guiSuspended = false;
            guiErrorStreak = 0;
            print(chat.header('mobparser') .. chat.message('GUI turned back on.'));
        else
            mobparser_gui.toggle();
            print(chat.header('mobparser') .. chat.message(
                'GUI window ' .. (mobparser_gui.isVisible() and 'shown.' or 'hidden.')));
        end

    elseif sub == 'toggle' then
        -- (2026-11-07) Sent by the window key: same as `gui` but silent,
        -- so pressing the key doesn't print to chat every time.
        if mobparser_gui ~= nil then
            if guiSuspended then
                guiSuspended = false;
                guiErrorStreak = 0;
            else
                mobparser_gui.toggle();
            end
        end

    elseif sub == 'bind' then
        -- (2026-11-07) /mobparser bind <key> -- e.g. ^m (Ctrl+M), !p (Alt+P),
        -- or none. No argument puts back the default (Ctrl+M).
        if mobparser_keybind == nil then
            print(chat.header('mobparser') .. chat.message('window key unavailable (keybind module failed to load).'));
        else
            local spec = args[3] or mobparser_keybind.DEFAULT;
            local ok, msg = mobparser_keybind.apply(spec);
            print(chat.header('mobparser') .. chat.message(tostring(msg)));
            if ok then
                mobparser_settings.data.keybind = spec;
                mobparser_settings.save();
            end
        end

    else
        -- Also covers `/mobparser help`.
        print(chat.header('mobparser') .. chat.message(
            'usage: /mobparser export | wipe | status | gui | report [say|party|linkshell] | debug [on|off] | bind <key>'));
        print(chat.header('mobparser') .. chat.message(
            'window key: ' .. ((mobparser_keybind ~= nil and mobparser_keybind.current() ~= nil)
                and mobparser_keybind.describe(mobparser_keybind.current()) or 'none') ..
            ' -- change with /mobparser bind <key>, e.g. ^m (Ctrl+M), !p (Alt+P), or none'));
    end
end);

-- ===========================================================================
-- Per-frame hook: flushes the all-time database and renders the GUI.
-- ===========================================================================
ashita.events.register('d3d_present', 'mobparser_present', function()
    if alltime_db ~= nil then
        local okT, errT = pcall(alltime_db.tick);
        if not okT then
            reportError('database flush error: ', errT); -- throttled (2026-10-30)
        end
    end
    -- (2026-10-31) party saves: writes queued saves / loads a picked one,
    -- a slice per frame.
    if party_saves ~= nil then
        local okP, errP = pcall(party_saves.tick, (export_log.stats()));
        if not okP then
            reportError('party save error: ', errP);
        end
    end

    -- GUI render (2026-07-30). pcall-guarded per frame -- an error
    -- inside imgui drawing must not take down the database flush
    -- above, which has already run by this point regardless. Only calls .render() when the module actually
    -- loaded (mobparser_gui ~= nil, see the pcall(require, ...) guard
    -- near the top of this file).
    if mobparser_gui ~= nil and not guiSuspended then
        local rOk, rErr = pcall(mobparser_gui.render);
        if not rOk then
            reportError('GUI render error: ', rErr); -- throttled (2026-10-30)
            guiErrorStreak = guiErrorStreak + 1;
            if guiErrorStreak >= GUI_MAX_CONSECUTIVE_ERRORS then
                guiSuspended = true;
                print(chat.header('mobparser') .. chat.message(string.format(
                    'GUI turned off after %d errors in a row (capture keeps running). ' ..
                    '/mobparser gui to try again.', guiErrorStreak)));
            end
        else
            guiErrorStreak = 0;
        end
    end
end);

ashita.events.register('unload', 'mobparser_unload', function()
    -- (2026-11-07) remove the window key, only if mobparser made it.
    if mobparser_keybind ~= nil then pcall(mobparser_keybind.release); end
    if alltime_db ~= nil then pcall(alltime_db.flush); end
    -- (2026-10-31) the session is discarded on unload too: save it, and
    -- write everything still queued now.
    if party_saves ~= nil then
        pcall(party_saves.capture, export_log.snapshot(), 'unload');
        pcall(party_saves.finishAll);
    end
    print(chat.header('mobparser') .. chat.message('unloaded.'));
end);

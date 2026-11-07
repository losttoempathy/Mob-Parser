--[[
mobparser.lua -- Ashita v4 addon entry point.

Read-only combat capture for FFXI (AscensionXI / CatsEyeXI). Parses
incoming action packets (0x028) for you, your party and pets, tags each
event with your worn gear (client memory, dlac as fallback), and keeps:
  - the running session (export_log.lua), shown in the GUI
  - the all-time database, db\events.jsonl (alltime_db.lua)
  - a party save of each cleared session, db\saves\ (party_saves.lua)
Sends nothing to the server and never blocks or edits a packet.

Commands: /mobparser help.
]]

addon.name    = 'mobparser';
addon.author  = 'mobparser project';
addon.version = '0.3.0-capture-export-pivot';
addon.desc    = 'Read-only combat capture, all-time database and party saves, with an in-game GUI.';

-- Redundant with Ashita's own search path; kept as cheap insurance.
if addon.path ~= nil then
    package.path = package.path .. ';' .. addon.path .. '?.lua';
end

require('common');

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
-- (The /check packet probe was removed 2026-10-29: mobparser sends the
-- server nothing.)

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

-- dlac gear-listener state. Registered in the load handler below.
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

    -- debug_log.txt lives in the addon folder (addon.path ends in a
    -- separator). Only written while `/mobparser debug on`.
    local debugLogPath = (addon.path or '.\\') .. 'debug_log.txt';
    debug_log.setOutputPath(debugLogPath);

    -- dlac gear stream: ask once for the worn set and tolerate silence
    -- (dlac not loaded, or `/dl stream on` not set). A failure here never
    -- stops combat capture.
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
    -- dlacState is always a valid (possibly empty) table, so gear tagging
    -- works the same whether or not dlac is installed or streaming.
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

    -- mobparser never blocks or alters an incoming packet.
end);

-- ===========================================================================
-- Slash commands. Commands injected by other addons/scripts are ignored
-- (player-only), except `toggle`, which the window key sends.
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

    -- (`/mobparser save` was removed 2026-10-30: the all-time database and
    -- `/mobparser export` replace it.)

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

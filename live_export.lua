--[[
mobparser -- live_export.lua

Writes export_log's current in-memory session to a fixed, well-known
file path on disk, on a throttle, WITHOUT wiping or otherwise touching
running session state. Purely additive to export_log.lua's existing
three operations (exportSession/wipe/saveToMasterAndWipe) -- this is a
fourth, independent consumer of exportSession()'s snapshot, not a
modification to any of them.

## Why this exists

mobstats (separate addon, separate Lua state -- no shared runtime, no
cross-addon require) needs to read mobparser's captured combat data as
close to live as file-polling allows. exportSession() already returns
a snapshot as a JSON string; the only piece missing was something that
periodically PUTS that string on disk where a file-polling reader can
find it. See mobstats_PROJECT.md "Live-data roadmap" (mobstats side)
for the read side of this contract.

## Design

- **Throttled by event count, not wall-clock.** Writes only when
  export_log.stats() reports the event count has changed since the
  last write -- an idle session (no combat happening) costs zero disk
  I/O, not one write every N ms regardless of activity. This matters
  because d3d_present-driven callers (mobparser's own load hook) fire
  every rendered frame; checking the event count is cheap (no
  encode/write), so the actual expensive work (json_encode + io.write)
  only happens when there's genuinely new data.
- **250ms minimum interval even when the count DID change**, so a fast
  burst of swings (multiple events within one frame or a few frames)
  coalesces into one write rather than one per event. This is the
  "live but bounded" balance: at most 4 writes/sec, matching mobstats'
  poll rate on the read side (see mobstats' live_reader.lua) -- writing
  faster than the reader polls would just mean wasted I/O for data
  nobody reads any sooner.
- **Does not wipe.** Calls export_log.exportSession() only, never
  export_log.wipe() or saveToMasterAndWipe(). Running session memory
  keeps accumulating exactly as it does today; this module is a
  read-only tap on that state from mobparser's own side.
- **Path is fixed, not configurable (v1 scope).** Lives at
  config/addons/mobparser/live_export.json, i.e. right alongside
  where mobparser's own settings/data already live. mobstats computes
  this same path independently (see its live_reader.lua) rather than
  either addon being told the other's path at runtime, since there's
  no channel to tell it anything -- both sides just agree on the
  convention.
]]

local export_log = require('export_log');

local live_export = {};

-- ===========================================================================
-- Config
-- ===========================================================================

-- Fixed relative path -- resolved against Ashita's install path exactly
-- the same way mobstats' live_reader.lua resolves it, so both sides
-- agree without either telling the other anything at runtime.
--
-- CHANGED (2026-07-30): was 'config\addons\mobparser\live_export.json'.
-- That path does not reliably exist -- mobparser.lua's own load-handler
-- comments document hitting this exact failure for debug_log.txt
-- (silent io.open failure, no directory ever created, config/addons/
-- entry never appeared even after real combat) and deliberately moved
-- debugLogPath/masterExportPath to addon.path-relative locations
-- instead, since addon.path is the one path source confirmed to
-- resolve correctly in this codebase. 'addons\mobparser\' (the actual
-- installed-addon folder, not the config folder) is structurally
-- guaranteed to exist any time this code is even running -- Ashita
-- loaded this file FROM that folder -- so no directory-creation step
-- is needed, unlike the config/ path this replaces.
local LIVE_EXPORT_RELATIVE_PATH = 'addons\\mobparser\\live_export.json';

-- Minimum milliseconds between writes, even if the event count changed
-- every frame in between. Matches mobstats' poll interval -- writing
-- faster than that would burn I/O for no one.
local MIN_WRITE_INTERVAL_MS = 250;

-- ===========================================================================
-- State
-- ===========================================================================

local lastWrittenEventCount = -1;   -- -1 so the very first check always
                                     -- looks "changed" and writes once
                                     -- immediately, rather than waiting
                                     -- for a second event.
local lastWrittenSelfAt = -1;        -- same "-1 means always looks changed
                                      -- on first check" reasoning, for the
                                      -- selfStats.accAt+accAuxAt sum tick()
                                      -- watches (see tick()'s own comment).
local lastWriteTimeMs = 0;
local lastWriteError = nil;         -- last error string, if any, so a
                                     -- status command can surface it
                                     -- instead of failing silently forever

-- ===========================================================================
-- Path resolution
-- ===========================================================================

-- Resolves the full live-export path against Ashita's install root.
-- A function, not a computed-once local, in case AshitaCore isn't
-- available yet at require-time (load ordering) -- cheap to recompute
-- per call, and this is only called on actual write attempts (already
-- throttled), never per-frame.
local function resolveLiveExportPath()
    local ok, installPath = pcall(function()
        return AshitaCore:GetInstallPath();
    end);
    if not ok or installPath == nil then
        return nil, 'AshitaCore:GetInstallPath() unavailable';
    end
    -- Ashita's install path already ends in a separator in practice,
    -- but don't assume -- normalize defensively.
    local sep = installPath:sub(-1) == '\\' and '' or '\\';
    return installPath .. sep .. LIVE_EXPORT_RELATIVE_PATH;
end

-- ===========================================================================
-- Write
-- ===========================================================================

-- Writes the current session snapshot to the live-export path.
-- Returns true on success, or false + an error message on failure.
-- Failure here (e.g. directory doesn't exist, disk full, permissions)
-- is non-fatal to mobparser's own operation -- running session state
-- is untouched either way -- so callers should not treat this as a
-- reason to alter capture behavior, only to surface a warning.
local function writeSnapshot(selfStats)
    local path, pathErr = resolveLiveExportPath();
    if path == nil then
        return false, pathErr;
    end

    local ok, json = pcall(export_log.exportSession);
    if not ok then
        return false, 'export_log.exportSession() failed: ' .. tostring(json);
    end

    -- selfStats (2026-07-30): a STANDING snapshot of mobparser_probe's
    -- state.me, merged in as a top-level "selfStats" field alongside
    -- exportSession()'s own "events"/"gearStates" -- NOT folded into
    -- individual events. This is the fix for mobstats reading nil
    -- acc/accAux: previously the only place acc/accAux appeared in this
    -- JSON was riding along on the rare 'check'-kind event (one per
    -- target, only when a mob check fires), so a reader polling this
    -- file between checks saw nothing. mobstats' OWN probe (before the
    -- 2026-07-30 move to mobparser) worked as a standing "last known
    -- value" read every playerBlock() call, not an event-stamped one --
    -- this restores that same shape on mobparser's side, per user's
    -- explicit request to match mobstats' original probe behavior. A
    -- plain string-keyed table is spliced into the JSON text below
    -- rather than round-tripped through export_log's own encoder, since
    -- export_log has no concept of "self stats" and shouldn't need one
    -- just to support this addition -- keeps the one-way dependency
    -- (live_export depends on export_log, not the reverse) intact.
    if selfStats ~= nil then
        -- Deliberately NOT calling into export_log's own encoder here --
        -- its exact API surface (name, whether it handles a flat
        -- number/nil table the same way) isn't confirmed from this
        -- file, and guessing at it risks a silent breakage in the main
        -- events/gearStates path this whole module exists to protect.
        -- selfStats is always the same flat shape (acc/accAux/accAt/
        -- accAuxAt, all number-or-nil -- see mobparser.lua's call
        -- site), so a tiny local encoder scoped to exactly that shape
        -- is safer than reaching for a shared one.
        local function numOrNull(v)
            return (v == nil) and 'null' or tostring(v);
        end
        local ok2, selfJson = true, ('{"acc":%s,"accAux":%s,"accAt":%s,"accAuxAt":%s}'):format(
            numOrNull(selfStats.acc), numOrNull(selfStats.accAux),
            numOrNull(selfStats.accAt), numOrNull(selfStats.accAuxAt));
        if ok2 and selfJson ~= nil then
            -- json is a JSON OBJECT string starting '{' and ending '}'
            -- (exportSession's own contract -- events/gearStates are
            -- both keys of one top-level object). Splice a new key in
            -- just before the closing brace. If exportSession() ever
            -- returns something that doesn't end in '}' (a format
            -- change on export_log's side), this splice is skipped
            -- rather than producing corrupt JSON -- selfStats is a
            -- nice-to-have addition, not worth breaking the whole file
            -- over.
            local trimmed = json:gsub('%s+$', '');
            if trimmed:sub(-1) == '}' then
                json = trimmed:sub(1, -2) ..
                    (trimmed:sub(-2, -2) == '{' and '' or ',') ..
                    '"selfStats":' .. selfJson .. '}';
            end
        end
    end

    -- Write to a temp file in the SAME directory, then rename over the
    -- real path, rather than writing live_export.json directly. Plain
    -- io.open(path, 'w') truncates before writing, so a reader polling
    -- at 250ms can catch the file mid-write (partial/truncated JSON) --
    -- mobstats' live_reader.lua already tolerates that (skip a bad
    -- poll, keep last-good data, retry next tick), but avoiding the
    -- torn read in the first place is cheap and removes an entire
    -- class of "why did my data blip for one frame" reports.
    --
    -- BUGFIX (2026-07-30, caught on first real in-game test -- write
    -- #1 succeeded, every write after that failed with "could not
    -- rename"): the original comment here claimed rename is atomic and
    -- doesn't need special handling. True on POSIX, FALSE on Windows --
    -- Ashita only runs on Windows, and the Windows C runtime's
    -- rename() (what Lua's os.rename calls) FAILS if the destination
    -- already exists, unlike POSIX rename() which atomically replaces
    -- it. So the very first tick() succeeded (no live_export.json yet),
    -- and it failed every time after, since the file it needed to
    -- overwrite was now present. Fixed by removing any existing
    -- destination first. This reopens a tiny (sub-millisecond,
    -- filesystem-call-only) non-atomic window between the delete and
    -- the rename -- true atomic replace on Windows needs
    -- MoveFileEx+MOVEFILE_REPLACE_EXISTING, which isn't exposed
    -- through stock os.rename and isn't worth an FFI dependency for
    -- this -- but live_reader.lua already tolerates a failed/torn poll
    -- and just retries next tick, so this is an acceptable tradeoff,
    -- not a new class of problem.
    local tempPath = path .. '.tmp';

    local file, openErr = io.open(tempPath, 'w');
    if file == nil then
        -- Unlike the earlier config\addons\mobparser\ path this
        -- replaced, the addons\mobparser\ folder always exists by the
        -- time this code runs (Ashita loaded this very file from it),
        -- so a missing-directory failure here would be unexpected.
        -- More likely real causes: permissions, disk full, or the
        -- path being held open by another process. Not attempting to
        -- mkdir here -- out of scope for a file writer, and shouldn't
        -- be needed for this path.
        return false, 'could not open "' .. tempPath .. '" for writing: ' .. tostring(openErr);
    end
    file:write(json);
    file:close();

    -- os.remove() on a nonexistent file returns false + an error --
    -- that's the expected/normal case on the very first write ever
    -- (no live_export.json yet), so its result is deliberately not
    -- checked or treated as a failure. Only the rename below is a
    -- real failure signal.
    os.remove(path);

    local renameOk, renameErr = os.rename(tempPath, path);
    if not renameOk then
        return false, 'wrote temp file but could not rename to "' .. path .. '": ' .. tostring(renameErr);
    end
    return true;
end

-- ===========================================================================
-- Public: call this every frame (e.g. from a d3d_present hook). Cheap
-- to call when nothing has changed -- the expensive path (encode +
-- write) only runs when both the event count changed AND the throttle
-- window has elapsed.
-- ===========================================================================

-- selfStats (2026-07-30, optional): { acc, accAux, accAt, accAuxAt },
-- typically mobparser_probe.state.me passed straight through by the
-- caller (mobparser.lua). When provided, written into every snapshot
-- as a standing top-level "selfStats" field -- see writeSnapshot's own
-- comment for why this exists.
--
-- selfStats.accAt/accAuxAt (not just acc/accAux themselves) are also
-- watched for change below, alongside eventCount -- a buff/debuff
-- refresh (mobparser_probe.maybeAutoRefresh) can update acc/accAux with
-- NO new combat event in between, and gating solely on eventCount would
-- leave a fresher ACC value sitting unwritten until the next swing
-- happens to land. This is the whole point of matching mobstats'
-- original "continuously current" probe behavior rather than only the
-- one-shot per-check stamp this module had before.
---@param selfStats table|nil
---@return boolean wrote  true if a write actually happened this call
function live_export.tick(selfStats)
    local eventCount = export_log.stats();
    local selfAt = selfStats ~= nil and
        ((selfStats.accAt or 0) + (selfStats.accAuxAt or 0)) or 0;

    if eventCount == lastWrittenEventCount and selfAt == lastWrittenSelfAt then
        return false; -- nothing new -- skip even the throttle-time check
    end

    local ok, nowMs = pcall(function() return os.clock() * 1000; end);
    if not ok then
        nowMs = 0;
    end

    if (nowMs - lastWriteTimeMs) < MIN_WRITE_INTERVAL_MS and lastWriteTimeMs > 0 then
        return false; -- data changed, but within the coalescing window -- wait
    end

    local wroteOk, err = writeSnapshot(selfStats);
    if wroteOk then
        lastWrittenEventCount = eventCount;
        lastWrittenSelfAt = selfAt;
        lastWriteTimeMs = nowMs;
        lastWriteError = nil;
        return true;
    else
        -- Record the error but do NOT update lastWrittenEventCount or
        -- lastWrittenSelfAt -- so the next tick() retries rather than
        -- silently giving up because "nothing looked changed since
        -- last (failed) write".
        lastWriteError = err;
        return false;
    end
end

-- For a status command -- lets the user see whether live export is
-- actually working without digging through logs.
---@return number lastWrittenEventCount, string|nil lastWriteError
function live_export.status()
    return lastWrittenEventCount, lastWriteError;
end

return live_export;

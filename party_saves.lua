--[[
mobparser -- party_saves.lua

Party saves (2026-10-31, Brad's request): every time the running session
is cleared -- zoning with "Clear session data on zone" on, the GUI's Clear
data button, /mobparser wipe, or unloading the addon -- a full snapshot
of that session is written to disk before it is discarded. Any save can
be reopened from the GUI's "Saves" dropdown and viewed exactly like the
Session view (main table, Iso, Per enemy, every filter).

On disk (all under <addon>\db\saves\, git-ignored with the rest of db\):
  index.jsonl              one line per save, read at load (small):
                           {"file","reason","zone","zones","startTime",
                            "endTime","savedAt","events","trimmed"}
  save_YYYYMMDD_HHMMSS.jsonl   one save, JSON Lines:
                           line 1: {"mobparserPartySave":1, ...same meta}
                           gear:   {"gearState":{id=,Main=name,...},"ids":{Main=itemId,...}}
                           events: one event per line, exactly as the
                                   session held it (session gear ids)
  Nothing here deletes a save; delete files by hand to remove them (a
  save whose file is gone shows an error when picked).

Performance: nothing is encoded at the moment of the wipe. export_log.wipe()
REPLACES its tables rather than clearing them, so the snapshot just keeps
references to the old ones; tick() then encodes them a slice per frame
(SLICE_SECONDS) and writes the file in one go when done. Viewing a save
decodes it a slice per frame the same way All time loads. Unload finishes
any pending save immediately (one short stall on unload only).

Zone names: AshitaCore:GetMemoryManager():GetParty():GetMemberZone(0) and
AshitaCore:GetResourceManager():GetString('zones.names', id). Standard
Ashita v4 calls but NOT yet confirmed in this project -- both are
pcall'd; if either fails the save is labelled without a zone ("?").

Read-only with respect to the game: touches local files only.
]]

local json_encode = require('json_encode');
local json_decode = require('json_decode');

local party_saves = {};

local SLICE_SECONDS = 0.003;      -- encode / decode work per frame
local ZONE_CHECK_SECONDS = 1;     -- how often to note the zone while events arrive
local LIST_LIMIT = nil;           -- nil = list every save

local S = {
    dir = nil, indexPath = nil, ready = false,
    index = {},          -- array of meta, oldest first
    jobs = {},           -- queued writes (FIFO)
    loading = nil,       -- in-progress view load
    loaded = nil,        -- { file, meta, events, gearById, idsById }
    version = 0,         -- bumped whenever index changes
    lastError = nil,
    -- the running session's metadata (reset on every capture)
    cur = { zones = {}, zoneSet = {}, lastN = 0, lastCheck = nil },
};

local function clock() return os.clock(); end
local function setError(m) S.lastError = tostring(m); end

-- ---------------------------------------------------------------------------
-- Zone (unconfirmed Ashita calls -- see header)
-- ---------------------------------------------------------------------------
local function currentZoneName()
    local ok, name = pcall(function()
        local id = AshitaCore:GetMemoryManager():GetParty():GetMemberZone(0);
        if type(id) ~= 'number' or id <= 0 then return nil; end
        local n = AshitaCore:GetResourceManager():GetString('zones.names', id);
        if type(n) == 'string' and n ~= '' then return n; end
        return 'Zone ' .. tostring(id);
    end);
    if ok then return name; end
    return nil;
end

local function resetCur()
    S.cur = { zones = {}, zoneSet = {}, lastN = 0, lastCheck = nil };
end

local function noteZone()
    local z = currentZoneName();
    if z ~= nil and not S.cur.zoneSet[z] then
        S.cur.zoneSet[z] = true;
        table.insert(S.cur.zones, z);
    end
end

-- ---------------------------------------------------------------------------
-- Index
-- ---------------------------------------------------------------------------
local function readIndex()
    local f = io.open(S.indexPath, 'r');
    if f == nil then return; end
    for line in f:lines() do
        line = line:gsub('\r$', '');
        if line:match('%S') then
            local ok, m = pcall(json_decode.decode, line);
            if ok and type(m) == 'table' and type(m.file) == 'string' then
                table.insert(S.index, m);
            end
        end
    end
    f:close();
end

-- dir: absolute folder ending in a separator, e.g. addon.path .. 'db\\saves\\'
-- parentDir (optional): created first, for create_directory calls that
-- don't make nested folders.
function party_saves.init(dir, parentDir)
    S.dir = dir;
    S.indexPath = dir .. 'index.jsonl';
    if ashita ~= nil and ashita.fs ~= nil and ashita.fs.create_directory ~= nil then
        if parentDir ~= nil then pcall(ashita.fs.create_directory, parentDir); end
        local ok, err = pcall(ashita.fs.create_directory, dir);
        if not ok then setError('create_directory: ' .. tostring(err)); end
    end
    local ok, err = pcall(readIndex);
    if not ok then setError('reading index.jsonl: ' .. tostring(err)); end
    S.ready = true;
    S.version = S.version + 1;
end

-- ---------------------------------------------------------------------------
-- Capture (call BEFORE export_log.wipe)
-- snap = export_log.snapshot(): { events, gearById, idsById, trimmed }
-- reason: 'zone' | 'clear' | 'unload'
-- Returns the queued meta, or nil (nothing to save).
-- ---------------------------------------------------------------------------
function party_saves.capture(snap, reason)
    if not S.ready or snap == nil or snap.events == nil or #snap.events == 0 then
        resetCur();
        return nil;
    end
    local events = snap.events;
    local startTime, endTime = nil, nil;
    for i = 1, #events do
        local t = events[i].timestamp;
        if type(t) == 'number' then
            if startTime == nil or t < startTime then startTime = t; end
            if endTime == nil or t > endTime then endTime = t; end
        end
    end
    -- zone list: what was seen while events arrived; if nothing was seen
    -- (session too short for a check) ask now -- unless this is a zone-in,
    -- where "now" is already the NEW zone.
    if #S.cur.zones == 0 and reason ~= 'zone' then noteZone(); end
    local zones = {};
    for i, z in ipairs(S.cur.zones) do zones[i] = z; end

    local now = os.time();
    local base = 'save_' .. os.date('%Y%m%d_%H%M%S', now);
    -- unique file name (two saves in the same second)
    local file, n = base .. '.jsonl', 1;
    local taken = {};
    for _, m in ipairs(S.index) do taken[m.file] = true; end
    for _, j in ipairs(S.jobs) do taken[j.meta.file] = true; end
    while taken[file] do n = n + 1; file = base .. '_' .. n .. '.jsonl'; end

    local meta = {
        file = file, reason = reason or 'clear',
        zone = zones[1] or '?',
        zones = (#zones > 0) and zones or json_encode.EMPTY_ARRAY,
        startTime = startTime, endTime = endTime, savedAt = now,
        events = #events, trimmed = snap.trimmed or 0,
    };
    table.insert(S.jobs, {
        meta = meta, events = events,
        gearById = snap.gearById or {}, idsById = snap.idsById or {},
        parts = nil, pos = 1, skipped = 0,
    });
    resetCur();
    return meta;
end

-- One write job: encode for up to `budget` seconds. Returns true when the
-- file has been written (or failed for good).
local function stepJob(job, budget)
    local deadline = clock() + budget;
    if job.parts == nil then
        local header = {};
        for k, v in pairs(job.meta) do header[k] = v; end
        header.mobparserPartySave = 1;
        job.parts = { json_encode.encode(header) };
        local gids = {};
        for id in pairs(job.gearById) do gids[#gids + 1] = id; end
        table.sort(gids);
        for _, id in ipairs(gids) do
            local ids = job.idsById[id];
            local hasIds = false;
            if ids ~= nil then for _ in pairs(ids) do hasIds = true; break; end end
            local ok, line = pcall(json_encode.encode, {
                gearState = job.gearById[id],
                ids = hasIds and ids or json_encode.EMPTY_ARRAY,
            });
            if ok then job.parts[#job.parts + 1] = line; end
        end
    end
    local events, parts = job.events, job.parts;
    local nEv = #events;
    while job.pos <= nEv do
        local ok, line = pcall(json_encode.encode, events[job.pos]);
        if ok then parts[#parts + 1] = line; else job.skipped = job.skipped + 1; end
        job.pos = job.pos + 1;
        if job.pos % 64 == 0 and clock() >= deadline then return false; end
    end

    local path = S.dir .. job.meta.file;
    local f, err = io.open(path, 'wb');
    if f == nil then
        setError('writing ' .. job.meta.file .. ': ' .. tostring(err));
        return true; -- give up on this one; don't retry every frame
    end
    f:write(table.concat(parts, '\n'));
    f:write('\n');
    f:close();
    if job.skipped > 0 then job.meta.events = job.meta.events - job.skipped; end

    local fi = io.open(S.indexPath, 'ab');
    if fi ~= nil then
        fi:write(json_encode.encode(job.meta));
        fi:write('\n');
        fi:close();
    else
        setError('writing index.jsonl');
    end
    table.insert(S.index, job.meta);
    S.version = S.version + 1;
    return true;
end

-- ---------------------------------------------------------------------------
-- Viewing a save (sliced load, like All time)
-- ---------------------------------------------------------------------------
function party_saves.beginLoad(file)
    if not S.ready then return false, 'party saves not initialised'; end
    if S.loaded ~= nil and S.loaded.file == file then return true, 'already loaded'; end
    if S.loading ~= nil and S.loading.file == file then return true, 'loading'; end
    -- still being written? finish it first so it can be read
    for _, j in ipairs(S.jobs) do
        if j.meta.file == file then party_saves.finishAll(); break; end
    end
    local f = io.open(S.dir .. file, 'rb');
    if f == nil then return false, 'save file missing: ' .. file; end
    local content = f:read('*a') or '';
    f:close();
    S.loading = { file = file, content = content, pos = 1, meta = nil,
                  events = {}, gearById = {}, idsById = {}, bad = 0 };
    return true, 'loading';
end

local function loadStep(budget)
    local L = S.loading;
    if L == nil then return true; end
    local deadline = clock() + budget;
    local content, len = L.content, #L.content;
    local n = 0;
    while L.pos <= len do
        local nl = content:find('\n', L.pos, true);
        local line;
        if nl == nil then line = content:sub(L.pos); L.pos = len + 1;
        else line = content:sub(L.pos, nl - 1); L.pos = nl + 1; end
        if line:find('%S') then
            line = line:gsub('\r$', '');
            local ok, rec = pcall(json_decode.decode, line);
            if ok and type(rec) == 'table' then
                if rec.mobparserPartySave ~= nil then
                    L.meta = rec;
                elseif type(rec.gearState) == 'table' and type(rec.gearState.id) == 'number' then
                    local id = rec.gearState.id;
                    L.gearById[id] = rec.gearState;
                    L.idsById[id] = (type(rec.ids) == 'table') and rec.ids or {};
                else
                    L.events[#L.events + 1] = rec;
                end
            else
                L.bad = L.bad + 1;
            end
        end
        n = n + 1;
        if n % 32 == 0 and clock() >= deadline then return false; end
    end
    S.loaded = { file = L.file, meta = L.meta, events = L.events,
                 gearById = L.gearById, idsById = L.idsById, bad = L.bad };
    S.loading = nil;
    return true;
end

function party_saves.isLoading() return S.loading ~= nil; end
function party_saves.loadingFile() return S.loading and S.loading.file or nil; end
function party_saves.loadProgress()
    local L = S.loading;
    if L == nil then return nil; end
    if #L.content == 0 then return 1; end
    return (L.pos - 1) / #L.content;
end
function party_saves.loadedFile() return S.loaded and S.loaded.file or nil; end
-- Live reference -- DO NOT MUTATE.
function party_saves.events() return S.loaded and S.loaded.events or nil; end
function party_saves.gearState(id)
    if S.loaded == nil or id == nil then return nil, nil; end
    return S.loaded.gearById[id], S.loaded.idsById[id];
end
-- Frees the loaded save (going back to Session / All time).
function party_saves.unloadView()
    S.loaded = nil;
    S.loading = nil;
end

-- ---------------------------------------------------------------------------
-- Per frame / lifecycle
-- ---------------------------------------------------------------------------
-- eventCount: export_log.stats() -- used to note the zone only while the
-- session is actually receiving events.
function party_saves.tick(eventCount)
    if not S.ready then return; end
    if eventCount ~= nil and eventCount > 0 and eventCount ~= S.cur.lastN then
        local now = clock();
        if S.cur.lastCheck == nil or (now - S.cur.lastCheck) >= ZONE_CHECK_SECONDS then
            S.cur.lastCheck = now;
            S.cur.lastN = eventCount;
            noteZone();
        end
    end
    -- one job at a time, one slice per frame shared with view loading
    if S.jobs[1] ~= nil then
        if stepJob(S.jobs[1], SLICE_SECONDS) then table.remove(S.jobs, 1); end
        return;
    end
    if S.loading ~= nil then loadStep(SLICE_SECONDS); end
end

-- Writes every queued save now (unload, or a save picked while writing).
function party_saves.finishAll()
    while S.jobs[1] ~= nil do
        stepJob(S.jobs[1], math.huge);
        table.remove(S.jobs, 1);
    end
end

-- Blocking view load (offline tests).
function party_saves.loadNow(file)
    local ok, msg = party_saves.beginLoad(file);
    if not ok then return false, msg; end
    loadStep(math.huge);
    return true;
end

-- Saves, NEWEST FIRST (a new array each call -- cache by version()).
function party_saves.list()
    local out = {};
    for i = #S.index, 1, -1 do
        out[#out + 1] = S.index[i];
        if LIST_LIMIT ~= nil and #out >= LIST_LIMIT then break; end
    end
    return out;
end

function party_saves.version() return S.version; end
function party_saves.pending() return #S.jobs; end

-- "10/31 07:12-07:45  Valkurm Dunes  (312)"
function party_saves.label(m)
    if m == nil then return '?'; end
    local t1 = (type(m.startTime) == 'number') and os.date('%m/%d %H:%M', m.startTime) or '?';
    local t2 = (type(m.endTime) == 'number') and os.date('%H:%M', m.endTime) or '?';
    local zone = tostring(m.zone or '?');
    if type(m.zones) == 'table' and #m.zones > 1 then
        zone = zone .. ' +' .. tostring(#m.zones - 1);
    end
    return string.format('%s-%s  %s  (%d)', t1, t2, zone, tonumber(m.events) or 0);
end

function party_saves.metaFor(file)
    for i = #S.index, 1, -1 do
        if S.index[i].file == file then return S.index[i]; end
    end
    return nil;
end

function party_saves.status()
    return { ready = S.ready, saves = #S.index, pending = #S.jobs, dir = S.dir,
             loaded = S.loaded and S.loaded.file or nil, lastError = S.lastError };
end

-- Offline tests only.
function party_saves._reset()
    S.ready = false; S.index = {}; S.jobs = {}; S.loading = nil; S.loaded = nil;
    S.version = 0; S.lastError = nil; resetCur();
end

return party_saves;

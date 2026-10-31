--[[
mobparser -- alltime_db.lua

All-time event database (2026-10-30; rebuilt 2026-10-30 night after the
afternoon files were lost -- same on-disk format, so the existing
db\events.jsonl / db\gear.jsonl keep working).

- Every event export_log.record() stores is also appended to
  <addon>\db\events.jsonl (JSON Lines, one event per line). Its
  gearStateId is the DATABASE's permanent gear id, not the session's.
- Gear compositions go to db\gear.jsonl, one per line:
  {"id":N,"gear":{slot:name},"ids":{weapon slot:itemId}}
- Nothing in mobparser deletes this data. Clear data, /mobparser wipe,
  reload and game exit all leave it. To reset it,
  delete the db folder by hand.
- Writes are buffered and flushed every FLUSH_SECONDS (tick() from
  d3d_present) and on unload. A crash loses at most ~2 s. A line cut
  short by a crash is skipped on load, and a newline is written before
  the next append so later lines stay intact.
- gear.jsonl is read at init (small) so ids continue after the highest
  one on disk. events.jsonl is read only on the first loadAll() (the
  GUI's All time button); after that new events are added live.

Not SQLite: no SQLite binding is confirmed in this Ashita install.
Read-only with respect to the game: touches local files only.
]]

local json_encode = require('json_encode');
local json_decode = require('json_decode');

local alltime_db = {};

local FLUSH_SECONDS = 2;
-- (2026-10-30, perf) Unwritten event lines kept while writes are failing.
local MAX_PENDING = 20000;
-- (2026-10-30, perf) All time loads in slices across frames: at most this
-- many seconds of decoding per frame, so the game never stalls on it.
local LOAD_BUDGET_SECONDS = 0.004;
local SLOT_ORDER = {
    'Main', 'Sub', 'Range', 'Ammo', 'Head', 'Neck', 'Ear1', 'Ear2',
    'Body', 'Hands', 'Ring1', 'Ring2', 'Back', 'Waist', 'Legs', 'Feet',
};
local WEAPON_SLOTS = { 'Main', 'Sub', 'Range', 'Ammo' };

local db = {
    dir = nil, eventsPath = nil, gearPath = nil,
    ready = false,
    gearById = {},        -- dbId -> entry {id=, Main=name, ...}
    idsById = {},         -- dbId -> {Main=itemId, ...}
    idBySig = {},         -- signature -> dbId
    maxGearId = 0,
    pendingEvents = {},   -- encoded lines not yet written
    pendingGear = {},
    eventsNeedNl = false, gearNeedNl = false,
    loaded = false,       -- events.jsonl read into `events`
    events = {},
    version = 0,          -- bumped when `events` changes
    writtenThisSession = 0,
    badLines = 0,
    lastError = nil,
    lastFlush = nil,
    loading = nil,        -- (2026-10-30) in-progress sliced load, see beginLoad
    dropped = 0,          -- (2026-10-30) pending lines dropped by MAX_PENDING
};

local function clock() return os.clock(); end

local function setError(msg)
    db.lastError = tostring(msg);
end

local function signature(entry)
    local parts = {};
    for _, slot in ipairs(SLOT_ORDER) do
        table.insert(parts, slot .. '=' .. tostring(entry[slot] or ''));
    end
    return table.concat(parts, '|');
end

-- true if a non-empty file does not end in '\n' (crash-truncated line)
local function needsLeadingNewline(path)
    local f = io.open(path, 'rb');
    if f == nil then return false; end
    local size = f:seek('end');
    if size == nil or size == 0 then f:close(); return false; end
    f:seek('set', size - 1);
    local last = f:read(1);
    f:close();
    return last ~= '\n';
end

local function readGearFile()
    local f = io.open(db.gearPath, 'r');
    if f == nil then return; end
    for line in f:lines() do
        if line:match('%S') then
            local ok, rec = pcall(json_decode.decode, line);
            if ok and type(rec) == 'table' and type(rec.id) == 'number' then
                local entry = { id = rec.id };
                if type(rec.gear) == 'table' then
                    for slot, name in pairs(rec.gear) do entry[slot] = name; end
                end
                local ids = {};
                if type(rec.ids) == 'table' then
                    for slot, v in pairs(rec.ids) do ids[slot] = v; end
                end
                db.gearById[rec.id] = entry;
                db.idsById[rec.id] = ids;
                db.idBySig[signature(entry)] = rec.id;
                if rec.id > db.maxGearId then db.maxGearId = rec.id; end
            else
                db.badLines = db.badLines + 1;
            end
        end
    end
    f:close();
end

-- dir: absolute folder path ending in a separator, e.g. addon.path .. 'db\\'
function alltime_db.init(dir)
    db.dir = dir;
    db.eventsPath = dir .. 'events.jsonl';
    db.gearPath = dir .. 'gear.jsonl';
    if ashita ~= nil and ashita.fs ~= nil and ashita.fs.create_directory ~= nil then
        local ok, err = pcall(ashita.fs.create_directory, dir);
        if not ok then setError('create_directory: ' .. tostring(err)); end
    end
    local ok, err = pcall(readGearFile);
    if not ok then setError('reading gear.jsonl: ' .. tostring(err)); end
    db.eventsNeedNl = needsLeadingNewline(db.eventsPath);
    db.gearNeedNl = needsLeadingNewline(db.gearPath);
    db.ready = true;
    db.lastFlush = clock();
end

-- Permanent database gear id for a session gear entry (creates one if new).
local function dbGearId(entry, weaponIds)
    local e = { };
    if entry ~= nil then
        for _, slot in ipairs(SLOT_ORDER) do
            if entry[slot] ~= nil then e[slot] = entry[slot]; end
        end
    end
    local sig = signature(e);
    local id = db.idBySig[sig];
    if id ~= nil then
        -- fill in weapon ids an older line didn't have
        local ids = db.idsById[id];
        if weaponIds ~= nil and ids ~= nil then
            for _, slot in ipairs(WEAPON_SLOTS) do
                if ids[slot] == nil and weaponIds[slot] ~= nil then ids[slot] = weaponIds[slot]; end
            end
        end
        return id;
    end
    db.maxGearId = db.maxGearId + 1;
    id = db.maxGearId;
    e.id = id;
    local ids = {};
    if weaponIds ~= nil then
        for _, slot in ipairs(WEAPON_SLOTS) do ids[slot] = weaponIds[slot]; end
    end
    db.gearById[id] = e;
    db.idsById[id] = ids;
    db.idBySig[sig] = id;

    local gear = {};
    local anyGear, anyIds = false, false;
    for _, slot in ipairs(SLOT_ORDER) do
        if e[slot] ~= nil then gear[slot] = e[slot]; anyGear = true; end
    end
    for _ in pairs(ids) do anyIds = true; break; end
    table.insert(db.pendingGear, json_encode.encode({
        id = id,
        gear = anyGear and gear or json_encode.EMPTY_ARRAY,
        ids = anyIds and ids or json_encode.EMPTY_ARRAY,
    }));
    return id;
end

-- Called from export_log.record (pcall-wrapped there).
function alltime_db.record(event, gearEntry, weaponIds)
    if not db.ready then return; end
    local copy = {};
    for k, v in pairs(event) do copy[k] = v; end
    copy.gearStateId = dbGearId(gearEntry, weaponIds);
    table.insert(db.pendingEvents, json_encode.encode(copy));
    db.writtenThisSession = db.writtenThisSession + 1;
    if db.loaded then
        table.insert(db.events, copy);
        db.version = db.version + 1;
    elseif db.loading ~= nil then
        -- (2026-10-30) recorded while All time is still loading: the load
        -- reads a snapshot taken before this event was written, so hold it
        -- and append it when the load finishes.
        table.insert(db.loading.backlog, copy);
    end
    -- (2026-10-30) Pending cap: if writes keep failing (disk full, file
    -- locked), drop the OLDEST unwritten lines past the cap instead of
    -- growing memory forever. Counted, shown in /mobparser status.
    -- Trims to 90% of the cap in one go so this runs rarely, not per event.
    if #db.pendingEvents > MAX_PENDING then
        local over = #db.pendingEvents - math.floor(MAX_PENDING * 0.9);
        local kept = {};
        for i = over + 1, #db.pendingEvents do kept[#kept + 1] = db.pendingEvents[i]; end
        db.pendingEvents = kept;
        db.dropped = db.dropped + over;
    end
end

local function appendLines(path, lines, needNl)
    local f, err = io.open(path, 'ab');
    if f == nil then return false, err; end
    if needNl then f:write('\n'); end
    f:write(table.concat(lines, '\n'));
    f:write('\n');
    f:close();
    return true;
end

-- Writes everything pending. Gear first, so an event never references a
-- gear id that isn't on disk yet.
function alltime_db.flush()
    if not db.ready then return; end
    if #db.pendingGear > 0 then
        local ok, err = appendLines(db.gearPath, db.pendingGear, db.gearNeedNl);
        if ok then
            db.pendingGear = {};
            db.gearNeedNl = false;
        else
            setError('writing gear.jsonl: ' .. tostring(err));
            -- (2026-10-30) BUGFIX: lastFlush was not updated on this path,
            -- so a failing write was retried (file reopened) EVERY frame.
            -- Now waits FLUSH_SECONDS like any other flush.
            db.lastFlush = clock();
            return; -- keep events pending too, retry next tick
        end
    end
    if #db.pendingEvents > 0 then
        local ok, err = appendLines(db.eventsPath, db.pendingEvents, db.eventsNeedNl);
        if ok then
            db.pendingEvents = {};
            db.eventsNeedNl = false;
        else
            setError('writing events.jsonl: ' .. tostring(err));
        end
    end
    db.lastFlush = clock();
end

-- ---------------------------------------------------------------------------
-- Sliced All time load (2026-10-30, perf). The old loadAll() decoded the
-- whole events.jsonl in ONE frame -- measured 135 ms for 7,756 events on a
-- fast PC with LuaJIT, several times that on a weak one, and the file only
-- grows. Now: beginLoad() flushes, reads the file's bytes once (fast -- the
-- slow part is JSON decoding, not disk), then loadStep() decodes lines for
-- at most LOAD_BUDGET_SECONDS per frame (called from tick()). Events
-- recorded mid-load are held in a backlog and appended at the end, so
-- nothing is missed or counted twice.
-- ---------------------------------------------------------------------------
function alltime_db.beginLoad()
    if not db.ready then return false, 'database not initialised'; end
    if db.loaded then return true, 'already loaded'; end
    if db.loading ~= nil then return true, 'loading'; end
    alltime_db.flush();
    local content = '';
    local f = io.open(db.eventsPath, 'rb');
    if f ~= nil then
        content = f:read('*a') or '';
        f:close();
    end
    db.loading = { content = content, pos = 1, events = {}, backlog = {} };
    return true, 'loading';
end

-- Decodes lines for up to `budget` seconds (default LOAD_BUDGET_SECONDS).
-- Returns true when the load has finished.
function alltime_db.loadStep(budget)
    local L = db.loading;
    if L == nil then return db.loaded; end
    local deadline = clock() + (budget or LOAD_BUDGET_SECONDS);
    local content, len = L.content, #L.content;
    local n = 0;
    while L.pos <= len do
        local nl = content:find('\n', L.pos, true);
        local line;
        if nl == nil then
            line = content:sub(L.pos); L.pos = len + 1;
        else
            line = content:sub(L.pos, nl - 1); L.pos = nl + 1;
        end
        if line:find('%S') then
            line = line:gsub('\r$', '');
            local ok, ev = pcall(json_decode.decode, line);
            if ok and type(ev) == 'table' then
                L.events[#L.events + 1] = ev;
            else
                db.badLines = db.badLines + 1;
            end
        end
        n = n + 1;
        -- check the clock every 32 lines, not every line
        if n % 32 == 0 and clock() >= deadline then return false; end
    end
    for _, ev in ipairs(L.backlog) do L.events[#L.events + 1] = ev; end
    db.events = L.events;
    db.loading = nil;
    db.loaded = true;
    db.version = db.version + 1;
    return true;
end

function alltime_db.isLoading() return db.loading ~= nil; end

-- 0..1 while loading, nil otherwise.
function alltime_db.loadProgress()
    local L = db.loading;
    if L == nil then return nil; end
    if #L.content == 0 then return 1; end
    return (L.pos - 1) / #L.content;
end

-- Call every frame; flushes at most every FLUSH_SECONDS, and advances a
-- sliced All time load.
function alltime_db.tick()
    if not db.ready then return; end
    if db.loading ~= nil then alltime_db.loadStep(); end
    if #db.pendingEvents == 0 and #db.pendingGear == 0 then return; end
    if db.lastFlush ~= nil and (clock() - db.lastFlush) < FLUSH_SECONDS then return; end
    alltime_db.flush();
end

-- Blocking load (offline tests / anything that needs it now). The GUI uses
-- beginLoad() + tick() instead. Returns ok, message.
function alltime_db.loadAll()
    local ok, msg = alltime_db.beginLoad();
    if not ok then return false, msg; end
    alltime_db.loadStep(math.huge);
    return true, string.format('loaded %d event(s)', #db.events);
end

function alltime_db.isLoaded() return db.loaded; end

-- Live reference -- DO NOT MUTATE.
function alltime_db.events() return db.events; end

function alltime_db.version() return db.version; end

-- entry ({id, Main=name, ...}), weaponIds ({Main=itemId, ...}) or nil
function alltime_db.gearState(id)
    if id == nil then return nil, nil; end
    return db.gearById[id], db.idsById[id];
end

function alltime_db.status()
    local gearCount = 0;
    for _ in pairs(db.gearById) do gearCount = gearCount + 1; end
    return {
        loaded = db.loaded,
        events = db.loaded and #db.events or nil,
        writtenThisSession = db.writtenThisSession,
        gearStates = gearCount,
        pending = #db.pendingEvents + #db.pendingGear,
        badLines = db.badLines,
        dir = db.dir,
        lastError = db.lastError,
        dropped = db.dropped,
        loading = db.loading ~= nil,
    };
end

-- Offline tests only.
function alltime_db._reset()
    db.ready = false; db.gearById = {}; db.idsById = {}; db.idBySig = {}; db.maxGearId = 0;
    db.pendingEvents = {}; db.pendingGear = {}; db.loaded = false; db.events = {};
    db.version = 0; db.writtenThisSession = 0; db.badLines = 0; db.lastError = nil;
    db.loading = nil; db.dropped = 0;
end

return alltime_db;

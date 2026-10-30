--[[
mobparser -- export_log.lua

The real data-capture/export layer under the 2026-07-28 scope pivot
(see mobparser_PROJECT.md "SCOPE PIVOT" section) -- accumulates
captured events plus a deduplicated gear-state table in memory during
a session, and exports both to JSON on demand.

Distinct from debug_log.lua, which remains a disposable, flat-text,
human-skimmable diagnostic (originally built for the first in-game
test, comparing output against Metrics) -- NOT the real data pipeline
and never meant to become it. This file IS the real data pipeline.
debug_log.lua is left as-is for now (still useful for quick human
sanity-checking during testing) rather than deleted or merged into
this file -- they serve different purposes and this project has
already learned the cost of letting a diagnostic scaffold grow into
something it wasn't designed to be (see debug_log.lua's own header
warning against exactly that).

## Design decisions this file implements (user-directed, 2026-07-28)

- **Gear stamping: reference table, not embedded.** Each event stores a
  `gearStateId` (an integer) rather than a full 16-slot composition
  inline. Distinct gear compositions are stored ONCE in a separate
  gearStates table and referenced by id. Rationale (given directly to
  the user before this was built): real captured session data already
  showed gear is IDENTICAL across long runs of consecutive events
  (12+ consecutive swings with the same Main/Ammo in the second live
  test) -- embedding the full composition in every single event at
  "capture everything" volume would be dominated by pure duplication.
  A reference table also matches dlac's OWN model (worn envelopes are
  themselves deltas/partial for the same reason) and is a standard,
  cheap-to-join pattern for any downstream consumer (including the
  future mobstats ingestion this data is ultimately headed toward).
- **Lifecycle: keep accumulating in running memory; user controls wipe
  and master-file consolidation separately.** Per the user directly:
  "Keep storing, but we'll give the parser an option to wipe data...
  we also want an option to Save data to a master file, then wipe the
  running parser memory." Implemented as three distinct operations,
  not fused together, so each can be used independently:
    - `export_log.exportSession()` -- returns the current in-memory
      session as a JSON string. Does NOT wipe or touch the master file.
      Pure "give me a snapshot of what's been captured so far."
    - `export_log.wipe()` -- clears in-memory session state (events +
      gearStates) back to empty. Does NOT export or write anything
      first -- if the data isn't wanted, this is a clean discard.
    - `export_log.saveToMasterAndWipe(masterPath)` -- the combined
      operation the user specifically asked for: reads any existing
      master JSON file, merges the current session's events and
      gearStates into it (renumbering gearStateIds to avoid cross-
      session collisions -- see the function's own comment for exactly
      what "merge" does and does not do, e.g. no cross-session gear-
      state deduplication in v1), writes the combined result back to
      masterPath, THEN wipes running memory. This is the "consolidate
      and start fresh" workflow. Requires json_decode.lua (built
      alongside this file specifically to make real merging possible,
      rather than shipping a refuse-if-exists placeholder).
  Kept as three separate functions (not one do-everything call) so a
  future UI/command layer can expose "just export," "just wipe," and
  "save+wipe" as genuinely distinct user actions, matching how the
  user described the need.
]]

local json_encode = require('json_encode');
local json_decode = require('json_decode');

local export_log = {};

-- ===========================================================================
-- Session state -- module-level (not per-instance) intentionally, same
-- reasoning as debug_log.lua's own settings table: there is exactly one
-- mobparser session running per Ashita Lua state, so a singleton is the
-- right shape here (unlike dlac_listener.newState(), which deliberately
-- supports multiple independent instances for offline testability --
-- export_log's tests instead reset this module-level state between
-- cases via export_log.wipe(), which is simpler given there's only ever
-- one real session to track).
-- ===========================================================================
local session = {
    events = {},       -- array, in capture order
    gearStates = {},   -- array of { id = N, Main = {...}, ... }
    nextGearStateId = 1,
};

-- Maps a gear-state SIGNATURE (a stable string built from sorted
-- slot=name pairs) to the id already assigned to that exact
-- composition this session -- so identical compositions seen at
-- different times reuse the same gearStateId instead of creating a
-- duplicate entry. Cleared alongside session.gearStates on wipe.
local gearStateIdBySignature = {};

-- (2026-10-30) Main/Sub/Range/Ammo ITEM IDS per gear state, for the GUI's
-- weapon filter (weapon type comes from the item id). Side table only --
-- NOT exported, so the export schema is unchanged. Cleared on wipe.
local weaponIdsByGearState = {};
local gearStateById = {};
local WEAPON_SLOTS = { 'Main', 'Sub', 'Range', 'Ammo' };

-- All-time database hook (2026-10-30). Injected by mobparser.lua via
-- export_log.setPersist(alltime_db) so this file's own offline tests don't
-- need it. persist.record(event, gearEntry, weaponIds) is pcall-wrapped:
-- the database can never stop capture.
local persist = nil;
local persistError = nil;

-- Bumped on every wipe so a reader can tell "same event count, different
-- events" apart (GUI cache).
local generation = 0;

-- Builds a stable, order-independent signature string for a `worn`
-- table (as returned by dlac_listener.currentComposition/
-- compositionFor), so two calls describing the identical composition
-- produce the identical signature regardless of Lua's unspecified
-- pairs() iteration order. Uses dlac_listener's own canonical slot
-- list ordering (not alphabetical, not insertion order) so this stays
-- consistent with how the rest of this project already thinks about
-- slot order (see combat_router.lua's SLOT_ORDER, vendored from
-- integration-guide.md §2.3 -- duplicated here rather than requiring
-- combat_router.lua from this file, to avoid a require-cycle risk
-- between the capture layer and the export layer, which should stay
-- one-directional).
local SLOT_ORDER = {
    'Main', 'Sub', 'Range', 'Ammo', 'Head', 'Neck', 'Ear1', 'Ear2',
    'Body', 'Hands', 'Ring1', 'Ring2', 'Back', 'Waist', 'Legs', 'Feet',
};

local function gearSignature(worn)
    if worn == nil then
        return 'none';
    end
    local parts = {};
    for _, slot in ipairs(SLOT_ORDER) do
        local item = worn[slot];
        table.insert(parts, slot .. '=' .. (item and tostring(item.name) or ''));
    end
    return table.concat(parts, '|');
end

-- Returns the gearStateId for the given `worn` composition, creating a
-- new gearStates entry only if this exact composition hasn't been seen
-- yet this session. `worn` may be nil (no dlac data at all) or a
-- partial/full table from dlac_listener -- either way this always
-- returns SOME id (a dedicated "no gear data" entry is created and
-- reused the same way a real composition would be, so every event
-- always has a valid gearStateId to reference, never a special-cased
-- nil).
---@param worn table|nil  from dlac_listener's currentComposition/compositionFor
---@return number  gearStateId
function export_log.internGearState(worn)
    local sig = gearSignature(worn);
    local existing = gearStateIdBySignature[sig];
    if existing ~= nil then
        return existing;
    end

    local id = session.nextGearStateId;
    session.nextGearStateId = session.nextGearStateId + 1;

    local entry = { id = id };
    if worn ~= nil then
        for _, slot in ipairs(SLOT_ORDER) do
            if worn[slot] ~= nil then
                -- Store just the name for now, matching the level of
                -- detail combat_router.buildGearTag's debug signature
                -- already exposes -- NOT the full item record (id,
                -- rec, stats, aug) dlac's envelope carries. This is a
                -- deliberate v1 scoping choice, not an oversight: the
                -- full item detail is available in dlac's own data
                -- (see integration-guide.md §1's static catalog) for
                -- any consumer that needs to resolve a name back to
                -- full stats, and keeping THIS export lean matters at
                -- "capture everything" volume. Revisit if a real
                -- consumer needs more than the name per slot.
                entry[slot] = worn[slot].name;
            end
        end
    end

    local ids = {};
    if worn ~= nil then
        for _, slot in ipairs(WEAPON_SLOTS) do
            local item = worn[slot];
            if item ~= nil and type(item.id) == 'number' then ids[slot] = item.id; end
        end
    end
    weaponIdsByGearState[id] = ids;
    gearStateById[id] = entry;

    table.insert(session.gearStates, entry);
    gearStateIdBySignature[sig] = id;
    return id;
end

-- ===========================================================================
-- Event recording
-- ===========================================================================

-- Records one captured event. `fields` is a flat table of whatever
-- fields this event type needs (type-specific -- a melee swing and a
-- resting tick will have different shapes) -- this function does not
-- prescribe a schema per event type, that's the caller's
-- responsibility (combat_router.lua and whatever future modules handle
-- non-melee categories). This function's only two universal
-- responsibilities: stamp a timestamp if the caller didn't supply one,
-- and resolve `worn` into a `gearStateId` via internGearState so
-- callers never have to think about gear-state deduplication
-- themselves.
--
-- `fields.worn` (if present) is CONSUMED, not stored verbatim -- it's
-- replaced with `fields.gearStateId` before the event is stored, so
-- the exported event never carries a redundant embedded composition
-- alongside its reference id.
---@param fields table  event-specific fields; may include `worn` (a
---                       dlac_listener composition table, converted to
---                       gearStateId here) and/or `timestamp`
function export_log.record(fields)
    local event = {};
    for k, v in pairs(fields) do
        event[k] = v;
    end

    if event.timestamp == nil then
        event.timestamp = os.time();
    end

    if event.worn ~= nil then
        event.gearStateId = export_log.internGearState(event.worn);
        event.worn = nil;
    else
        -- No gear data supplied at all (e.g. dlac not installed/
        -- streaming this session) -- still assign a real gearStateId
        -- (the shared "no gear data" entry) rather than leaving the
        -- field absent, so every exported event has a consistent shape
        -- for downstream consumers to rely on.
        event.gearStateId = export_log.internGearState(nil);
    end

    table.insert(session.events, event);

    if persist ~= nil then
        local gid = event.gearStateId;
        local ok, err = pcall(persist.record, event, gearStateById[gid], weaponIdsByGearState[gid]);
        if not ok then persistError = tostring(err); end
    end
end

-- (2026-10-30) Gear state lookup for the GUI: returns entry ({id, Main=name,
-- ...}) and weaponIds ({Main=itemId, ...}), or nil.
function export_log.gearState(id)
    if id == nil then return nil, nil; end
    return gearStateById[id], weaponIdsByGearState[id];
end

function export_log.setPersist(p)
    persist = p;
end

function export_log.persistError()
    return persistError;
end

function export_log.generation()
    return generation;
end

-- ===========================================================================
-- Export / lifecycle operations -- see module header for the three-
-- operation design and why they're kept separate.
-- ===========================================================================

-- Returns the current in-memory session as a JSON string. Pure
-- snapshot -- does not modify session state at all.
---@return string  JSON text: { events: [...], gearStates: [...] }
function export_log.exportSession()
    return json_encode.encode({
        events = (#session.events > 0) and session.events or json_encode.EMPTY_ARRAY,
        gearStates = (#session.gearStates > 0) and session.gearStates or json_encode.EMPTY_ARRAY,
    });
end

-- Clears in-memory session state entirely. Does NOT export or save
-- anything first -- callers wanting to preserve data before wiping
-- should call exportSession() or saveToMasterAndWipe() instead.
function export_log.wipe()
    session.events = {};
    session.gearStates = {};
    session.nextGearStateId = 1;
    gearStateIdBySignature = {};
    weaponIdsByGearState = {};
    gearStateById = {};
    generation = generation + 1;
end

-- Returns the number of events / gear states currently held in memory
-- -- for a status command / load-message summary, so the user can see
-- session size without exporting it first.
---@return number eventCount, number gearStateCount
function export_log.stats()
    return #session.events, #session.gearStates;
end

-- ===========================================================================
-- Live read accessor (2026-07-30, added for mobparser_gui.lua)
-- ===========================================================================

-- Returns the LIVE session.events array BY REFERENCE, not a copy --
-- deliberate, for a per-frame imgui consumer: exportSession() already
-- exists for "give me an independent JSON snapshot" (encode cost paid
-- once, on demand); this is for "let a live in-game window read
-- what's already in memory every frame" without paying a json_encode +
-- json_decode round-trip 60 times a second. Callers MUST treat the
-- returned table as read-only -- mutating it would corrupt export_log's
-- own session state. This mirrors the same read-only-reference
-- discipline mobparser_probe.lua's own state tables already rely on
-- elsewhere in this project (no defensive deep-copy there either).
---@return table  session.events, live reference, DO NOT MUTATE
function export_log.liveEvents()
    return session.events;
end

-- ===========================================================================
-- Master-file consolidation
-- ===========================================================================

-- Reads and decodes an existing master JSON file, if any. Returns
-- { events = {...}, gearStates = {...} } (empty arrays if the file
-- doesn't exist yet), or raises an error if the file exists but is not
-- valid JSON (a corrupt/hand-edited master file is a real problem
-- worth surfacing loudly, not silently discarding).
local function readMasterFile(masterPath)
    local file = io.open(masterPath, 'r');
    if file == nil then
        return { events = {}, gearStates = {} }; -- doesn't exist yet -- fresh start
    end
    local content = file:read('*a');
    file:close();

    if not content:match('%S') then
        return { events = {}, gearStates = {} }; -- exists but empty -- treat as fresh
    end

    local decoded = json_decode.decode(content);
    return {
        events = decoded.events or {},
        gearStates = decoded.gearStates or {},
    };
end

-- Appends the current session into a persistent master JSON file, then
-- wipes running memory. This is the exact "save to master, then wipe
-- the running parser memory" workflow the user asked for.
--
-- REAL merge (2026-07-28, once json_decode.lua existed to make this
-- possible -- see that file's own header for why it was built). Reads
-- the existing master file (if any), decodes it, RENUMBERS the current
-- session's gearStateIds to continue after the master file's highest
-- existing id (so two sessions' gear-state tables don't collide -- a
-- gearStateId of 3 in the master file and a gearStateId of 3 in this
-- session almost certainly do NOT refer to the same composition), then
-- appends both the renumbered events and the renumbered gearStates
-- onto the master file's existing arrays, and writes the combined
-- result back out.
--
-- Gear-state DEDUPLICATION across sessions is intentionally NOT
-- attempted here (v1 scope) -- the same composition seen in two
-- different sessions will get two different gearStates entries in the
-- combined master file, rather than being recognized as identical and
-- merged into one. This is a real, deliberate limitation, not an
-- oversight: proper cross-session dedup would need to compare full
-- compositions (not just ids, which are already known to collide
-- across sessions) against the master file's existing entries, which
-- is more work than this pass is scoping in -- correctness (never
-- silently merging two DIFFERENT compositions under one id) matters
-- more here than file-size efficiency across sessions, and simply not
-- deduplicating is always safe, just not maximally compact. Revisit if
-- master-file size across many sessions becomes a real problem.
---@param masterPath string  full path to the master JSON file
---@return boolean ok, string message
function export_log.saveToMasterAndWipe(masterPath)
    local ok, master = pcall(readMasterFile, masterPath);
    if not ok then
        return false, 'existing master file at "' .. masterPath ..
            '" could not be read as valid JSON (' .. tostring(master) ..
            ') -- refusing to proceed rather than overwrite or guess. ' ..
            'Session data was NOT wiped.';
    end

    -- Find the highest gearStateId already in the master file, so this
    -- session's ids can be renumbered to continue after it without
    -- collision.
    local maxExistingId = 0;
    for _, gs in ipairs(master.gearStates) do
        if type(gs.id) == 'number' and gs.id > maxExistingId then
            maxExistingId = gs.id;
        end
    end

    local idOffset = maxExistingId; -- this session's id N becomes N + idOffset
    local combinedGearStates = {};
    for _, gs in ipairs(master.gearStates) do
        table.insert(combinedGearStates, gs);
    end
    for _, gs in ipairs(session.gearStates) do
        local renumbered = {};
        for k, v in pairs(gs) do
            renumbered[k] = v;
        end
        renumbered.id = gs.id + idOffset;
        table.insert(combinedGearStates, renumbered);
    end

    local combinedEvents = {};
    for _, ev in ipairs(master.events) do
        table.insert(combinedEvents, ev);
    end
    for _, ev in ipairs(session.events) do
        local renumbered = {};
        for k, v in pairs(ev) do
            renumbered[k] = v;
        end
        if renumbered.gearStateId ~= nil then
            renumbered.gearStateId = renumbered.gearStateId + idOffset;
        end
        table.insert(combinedEvents, renumbered);
    end

    local json = json_encode.encode({
        events = (#combinedEvents > 0) and combinedEvents or json_encode.EMPTY_ARRAY,
        gearStates = (#combinedGearStates > 0) and combinedGearStates or json_encode.EMPTY_ARRAY,
    });

    local file, openErr = io.open(masterPath, 'w');
    if file == nil then
        return false, 'could not open master file for writing: ' .. tostring(openErr) ..
            ' -- session data was NOT wiped.';
    end
    file:write(json);
    file:close();

    local sessionEventCount = #session.events;
    local sessionGearStateCount = #session.gearStates;
    export_log.wipe();
    return true, string.format(
        'merged %d event(s) and %d gear state(s) into master file (now %d event(s) total); running session wiped.',
        sessionEventCount, sessionGearStateCount, #combinedEvents);
end

return export_log;

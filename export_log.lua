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
    - (save-to-master-and-wipe was removed 2026-10-30; the all-time
      database in db\ replaced it.)
  Kept as three separate functions (not one do-everything call) so a
  future UI/command layer can expose "just export," "just wipe," and
  "save+wipe" as genuinely distinct user actions, matching how the
  user described the need.
]]

local json_encode = require('json_encode');

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

-- Session size cap (2026-10-30, perf). With Clear on zone off, or a long
-- stay in one zone, the running session grew without limit -- and every
-- GUI rebuild with it. Past MAX_SESSION_EVENTS the oldest 10% are dropped
-- from the RUNNING SESSION ONLY (the all-time database keeps every event).
-- Done in one batch into a new table, so it is rare, and the GUI sees a
-- new table and rebuilds cleanly. gearStates are kept (small, still
-- referenced by the remaining events).
local MAX_SESSION_EVENTS = 50000;
local trimmedTotal = 0;

-- Builds a stable, order-independent signature string for a `worn`
-- table (as returned by dlac_listener.currentComposition), so two calls describing the identical composition
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
---@param worn table|nil  from dlac_listener's currentComposition
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
    if #session.events > MAX_SESSION_EVENTS then
        local drop = math.floor(MAX_SESSION_EVENTS * 0.1);
        local kept = {};
        for i = drop + 1, #session.events do kept[#kept + 1] = session.events[i]; end
        session.events = kept;
        trimmedTotal = trimmedTotal + drop;
    end

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

-- (2026-10-31) References to the current session's tables, for a party
-- save (party_saves.capture) taken just before wipe(). Safe to keep after
-- the wipe: wipe() REPLACES these tables, it never clears them in place,
-- and record() only ever appends to the new ones. Callers must not mutate.
function export_log.snapshot()
    return {
        events = session.events,
        gearById = gearStateById,
        idsById = weaponIdsByGearState,
        trimmed = trimmedTotal,
    };
end

-- Clears in-memory session state entirely. Does NOT export or save
-- anything first -- callers wanting to preserve data before wiping
-- should call exportSession() first.
function export_log.wipe()
    session.events = {};
    session.gearStates = {};
    session.nextGearStateId = 1;
    gearStateIdBySignature = {};
    weaponIdsByGearState = {};
    gearStateById = {};
    trimmedTotal = 0;
end

-- Returns the number of events / gear states currently held in memory
-- -- for a status command / load-message summary, so the user can see
-- session size without exporting it first.
---@return number eventCount, number gearStateCount
-- Events dropped from the running session by MAX_SESSION_EVENTS (2026-10-30).
function export_log.trimmed()
    return trimmedTotal;
end

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

return export_log;

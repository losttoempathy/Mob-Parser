--[[
mobparser -- mobparser_gui.lua

In-game ImGui window: player rows x stat columns, sourced LIVE from
export_log.liveEvents() (added alongside this file -- see that
function's own header). This is a pure display layer -- T2 Information
Display per server rules (ServerRules.txt): reads already-captured
data, sends nothing to the server, does not act on the player's
behalf. Allowed by default, no whitelist/GM action needed.

## Framework

Real Ashita v4 ImGui, `require('imgui')`, matching the confirmed-real
usage pattern seen in mousseng/xitools (trials.lua, skillchain
addon) -- imgui.Begin/BeginTable/TableSetupColumn/TableHeadersRow/
TableNextRow/TableNextColumn/Text/Checkbox/End, ImGuiTableFlags_*
globals. NOT invented from memory -- checked against a real, current
addon source this session rather than guessed, per this project's
standing no-invented-API-names discipline (see mobparser_PROJECT.md's
"API research dead end" note for why that discipline exists).

## Sorting / column reorder

Column REORDER (drag a header) and HIDE (right-click a header) use
ImGui's own table machinery. SORTING is self-managed: each header is
drawn with imgui.TableHeader() and clicks are caught with
imgui.IsItemClicked(). The earlier approach (ImGuiTableFlags_Sortable +
imgui.TableGetSortSpecs()) never sorted anything, because Ashita's
binding returns Specs as userdata rather than a Lua table and the old
code discarded it. Default sort: Damage, high->low.

## Player limit

Player mode shows at most settings.data.guiMaxPlayers rows (default 6,
1-18), set in the Settings window and persisted via mobparser_settings.

## Theme

Fully user-editable (Colors button -> 'mobparser colors' window), default black/grey. Pushed
per-window via PushStyleColor/PopStyleColor so it does not affect
other addons. Saved as settings.data.guiColors.

## Column set

Every stat classify.lua's outcome vocabulary can support, grouped the
same way as the (earlier, now-superseded) browser mockup this replaces
-- core combat, defense/mitigation, weaponskill, magic, JA, pet,
unclassified. Display-on defaults to the core set; everything else is
computed but hidden until enabled in Settings.

## Isolation mode (2026-10-29)

Player mode puts an 'Iso' button beside each name. Clicking it replaces
the table with that player's breakdown; '< Full list' goes back.
Tables: Physical (melee / WS / ranged / ranged WS, + pet melee if any),
Weaponskills by name, Magic by spell, Job abilities by name, Additional
effects & skillchains, TP moves / items / other, Damage taken. Empty
tables are hidden (Physical always shows). Ranged-WS detection is by WS
ID range -- see RANGED_WS_MIN/MAX (unconfirmed for AscensionXI).

2026-10-30: player isolation adds 'Per enemy' -- one row per individual
mob (server ID, not name), with hits/misses/acc/crits, WS & cast counts
and damage split melee+ranged / WS / magic / other. Isolating a mob row
(enemy rows on in Settings) adds 'Per target' (the mob's attacks split
by the player hit) and, when more than one mob of that name was seen,
'Per spawn'. Same-named mobs are labelled 'Name #1', 'Name #2' in
first-seen order (numbering resets on Clear data).

## Tracking vs display (per user's explicit request)

- "Display" toggle: show/hide a column. Never affects capture.
- "Tracking" toggle: exclude a stat from THIS window's aggregation.
  Per the user: "keep logging" regardless -- this file only ever READS
  export_log.liveEvents() and never mutates or filters what
  export_log itself stores. Turning tracking off here just means this
  window stops counting that stat into its own displayed totals; the
  underlying events remain fully captured, exportable, and saveable
  exactly as before.
]]

local imgui = require('imgui');
local export_log = require('export_log');
local settings = require('mobparser_settings');
-- All-time database (2026-10-30). Optional: the All time button is hidden
-- if it failed to load.
local dbOk, alltime_db = pcall(require, 'alltime_db');
if not dbOk then alltime_db = nil; end
-- Party saves (2026-10-31). Optional: the Saves dropdown is hidden if it
-- failed to load.
local psOk, party_saves = pcall(require, 'party_saves');
if not psOk then party_saves = nil; end

local mobparser_gui = {};

-- ===========================================================================
-- Stat definitions (mirrors classify.lua's real OUTCOME/COUNTS_AS_HIT
-- vocabulary -- see that file for the authoritative source of every
-- outcome string checked below)
-- ===========================================================================

local STAT_GROUPS = {
    { id = 'core', label = 'Core combat', stats = {
        { key = 'events',    label = 'Events' },
        { key = 'hits',      label = 'Hits' },
        { key = 'misses',    label = 'Misses' },
        { key = 'crits',     label = 'Crits' },
        { key = 'acc',       label = 'Acc %' },
        { key = 'damage',    label = 'Damage' },
        { key = 'dps',       label = 'DPS' },
        { key = 'avgDamage', label = 'Avg dmg' },
    }},
    { id = 'defense', label = 'Defense / mitigation', stats = {
        { key = 'parry',       label = 'Parry' },
        { key = 'guard',       label = 'Guard' },
        { key = 'shieldBlock', label = 'Shield block' },
        { key = 'shadows',     label = 'Shadows' },
        { key = 'dodge',       label = 'Perfect dodge' },
        { key = 'counter',     label = 'Counter' },
    }},
    { id = 'ws', label = 'Weaponskills', stats = {
        { key = 'wsCount',  label = 'WS used' },
        { key = 'wsDamage', label = 'WS dmg' },
        { key = 'wsMiss',   label = 'WS miss' },
    }},
    { id = 'magic', label = 'Magic', stats = {
        { key = 'magicCount',  label = 'Casts' },
        { key = 'magicDamage', label = 'Magic dmg' },
        { key = 'magicResist', label = 'Resists' },
        { key = 'magicHeal',   label = 'Heals' },
    }},
    { id = 'ja', label = 'Job abilities', stats = {
        { key = 'jaCount',  label = 'JA uses' },
        { key = 'jaDamage', label = 'JA dmg' },
    }},
    { id = 'pet', label = 'Pet', stats = {
        { key = 'petMelee',  label = 'Pet melee' },
        { key = 'petTpMove', label = 'Pet TP move' },
        { key = 'petDamage', label = 'Pet dmg' },
    }},
    { id = 'meta', label = 'Other / unclassified', stats = {
        { key = 'skillchain', label = 'Skillchains' },
        { key = 'unknown',    label = 'Unknown' },
    }},
};

local STAT_META = {};       -- key -> {key,label}
local ALL_STAT_KEYS = {};   -- ordered array of every stat key
for _, group in ipairs(STAT_GROUPS) do
    for _, stat in ipairs(group.stats) do
        STAT_META[stat.key] = stat;
        table.insert(ALL_STAT_KEYS, stat.key);
    end
end

local DEFAULT_DISPLAY_ON = {
    events = true, hits = true, misses = true, crits = true,
    acc = true, damage = true, dps = true, avgDamage = true,
};

-- DPS: a row's Damage divided by COMBAT TIME -- the time the whole group
-- spent fighting, measured from event timestamps (1-second resolution,
-- export_log stamps os.time()). A gap longer than DPS_IDLE_GAP seconds
-- between consecutive events is treated as downtime (walking to the next
-- mob, resting) and not counted, so DPS doesn't sink between fights.
-- Every row shares the same combat time, so DPS columns are directly
-- comparable between players (same convention as most FFXI parsers).
local DPS_IDLE_GAP = 10;

-- 2026-10-29: ranged and weaponskill outcomes added -- the main table's
-- Hits / Misses / Crits / Acc used to count melee only.
-- (2026-10-30) These are the only hit/miss sets; classify.lua's unused
-- copies were removed. Rules carried over from there: SHADOWS, PARRY,
-- GUARD, SHIELD_BLOCK, COUNTER and MOB_HEAL all passed the accuracy roll,
-- so they count as hits (PARRY confirmed by Brad 2026-07-27). DODGE
-- (Perfect Dodge) is in neither set -- not an accuracy roll.
local COUNTS_AS_HIT = {
    HIT = true, CRIT = true, SHADOWS = true, GUARD = true,
    SHIELD_BLOCK = true, UNMITIGATED = true, COUNTER = true,
    MOB_HEAL = true, PARRY = true,
    RANGED_HIT = true, RANGED_CRIT = true,
    WS_DAMAGE = true, WS_RESIST_STILL_DAMAGES = true, WS_DRAIN_HP = true,
};
local COUNTS_AS_MISS = { MISS = true, RANGED_MISS = true, WS_NO_EFFECT = true };
local COUNTS_AS_CRIT = { CRIT = true, RANGED_CRIT = true };
-- Outcomes whose `damage` is an amount healed, not damage dealt -- kept out
-- of every Damage total (2026-10-29: the main Damage column used to add them).
local HEAL_OUTCOMES = {
    MOB_HEAL = true, RANGED_MOB_HEAL = true, MAGIC_HEAL = true, JA_HEAL = true, WS_HEAL = true,
    ADD_EFFECT_HP_HEAL = true, ADD_EFFECT_HEAL = true, ADD_EFFECT_SPIKES_HEAL = true,
};

-- ===========================================================================
-- Module state
-- ===========================================================================

local state = {
    windowVisible  = { false },  -- imgui out-param convention -- see trials.lua real usage
    settingsVisible = { false },
    colorsVisible   = { false },
    displayOn  = {},   -- key -> bool
    trackingOn = {},   -- key -> bool (true = tracked, default all on)
    groupBy    = 'actorName', -- 'actorName' or 'type'
    sortKey    = 'damage',    -- column key currently sorted on (nil = first-seen order)
    sortAsc    = false,       -- false = high->low
    isolated   = nil,         -- row key (player name) shown in isolation mode; nil = full list
    source     = 'session',   -- 'session', 'alltime' (2026-10-30) or 'save' (2026-10-31)
    saveFile   = nil,         -- party save shown when source == 'save'
    wf         = {},          -- isolation weapon filter (see computeIsolation)
    mf         = nil,         -- isolation monster filter (see computeIsolation)
    jf         = nil,         -- isolation job filter: nil = all jobs, else 'WAR' etc.
};

-- ===========================================================================
-- Data source (2026-10-30): the running session, or the all-time database.
-- Everything (main table, isolation, Per enemy, filters, Report) reads
-- through these, so All time drives it all.
-- ===========================================================================

local function useAllTime()
    return state.source == 'alltime' and alltime_db ~= nil and alltime_db.isLoaded();
end

-- (2026-10-31) a party save, once it has finished loading
local function useSave()
    return state.source == 'save' and party_saves ~= nil and state.saveFile ~= nil
        and party_saves.loadedFile() == state.saveFile;
end

-- A save picked but still loading shows nothing (not the live session).
local EMPTY_EVENTS = {};

local function currentEvents()
    if useSave() then return party_saves.events(); end
    if state.source == 'save' then return EMPTY_EVENTS; end
    if useAllTime() then return alltime_db.events(); end
    return export_log.liveEvents();
end

-- entry ({id, Main=name, ...}), weaponIds ({Main=itemId, ...}) or nil
local function gearLookup(id)
    if useSave() then return party_saves.gearState(id); end
    if useAllTime() then return alltime_db.gearState(id); end
    if export_log.gearState ~= nil then return export_log.gearState(id); end
    return nil, nil;
end

local function gearLookupAvailable()
    if useSave() or useAllTime() then return true; end
    return export_log.gearState ~= nil;
end

-- ---------------------------------------------------------------------------
-- PERF (2026-10-30, low-end machines). Replaces the per-frame string
-- "data stamp" cache.
--   * The event list only ever GROWS (append-only) until it is replaced
--     outright (wipe, session trim, All time load) -- so "same table, more
--     events" means "fold in the new ones", and "different table" means
--     "start over". No strings are built per frame to check this.
--   * Main table: incremental -- each refresh only processes events added
--     since the last one (was: re-walk + re-sort everything every 0.5 s /
--     2 s).
--   * Isolation: cannot be incremental (mob numbering 'Crab #1/#2' and
--     party detection depend on ALL events, so earlier lines can change
--     when later events arrive). It is rebuilt exactly as before, but as a
--     coroutine that runs at most SLICE_BUDGET seconds per frame; the
--     previous result stays on screen until the new one is ready.
--   * Any big first build (e.g. the main table right after All time loads)
--     is sliced the same way.
-- ---------------------------------------------------------------------------
local REFRESH_SECONDS = 0.5;  -- fold new events in at most this often
local SLICE_BUDGET = 0.003;   -- seconds of aggregation work per frame

local sliceDeadline = nil;    -- set only while a sliced coroutine runs
local sliceCounter = 0;
-- Called inside long loops. Yields back to the frame when the slice budget
-- is used up. A no-op outside a sliced coroutine (e.g. offline tests).
local function sliceCheck()
    if sliceDeadline == nil then return; end
    sliceCounter = sliceCounter + 1;
    if sliceCounter < 64 then return; end
    sliceCounter = 0;
    if os.clock() >= sliceDeadline then coroutine.yield(); end
end

-- Combat time for DPS without sorting (2026-10-30, perf). Gives exactly the
-- same answer as sorting every timestamp and summing the gaps (a gap over
-- DPS_IDLE_GAP counts as 1 s), but each event costs O(1): timestamps are
-- whole seconds, so only the distinct seconds matter, and an out-of-order
-- second only needs its neighbours within DPS_IDLE_GAP looked up.
local function newCombatClock()
    return { seen = {}, min = nil, max = nil, total = 0, inexact = false };
end

local function gapValue(g)
    if g > DPS_IDLE_GAP then return 1; end
    return g;
end

local function combatClockAdd(c, t)
    if type(t) ~= 'number' then return; end
    if t ~= math.floor(t) then c.inexact = true; return; end
    if c.seen[t] then return; end
    c.seen[t] = true;
    if c.min == nil then
        c.min, c.max, c.total = t, t, 1;
        return;
    end
    if t > c.max then
        c.total = c.total + gapValue(t - c.max); c.max = t;
    elseif t < c.min then
        c.total = c.total + gapValue(c.min - t); c.min = t;
    else
        -- strictly inside: replace gap (a,b) with (a,t)+(t,b)
        local a, b = nil, nil;
        for d = 1, DPS_IDLE_GAP do
            if a == nil and c.seen[t - d] then a = t - d; end
            if b == nil and c.seen[t + d] then b = t + d; end
            if a ~= nil and b ~= nil then break; end
        end
        if a ~= nil and b ~= nil then
            c.total = c.total + gapValue(t - a) + gapValue(b - t) - gapValue(b - a);
        elseif a ~= nil then
            c.total = c.total + gapValue(t - a);   -- (t,b) and (a,b) both count 1
        elseif b ~= nil then
            c.total = c.total + gapValue(b - t);
        else
            c.total = c.total + 1;
        end
    end
end

for k in pairs(DEFAULT_DISPLAY_ON) do state.displayOn[k] = true; end
for _, key in ipairs(ALL_STAT_KEYS) do
    if state.displayOn[key] == nil then state.displayOn[key] = false; end
    state.trackingOn[key] = true;
end

-- ===========================================================================
-- Aggregation -- pure function over export_log.liveEvents(), read-only.
-- Mirrors the same rules as classify.lua's own COUNTS_AS_HIT/MISS
-- tables and the per-type field shapes documented in that file's
-- header and in export_log's own recorded event samples.
-- ===========================================================================

-- FFXI main-job IDs as returned by IParty:GetMemberMainJob (the value
-- export events carry as actorJob). Live export 2026-10-29 confirms the
-- field is numeric: Lift 6 (THF), Broken 3 (WHM), Mtlol 4 (BLM).
local JOB_ABBR = {
    [1] = 'WAR', [2] = 'MNK', [3] = 'WHM', [4] = 'BLM', [5] = 'RDM', [6] = 'THF',
    [7] = 'PLD', [8] = 'DRK', [9] = 'BST', [10] = 'BRD', [11] = 'RNG', [12] = 'SAM',
    [13] = 'NIN', [14] = 'DRG', [15] = 'SMN', [16] = 'BLU', [17] = 'COR', [18] = 'PUP',
    [19] = 'DNC', [20] = 'SCH', [21] = 'GEO', [22] = 'RUN',
};

local function bump(row, key)
    if not state.trackingOn[key] then return; end
    row[key] = (row[key] or 0) + 1;
end

local function addDmg(row, key, val)
    if not state.trackingOn[key] then return; end
    row[key] = (row[key] or 0) + val;
end

-- Which row an event belongs to. Shared by the main table and isolation
-- mode so "isolate this row" always means exactly the events that built
-- the row. Returns key, isMob, job.
-- job (2026-10-30): the acting player's main-job abbreviation for this
-- event (actorJob, or finisherJob on skillchains), nil for mobs, pets and
-- old events without one. The main table splits a player's row by it.
local function jobOf(e)
    local jobId = e.actorJob or e.finisherJob;
    if jobId == nil then return nil; end
    return JOB_ABBR[jobId] or tostring(jobId);
end

-- ---------------------------------------------------------------------------
-- Pets under their owner (2026-11-07). A pet's actions no longer get a row
-- of their own: they count toward the OWNER's row (owner name + owner job),
-- like one of the owner's spells, and isolation shows them in a Pets table
-- that can be broken out by summon.
--
-- petOwnerOf(e) -> ownerName, ownerJobId, petName, or nil if not a pet event.
--   * new events: actorIsPet + actorOwnerName (+ actorOwnerJob), or
--     finisherIsPet + finisherOwnerName on skillchains (combat_router).
--   * older events: party-member pets already carried actorOwnerName (no
--     owner job -- the owner's last job seen is used). Your OWN pet before
--     2026-11-07 often had no party info at all; a pet_melee / pet_tp_move
--     row with no actorName can only be yours (party pets always resolve
--     through the party snapshot), so it goes to the local player.
-- ---------------------------------------------------------------------------
local lastJobByName = {}; -- player name -> last job abbreviation seen

-- Local player name, re-read at most once a second (old-event fallback
-- below can hit this once per event during a rebuild).
local lnName, lnAt = nil, nil;
local function localNameCached()
    local now = os.clock();
    if lnAt ~= nil and lnName ~= nil and now >= lnAt and (now - lnAt) < 1 then return lnName; end
    local ok, n = pcall(function()
        return AshitaCore:GetMemoryManager():GetParty():GetMemberName(0);
    end);
    lnAt = now;
    if ok and type(n) == 'string' and n ~= '' then lnName = n; else lnName = nil; end
    return lnName;
end

local function petOwnerOf(e)
    if e.type == 'skillchain' then
        if e.finisherIsPet == true and e.finisherOwnerName ~= nil then
            return e.finisherOwnerName, e.finisherOwnerJob,
                e.finisherName or e.finisherEntityName or ('#' .. tostring(e.finisherActorId));
        end
        return nil;
    end
    if e.side == 'defense' then return nil; end -- something hitting the pet: mob's row
    if e.actorIsPet == true and e.actorOwnerName ~= nil then
        return e.actorOwnerName, e.actorOwnerJob,
            e.actorName or e.actorEntityName or ('#' .. tostring(e.actorId));
    end
    if (e.type == 'pet_melee' or e.type == 'pet_tp_move') and e.actorName == nil
            and e.actorOwnerName == nil then
        local me = localNameCached();
        if me ~= nil then
            return me, nil, e.actorEntityName or ('#' .. tostring(e.actorId));
        end
    end
    return nil;
end

local function rowKeyFor(e, groupField)
    if groupField == 'actorName' then
        local owner, ownerJob, petName = petOwnerOf(e);
        if owner ~= nil then
            local job = nil;
            if ownerJob ~= nil then
                job = JOB_ABBR[ownerJob] or tostring(ownerJob);
            else
                job = lastJobByName[owner];
            end
            return owner, false, job, petName;
        end
    end
    local key = e[groupField];
    local isMob = false;
    local job = nil;
    if key ~= nil and groupField == 'actorName' then
        job = jobOf(e);
    end
    if key == nil and groupField == 'actorName' then
        -- 2026-10-29: was a single '(pet/unknown)' bucket. actorName is
        -- only set for party members, so every mob action (hits/misses on
        -- you, TP moves) and every skillchain row (finisherName, not
        -- actorName) piled in there. Resolve in order: skillchain
        -- finisher -> the actor's entity name from client memory (mobs)
        -- -> the raw ID, so nothing is ever anonymous.
        key = e.finisherName;
        if key ~= nil then job = jobOf(e); end
        if key == nil then
            local ent = e.actorEntityName or e.finisherEntityName;
            local id = e.actorId or e.finisherActorId;
            if ent ~= nil then
                key = ent;
            elseif id ~= nil then
                key = '#' .. tostring(id);
            else
                key = '(no actor)';
            end
            -- defense side = the mob is the actor
            isMob = (e.side == 'defense');
        end
    elseif key == nil then
        key = e.type or 'unknown';
    end
    if isMob then key = key .. ' (mob)'; end
    if job ~= nil and not isMob then lastJobByName[key] = job; end
    return key, isMob, job, nil;
end

-- Combat time for DPS (see DPS_IDLE_GAP above). Original sort-based
-- version -- now only a fallback for non-whole-second timestamps (none are
-- written today: export_log stamps os.time()).
local function computeCombatSecondsSorted(events)
    local times = {};
    for _, e in ipairs(events) do
        if type(e.timestamp) == 'number' then table.insert(times, e.timestamp); end
    end
    table.sort(times);
    if #times == 0 then return 0; end
    local combatSeconds = 1; -- the first event's own second
    for i = 2, #times do
        local gap = times[i] - times[i - 1];
        if gap > DPS_IDLE_GAP then
            combatSeconds = combatSeconds + 1; -- new fight starts
        else
            combatSeconds = combatSeconds + gap;
        end
    end
    return combatSeconds;
end

-- Same result, no sort (see newCombatClock). Sliced-coroutine aware.
local function computeCombatSeconds(events)
    local c = newCombatClock();
    for _, e in ipairs(events) do
        combatClockAdd(c, e.timestamp);
        sliceCheck();
    end
    if c.inexact then return computeCombatSecondsSorted(events); end
    return c.total;
end

-- One event into the main-table rows. Body unchanged from the old
-- computeRowsUncached loop (2026-10-30 split out so it can run
-- incrementally).
local function accumulateRow(c, e, groupField)
    local rows, order = c.rows, c.order;
    local name, isMob, job, petName = rowKeyFor(e, groupField);
    -- 2026-10-30: one row per player per job (Lift WAR / Lift MNK are
    -- separate rows). Mobs, pets and job-less events keep one row.
    local key = name;
    if job ~= nil then key = name .. '\t' .. job; end
    local r = rows[key];
    if r == nil then
        r = { name = name, job = job, isMob = isMob };
        rows[key] = r;
        table.insert(order, key);
    end

    local outcome = e.outcome or '';
    local dmg = type(e.damage) == 'number' and e.damage or 0;
    local isHit = COUNTS_AS_HIT[outcome] == true;
    local isMiss = COUNTS_AS_MISS[outcome] == true;
    -- heal amounts are not damage
    if HEAL_OUTCOMES[outcome] then dmg = 0; end

    -- 2026-11-07: a pet's action counts for its owner like a spell would --
    -- events, damage and DPS -- but not toward the owner's own swing
    -- hits / misses / crits / accuracy, defense, WS, magic or JA counts.
    if petName ~= nil then
        local d = dmg;
        if COUNTS_AS_MISS[outcome] or outcome == 'PET_TP_MOVE_LIKELY_FAILURE' then d = 0; end
        bump(r, 'events');
        addDmg(r, 'damage', d);
        addDmg(r, 'petDamage', d);
        if e.type == 'pet_melee' then bump(r, 'petMelee'); end
        if outcome:sub(1, 12) == 'PET_TP_MOVE' then bump(r, 'petTpMove'); end
        if outcome == 'SKILLCHAIN' then bump(r, 'skillchain'); end
        if outcome == 'UNKNOWN' or outcome == 'UNKNOWN_ADD_EFFECT' then bump(r, 'unknown'); end
        if state.trackingOn.dps then combatClockAdd(c.clock, e.timestamp); end
        return;
    end

    bump(r, 'events');
    if isHit then bump(r, 'hits'); end
    if isMiss then bump(r, 'misses'); end
    if COUNTS_AS_CRIT[outcome] then bump(r, 'crits'); end
    addDmg(r, 'damage', dmg);

    if outcome == 'PARRY' then bump(r, 'parry'); end
    if outcome == 'GUARD' then bump(r, 'guard'); end
    if outcome == 'SHIELD_BLOCK' then bump(r, 'shieldBlock'); end
    if outcome == 'SHADOWS' then bump(r, 'shadows'); end
    if outcome == 'DODGE' then bump(r, 'dodge'); end
    if outcome == 'COUNTER' then bump(r, 'counter'); end

    if e.type == 'weaponskill' and outcome ~= 'TOO_FAR' then -- too far = WS never went off
        bump(r, 'wsCount');
        addDmg(r, 'wsDamage', dmg);
        if isMiss then bump(r, 'wsMiss'); end -- MISS / WS_NO_EFFECT
    end
    if e.type == 'magic' then
        bump(r, 'magicCount');
        addDmg(r, 'magicDamage', dmg);
        if outcome == 'MAGIC_RESIST' then bump(r, 'magicResist'); end
        if outcome == 'MAGIC_HEAL' then bump(r, 'magicHeal'); end
    end
    if outcome:sub(1, 3) == 'JA_' then
        bump(r, 'jaCount');
        if outcome == 'JA_DAMAGE' then addDmg(r, 'jaDamage', dmg); end
    end
    if e.type == 'pet_melee' then bump(r, 'petMelee'); end
    if outcome:sub(1, 12) == 'PET_TP_MOVE' then bump(r, 'petTpMove'); end
    if outcome == 'SKILLCHAIN' then bump(r, 'skillchain'); end
    if outcome == 'UNKNOWN' or outcome == 'UNKNOWN_ADD_EFFECT' then bump(r, 'unknown'); end

    -- combat time for DPS (see DPS_IDLE_GAP above)
    if state.trackingOn.dps then combatClockAdd(c.clock, e.timestamp); end
end

-- Derived stats + the row list, after a batch of new events.
local function finalizeRows(c, events)
    local combatSeconds = 0;
    if state.trackingOn.dps then
        if c.clock.inexact then
            combatSeconds = computeCombatSecondsSorted(events);
        else
            combatSeconds = c.clock.total;
        end
    end
    c.combatSeconds = combatSeconds;

    local list = {};
    for _, key in ipairs(c.order) do
        local r = c.rows[key];
        local hits, misses = r.hits or 0, r.misses or 0;
        r.acc, r.dps, r.avgDamage = nil, nil, nil;
        if state.trackingOn.acc and (hits + misses) > 0 then
            r.acc = math.floor((hits / (hits + misses)) * 1000 + 0.5) / 10;
        end
        if state.trackingOn.dps and combatSeconds > 0 and (r.damage or 0) > 0 then
            r.dps = math.floor(((r.damage or 0) / combatSeconds) * 10 + 0.5) / 10;
        end
        if state.trackingOn.avgDamage and hits > 0 then
            r.avgDamage = math.floor(((r.damage or 0) / hits) * 10 + 0.5) / 10;
        end
        table.insert(list, r);
    end
    c.list = list;
end

-- Tracking-toggle fingerprint. PERF (2026-10-30): only rebuilds its string
-- when a toggle actually changed (was a new string every frame).
local tkSnap, tkStr = {}, nil;
local function trackingKey()
    if tkStr ~= nil then
        local same = true;
        for i, key in ipairs(ALL_STAT_KEYS) do
            if (state.trackingOn[key] == true) ~= tkSnap[i] then same = false; break; end
        end
        if same then return tkStr; end
    end
    local parts = {};
    for i, key in ipairs(ALL_STAT_KEYS) do
        tkSnap[i] = (state.trackingOn[key] == true);
        parts[i] = tkSnap[i] and '1' or '0';
    end
    tkStr = table.concat(parts);
    return tkStr;
end

-- Main-table rows, incremental (see the PERF block near the top).
-- Returns list, combatSeconds, buildId (changes whenever the list does),
-- building (true while a big first build is still being sliced).
-- budget: seconds to spend this call (nil = SLICE_BUDGET; math.huge =
-- finish now, used by Report).
local rowsCache = {};   -- groupField -> cache
local rowsBuildId = 0;

local function computeRows(groupField, budget)
    local events = currentEvents();
    local n = #events;
    local tk = trackingKey();
    local now = os.clock();
    local c = rowsCache[groupField];
    if c == nil or c.events ~= events or c.tk ~= tk or n < c.done then
        c = { events = events, tk = tk, done = 0, rows = {}, order = {}, list = {},
              clock = newCombatClock(), combatSeconds = 0, at = -math.huge, id = 0 };
        rowsCache[groupField] = c;
    end
    local catchingUp = (c.done < n) and (c.building or c.done == 0
        or (now - c.at) >= REFRESH_SECONDS or budget == math.huge);
    if catchingUp then
        local deadline = now + (budget or SLICE_BUDGET);
        local i = c.done;
        while i < n do
            i = i + 1;
            accumulateRow(c, events[i], groupField);
            if i % 64 == 0 and os.clock() >= deadline then break; end
        end
        c.done = i;
        c.building = (i < n) and (budget ~= math.huge);
        finalizeRows(c, events);
        c.at = now;
        rowsBuildId = rowsBuildId + 1;
        c.id = rowsBuildId;
    end
    return c.list, c.combatSeconds, c.id, c.building == true;
end

-- ===========================================================================
-- Isolation mode (2026-10-29) -- one player's damage broken down by source.
-- Same read-only rules as computeRows: reads export_log.liveEvents(),
-- never filters or changes what is captured. The Tracking toggles in
-- Settings do NOT apply here; this view always shows everything.
-- ===========================================================================

-- Ranged weaponskills arrive on the same category (3) and type
-- ('weaponskill') as melee WSs; only the WS ID tells them apart.
-- Stock LSB lays WS IDs out in 16-slot blocks per weapon skill (sword
-- 32-47 -- matches the live-confirmed Vorpal Blade = 40), with Archery
-- 192-207 and Marksmanship 208-223. The AscensionXI wiki says Archery /
-- Marksmanship WSs are unchanged from stock.
-- UNCONFIRMED against AscensionXI weapon_skills.sql / a live ranged-WS
-- capture -- if wrong, a ranged WS just lands on the melee WS line.
local RANGED_WS_MIN, RANGED_WS_MAX = 192, 223;

local function isRangedWs(e)
    local id = e.actionId;
    return type(id) == 'number' and id >= RANGED_WS_MIN and id <= RANGED_WS_MAX;
end

-- Outcome sets (names from classify.OUTCOME).
-- Same sets as the main table (defined at the top of the file).
local ISO_HIT, ISO_MISS, ISO_CRIT, ISO_HEAL = COUNTS_AS_HIT, COUNTS_AS_MISS, COUNTS_AS_CRIT, HEAL_OUTCOMES;
local MAGIC_DMG = {
    MAGIC_DAMAGE = true, MAGIC_BURST_DAMAGE = true,
    MAGIC_DRAIN_HP = true, MAGIC_BURST_DRAIN_HP = true,
};
local MAGIC_BURST = {
    MAGIC_BURST_DAMAGE = true, MAGIC_BURST_STATUS_LANDED = true,
    MAGIC_BURST_DRAIN_HP = true, MAGIC_BURST_DRAIN_MP = true,
};
local MAGIC_RESISTED = { MAGIC_RESIST = true, MAGIC_EVADES = true };
local JA_FAILED = { JA_MISS = true, JA_STEAL_FAIL = true, JA_MUG_FAIL = true, JA_CHARM_FAIL = true };

-- Add-effect rows: only these carry real damage in `damage` (status / TH /
-- MP / TP procs export damage 0 or a non-damage amount).
local AE_DAMAGE = { SKILLCHAIN = true, ADD_EFFECT_HP_DRAIN = true, UNKNOWN_ADD_EFFECT = true };
local AE_LABEL = {
    ADD_EFFECT_HP_DRAIN        = 'HP drain (e.g. Drain Samba)',
    ADD_EFFECT_TREASURE_HUNTER = 'Treasure Hunter proc',
    ADD_EFFECT_STATUS          = 'Status proc',
    ADD_EFFECT_MP_HEAL         = 'MP drain',
    ADD_EFFECT_TP_DRAIN        = 'TP drain',
    ADD_EFFECT_SELFBUFF        = 'Self-buff proc',
    ADD_EFFECT_HP_HEAL         = 'HP heal proc',
    ADD_EFFECT_HEAL            = 'Heal proc',
    ADD_EFFECT_DISPEL          = 'Dispel proc',
    ADD_EFFECT_STATUS_SPIKES   = 'Status spikes',
    ADD_EFFECT_SPIKES_HEAL     = 'Spikes heal',
    UNKNOWN_ADD_EFFECT         = 'Unidentified add. effect (enspell etc.)',
};

local TYPE_LABEL = {
    melee = 'Melee', ranged = 'Ranged', weaponskill = 'Weaponskill',
    magic = 'Magic', job_ability = 'Job ability', monster_tp_move = 'TP move',
    pet_tp_move = 'Pet TP move', pet_melee = 'Pet melee', item_use = 'Item',
    add_effect = 'Additional effect',
};

local function newLine(label)
    return {
        label = label, count = 0, uses = 0, useSeen = {},
        hits = 0, dmgHits = 0, misses = 0, crits = 0, damage = 0, heal = 0,
        bursts = 0, resists = 0, parry = 0, shadows = 0, blocked = 0,
    };
end

local function newBucket() return { map = {}, list = {} }; end

local function namedLine(bucket, label)
    local l = bucket.map[label];
    if l == nil then
        l = newLine(label);
        bucket.map[label] = l;
        table.insert(bucket.list, l);
    end
    return l;
end

local function noteDamage(l, dmg)
    l.damage = l.damage + dmg;
    if dmg > 0 then
        l.dmgHits = l.dmgHits + 1;
        if l.high == nil or dmg > l.high then l.high = dmg; end
        if l.low == nil or dmg < l.low then l.low = dmg; end
    end
end

-- One use of a spell/JA/WS = one action packet; an AoE produces one row
-- per target, so rows sharing second + action + actor count once.
local function markUse(l, e)
    local k = tostring(e.timestamp) .. ':' .. tostring(e.actionId) .. ':'
        .. tostring(e.actorId or e.finisherActorId);
    if not l.useSeen[k] then
        l.useSeen[k] = true;
        l.uses = l.uses + 1;
    end
end

local function actionLabel(e)
    if e.actionName ~= nil then return tostring(e.actionName); end
    if type(e.actionId) == 'number' and e.actionId > 0 then return '#' .. tostring(e.actionId); end
    return '(unnamed)';
end

-- Melee / ranged / WS swing tally.
local function addPhysical(l, outcome, dmg)
    l.count = l.count + 1;
    if ISO_HIT[outcome] then
        l.hits = l.hits + 1;
        if not ISO_HEAL[outcome] then noteDamage(l, dmg); end
    elseif ISO_MISS[outcome] then
        l.misses = l.misses + 1;
    elseif dmg > 0 and not ISO_HEAL[outcome] then
        noteDamage(l, dmg); -- e.g. a new damage outcome: keep it in the total
    end
    if ISO_CRIT[outcome] then l.crits = l.crits + 1; end
end

-- Same use-dedupe as markUse, into a caller-owned seen table. Returns
-- true the first time a use is seen.
local function markSeen(seen, e)
    local k = tostring(e.timestamp) .. ':' .. tostring(e.actionId) .. ':'
        .. tostring(e.actorId or e.finisherActorId);
    if seen[k] then return false; end
    seen[k] = true;
    return true;
end

-- Damage an event adds to the isolated player's 'Damage' total -- the
-- same rules computeIsolation's per-type branches use, so the Per enemy
-- table sums to the header total.
local function dealtBy(t, outcome, dmg)
    if dmg <= 0 or ISO_HEAL[outcome] then return 0; end
    if t == 'melee' or t == 'ranged' or t == 'pet_melee' or t == 'weaponskill' then
        return ISO_MISS[outcome] and 0 or dmg;
    end
    if t == 'magic' then return MAGIC_DMG[outcome] and dmg or 0; end
    if t == 'job_ability' then return (outcome == 'JA_DAMAGE') and dmg or 0; end
    if t == 'add_effect' or t == 'skillchain' then return AE_DAMAGE[outcome] and dmg or 0; end
    return dmg; -- TP moves, items, anything else
end

local function newEnemyLine(label)
    local l = newLine(label);
    l.wsUses, l.casts = 0, 0;
    l.physDmg, l.wsDmg, l.magicDmg, l.otherDmg, l.petDmg = 0, 0, 0, 0, 0;
    l.wsSeen, l.castSeen = {}, {};
    return l;
end

local function addEnemy(l, e, t, outcome, dmg, isPetEv)
    local d = dealtBy(t, outcome, dmg);
    if outcome == 'PET_TP_MOVE_LIKELY_FAILURE' then d = 0; end
    l.count = l.count + 1;
    if isPetEv then
        -- 2026-11-07: pet damage has its own column and stays out of the
        -- owner's hits / misses / crits
        l.petDmg = l.petDmg + d;
        noteDamage(l, d);
        return;
    end
    if t == 'melee' or t == 'ranged' or t == 'pet_melee' or t == 'weaponskill' then
        if ISO_HIT[outcome] then
            l.hits = l.hits + 1;
        elseif ISO_MISS[outcome] then
            l.misses = l.misses + 1;
        end
        if ISO_CRIT[outcome] then l.crits = l.crits + 1; end
    end
    if t == 'weaponskill' then
        if markSeen(l.wsSeen, e) then l.wsUses = l.wsUses + 1; end
        l.wsDmg = l.wsDmg + d;
    elseif t == 'magic' then
        if markSeen(l.castSeen, e) then l.casts = l.casts + 1; end
        l.magicDmg = l.magicDmg + d;
    elseif t == 'melee' or t == 'ranged' or t == 'pet_melee' then
        l.physDmg = l.physDmg + d;
    else
        l.otherDmg = l.otherDmg + d;
    end
    noteDamage(l, d);
end

-- Pet lines (2026-11-07). One shape for the "all pets" line, each summon's
-- line and each summon's per-action lines: melee swings are tallied apart
-- from abilities so Acc % / Crits only ever describe swings.
local function newPetLine(label)
    local l = newLine(label);
    l.swings, l.swingHits, l.swingMisses, l.swingCrits = 0, 0, 0, 0;
    return l;
end

local function addPetEvent(l, e, t, outcome, dmg)
    l.count = l.count + 1;
    if t == 'pet_melee' then
        l.swings = l.swings + 1;
        if ISO_HIT[outcome] then
            l.swingHits = l.swingHits + 1;
            if not ISO_HEAL[outcome] then noteDamage(l, dmg); end
        elseif ISO_MISS[outcome] then
            l.swingMisses = l.swingMisses + 1;
        elseif dmg > 0 and not ISO_HEAL[outcome] then
            noteDamage(l, dmg);
        end
        if ISO_CRIT[outcome] then l.swingCrits = l.swingCrits + 1; end
        return;
    end
    markUse(l, e);
    if ISO_HEAL[outcome] then
        l.heal = l.heal + dmg;
        return;
    end
    if ISO_MISS[outcome] or JA_FAILED[outcome] or outcome == 'PET_TP_MOVE_LIKELY_FAILURE' then
        l.misses = l.misses + 1;
        return;
    end
    if MAGIC_RESISTED[outcome] then l.resists = l.resists + 1; end
    local d = dealtBy(t, outcome, dmg);
    if d > 0 then
        l.hits = l.hits + 1;
        noteDamage(l, d);
    end
end

local function petActionLabel(e, t, outcome)
    if t == 'pet_melee' then return 'Melee (auto-attack)'; end
    if t == 'skillchain' then return 'Skillchain: ' .. tostring(e.property or 'unknown'); end
    if t == 'add_effect' then
        local label = AE_LABEL[outcome] or outcome;
        if e.statusName ~= nil then label = label .. ' - ' .. tostring(e.statusName); end
        return label;
    end
    if t == 'pet_tp_move' then return actionLabel(e); end
    return actionLabel(e) .. ' [' .. (TYPE_LABEL[t] or tostring(t)) .. ']';
end

-- A mob's action landing on (or missing) a player. Shared by the player
-- view's 'Damage taken' and the mob view's 'Per target' / 'Per spawn'.
local function addTaken(l, e, t, outcome, dmg)
    l.count = l.count + 1;
    if outcome == 'MISS' or outcome == 'RANGED_MISS' or outcome == 'MOB_TP_MISS'
            or outcome == 'DODGE' then
        l.misses = l.misses + 1;
    end
    if outcome == 'PARRY' then l.parry = l.parry + 1; end
    if outcome == 'SHADOWS' then l.shadows = l.shadows + 1; end
    if outcome == 'GUARD' or outcome == 'SHIELD_BLOCK' then l.blocked = l.blocked + 1; end
    if t == 'monster_tp_move' then
        l.tpSeen = l.tpSeen or {};
        if markSeen(l.tpSeen, e) then l.tpMoves = (l.tpMoves or 0) + 1; end
    end
    if dmg > 0 and not ISO_HEAL[outcome] then
        l.hits = l.hits + 1;
        noteDamage(l, dmg);
    end
end

-- Individual-mob labels. One pass over the log: party members and their
-- pets are every actorId that carried an actorName; every other actor on
-- the defense side, or target of a party action, is a mob. Mobs sharing
-- a name are numbered in first-seen order ('Crab #1', 'Crab #2'); a name
-- seen once stays plain. Returns isEnemy(id, name) and labelFor(id, name).
local function buildEnemyIndex(events)
    local partyIds, partyNames = {}, {};
    local idName, idOrder = {}, {};
    local function note(id, name)
        if id == nil or idName[id] ~= nil then return; end
        idName[id] = name or ('#' .. tostring(id));
        table.insert(idOrder, id);
    end
    for _, e in ipairs(events) do
        sliceCheck(); -- PERF 2026-10-30: lets a sliced rebuild pause here
        if e.actorName ~= nil and e.actorId ~= nil then
            partyIds[e.actorId] = true;
            partyNames[e.actorName] = true;
        end
        if e.type == 'skillchain' then
            note(e.finisherTargetId, e.targetName);
        elseif e.side == 'offense' then
            note(e.targetId, e.targetName);
        elseif e.side == 'defense' and e.actorName == nil then
            note(e.actorId, e.actorEntityName);
        end
    end
    local function isEnemy(id, name)
        if id == nil or partyIds[id] then return false; end
        local n = name or idName[id];
        return not (n ~= nil and partyNames[n]);
    end
    local perName, spawnNo = {}, {};
    for _, id in ipairs(idOrder) do
        if isEnemy(id) then
            local n = idName[id];
            perName[n] = (perName[n] or 0) + 1;
            spawnNo[id] = perName[n];
        end
    end
    local function labelFor(id, name)
        local n = idName[id] or name or ('#' .. tostring(id));
        if spawnNo[id] ~= nil and (perName[n] or 0) > 1 then
            return n .. ' #' .. tostring(spawnNo[id]);
        end
        return n;
    end
    local function nameOf(id) return idName[id] or ('#' .. tostring(id)); end
    local function spawnNoOf(id) return spawnNo[id]; end
    return isEnemy, labelFor, nameOf, spawnNoOf;
end

local function sortBucket(b)
    table.sort(b.list, function(a, c)
        if a.damage ~= c.damage then return a.damage > c.damage; end
        if a.heal ~= c.heal then return a.heal > c.heal; end
        local au, cu = math.max(a.uses, a.count), math.max(c.uses, c.count);
        if au ~= cu then return au > cu; end
        return a.label < c.label;
    end);
end

-- ---------------------------------------------------------------------------
-- Isolation filters (2026-10-30). Rebuilt 2026-10-30 night after the
-- afternoon files were lost, plus the new Monster filter.
--
-- Weapon filter (own character only -- dlac / memory gear is the local
-- player's, and party-member events carry the local player's gear id):
--   wf.main / wf.sub = nil | { type = 'Great Axe' } | { type =, name = }
--   wf.range / wf.ammo = nil | item name
-- Monster filter (any isolated player):
--   mf = nil | { name = 'Goblin Smithy' } | { name =, id = serverId, label = 'Goblin Smithy #2' }
-- Both stack. While any filter is on, every isolation table counts only
-- matching events, and DPS combat time uses only those events.
-- ---------------------------------------------------------------------------

-- Standard FFXI combat skill ids (IItem.Skill).
local SKILL_TYPE = {
    [1] = 'Hand-to-Hand', [2] = 'Dagger', [3] = 'Sword', [4] = 'Great Sword', [5] = 'Axe',
    [6] = 'Great Axe', [7] = 'Scythe', [8] = 'Polearm', [9] = 'Katana', [10] = 'Great Katana',
    [11] = 'Club', [12] = 'Staff', [25] = 'Archery', [26] = 'Marksmanship', [27] = 'Throwing',
};
local THROWING_SKILL = 27;
local NOTHING = '(nothing)';

local itemSkillCache = {};
local typeLookupFailed = false;

-- AshitaCore:GetResourceManager():GetItemById(id).Skill -- standard Ashita v4
-- IItem surface, pcall-wrapped (unconfirmed live in this project).
local function itemSkill(id)
    if type(id) ~= 'number' then return nil; end
    local c = itemSkillCache[id];
    if c ~= nil then return c or nil; end
    local ok, sk = pcall(function()
        local it = AshitaCore:GetResourceManager():GetItemById(id);
        return it and it.Skill;
    end);
    if not ok then
        typeLookupFailed = true;
        itemSkillCache[id] = false;
        return nil;
    end
    itemSkillCache[id] = (type(sk) == 'number') and sk or false;
    return itemSkillCache[id] or nil;
end

local function weaponType(id)
    return SKILL_TYPE[itemSkill(id)] or 'Other';
end

local function localPlayerName()
    local ok, n = pcall(function()
        return AshitaCore:GetMemoryManager():GetParty():GetMemberName(0);
    end);
    if ok and type(n) == 'string' and n ~= '' then return n; end
    return nil;
end

-- Main/Sub/Ranged/Ammo for one event's gear state, or nil (no gear data).
local function gearInfoFor(gearStateId)
    local entry, ids = gearLookup(gearStateId);
    if entry == nil then return nil; end
    local any = false;
    for k in pairs(entry) do
        if k ~= 'id' then any = true; break; end
    end
    if not any then return nil; end -- the shared "no gear data" state
    ids = ids or {};
    local g = {};
    if entry.Main ~= nil then
        g.main, g.mainType = entry.Main, weaponType(ids.Main);
    else
        g.main, g.mainType = NOTHING, NOTHING;
    end
    if entry.Sub ~= nil then
        g.sub, g.subType = entry.Sub, weaponType(ids.Sub);
    else
        g.sub, g.subType = NOTHING, NOTHING;
    end
    g.range, g.ammo = entry.Range, entry.Ammo;
    -- A throwing item in the Ammo slot with no Range weapon IS the weapon.
    if g.range == nil and g.ammo ~= nil and itemSkill(ids.Ammo) == THROWING_SKILL then
        g.range, g.ammo = g.ammo, nil;
    end
    return g;
end

local function pickMatches(pick, name, typ)
    if pick == nil then return true; end
    if pick.type ~= typ then return false; end
    return pick.name == nil or pick.name == name;
end

local function weaponFilterActive(wf)
    return wf ~= nil and (wf.main ~= nil or wf.sub ~= nil or wf.range ~= nil or wf.ammo ~= nil);
end

local function passWeapon(wf, g)
    if g == nil then return false; end -- no gear data: drops out while filtering
    return pickMatches(wf.main, g.main, g.mainType)
        and pickMatches(wf.sub, g.sub, g.subType)
        and (wf.range == nil or wf.range == g.range)
        and (wf.ammo == nil or wf.ammo == (g.ammo or NOTHING));
end

local function noteTypeName(opt, typ, name)
    local set = opt[typ];
    if set == nil then set = {}; opt[typ] = set; end
    set[name] = true;
end

-- Cache-key fingerprint for the filters.
local function filterKeyUncached(wf, mf, jf)
    local function p(x)
        if x == nil then return '-'; end
        if type(x) == 'table' then return tostring(x.type) .. '/' .. tostring(x.name); end
        return tostring(x);
    end
    wf = wf or {};
    return table.concat({ p(wf.main), p(wf.sub), p(wf.range), p(wf.ammo),
        mf and (tostring(mf.name) .. '/' .. tostring(mf.id)) or '-',
        jf or '-' }, '|');
end

-- PERF (2026-10-30): same key, but the string is only rebuilt when one of
-- its inputs actually changed (was rebuilt every frame in Iso view).
-- Compared by value, so it is right whether a filter table is replaced or
-- edited in place.
local fkSnap, fkStr = {}, nil;
local EMPTY_WF = {};
local function pickA(x) if type(x) == 'table' then return x.type; end return x; end
local function pickB(x) if type(x) == 'table' then return x.name; end return nil; end
-- writes slot i, returns true if it differed
local function fkSet(i, val)
    if fkSnap[i] == val then return false; end
    fkSnap[i] = val;
    return true;
end
local function filterKey(wf, mf, jf)
    wf = wf or EMPTY_WF;
    -- no short-circuit: every slot must be refreshed
    local d = false;
    if fkSet(1, jf) then d = true; end
    if fkSet(2, mf and mf.name) then d = true; end
    if fkSet(3, mf and mf.id) then d = true; end
    if fkSet(4, pickA(wf.main)) then d = true; end
    if fkSet(5, pickB(wf.main)) then d = true; end
    if fkSet(6, pickA(wf.sub)) then d = true; end
    if fkSet(7, pickB(wf.sub)) then d = true; end
    if fkSet(8, pickA(wf.range)) then d = true; end
    if fkSet(9, pickB(wf.range)) then d = true; end
    if fkSet(10, pickA(wf.ammo)) then d = true; end
    if fkSet(11, pickB(wf.ammo)) then d = true; end
    if d or fkStr == nil then fkStr = filterKeyUncached(wf, mf, jf); end
    return fkStr;
end

-- jf (2026-10-30): job filter -- nil = all jobs, else a job abbreviation
-- ('WAR'). Own events use the event's own job; damage taken uses the
-- player's most recent job seen before that event (defense events don't
-- carry the target's job), so a hit taken before the player's first own
-- action drops out while a job is picked.
local function computeIsolation(isoKey, wf, mf, jf)
    local events = currentEvents();
    local iso = {
        name = isoKey, found = false, matched = 0,
        phys = {
            melee  = newLine('Melee (auto-attack)'),
            ws     = newLine('Weaponskill'),
            ranged = newLine('Ranged attack'),
            rws    = newLine('Ranged weaponskill'),
            pet    = newLine('Pet melee'),
        },
        -- 2026-10-30: Physical shows one line per WS name
        physWs = newBucket(), physRws = newBucket(),
        wsByName = newBucket(), magic = newBucket(), ja = newBucket(),
        effects = newBucket(), other = newBucket(), taken = newBucket(),
        enemies = newBucket(), byTarget = newBucket(), bySpawn = newBucket(),
        -- 2026-11-07: this player's pets -- one line for all of them, and
        -- one per summon (each with its own per-action lines)
        pets = { all = newPetLine('Pets'), bySummon = newBucket() },
        dealt = 0, healed = 0,
        -- filter dropdown options
        opt = { main = {}, sub = {}, range = {}, ammo = {}, mobs = {}, jobs = {} },
    };
    local isoIsMob = isoKey:sub(-6) == ' (mob)';
    local baseName = (isoKey:gsub(' %(mob%)$', ''));
    local isEnemy, labelFor, nameOf, spawnNoOf = buildEnemyIndex(events);

    wf = wf or {};
    iso.gearOn = (not isoIsMob) and gearLookupAvailable() and (localPlayerName() == baseName);
    if not iso.gearOn then wf = {}; end
    if isoIsMob then mf = nil; jf = nil; end
    local wfOn = weaponFilterActive(wf);
    iso.filtering = wfOn or (mf ~= nil) or (jf ~= nil);
    local lastJob = nil; -- this player's most recent job, for damage taken

    local gearCache = {};
    local function gearOf(e)
        local id = e.gearStateId;
        if id == nil then return nil; end
        local g = gearCache[id];
        if g == nil then
            g = gearInfoFor(id) or false;
            gearCache[id] = g;
        end
        return g or nil;
    end

    -- The enemy on the other side of an event, or nil.
    local function opponentOf(e, mine)
        if mine then
            local id;
            if e.type == 'skillchain' then
                id = e.finisherTargetId;
            elseif e.side == 'offense' then
                id = e.targetId;
            end
            if id ~= nil and isEnemy(id, e.targetName) then return id; end
            return nil;
        end
        if e.actorId ~= nil and isEnemy(e.actorId, e.actorEntityName) then return e.actorId; end
        return nil;
    end

    local mobSeen = {};
    local function noteMob(id)
        if mobSeen[id] then return; end
        mobSeen[id] = true;
        local n = nameOf(id);
        local m = iso.opt.mobs[n];
        if m == nil then m = { spawns = {} }; iso.opt.mobs[n] = m; end
        table.insert(m.spawns, { id = id, label = labelFor(id), no = spawnNoOf(id) or 0 });
    end

    local filteredTimes = {};
    -- 2026-11-07: owner's command JA line by actionId (e.g. "Claw" 592), so
    -- the pet move with the same id can show its damage on that JA row.
    local jaLineById = {};

    for _, e in ipairs(events) do
        sliceCheck(); -- PERF 2026-10-30: lets a sliced rebuild pause here
        local key, _, evJob, petName = rowKeyFor(e, 'actorName');
        if key == isoKey and evJob ~= nil then lastJob = evJob; end
        local outcome = e.outcome or '';
        local dmg = type(e.damage) == 'number' and e.damage or 0;
        local t = e.type;

        local mine = (key == isoKey and outcome ~= 'TOO_FAR'); -- too far = never went off
        -- Damage taken: something else acting on this player.
        local taken = (not mine) and (not isoIsMob) and key ~= isoKey and e.side == 'defense'
            and e.targetName == baseName and t ~= 'skillchain';

        if mine or taken then
            if mine then iso.found = true; end

            local g = iso.gearOn and gearOf(e) or nil;
            local opp = (not isoIsMob) and opponentOf(e, mine) or nil;

            -- dropdown options (from ALL of this player's events; Sub and
            -- Ammo follow the Main / Ranged picks)
            if mine and g ~= nil then
                noteTypeName(iso.opt.main, g.mainType, g.main);
                if pickMatches(wf.main, g.main, g.mainType) then
                    noteTypeName(iso.opt.sub, g.subType, g.sub);
                end
                if g.range ~= nil then iso.opt.range[g.range] = true; end
                if wf.range == nil or wf.range == g.range then
                    iso.opt.ammo[g.ammo or NOTHING] = true;
                end
            end
            if opp ~= nil then noteMob(opp); end
            local thisJob = mine and evJob or lastJob;
            if mine and evJob ~= nil then iso.opt.jobs[evJob] = true; end

            local pass = true;
            if jf ~= nil and thisJob ~= jf then pass = false; end
            if pass and wfOn and not passWeapon(wf, g) then pass = false; end
            if pass and mf ~= nil then
                if opp == nil then
                    pass = false;
                elseif mf.id ~= nil then
                    pass = (opp == mf.id);
                else
                    pass = (nameOf(opp) == mf.name);
                end
            end

            if pass then
                iso.matched = iso.matched + 1;
                if iso.filtering and type(e.timestamp) == 'number' then
                    table.insert(filteredTimes, { timestamp = e.timestamp });
                end
            end

            if pass and mine then
                local jobId = e.actorJob or e.finisherJob;
                if jobId ~= nil then iso.job = JOB_ABBR[jobId] or tostring(jobId); end

                if petName ~= nil then
                    -- 2026-11-07: pet action -> Pets table only
                    addPetEvent(iso.pets.all, e, t, outcome, dmg);
                    local sl = iso.pets.bySummon.map[petName];
                    if sl == nil then
                        sl = newPetLine(petName);
                        sl.actions = newBucket();
                        iso.pets.bySummon.map[petName] = sl;
                        table.insert(iso.pets.bySummon.list, sl);
                    end
                    addPetEvent(sl, e, t, outcome, dmg);
                    local al = sl.actions.map[petActionLabel(e, t, outcome)];
                    if al == nil then
                        local lab = petActionLabel(e, t, outcome);
                        al = newPetLine(lab);
                        sl.actions.map[lab] = al;
                        table.insert(sl.actions.list, al);
                    end
                    addPetEvent(al, e, t, outcome, dmg);
                    -- 2026-11-07: pet move damage onto the owner's command
                    -- JA row (Pet dmg columns only -- already in the
                    -- totals via the Pets table, so not added to l.damage)
                    if t == 'pet_tp_move' and e.actionId ~= nil then
                        local jl = jaLineById[e.actionId];
                        if jl ~= nil then
                            local d = dealtBy(t, outcome, dmg);
                            if outcome == 'PET_TP_MOVE_LIKELY_FAILURE' then d = 0; end
                            if d > 0 then
                                jl.petDmg = (jl.petDmg or 0) + d;
                                jl.petHits = (jl.petHits or 0) + 1;
                                if jl.petHigh == nil or d > jl.petHigh then jl.petHigh = d; end
                            end
                        end
                    end
                elseif t == 'melee' then
                    addPhysical(iso.phys.melee, outcome, dmg);
                elseif t == 'ranged' then
                    addPhysical(iso.phys.ranged, outcome, dmg);
                elseif t == 'pet_melee' then
                    addPhysical(iso.phys.pet, outcome, dmg);
                elseif t == 'weaponskill' then
                    local ranged = isRangedWs(e);
                    local l = ranged and iso.phys.rws or iso.phys.ws;
                    markUse(l, e);
                    addPhysical(l, outcome, dmg);
                    local pl = namedLine(ranged and iso.physRws or iso.physWs,
                        (ranged and 'Ranged WS: ' or 'WS: ') .. actionLabel(e));
                    pl.isWs = true;
                    markUse(pl, e);
                    addPhysical(pl, outcome, dmg);
                    local n = namedLine(iso.wsByName, actionLabel(e) .. (ranged and ' (ranged)' or ''));
                    markUse(n, e);
                    addPhysical(n, outcome, dmg);
                elseif t == 'magic' then
                    local l = namedLine(iso.magic, actionLabel(e));
                    markUse(l, e);
                    l.count = l.count + 1;
                    if MAGIC_DMG[outcome] then
                        l.hits = l.hits + 1;
                        noteDamage(l, dmg);
                    end
                    if MAGIC_BURST[outcome] then l.bursts = l.bursts + 1; end
                    if MAGIC_RESISTED[outcome] then l.resists = l.resists + 1; end
                    if outcome == 'MAGIC_HEAL' then l.heal = l.heal + dmg; end
                elseif t == 'job_ability' then
                    local l = namedLine(iso.ja, actionLabel(e));
                    if e.actionId ~= nil then jaLineById[e.actionId] = l; end
                    markUse(l, e);
                    l.count = l.count + 1;
                    if outcome == 'JA_DAMAGE' then
                        l.hits = l.hits + 1;
                        noteDamage(l, dmg);
                    elseif outcome == 'JA_HEAL' then
                        l.heal = l.heal + dmg;
                    elseif JA_FAILED[outcome] then
                        l.misses = l.misses + 1;
                    end
                elseif t == 'add_effect' or t == 'skillchain' then
                    local label;
                    if t == 'skillchain' then
                        label = 'Skillchain: ' .. tostring(e.property or 'unknown');
                    else
                        label = AE_LABEL[outcome] or outcome;
                        if e.statusName ~= nil then label = label .. ' - ' .. tostring(e.statusName); end
                    end
                    local l = namedLine(iso.effects, label);
                    l.count = l.count + 1;
                    if AE_DAMAGE[outcome] then
                        l.hits = l.hits + 1;
                        noteDamage(l, dmg);
                    end
                    if type(e.thLevel) == 'number' and (l.thMax == nil or e.thLevel > l.thMax) then
                        l.thMax = e.thLevel;
                    end
                else
                    -- TP moves, pet TP moves, items, any type added later
                    local l = namedLine(iso.other, actionLabel(e) .. ' [' .. (TYPE_LABEL[t] or tostring(t)) .. ']');
                    markUse(l, e);
                    l.count = l.count + 1;
                    if ISO_HEAL[outcome] then
                        l.heal = l.heal + dmg;
                    elseif dmg > 0 then
                        l.hits = l.hits + 1;
                        noteDamage(l, dmg);
                    end
                end

                if isoIsMob then
                    -- Mob view: its actions split by the player hit, and by spawn.
                    if t ~= 'skillchain' then
                        local tName = e.targetName or ('#' .. tostring(e.targetId));
                        addTaken(namedLine(iso.byTarget, tName), e, t, outcome, dmg);
                        addTaken(namedLine(iso.bySpawn, labelFor(e.actorId, e.actorEntityName)), e, t, outcome, dmg);
                    end
                elseif opp ~= nil then
                    -- Player view: everything this player did to each individual mob.
                    local label = labelFor(opp, e.targetName);
                    local l = iso.enemies.map[label];
                    if l == nil then
                        l = newEnemyLine(label);
                        iso.enemies.map[label] = l;
                        table.insert(iso.enemies.list, l);
                    end
                    addEnemy(l, e, t, outcome, dmg, petName ~= nil);
                end
            elseif pass and taken then
                addTaken(namedLine(iso.taken, TYPE_LABEL[t] or tostring(t)), e, t, outcome, dmg);
            end
        end
    end

    for _, l in pairs(iso.phys) do iso.dealt = iso.dealt + l.damage; end
    iso.dealt = iso.dealt + iso.pets.all.damage;
    iso.healed = iso.healed + iso.pets.all.heal;
    sortBucket(iso.pets.bySummon);
    for _, sl in ipairs(iso.pets.bySummon.list) do sortBucket(sl.actions); end
    if #iso.pets.bySummon.list == 1 then
        iso.pets.all.label = 'Pet: ' .. iso.pets.bySummon.list[1].label;
    elseif #iso.pets.bySummon.list > 1 then
        iso.pets.all.label = 'Pets (' .. #iso.pets.bySummon.list .. ' summons)';
    end
    for _, b in ipairs({ iso.magic, iso.ja, iso.effects, iso.other }) do
        for _, l in ipairs(b.list) do
            iso.dealt = iso.dealt + l.damage;
            iso.healed = iso.healed + l.heal;
        end
    end
    for _, b in ipairs({ iso.physWs, iso.physRws, iso.wsByName, iso.magic, iso.ja, iso.effects,
                         iso.other, iso.taken, iso.enemies, iso.byTarget, iso.bySpawn }) do
        sortBucket(b);
    end
    for _, m in pairs(iso.opt.mobs) do
        table.sort(m.spawns, function(a, b) return a.no < b.no; end);
    end
    if iso.filtering then
        iso.combatSeconds = computeCombatSeconds(filteredTimes);
    else
        iso.combatSeconds = computeCombatSeconds(events);
    end
    iso.typeLookupFailed = typeLookupFailed;
    return iso;
end


-- ===========================================================================
-- Theme -- black / grey. Pushed around every mobparser window and popped
-- right after, so it never leaks into other addons' windows. Each colour
-- is only pushed if this Ashita build defines that ImGuiCol_* constant,
-- and the pop count always matches what was actually pushed.
-- ===========================================================================

local function c(r, g, b, a) return { r / 255, g / 255, b / 255, a or 1.0 }; end

-- User-editable colour slots. Each slot drives one or more ImGuiCol_*
-- entries, so the whole window can be recoloured from ~16 pickers in
-- Settings > Colors. Defaults are the black/grey scheme. Saved to the
-- settings file as settings.data.guiColors[slotKey] = {r,g,b,a}.
local COLOR_SLOTS = {
    { key = 'text',        label = 'Text',                      def = c(220, 220, 220),
      cols = { 'ImGuiCol_Text' } },
    { key = 'textDim',     label = 'Text (dim / zero values)',  def = c(120, 120, 120),
      cols = { 'ImGuiCol_TextDisabled' } },
    { key = 'windowBg',    label = 'Window background',         def = c(10, 10, 10, 0.94),
      cols = { 'ImGuiCol_WindowBg', 'ImGuiCol_PopupBg' } },
    { key = 'titleBg',     label = 'Title bar',                 def = c(0, 0, 0),
      cols = { 'ImGuiCol_TitleBg', 'ImGuiCol_TitleBgCollapsed' } },
    { key = 'titleActive', label = 'Title bar (focused)',       def = c(28, 28, 28),
      cols = { 'ImGuiCol_TitleBgActive' } },
    { key = 'border',      label = 'Borders / separators',      def = c(70, 70, 70),
      cols = { 'ImGuiCol_Border', 'ImGuiCol_Separator', 'ImGuiCol_TableBorderStrong' } },
    { key = 'innerBorder', label = 'Table inner lines',         def = c(48, 48, 48),
      cols = { 'ImGuiCol_TableBorderLight' } },
    { key = 'frame',       label = 'Input boxes / checkboxes',  def = c(38, 38, 38),
      cols = { 'ImGuiCol_FrameBg', 'ImGuiCol_ScrollbarBg' } },
    { key = 'frameHover',  label = 'Input boxes (hover)',       def = c(58, 58, 58),
      cols = { 'ImGuiCol_FrameBgHovered', 'ImGuiCol_FrameBgActive' } },
    { key = 'checkMark',   label = 'Checkmark',                 def = c(210, 210, 210),
      cols = { 'ImGuiCol_CheckMark' } },
    { key = 'button',      label = 'Button',                    def = c(45, 45, 45),
      cols = { 'ImGuiCol_Button' } },
    { key = 'buttonHover', label = 'Button (hover)',            def = c(70, 70, 70),
      cols = { 'ImGuiCol_ButtonHovered' } },
    { key = 'buttonOn',    label = 'Button (pressed / selected)', def = c(105, 105, 105),
      cols = { 'ImGuiCol_ButtonActive' } },
    { key = 'header',      label = 'Column headers',            def = c(30, 30, 30),
      cols = { 'ImGuiCol_TableHeaderBg', 'ImGuiCol_Header' } },
    { key = 'headerHover', label = 'Column headers (hover)',    def = c(72, 72, 72),
      cols = { 'ImGuiCol_HeaderHovered', 'ImGuiCol_HeaderActive', 'ImGuiCol_SeparatorHovered' } },
    { key = 'rowStripe',   label = 'Alternate row stripe',      def = c(255, 255, 255, 0.04),
      cols = { 'ImGuiCol_TableRowBgAlt' } },
    { key = 'grab',        label = 'Scrollbar / resize grips',  def = c(80, 80, 80),
      cols = { 'ImGuiCol_ScrollbarGrab', 'ImGuiCol_ScrollbarGrabHovered', 'ImGuiCol_ScrollbarGrabActive',
               'ImGuiCol_SliderGrab', 'ImGuiCol_SliderGrabActive', 'ImGuiCol_SeparatorActive',
               'ImGuiCol_ResizeGrip', 'ImGuiCol_ResizeGripHovered', 'ImGuiCol_ResizeGripActive',
               'ImGuiCol_TextSelectedBg' } },
};

-- Always transparent so the window background shows through.
local FIXED_COLORS = {
    { 'ImGuiCol_ChildBg',    c(0, 0, 0, 0.0) },
    { 'ImGuiCol_TableRowBg', c(0, 0, 0, 0.0) },
};

-- Live editable copies, {r,g,b,a} arrays (what imgui.ColorEdit4 wants).
local colors = {};

local function copyColor(src) return { src[1], src[2], src[3], src[4] }; end

local function resetColors()
    for _, slot in ipairs(COLOR_SLOTS) do colors[slot.key] = copyColor(slot.def); end
end

local function clamp01(v)
    v = tonumber(v) or 0;
    if v < 0 then return 0; end
    if v > 1 then return 1; end
    return v;
end

-- Pull saved colours from settings (called lazily, after mobparser.lua
-- has run settings.load()).
local colorsLoaded = false;
local function ensureColorsLoaded()
    if colorsLoaded then return; end
    colorsLoaded = true;
    resetColors();
    local saved = settings.data.guiColors;
    if type(saved) ~= 'table' then return; end
    for _, slot in ipairs(COLOR_SLOTS) do
        local s = saved[slot.key];
        if type(s) == 'table' and s.r ~= nil then
            colors[slot.key] = { clamp01(s.r), clamp01(s.g), clamp01(s.b), clamp01(s.a == nil and 1 or s.a) };
        end
    end
end

-- Saving: ColorEdit4 reports a change every frame while dragging, so
-- writes are throttled to once a second, plus a final flush when the
-- settings window closes.
local colorsDirty, lastColorSave = false, -math.huge;

local function saveColors()
    local out = {};
    for _, slot in ipairs(COLOR_SLOTS) do
        local col = colors[slot.key];
        out[slot.key] = { r = col[1], g = col[2], b = col[3], a = col[4] };
    end
    settings.data.guiColors = out;
    pcall(settings.save);
    colorsDirty = false;
    lastColorSave = os.clock();
end

local function maybeSaveColors(force)
    if not colorsDirty then return; end
    if force or (os.clock() - lastColorSave) >= 1.0 then saveColors(); end
end

local function pushTheme()
    ensureColorsLoaded();
    local n = 0;
    for _, slot in ipairs(COLOR_SLOTS) do
        local col = colors[slot.key];
        for _, name in ipairs(slot.cols) do
            local id = _G[name];
            if id ~= nil then
                imgui.PushStyleColor(id, col);
                n = n + 1;
            end
        end
    end
    for _, entry in ipairs(FIXED_COLORS) do
        local id = _G[entry[1]];
        if id ~= nil then
            imgui.PushStyleColor(id, entry[2]);
            n = n + 1;
        end
    end
    return n;
end

local function popTheme(n)
    if n > 0 then imgui.PopStyleColor(n); end
end

local function drawColorSettings()
    ensureColorsLoaded();
    imgui.TextDisabled('Click a swatch to pick a colour; last value is opacity.');
    for _, slot in ipairs(COLOR_SLOTS) do
        if imgui.ColorEdit4(slot.label .. '##color_' .. slot.key, colors[slot.key]) then
            colorsDirty = true;
        end
    end
    if imgui.Button('Reset colors to black/grey') then
        resetColors();
        colorsDirty = true;
        maybeSaveColors(true);
    end
    maybeSaveColors(false);
end

-- ===========================================================================
-- Settings helpers (player row limit, persisted via mobparser_settings)
-- ===========================================================================

local MAX_PLAYERS_MIN, MAX_PLAYERS_MAX, MAX_PLAYERS_DEFAULT = 1, 18, 6;

local function getMaxPlayers()
    local v = tonumber(settings.data.guiMaxPlayers) or MAX_PLAYERS_DEFAULT;
    v = math.floor(v);
    if v < MAX_PLAYERS_MIN then v = MAX_PLAYERS_MIN; end
    if v > MAX_PLAYERS_MAX then v = MAX_PLAYERS_MAX; end
    return v;
end

local function setMaxPlayers(v)
    v = math.floor(tonumber(v) or MAX_PLAYERS_DEFAULT);
    if v < MAX_PLAYERS_MIN then v = MAX_PLAYERS_MIN; end
    if v > MAX_PLAYERS_MAX then v = MAX_PLAYERS_MAX; end
    if settings.data.guiMaxPlayers ~= v then
        settings.data.guiMaxPlayers = v;
        pcall(settings.save);
    end
end

-- ===========================================================================
-- Chat report (2026-10-29). Prints the Player view (players only, sorted by
-- damage, same row limit as the window) to say / party / linkshell.
-- Lines go out one at a time, REPORT_SPACING seconds apart, so a 6-line
-- report doesn't trip the client's chat spam limit. Sent through
-- AshitaCore:GetChatManager():QueueCommand(1, ...) -- the same as typing
-- the /s /p /l command yourself.
-- ===========================================================================

local REPORT_MODES = {
    say       = { cmd = '/s', label = 'Say' },
    party     = { cmd = '/p', label = 'Party' },
    linkshell = { cmd = '/l', label = 'Linkshell' },
};
local REPORT_MODE_ORDER = { 'say', 'party', 'linkshell' };
local REPORT_ALIASES = {
    s = 'say', say = 'say',
    p = 'party', party = 'party',
    l = 'linkshell', ls = 'linkshell', linkshell = 'linkshell',
};
local REPORT_SPACING = 1.5; -- seconds between lines
local reportQueue = {};
local nextReportAt = 0;

local function getReportMode()
    local m = settings.data.guiReportMode;
    if REPORT_MODES[m] == nil then m = 'party'; end
    return m;
end

local function setReportMode(m)
    if REPORT_MODES[m] == nil or settings.data.guiReportMode == m then return; end
    settings.data.guiReportMode = m;
    pcall(settings.save);
end

local function fmtDuration(sec)
    sec = math.floor(sec or 0);
    if sec >= 60 then
        return string.format('%dm%02ds', math.floor(sec / 60), sec % 60);
    end
    return string.format('%ds', sec);
end

local function buildReportLines()
    local rows, combatSeconds = computeRows('actorName', math.huge); -- complete, not sliced
    local players = {};
    for _, r in ipairs(rows) do
        if not r.isMob then table.insert(players, r); end
    end
    table.sort(players, function(a, b)
        local ad, bd = a.damage or 0, b.damage or 0;
        if ad == bd then return tostring(a.name) < tostring(b.name); end
        return ad > bd;
    end);
    local limit = math.min(#players, getMaxPlayers());
    if limit == 0 then return nil; end

    local totalDmg = 0;
    for i = 1, limit do totalDmg = totalDmg + (players[i].damage or 0); end

    local lines = {
        string.format('mobparser damage (%s of combat)', fmtDuration(combatSeconds)),
    };
    for i = 1, limit do
        local r = players[i];
        local dmg = r.damage or 0;
        local name = tostring(r.name):gsub('[^%w%s%(%)%-\']', '');
        if r.job ~= nil then name = name .. ' (' .. r.job .. ')'; end
        local parts = { string.format('%d. %s: %d', i, name, dmg) };
        if totalDmg > 0 then
            table.insert(parts, string.format('(%.1f%%)', dmg / totalDmg * 100));
        end
        if r.dps ~= nil then table.insert(parts, string.format('| %.1f DPS', r.dps)); end
        if r.acc ~= nil then table.insert(parts, string.format('| Acc %.1f%%', r.acc)); end
        table.insert(lines, table.concat(parts, ' '));
    end
    return lines;
end

-- Sends one queued line when its time comes. Called every frame from
-- render(), whether or not the window is open.
local function pumpReport()
    if #reportQueue == 0 then return; end
    local now = os.clock();
    if now < nextReportAt then return; end
    local line = table.remove(reportQueue, 1);
    AshitaCore:GetChatManager():QueueCommand(1, line);
    nextReportAt = now + REPORT_SPACING;
end

-- mode: 'say'/'party'/'linkshell' or s/p/l/ls; nil = the Settings choice.
-- Returns ok (bool), message (string).
function mobparser_gui.report(mode)
    local key = (mode == nil) and getReportMode() or REPORT_ALIASES[tostring(mode):lower()];
    if key == nil then
        return false, 'unknown chat mode "' .. tostring(mode) .. '" -- use say, party or linkshell (s / p / l).';
    end
    if #reportQueue > 0 then
        return false, 'a report is still being sent -- wait a few seconds.';
    end
    local lines = buildReportLines();
    if lines == nil then
        return false, 'nothing to report yet.';
    end
    local cmd = REPORT_MODES[key].cmd;
    for _, l in ipairs(lines) do table.insert(reportQueue, cmd .. ' ' .. l); end
    nextReportAt = 0;
    return true, string.format('reporting %d line(s) to %s.', #lines, REPORT_MODES[key].label);
end

-- ===========================================================================
-- Sorting -- self-managed. ImGui's TableGetSortSpecs() could not be read
-- reliably through Ashita's binding (Specs comes back as userdata, not a
-- Lua table, so the old code silently skipped every sort). Instead each
-- header is drawn with imgui.TableHeader() and a click on it is detected
-- with imgui.IsItemClicked(); sort state lives in `state` below.
-- ===========================================================================

local function applySort(rows)
    local colKey, asc = state.sortKey, state.sortAsc;
    if colKey == nil then return; end
    table.sort(rows, function(a, b)
        local av, bv;
        if colKey == 'name' or colKey == 'job' then
            av, bv = tostring(a[colKey] or ''):lower(), tostring(b[colKey] or ''):lower();
        else
            av = a[colKey]; bv = b[colKey];
            av = (av == nil) and -math.huge or av;
            bv = (bv == nil) and -math.huge or bv;
        end
        if av == bv then
            -- stable tie-break on name so rows don't jitter frame to frame
            return tostring(a.name or '') < tostring(b.name or '');
        end
        if asc then return av < bv; end
        return av > bv;
    end);
end

local function onHeaderClicked(key)
    if state.sortKey == key then
        state.sortAsc = not state.sortAsc;
    else
        state.sortKey = key;
        state.sortAsc = (key == 'name'); -- names A->Z first, numbers high->low first
    end
end

-- ===========================================================================
-- Settings window
-- ===========================================================================

local function drawSettingsBody()
    if imgui.Button('Open color editor') then
        state.colorsVisible[1] = true;
    end
    imgui.Separator();
    imgui.Text('Players shown in the main window (1-18):');
    local buf = { getMaxPlayers() };
    imgui.PushItemWidth(120);
    if imgui.InputInt('##mobparser_maxplayers', buf) then
        setMaxPlayers(buf[1]);
    end
    imgui.PopItemWidth();
    imgui.Text('Report button sends to:');
    local cur = getReportMode();
    for _, m in ipairs(REPORT_MODE_ORDER) do
        imgui.SameLine();
        local on = { cur == m };
        if imgui.Checkbox(REPORT_MODES[m].label .. '##report_' .. m, on) and on[1] then
            setReportMode(m);
        end
    end
    local showJob = { settings.data.guiShowJob ~= false };
    if imgui.Checkbox('Show job column', showJob) then
        settings.data.guiShowJob = showJob[1];
        pcall(settings.save);
    end
    local openOnLoad = { settings.data.guiOpenOnLoad ~= false };
    if imgui.Checkbox('Open this window when mobparser loads', openOnLoad) then
        settings.data.guiOpenOnLoad = openOnLoad[1];
        pcall(settings.save);
    end
    local clearOnZone = { settings.data.clearOnZone ~= false };
    if imgui.Checkbox('Clear session data on zone', clearOnZone) then
        settings.data.clearOnZone = clearOnZone[1];
        pcall(settings.save);
    end
    local showEnemies = { settings.data.guiShowEnemies == true };
    if imgui.Checkbox('Show enemies (damage mobs did to you)', showEnemies) then
        settings.data.guiShowEnemies = showEnemies[1];
        pcall(settings.save);
    end
    imgui.Separator();


    imgui.Text('Display: show/hide a column below. Logging is not affected.');
    imgui.Text('Tracking: stop counting a stat into this window\'s totals.');
    imgui.Text('Raw events keep being captured either way.');
    imgui.Separator();

    for _, group in ipairs(STAT_GROUPS) do
        local headerOk, headerOpen = pcall(imgui.CollapsingHeader, group.label);
        local expanded = headerOk and headerOpen;
        if not headerOk then
            imgui.Separator();
            imgui.Text(group.label);
            expanded = true;
        end
        if expanded then
            if imgui.BeginTable('mobparser.settings.' .. group.id, 3,
                    bit.bor(ImGuiTableFlags_Borders, ImGuiTableFlags_RowBg)) then
                imgui.TableSetupColumn('Stat');
                imgui.TableSetupColumn('Display');
                imgui.TableSetupColumn('Tracking');
                imgui.TableHeadersRow();

                for _, stat in ipairs(group.stats) do
                    imgui.TableNextRow();
                    imgui.TableNextColumn();
                    imgui.Text(stat.label);

                    imgui.TableNextColumn();
                    local dOn = { state.displayOn[stat.key] };
                    if imgui.Checkbox('##display_' .. stat.key, dOn) then
                        state.displayOn[stat.key] = dOn[1];
                    end

                    imgui.TableNextColumn();
                    local tOn = { state.trackingOn[stat.key] };
                    if imgui.Checkbox('##tracking_' .. stat.key, tOn) then
                        state.trackingOn[stat.key] = tOn[1];
                    end
                end

                imgui.EndTable();
            end
        end
    end
end

local function drawColorsWindow()
    if not state.colorsVisible[1] then
        maybeSaveColors(true);
        return;
    end
    local pushed = pushTheme();
    if imgui.Begin('mobparser colors', state.colorsVisible) then
        local ok, err = pcall(drawColorSettings);
        if not ok then imgui.TextDisabled('colors error: ' .. tostring(err)); end
    end
    imgui.End();
    popTheme(pushed);
end

local function drawSettings()
    if not state.settingsVisible[1] then return; end
    local pushed = pushTheme();
    if imgui.Begin('mobparser settings', state.settingsVisible) then
        local ok, err = pcall(drawSettingsBody);
        if not ok then imgui.TextDisabled('settings error: ' .. tostring(err)); end
    end
    imgui.End();
    popTheme(pushed);
end

-- ===========================================================================
-- Main table window
-- ===========================================================================

-- NOTE: ImGuiTableFlags_Sortable deliberately NOT set -- sorting is handled
-- by onHeaderClicked() above. Reorder (drag headers) and hide (right-click
-- a header) still use ImGui's own machinery.
local tableFlags = bit.bor(
    ImGuiTableFlags_Resizable, ImGuiTableFlags_Reorderable, ImGuiTableFlags_Hideable,
    ImGuiTableFlags_RowBg, ImGuiTableFlags_Borders,
    ImGuiTableFlags_NoBordersInBody, ImGuiTableFlags_ScrollY
);

local HEADER_ROW_FLAG = ImGuiTableRowFlags_Headers or 1;

local function visibleColumns()
    local cols = { 'name' };
    if state.groupBy == 'actorName' and settings.data.guiShowJob ~= false then
        table.insert(cols, 'job');
    end
    for _, key in ipairs(ALL_STAT_KEYS) do
        if state.displayOn[key] then table.insert(cols, key); end
    end
    return cols;
end

local function columnLabel(key)
    if key == 'name' then
        return state.groupBy == 'actorName' and 'Player' or 'Event type';
    end
    if key == 'job' then return 'Job'; end
    return STAT_META[key].label;
end

local function drawHeaderRow(columns)
    imgui.TableNextRow(HEADER_ROW_FLAG);
    for _, key in ipairs(columns) do
        imgui.TableNextColumn();
        local label = columnLabel(key);
        if state.sortKey == key then
            label = label .. (state.sortAsc and ' ^' or ' v');
        end
        -- '###' keeps the item ID stable while the arrow text changes
        imgui.TableHeader(label .. '###hdr_' .. key);
        if imgui.IsItemClicked(0) then
            onHeaderClicked(key);
        end
    end
end

local function drawGroupButton(label, value)
    local active = (state.groupBy == value);
    local pushed = 0;
    if active and ImGuiCol_Button ~= nil then
        ensureColorsLoaded();
        imgui.PushStyleColor(ImGuiCol_Button, colors.buttonOn);
        pushed = 1;
    end
    if imgui.Button(label .. '###grp_' .. value) then
        if state.groupBy ~= value then
            state.groupBy = value;
            if state.sortKey == 'name' then state.sortAsc = true; end
        end
    end
    if pushed > 0 then imgui.PopStyleColor(pushed); end
end

-- ---------------------------------------------------------------------------
-- Isolation view drawing
-- ---------------------------------------------------------------------------

local ISO_TABLE_FLAGS = bit.bor(ImGuiTableFlags_Resizable, ImGuiTableFlags_RowBg, ImGuiTableFlags_Borders);

-- Cell formatters: nil = draw a dim '--'.
local function fInt(v)
    if v == nil or v == 0 then return nil; end
    return tostring(math.floor(v + 0.5));
end
local function fPct(part, whole)
    if whole == nil or whole <= 0 or part == nil or part <= 0 then return nil; end
    return string.format('%.1f%%', part / whole * 100);
end
-- Average per hit that did damage (a parried / shadowed 'hit' counts for
-- accuracy but would drag the average down).
local function fAvg(l)
    if l.dmgHits <= 0 or l.damage <= 0 then return nil; end
    return string.format('%.1f', l.damage / l.dmgHits);
end
local function fAcc(l) return fPct(l.hits, l.hits + l.misses) or ((l.hits + l.misses) > 0 and '0.0%' or nil); end

local function drawIsoTable(id, title, cols, lines)
    imgui.Separator();
    imgui.Text(title);
    if imgui.BeginTable(id, #cols, ISO_TABLE_FLAGS) then
        local ok, err = pcall(function()
            for _, col in ipairs(cols) do imgui.TableSetupColumn(col[1]); end
            imgui.TableHeadersRow();
            for _, l in ipairs(lines) do
                imgui.TableNextRow();
                for i, col in ipairs(cols) do
                    imgui.TableNextColumn();
                    local v = col[2](l);
                    if i == 1 then
                        imgui.Text(tostring(v));
                    elseif v == nil then
                        imgui.TextDisabled('--');
                    else
                        imgui.Text(v);
                    end
                end
            end
        end);
        imgui.EndTable();
        if not ok then imgui.TextDisabled('table error: ' .. tostring(err)); end
    end
end

-- ---------------------------------------------------------------------------
-- Filter dropdowns (2026-10-30). ImGui BeginCombo / Selectable / EndCombo,
-- pcall-wrapped by the caller (not yet confirmed on this Ashita build).
-- ---------------------------------------------------------------------------
local FILTER_COMBO_WIDTH = 190;

local function sortedKeys(t)
    local out = {};
    for k in pairs(t) do table.insert(out, k); end
    table.sort(out, function(a, b) return tostring(a):lower() < tostring(b):lower(); end);
    return out;
end

-- Combo of weapon types with their items nested under them. opt is
-- { [type] = { [name] = true } }. Returns changed, newPick.
local function typeNameCombo(id, pick, opt)
    local preview = 'All';
    if pick ~= nil then
        preview = pick.name or (pick.type .. ' (all)');
    end
    local changed, newPick = false, pick;
    imgui.PushItemWidth(FILTER_COMBO_WIDTH);
    if imgui.BeginCombo('##' .. id, preview) then
        if imgui.Selectable('All##' .. id .. '_all', pick == nil) then
            changed, newPick = true, nil;
        end
        local n = 0;
        for _, typ in ipairs(sortedKeys(opt)) do
            local names = sortedKeys(opt[typ]);
            if #names == 1 then
                n = n + 1;
                local sel = pick ~= nil and pick.type == typ and pick.name == names[1];
                if imgui.Selectable(typ .. ': ' .. names[1] .. '##' .. id .. n, sel) then
                    changed, newPick = true, { type = typ, name = names[1] };
                end
            else
                n = n + 1;
                local selAll = pick ~= nil and pick.type == typ and pick.name == nil;
                if imgui.Selectable(typ .. ' (all)##' .. id .. n, selAll) then
                    changed, newPick = true, { type = typ };
                end
                for _, nm in ipairs(names) do
                    n = n + 1;
                    local sel = pick ~= nil and pick.type == typ and pick.name == nm;
                    if imgui.Selectable('    ' .. nm .. '##' .. id .. n, sel) then
                        changed, newPick = true, { type = typ, name = nm };
                    end
                end
            end
        end
        imgui.EndCombo();
    end
    imgui.PopItemWidth();
    return changed, newPick;
end

-- Flat combo of names. opt is { [name] = true }. Returns changed, newName.
local function nameCombo(id, cur, opt)
    local changed, new = false, cur;
    imgui.PushItemWidth(FILTER_COMBO_WIDTH);
    if imgui.BeginCombo('##' .. id, cur or 'All') then
        if imgui.Selectable('All##' .. id .. '_all', cur == nil) then
            changed, new = true, nil;
        end
        for i, nm in ipairs(sortedKeys(opt)) do
            if imgui.Selectable(nm .. '##' .. id .. i, cur == nm) then
                changed, new = true, nm;
            end
        end
        imgui.EndCombo();
    end
    imgui.PopItemWidth();
    return changed, new;
end

-- Monster combo: mob names, with each spawn nested under a name that was
-- seen more than once. opt is { [name] = { spawns = { {id, label, no} } } }.
local function monsterCombo(id, mf, opt)
    local preview = 'All';
    if mf ~= nil then
        preview = mf.label or (mf.name .. ((opt[mf.name] and #opt[mf.name].spawns > 1) and ' (all)' or ''));
    end
    local changed, new = false, mf;
    imgui.PushItemWidth(FILTER_COMBO_WIDTH + 40);
    if imgui.BeginCombo('##' .. id, preview) then
        if imgui.Selectable('All##' .. id .. '_all', mf == nil) then
            changed, new = true, nil;
        end
        local n = 0;
        for _, name in ipairs(sortedKeys(opt)) do
            local spawns = opt[name].spawns;
            n = n + 1;
            local selName = mf ~= nil and mf.name == name and mf.id == nil;
            if #spawns <= 1 then
                if imgui.Selectable(name .. '##' .. id .. n, selName) then
                    changed, new = true, { name = name };
                end
            else
                if imgui.Selectable(name .. ' (all ' .. #spawns .. ')##' .. id .. n, selName) then
                    changed, new = true, { name = name };
                end
                for _, sp in ipairs(spawns) do
                    n = n + 1;
                    local sel = mf ~= nil and mf.id == sp.id;
                    if imgui.Selectable('    ' .. sp.label .. '##' .. id .. n, sel) then
                        changed, new = true, { name = name, id = sp.id, label = sp.label };
                    end
                end
            end
        end
        imgui.EndCombo();
    end
    imgui.PopItemWidth();
    return changed, new;
end

local function drawFilters(iso, isoIsMob)
    local wf = state.wf;
    if iso.gearOn then
        imgui.Text('Main');
        imgui.SameLine();
        local ch, v = typeNameCombo('mobparser_wf_main', wf.main, iso.opt.main);
        if ch then wf.main = v; wf.sub = nil; end -- Sub follows Main
        if wf.main ~= nil then
            imgui.SameLine();
            imgui.Text('Sub');
            imgui.SameLine();
            ch, v = typeNameCombo('mobparser_wf_sub', wf.sub, iso.opt.sub);
            if ch then wf.sub = v; end
        end
        imgui.SameLine();
        imgui.Text('Ranged');
        imgui.SameLine();
        ch, v = nameCombo('mobparser_wf_range', wf.range, iso.opt.range);
        if ch and v ~= wf.range then wf.range = v; wf.ammo = nil; end -- Ammo follows Ranged
        imgui.SameLine();
        imgui.Text('Ammo');
        imgui.SameLine();
        ch, v = nameCombo('mobparser_wf_ammo', wf.ammo, iso.opt.ammo);
        if ch then wf.ammo = v; end
        if iso.typeLookupFailed then
            imgui.TextDisabled('(weapon type lookup failed -- weapons grouped under Other)');
        end
    end
    if not isoIsMob then
        -- Job filter (2026-10-30). Keep the current pick listed even if
        -- a stacked filter hid all its events.
        local jobs = {};
        for j in pairs(iso.opt.jobs) do jobs[j] = true; end
        if state.jf ~= nil then jobs[state.jf] = true; end
        imgui.Text('Job');
        imgui.SameLine();
        local chJ, vJ = nameCombo('mobparser_jf', state.jf, jobs);
        if chJ then state.jf = vJ; end
        imgui.SameLine();
        imgui.Text('Monster');
        imgui.SameLine();
        local ch, v = monsterCombo('mobparser_mf', state.mf, iso.opt.mobs);
        if ch then state.mf = v; end
    end
    if weaponFilterActive(wf) or state.mf ~= nil or state.jf ~= nil then
        imgui.SameLine();
        if imgui.Button('Reset filters###mobparser_filter_reset') then
            state.wf = {};
            state.mf = nil;
            state.jf = nil;
        end
    end
end

-- ---------------------------------------------------------------------------
-- Isolation result, built as a sliced coroutine (PERF 2026-10-30 -- see the
-- PERF block near the top). Returns the newest finished result for the
-- current player + filters, or nil while the very first one is building.
-- Same refresh rule as before: rebuilt when the data or the view changes,
-- new events folded in at most every REFRESH_SECONDS.
-- ---------------------------------------------------------------------------
local isoDone = nil;   -- { player, fkey, events, n, at, iso }
local isoJob = nil;    -- { player, fkey, events, n, co }

local function isoResult()
    local player = state.isolated;
    local fkey = filterKey(state.wf, state.mf, state.jf);
    local events = currentEvents();
    local n = #events;
    local now = os.clock();
    local d = isoDone;
    local sameView = d ~= nil and d.player == player and d.fkey == fkey and d.events == events;
    if sameView and (d.n == n or (now - d.at) < REFRESH_SECONDS) then
        return d.iso;
    end
    if isoJob == nil or isoJob.player ~= player or isoJob.fkey ~= fkey or isoJob.events ~= events then
        local wf, mf, jf = state.wf, state.mf, state.jf;
        isoJob = {
            player = player, fkey = fkey, events = events, n = n,
            co = coroutine.create(function() return computeIsolation(player, wf, mf, jf); end),
        };
    end
    sliceDeadline = now + SLICE_BUDGET;
    sliceCounter = 0;
    local ok, res = coroutine.resume(isoJob.co);
    sliceDeadline = nil;
    if not ok then
        isoJob = nil;
        error(res, 0);
    end
    if coroutine.status(isoJob.co) == 'dead' then
        isoDone = { player = player, fkey = fkey, events = events, n = isoJob.n, at = now, iso = res };
        isoJob = nil;
        return res;
    end
    -- still building: keep showing the previous result for this same view
    -- (same data table only -- after a wipe the old numbers are not shown)
    if sameView then return d.iso; end
    return nil;
end

local function drawIsolation()
    local isoIsMob = state.isolated:sub(-6) == ' (mob)';
    local iso = isoResult();

    if imgui.Button('< Full list###mobparser_iso_back') then
        state.isolated = nil;
        return;
    end
    if iso == nil then
        imgui.SameLine();
        imgui.TextDisabled('(building...)');
        return;
    end
    imgui.SameLine();
    local jobTag = state.jf or iso.job;
    imgui.Text(tostring(iso.name) .. (jobTag and ('  [' .. jobTag .. ']') or ''));

    if not iso.found then
        imgui.SameLine();
        imgui.TextDisabled('(no data for this player -- log cleared?)');
        return;
    end

    local dps = (iso.combatSeconds > 0) and (iso.dealt / iso.combatSeconds) or 0;
    imgui.SameLine();
    imgui.TextDisabled(string.format('Damage %d  |  %.1f DPS  |  Healed %d  |  %s combat',
        iso.dealt, dps, iso.healed, fmtDuration(iso.combatSeconds)));

    local fOk, fErr = pcall(drawFilters, iso, isoIsMob);
    if not fOk then imgui.TextDisabled('filter error: ' .. tostring(fErr)); end

    if iso.filtering and iso.matched == 0 then
        imgui.TextDisabled('No events match these filters.');
        return;
    end

    local total = iso.dealt;
    local function pctOfTotal(l) return fPct(l.damage, total); end

    -- 1. Physical: auto-attacks, one line per WS, ranged, one line per
    --    ranged WS (+ pet melee if any). WS lines sorted by damage.
    local physLines = { iso.phys.melee };
    for _, l in ipairs(iso.physWs.list) do table.insert(physLines, l); end
    table.insert(physLines, iso.phys.ranged);
    for _, l in ipairs(iso.physRws.list) do table.insert(physLines, l); end
    if iso.phys.pet.count > 0 then table.insert(physLines, iso.phys.pet); end
    drawIsoTable('mobparser.iso.phys', 'Physical', {
        { 'Type',     function(l) return l.label; end },
        -- swings/shots for auto-attacks, uses for weaponskills
        { 'Count',    function(l) return fInt(l.isWs and l.uses or l.count); end },
        { 'Hits',     function(l) return fInt(l.hits); end },
        { 'Misses',   function(l) return fInt(l.misses); end },
        { 'Crits',    function(l) return fInt(l.crits); end },
        { 'Acc %',    fAcc },
        { 'Crit %',   function(l) return fPct(l.crits, l.hits); end },
        { 'Damage',   function(l) return fInt(l.damage); end },
        { 'Avg',      fAvg },
        { 'Low',      function(l) return fInt(l.low); end },
        { 'High',     function(l) return fInt(l.high); end },
        { '% of dmg', pctOfTotal },
    }, physLines);

    -- 1b. Per enemy (player view): one row per individual mob
    if #iso.enemies.list > 0 then
        drawIsoTable('mobparser.iso.enemies', 'Per enemy', {
            { 'Enemy',    function(l) return l.label; end },
            { 'Hits',     function(l) return fInt(l.hits); end },
            { 'Misses',   function(l) return fInt(l.misses); end },
            { 'Acc %',    fAcc },
            { 'Crits',    function(l) return fInt(l.crits); end },
            { 'Crit %',   function(l) return fPct(l.crits, l.hits); end },
            { 'WS',       function(l) return fInt(l.wsUses); end },
            { 'Casts',    function(l) return fInt(l.casts); end },
            { 'Melee/rng dmg', function(l) return fInt(l.physDmg); end },
            { 'WS dmg',   function(l) return fInt(l.wsDmg); end },
            { 'Magic dmg', function(l) return fInt(l.magicDmg); end },
            { 'Other dmg', function(l) return fInt(l.otherDmg); end },
            { 'Pet dmg',  function(l) return fInt(l.petDmg); end },
            { 'Damage',   function(l) return fInt(l.damage); end },
            { 'High',     function(l) return fInt(l.high); end },
            { '% of dmg', pctOfTotal },
        }, iso.enemies.list);
    end

    -- 1c. Mob view: its attacks split by player hit, and by spawn
    local mobCols = function(first)
        return {
            { first,      function(l) return l.label; end },
            { 'Attacks',  function(l) return fInt(l.count); end },
            { 'TP moves', function(l) return fInt(l.tpMoves); end },
            { 'Landed',   function(l) return fInt(l.hits); end },
            { 'Evaded',   function(l) return fInt(l.misses); end },
            { 'Parried',  function(l) return fInt(l.parry); end },
            { 'Shadows',  function(l) return fInt(l.shadows); end },
            { 'Blocked',  function(l) return fInt(l.blocked); end },
            { 'Damage',   function(l) return fInt(l.damage); end },
            { 'Avg',      fAvg },
            { 'High',     function(l) return fInt(l.high); end },
            { '% of dmg', pctOfTotal },
        };
    end
    if #iso.byTarget.list > 0 then
        drawIsoTable('mobparser.iso.bytarget', 'Per target', mobCols('Target'), iso.byTarget.list);
    end
    if #iso.bySpawn.list > 1 then
        drawIsoTable('mobparser.iso.byspawn', 'Per spawn', mobCols('Mob'), iso.bySpawn.list);
    end

    -- 1d. Pets (2026-11-07): all of this player's pets as one line, like a
    --     spell. "By summon" breaks it out per pet, each followed by its
    --     own actions (melee, blood pacts / TP moves, ...).
    if iso.pets.all.count > 0 then
        local petLines;
        if state.isoPetSplit then
            petLines = {};
            for _, sl in ipairs(iso.pets.bySummon.list) do
                table.insert(petLines, sl);
                for _, al in ipairs(sl.actions.list) do
                    al.indent = true;
                    table.insert(petLines, al);
                end
            end
        else
            petLines = { iso.pets.all };
        end
        local function petAcc(l)
            local n = l.swingHits + l.swingMisses;
            if n <= 0 then return nil; end
            return fPct(l.swingHits, n) or '0.0%';
        end
        drawIsoTable('mobparser.iso.pets', 'Pets', {
            { state.isoPetSplit and 'Summon / action' or 'Pet',
                          function(l) return (l.indent and '    ' or '') .. l.label; end },
            { 'Uses',     function(l) return fInt(l.uses); end },
            { 'Swings',   function(l) return fInt(l.swings); end },
            { 'Acc %',    petAcc },
            { 'Crits',    function(l) return fInt(l.swingCrits); end },
            { 'Failed',   function(l) return fInt(l.misses); end },
            { 'Damage',   function(l) return fInt(l.damage); end },
            { 'Avg',      fAvg },
            { 'High',     function(l) return fInt(l.high); end },
            { 'Healed',   function(l) return fInt(l.heal); end },
            { '% of dmg', pctOfTotal },
        }, petLines);
        local split = { state.isoPetSplit == true };
        local okCb, changed = pcall(imgui.Checkbox, 'By summon###mobparser_iso_petsplit', split);
        if okCb and changed then state.isoPetSplit = split[1]; end
    end

    -- 2. Weaponskills by name (melee + ranged)
    if #iso.wsByName.list > 0 then
        drawIsoTable('mobparser.iso.ws', 'Weaponskills', {
            { 'Weaponskill', function(l) return l.label; end },
            { 'Uses',     function(l) return fInt(l.uses); end },
            { 'Hits',     function(l) return fInt(l.hits); end },
            { 'Misses',   function(l) return fInt(l.misses); end },
            { 'Damage',   function(l) return fInt(l.damage); end },
            { 'Avg',      fAvg },
            { 'Low',      function(l) return fInt(l.low); end },
            { 'High',     function(l) return fInt(l.high); end },
            { '% of dmg', pctOfTotal },
        }, iso.wsByName.list);
    end

    -- 3. Magic by spell
    if #iso.magic.list > 0 then
        drawIsoTable('mobparser.iso.magic', 'Magic', {
            { 'Spell',    function(l) return l.label; end },
            { 'Casts',    function(l) return fInt(l.uses); end },
            { 'Targets',  function(l) return fInt(l.count); end },
            { 'Damage',   function(l) return fInt(l.damage); end },
            { 'Avg',      fAvg },
            { 'High',     function(l) return fInt(l.high); end },
            { 'Bursts',   function(l) return fInt(l.bursts); end },
            { 'Resisted', function(l) return fInt(l.resists); end },
            { 'Healed',   function(l) return fInt(l.heal); end },
            { '% of dmg', pctOfTotal },
        }, iso.magic.list);
    end

    -- 4. Job abilities by name
    if #iso.ja.list > 0 then
        local jaCols = {
            { 'Ability',  function(l) return l.label; end },
            { 'Uses',     function(l) return fInt(l.uses); end },
            { 'Damage',   function(l) return fInt(l.damage); end },
            { 'Avg',      fAvg },
            { 'High',     function(l) return fInt(l.high); end },
            { 'Failed',   function(l) return fInt(l.misses); end },
            { 'Healed',   function(l) return fInt(l.heal); end },
            { '% of dmg', pctOfTotal },
        };
        -- 2026-11-07: damage the pet did with this command (blood pact /
        -- Ready move with the same id). Counted once, under Pets -- these
        -- columns only show it here. Hidden when no JA had pet damage.
        local anyPet = false;
        for _, l in ipairs(iso.ja.list) do
            if (l.petDmg or 0) > 0 then anyPet = true; break; end
        end
        if anyPet then
            table.insert(jaCols, #jaCols, { 'Pet dmg',  function(l) return fInt(l.petDmg); end });
            table.insert(jaCols, #jaCols, { 'Pet avg',  function(l)
                if (l.petHits or 0) <= 0 then return nil; end
                return string.format('%.1f', l.petDmg / l.petHits);
            end });
            table.insert(jaCols, #jaCols, { 'Pet high', function(l) return fInt(l.petHigh); end });
        end
        drawIsoTable('mobparser.iso.ja', 'Job abilities', jaCols, iso.ja.list);
    end

    -- 5. Additional effects & skillchains
    if #iso.effects.list > 0 then
        drawIsoTable('mobparser.iso.effects', 'Additional effects & skillchains', {
            { 'Effect',   function(l)
                if l.thMax ~= nil then return l.label .. ' (up to TH ' .. tostring(l.thMax) .. ')'; end
                return l.label;
            end },
            { 'Procs',    function(l) return fInt(l.count); end },
            { 'Damage',   function(l) return fInt(l.damage); end },
            { 'Avg',      fAvg },
            { 'High',     function(l) return fInt(l.high); end },
            { '% of dmg', pctOfTotal },
        }, iso.effects.list);
    end

    -- 6. TP moves / items / anything else
    if #iso.other.list > 0 then
        drawIsoTable('mobparser.iso.other', 'TP moves, items & other', {
            { 'Action',   function(l) return l.label; end },
            { 'Uses',     function(l) return fInt(l.uses); end },
            { 'Damage',   function(l) return fInt(l.damage); end },
            { 'Avg',      fAvg },
            { 'High',     function(l) return fInt(l.high); end },
            { 'Healed',   function(l) return fInt(l.heal); end },
            { '% of dmg', pctOfTotal },
        }, iso.other.list);
    end

    -- 7. Damage taken (players only)
    if #iso.taken.list > 0 then
        local takenTotal = 0;
        for _, l in ipairs(iso.taken.list) do takenTotal = takenTotal + l.damage; end
        drawIsoTable('mobparser.iso.taken', 'Damage taken', {
            { 'Source',    function(l) return l.label; end },
            { 'Attacks',   function(l) return fInt(l.count); end },
            { 'Landed',    function(l) return fInt(l.hits); end },
            { 'Evaded',    function(l) return fInt(l.misses); end },
            { 'Parried',   function(l) return fInt(l.parry); end },
            { 'Shadows',   function(l) return fInt(l.shadows); end },
            { 'Blocked',   function(l) return fInt(l.blocked); end },
            { 'Damage',    function(l) return fInt(l.damage); end },
            { 'Avg',       fAvg },
            { 'High',      function(l) return fInt(l.high); end },
            { '% taken',   function(l) return fPct(l.damage, takenTotal); end },
        }, iso.taken.list);
    end
end

-- ---------------------------------------------------------------------------
-- Save export / Clear data buttons (2026-10-29). The actual work lives
-- in mobparser.lua (doExport / doWipe, shared with /mobparser export and
-- /mobparser wipe) and is handed in via mobparser_gui.setActions(), so
-- this file still never mutates export_log itself.
-- Clear is two-click: the first click arms it ('Confirm clear?', red)
-- for CLEAR_ARM_SECONDS; a second click inside that window wipes.
-- ---------------------------------------------------------------------------
local actions = {};
local CLEAR_ARM_SECONDS = 3;
local clearArmedAt = nil;

function mobparser_gui.setActions(t)
    actions = t or {};
end

local function runAction(name)
    local fn = actions[name];
    if fn == nil then
        print('[mobparser] ' .. name .. ' unavailable (not wired up by mobparser.lua).');
        return;
    end
    local ok, aOk, msg = pcall(fn);
    if not ok then
        print('[mobparser] ' .. name .. ' error: ' .. tostring(aOk));
    else
        print('[mobparser] ' .. tostring(msg));
    end
end

local function drawDataButtons()
    if imgui.Button('Save export###mobparser_export') then
        runAction('export');
    end
    imgui.SameLine();

    local now = os.clock();
    if clearArmedAt ~= nil and (now - clearArmedAt) > CLEAR_ARM_SECONDS then
        clearArmedAt = nil;
    end
    if clearArmedAt == nil then
        if imgui.Button('Clear data###mobparser_clear') then
            clearArmedAt = now;
        end
    else
        local pushed = 0;
        if ImGuiCol_Button ~= nil then
            imgui.PushStyleColor(ImGuiCol_Button, { 0.60, 0.10, 0.10, 1.0 });
            imgui.PushStyleColor(ImGuiCol_ButtonHovered, { 0.75, 0.15, 0.15, 1.0 });
            pushed = 2;
        end
        local clicked = imgui.Button('Confirm clear?###mobparser_clear');
        if pushed > 0 then imgui.PopStyleColor(pushed); end
        if clicked then
            clearArmedAt = nil;
            state.isolated = nil; -- isolated player no longer exists after a wipe
            state.wf = {};
            state.mf = nil;
            state.jf = nil;
            runAction('wipe');
        end
    end
end

-- Party saves dropdown (2026-10-31). Lists every save, newest first;
-- picking one loads it (a slice per frame) and shows it like Session.
local SAVES_COMBO_WIDTH = 300;
local savesListCache = { version = -1, list = {}, labels = {} };

local function savesList()
    local v = party_saves.version();
    if savesListCache.version ~= v then
        local list = party_saves.list();
        local labels = {};
        for i, m in ipairs(list) do labels[i] = party_saves.label(m); end
        savesListCache = { version = v, list = list, labels = labels };
    end
    return savesListCache.list, savesListCache.labels;
end

local function leaveSave(newSource)
    state.source = newSource;
    state.saveFile = nil;
    state.mf = nil; -- spawn numbering differs between data sets
    if party_saves ~= nil then pcall(party_saves.unloadView); end
end

local function drawSavesCombo()
    if party_saves == nil then return; end
    local list, labels = savesList();
    local preview;
    if state.source == 'save' and state.saveFile ~= nil then
        local m = party_saves.metaFor(state.saveFile);
        preview = m and party_saves.label(m) or state.saveFile;
    else
        preview = string.format('Party saves (%d)', #list);
    end
    imgui.PushItemWidth(SAVES_COMBO_WIDTH);
    if imgui.BeginCombo('##mobparser_saves', preview) then
        if #list == 0 then
            imgui.TextDisabled('None yet -- one is made each time the session is cleared.');
        end
        for i, m in ipairs(list) do
            local sel = state.source == 'save' and state.saveFile == m.file;
            if imgui.Selectable(labels[i] .. '##mobparser_save_' .. i, sel) and not sel then
                local ok, lOk, msg = pcall(party_saves.beginLoad, m.file);
                if ok and lOk then
                    state.source = 'save';
                    state.saveFile = m.file;
                    state.mf = nil;
                else
                    print('[mobparser] party save unavailable: ' .. tostring(ok and msg or lOk));
                end
            end
        end
        imgui.EndCombo();
    end
    imgui.PopItemWidth();
end

-- All time / Session (2026-10-30). Session mode: All time, Save export,
-- Clear data. All-time mode: Session + an 'ALL TIME (N events)' label;
-- Save export and Clear are hidden since they act on the session only.
-- (2026-10-31) Party saves dropdown after them in every mode; viewing a
-- save works like All time (Session button + gold label).
local function drawSourceButtons()
    if state.source == 'save' then
        if imgui.Button('Session###mobparser_source') then
            leaveSave('session');
            return;
        end
        imgui.SameLine();
        drawSavesCombo();
        imgui.SameLine();
        if useSave() then
            local evs = party_saves.events();
            local label = string.format('PARTY SAVE (%d events)', evs and #evs or 0);
            local ok = pcall(imgui.TextColored, { 1.0, 0.75, 0.25, 1.0 }, label);
            if not ok then imgui.Text(label); end
        elseif party_saves.isLoading() and party_saves.loadingFile() == state.saveFile then
            imgui.TextDisabled(string.format('Loading save... %d%%',
                math.floor((party_saves.loadProgress() or 0) * 100)));
        else
            imgui.TextDisabled('(save not loaded)');
        end
        return;
    end
    if state.source == 'alltime' and useAllTime() then
        if imgui.Button('Session###mobparser_source') then
            state.source = 'session';
            state.mf = nil; -- spawn numbering differs between the two
        end
        imgui.SameLine();
        drawSavesCombo();
        if party_saves ~= nil then imgui.SameLine(); end
        local label = string.format('ALL TIME (%d events)', #alltime_db.events());
        local ok = pcall(imgui.TextColored, { 1.0, 0.75, 0.25, 1.0 }, label);
        if not ok then imgui.Text(label); end
        return;
    end
    -- PERF (2026-10-30): All time now loads a slice per frame (alltime_db
    -- .beginLoad + tick) instead of freezing the game for the whole file.
    -- The view switches over by itself when the load finishes.
    if state.source == 'alltime' and alltime_db ~= nil and alltime_db.isLoading ~= nil
        and alltime_db.isLoading() then
        if imgui.Button('Cancel###mobparser_source') then
            state.source = 'session'; -- load keeps going; shown when clicked again
        end
        imgui.SameLine();
        imgui.TextDisabled(string.format('Loading all time... %d%%',
            math.floor((alltime_db.loadProgress() or 0) * 100)));
        return;
    end
    state.source = 'session';
    if alltime_db ~= nil then
        if imgui.Button('All time###mobparser_source') then
            local ok, lOk, msg = pcall(alltime_db.beginLoad);
            if ok and lOk then
                state.source = 'alltime';
                state.mf = nil;
            else
                print('[mobparser] All time unavailable: ' .. tostring(ok and msg or lOk));
            end
        end
        imgui.SameLine();
    end
    if party_saves ~= nil then
        drawSavesCombo();
        imgui.SameLine();
    end
    drawDataButtons();
end

local mainDisplayCache = nil; -- see drawMainBody (PERF 2026-10-30)

local function drawMainBody()
    if imgui.Button('Settings') then
        state.settingsVisible[1] = not state.settingsVisible[1];
    end
    imgui.SameLine();
    if imgui.Button('Colors') then
        state.colorsVisible[1] = not state.colorsVisible[1];
    end
    imgui.SameLine();
    if imgui.Button('Report (' .. REPORT_MODES[getReportMode()].label .. ')###mobparser_report') then
        local _, msg = mobparser_gui.report();
        print('[mobparser] ' .. msg);
    end
    imgui.SameLine();
    drawSourceButtons();

    if state.isolated ~= nil then
        imgui.Separator();
        drawIsolation();
        return;
    end

    imgui.SameLine();
    imgui.Text('Group by:');
    imgui.SameLine();
    drawGroupButton('Player', 'actorName');
    imgui.SameLine();
    drawGroupButton('Event type', 'type');

    local columns = visibleColumns();
    local rows, display = nil, nil;
    do
        local list, _, buildId, building = computeRows(state.groupBy);
        local limit = getMaxPlayers();
        local showEnemies = settings.data.guiShowEnemies == true;
        -- PERF (2026-10-30): sort + top-N split cached; redone only when the
        -- rows were rebuilt or the sort / limit / enemy setting changed (was
        -- re-sorted every frame, allocating strings in the comparator).
        local dc = mainDisplayCache;
        if dc == nil or dc.buildId ~= buildId or dc.groupBy ~= state.groupBy
            or dc.sortKey ~= state.sortKey or dc.sortAsc ~= state.sortAsc
            or dc.limit ~= limit or dc.showEnemies ~= showEnemies then
            local sorted = {};
            for i = 1, #list do sorted[i] = list[i]; end -- never reorder the cached list
            applySort(sorted);
            dc = { buildId = buildId, groupBy = state.groupBy, sortKey = state.sortKey,
                   sortAsc = state.sortAsc, limit = limit, showEnemies = showEnemies };
            -- 2026-10-29: in Player mode, mob rows (damage the mobs did to you)
            -- no longer compete with players for the row limit: players first
            -- (top N), then mobs (top N), each in the current sort order.
            if state.groupBy == 'actorName' then
                local players, mobs = {}, {};
                for _, r in ipairs(sorted) do
                    if r.isMob then table.insert(mobs, r); else table.insert(players, r); end
                end
                -- Enemy rows hidden unless enabled in Settings (default off).
                if not showEnemies then mobs = {}; end
                local kept = {};
                for i = 1, math.min(#players, limit) do table.insert(kept, players[i]); end
                for i = 1, math.min(#mobs, limit) do table.insert(kept, mobs[i]); end
                if #players > limit or #mobs > limit then
                    dc.note = string.format('(top %d of %d players, %d of %d mobs)',
                        math.min(#players, limit), #players, math.min(#mobs, limit), #mobs);
                end
                dc.rows = kept;
            else
                dc.rows = sorted;
            end
            mainDisplayCache = dc;
        end
        if dc.note ~= nil then
            imgui.SameLine();
            imgui.TextDisabled(dc.note);
        end
        if building then
            imgui.SameLine();
            imgui.TextDisabled('(building...)');
        end
        rows, display = dc.rows, dc;
    end
    local shown = #rows;
    imgui.Separator();

    if shown == 0 then
        imgui.TextDisabled('No data yet -- get in a fight, or check /mobparser status.');
        return;
    end

    if imgui.BeginTable('mobparser.main', #columns, tableFlags) then
        local ok, err = pcall(function()
            for _, key in ipairs(columns) do
                imgui.TableSetupColumn(columnLabel(key));
            end
            drawHeaderRow(columns);

            for idx = 1, shown do
                local r = rows[idx];
                imgui.TableNextRow();
                for _, key in ipairs(columns) do
                    imgui.TableNextColumn();
                    if key == 'name' then
                        if state.groupBy == 'actorName' then
                            -- isolate this player ('##' + row index keeps the ID unique)
                            if imgui.Button('Iso##mobparser_iso_' .. idx) then
                                if state.isolated ~= r.name or state.jf ~= r.job then
                                    state.wf = {};
                                    state.mf = nil;
                                end
                                state.isolated = r.name;
                                -- 2026-10-30: open on this row's job
                                state.jf = (not r.isMob) and r.job or nil;
                            end
                            imgui.SameLine();
                        end
                        -- Job column hidden: put the job on the name so
                        -- a player's per-job rows stay distinguishable.
                        if r.job ~= nil and settings.data.guiShowJob == false then
                            imgui.Text(tostring(r.name) .. ' (' .. r.job .. ')');
                        else
                            imgui.Text(tostring(r.name));
                        end
                    elseif key == 'job' then
                        if r.job ~= nil then imgui.Text(r.job); else imgui.TextDisabled('--'); end
                    else
                        local v = r[key];
                        if v == nil then
                            imgui.TextDisabled(state.trackingOn[key] and '0' or '--');
                        elseif key == 'acc' then
                            imgui.Text(string.format('%.1f%%', v));
                        elseif key == 'avgDamage' or key == 'dps' then
                            imgui.Text(string.format('%.1f', v));
                        else
                            imgui.Text(tostring(v));
                        end
                    end
                end
            end
        end);
        imgui.EndTable();
        if not ok then imgui.TextDisabled('table error: ' .. tostring(err)); end
    end
end

local function drawMainWindow()
    if not state.windowVisible[1] then return; end

    local pushed = pushTheme();
    if imgui.Begin('mobparser', state.windowVisible) then
        local ok, err = pcall(drawMainBody);
        if not ok then imgui.TextDisabled('gui error: ' .. tostring(err)); end
    end
    imgui.End();
    popTheme(pushed);

    drawSettings();
    drawColorsWindow();
end

-- ===========================================================================
-- Public surface
-- ===========================================================================

-- Call every frame from mobparser.lua's own d3d_present handler.
-- First frame only: open the window if the setting says so. Done here
-- (not at require time) because mobparser.lua loads settings after
-- requiring this file. Missing key (older settings file) = open.
local openOnLoadApplied = false;

function mobparser_gui.render()
    if not openOnLoadApplied then
        openOnLoadApplied = true;
        if settings.data.guiOpenOnLoad ~= false then state.windowVisible[1] = true; end
    end
    pcall(pumpReport);
    drawMainWindow();
end

-- Toggles the main window's visibility -- wire to /mobparser gui.
function mobparser_gui.toggle()
    state.windowVisible[1] = not state.windowVisible[1];
end

function mobparser_gui.isVisible()
    return state.windowVisible[1];
end

-- Offline tests only.
mobparser_gui._test = {
    computeIsolation = computeIsolation, computeRows = computeRows, state = state,
    computeCombatSeconds = computeCombatSeconds, computeCombatSecondsSorted = computeCombatSecondsSorted,
    isoResult = isoResult,
};

return mobparser_gui;

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
};

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
-- the row. Returns key, isMob.
local function rowKeyFor(e, groupField)
    local key = e[groupField];
    local isMob = false;
    if key == nil and groupField == 'actorName' then
        -- 2026-10-29: was a single '(pet/unknown)' bucket. actorName is
        -- only set for party members, so every mob action (hits/misses on
        -- you, TP moves) and every skillchain row (finisherName, not
        -- actorName) piled in there. Resolve in order: skillchain
        -- finisher -> the actor's entity name from client memory (mobs)
        -- -> the raw ID, so nothing is ever anonymous.
        key = e.finisherName;
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
    return key, isMob;
end

-- Combat time for DPS (see DPS_IDLE_GAP above).
local function computeCombatSeconds(events)
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

local function computeRows(groupField)
    local rows = {};      -- name -> row table
    local order = {};     -- preserves first-seen order

    local events = export_log.liveEvents();
    for _, e in ipairs(events) do
        local key, isMob = rowKeyFor(e, groupField);
        local r = rows[key];
        if r == nil then
            r = { name = key, isMob = isMob };
            rows[key] = r;
            table.insert(order, key);
        end

        -- Job: newest value wins, so a mid-session job change shows the
        -- current job. Mobs have none.
        local jobId = e.actorJob or e.finisherJob;
        if jobId ~= nil then r.job = JOB_ABBR[jobId] or tostring(jobId); end

        local outcome = e.outcome or '';
        local dmg = type(e.damage) == 'number' and e.damage or 0;
        local isHit = COUNTS_AS_HIT[outcome] == true;
        local isMiss = COUNTS_AS_MISS[outcome] == true;
        -- heal amounts are not damage
        if HEAL_OUTCOMES[outcome] then dmg = 0; end

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
    end

    -- combat time for DPS (see DPS_IDLE_GAP above)
    local combatSeconds = 0;
    if state.trackingOn.dps then
        combatSeconds = computeCombatSeconds(events);
    end

    -- derived stats
    for _, key in ipairs(order) do
        local r = rows[key];
        local hits, misses = r.hits or 0, r.misses or 0;
        if state.trackingOn.acc and (hits + misses) > 0 then
            r.acc = math.floor((hits / (hits + misses)) * 1000 + 0.5) / 10;
        end
        if state.trackingOn.dps and combatSeconds > 0 and (r.damage or 0) > 0 then
            r.dps = math.floor(((r.damage or 0) / combatSeconds) * 10 + 0.5) / 10;
        end
        if state.trackingOn.avgDamage and hits > 0 then
            r.avgDamage = math.floor(((r.damage or 0) / hits) * 10 + 0.5) / 10;
        end
    end

    local list = {};
    for _, key in ipairs(order) do table.insert(list, rows[key]); end
    return list, combatSeconds;
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
    l.physDmg, l.wsDmg, l.magicDmg, l.otherDmg = 0, 0, 0, 0;
    l.wsSeen, l.castSeen = {}, {};
    return l;
end

local function addEnemy(l, e, t, outcome, dmg)
    local d = dealtBy(t, outcome, dmg);
    l.count = l.count + 1;
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
    return isEnemy, labelFor;
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

local function computeIsolation(isoKey)
    local events = export_log.liveEvents();
    local iso = {
        name = isoKey, found = false,
        phys = {
            melee  = newLine('Melee (auto-attack)'),
            ws     = newLine('Weaponskill'),
            ranged = newLine('Ranged attack'),
            rws    = newLine('Ranged weaponskill'),
            pet    = newLine('Pet melee'),
        },
        wsByName = newBucket(), magic = newBucket(), ja = newBucket(),
        effects = newBucket(), other = newBucket(), taken = newBucket(),
        enemies = newBucket(), byTarget = newBucket(), bySpawn = newBucket(),
        dealt = 0, healed = 0,
    };
    local isoIsMob = isoKey:sub(-6) == ' (mob)';
    local baseName = (isoKey:gsub(' %(mob%)$', ''));
    local isEnemy, labelFor = buildEnemyIndex(events);

    for _, e in ipairs(events) do
        local key = rowKeyFor(e, 'actorName');
        local outcome = e.outcome or '';
        local dmg = type(e.damage) == 'number' and e.damage or 0;
        local t = e.type;

        if key == isoKey and outcome ~= 'TOO_FAR' then -- too far = never went off
            iso.found = true;
            local jobId = e.actorJob or e.finisherJob;
            if jobId ~= nil then iso.job = JOB_ABBR[jobId] or tostring(jobId); end

            if t == 'melee' then
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
            else
                -- Player view: everything this player did to each individual mob.
                local tid = (t == 'skillchain') and e.finisherTargetId or e.targetId;
                if (e.side == 'offense' or t == 'skillchain') and isEnemy(tid, e.targetName) then
                    local label = labelFor(tid, e.targetName);
                    local l = iso.enemies.map[label];
                    if l == nil then
                        l = newEnemyLine(label);
                        iso.enemies.map[label] = l;
                        table.insert(iso.enemies.list, l);
                    end
                    addEnemy(l, e, t, outcome, dmg);
                end
            end

        -- Damage taken: something else acting on this player.
        elseif not isoIsMob and key ~= isoKey and e.side == 'defense'
                and e.targetName == baseName and t ~= 'skillchain' then
            addTaken(namedLine(iso.taken, TYPE_LABEL[t] or tostring(t)), e, t, outcome, dmg);
        end
    end

    for _, l in pairs(iso.phys) do iso.dealt = iso.dealt + l.damage; end
    for _, b in ipairs({ iso.magic, iso.ja, iso.effects, iso.other }) do
        for _, l in ipairs(b.list) do
            iso.dealt = iso.dealt + l.damage;
            iso.healed = iso.healed + l.heal;
        end
    end
    for _, b in ipairs({ iso.wsByName, iso.magic, iso.ja, iso.effects, iso.other, iso.taken,
                         iso.enemies, iso.byTarget, iso.bySpawn }) do
        sortBucket(b);
    end
    iso.combatSeconds = computeCombatSeconds(events);
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
    local rows, combatSeconds = computeRows('actorName');
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

local function drawIsolation()
    local iso = computeIsolation(state.isolated);

    if imgui.Button('< Full list###mobparser_iso_back') then
        state.isolated = nil;
        return;
    end
    imgui.SameLine();
    imgui.Text(tostring(iso.name) .. (iso.job and ('  [' .. iso.job .. ']') or ''));

    if not iso.found then
        imgui.SameLine();
        imgui.TextDisabled('(no data for this player -- log cleared?)');
        return;
    end

    local dps = (iso.combatSeconds > 0) and (iso.dealt / iso.combatSeconds) or 0;
    imgui.SameLine();
    imgui.TextDisabled(string.format('Damage %d  |  %.1f DPS  |  Healed %d  |  %s combat',
        iso.dealt, dps, iso.healed, fmtDuration(iso.combatSeconds)));

    local total = iso.dealt;
    local function pctOfTotal(l) return fPct(l.damage, total); end

    -- 1. Physical: auto-attacks, WS, ranged, ranged WS (+ pet melee if any)
    local physLines = { iso.phys.melee, iso.phys.ws, iso.phys.ranged, iso.phys.rws };
    if iso.phys.pet.count > 0 then table.insert(physLines, iso.phys.pet); end
    drawIsoTable('mobparser.iso.phys', 'Physical', {
        { 'Type',     function(l) return l.label; end },
        -- swings/shots for auto-attacks, uses for weaponskills
        { 'Count',    function(l) return fInt((l == iso.phys.ws or l == iso.phys.rws) and l.uses or l.count); end },
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
        drawIsoTable('mobparser.iso.ja', 'Job abilities', {
            { 'Ability',  function(l) return l.label; end },
            { 'Uses',     function(l) return fInt(l.uses); end },
            { 'Damage',   function(l) return fInt(l.damage); end },
            { 'Avg',      fAvg },
            { 'High',     function(l) return fInt(l.high); end },
            { 'Failed',   function(l) return fInt(l.misses); end },
            { 'Healed',   function(l) return fInt(l.heal); end },
            { '% of dmg', pctOfTotal },
        }, iso.ja.list);
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
            runAction('wipe');
        end
    end
end

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
    drawDataButtons();

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
    local rows = computeRows(state.groupBy);
    applySort(rows);

    -- 2026-10-29: in Player mode, mob rows (damage the mobs did to you)
    -- no longer compete with players for the row limit: players first (top
    -- N), then mobs (top N), each in the current sort order.
    local total = #rows;
    if state.groupBy == 'actorName' then
        local limit = getMaxPlayers();
        local players, mobs = {}, {};
        for _, r in ipairs(rows) do
            if r.isMob then table.insert(mobs, r); else table.insert(players, r); end
        end
        -- Enemy rows hidden unless enabled in Settings (default off).
        if settings.data.guiShowEnemies ~= true then mobs = {}; end
        local kept = {};
        for i = 1, math.min(#players, limit) do table.insert(kept, players[i]); end
        for i = 1, math.min(#mobs, limit) do table.insert(kept, mobs[i]); end
        if #players > limit or #mobs > limit then
            imgui.SameLine();
            imgui.TextDisabled(string.format('(top %d of %d players, %d of %d mobs)',
                math.min(#players, limit), #players, math.min(#mobs, limit), #mobs));
        end
        rows = kept;
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
                                state.isolated = r.name;
                            end
                            imgui.SameLine();
                        end
                        imgui.Text(tostring(r.name));
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

return mobparser_gui;

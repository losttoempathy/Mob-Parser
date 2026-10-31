--[[
mobparser -- combat_router.lua

Sits between packet_action.lua (raw packet -> parsed action) and
classify.lua (one result -> one outcome bucket). Determines, per action,
whether this is OFFENSE (tracked player attacking) or DEFENSE (tracked
player being attacked), and routes each per-target result through the
correct classify.* function.

Split deliberately into two layers:
  - `combat_router.route(...)` -- PURE LOGIC, no Ashita API calls, fully
    unit-testable offline (see test_combat_router.lua). Takes plain
    values (actor is player? / is affiliate? / target is player? /
    target is affiliate?) rather than reaching into AshitaCore itself,
    so the offense/defense decision logic can be verified without a
    running game client.
  - `combat_router.handlePacket(...)` -- the Ashita-facing glue that
    calls AshitaCore to answer those questions and feeds them into
    route(). THIS HALF IS UNTESTED OFFLINE (no Ashita environment
    available in this dev setup) -- needs in-game verification before
    trusting it. See the project file for this flagged item.

Scope: category 1 (melee), category 2 (ranged finish), category 3
(weaponskill), category 4 (magic finish), category 5 (item use
finish), category 6 (job ability finish), category 11 (monster TP move
landing on the player), category 13 (pet TP move), and category 14
(unblinkable job ability) as of 2026-07-29 -- see CLASSIFY_FN_BY_CATEGORY
below for the authoritative list (V1_SCOPED_CATEGORIES is a derived,
read-only view of the same keys, for callers that just want a
boolean-set check).
CORRECTION (2026-07-29, same session, gap-audit pass): an earlier
version of this comment incorrectly grouped category 5 in with the
genuine "no action needed" start-categories (8/9/10/12) -- that was
wrong. Category 5 (item use finish) DOES have real, confirmed
finish-shaped results (status effects landing, obtaining items,
dispel) -- see classify.itemUseOffense/Defense. Categories 7/8/9/10/12
remain correctly unwired -- monster-start, magic-start, item-start,
JA-start, ranged-start are genuinely "no action needed" precast/start
notifications per packet_ground_truth.md. Player/mob death
notifications travel on a DIFFERENT packet entirely (0x029, Action
Message) and are NOT covered by anything in this file.
This same gap-audit pass (prompted by the user asking "are there any
ids we haven't added") also found that classify.weaponskillOffense/
Defense had been missing an entire SECOND, WS-specific message
vocabulary (22 messages, classify.WS_MSG) -- now checked before
falling back to melee's generic vocabulary. See that pair's own header
for the full account. Job ability and magic each also gained a couple
of narrow, previously-missed message IDs (JA: 144/145 ACC/EVA-down
status, 77/157 named-ability damage variants; magic: 282 bare
"evades") found during the same audit.
Weaponskill, pet-TP-move, and monster-TP-move classification REUSE
melee's classify.offense/defense functions under the hood as a
fallback (thin wrappers, or a reaction-based branch layered on top for
pet TP moves specifically) -- see each pair's own header in
classify.lua for its own specific confidence level (pet-TP-move is the
LEAST confirmed; monster-TP-move rests on a general "message field is
shared across categories" claim without a category-11-specific
confirmation). Job ability, ranged, magic, and item use employ their
OWN confirmed, distinct message vocabularies -- CONFIRMED against the
Windower/Lua wiki's own message-id-to-text table, not corroborated-by-
analogy. Magic (classify.magicOffense/Defense) is the widest and
messiest vocabulary of any category here (~49 message IDs across 13
semantic groups) -- see that pair's own header for the still-open
question of why so many outcomes have both a "with cast-prefix" and
"without cast-prefix" message-id variant.
]]

local classify = require('classify');

local combat_router = {};

combat_router.CATEGORY = {
    MELEE          = 1,
    RANGED_FINISH  = 2,
    WEAPONSKILL    = 3,
    MAGIC_FINISH   = 4,
    ITEM_FINISH    = 5,
    JOB_ABILITY    = 6,
    MONSTER_START  = 7,
    MAGIC_START    = 8,
    ITEM_START     = 9,
    JOB_ABILITY_START = 10,
    MONSTER_FINISH = 11,
    RANGED_START   = 12,
    PET_ACTION     = 13,
    UNBLINKABLE_JA = 14,
};

-- Maps a v1-scoped category to its classify function pair, keyed by
-- side. Kept as a lookup table (not an if/elseif chain in route()
-- itself) so adding the next category later is a one-line addition
-- here plus a classify.<name>Offense/Defense pair, not a change to
-- route()'s own control flow. THIS is the single source of truth for
-- "which categories does v1 actually classify" -- route() reads this
-- table directly, not a separate boolean set, specifically to avoid
-- two tables (a scope list and a dispatch table) drifting out of sync
-- with each other if only one gets updated for a future category.
--
-- WEAPONSKILL added 2026-07-29 -- see classify.weaponskillOffense/
-- weaponskillDefense's own header for the UNCONFIRMED-for-WS-
-- specifically caveat (message IDs are reused from melee's table on
-- corroborated-but-not-live-verified grounds).
--
-- JOB_ABILITY/UNBLINKABLE_JA added 2026-07-29 (same session,
-- immediately after skillchain message IDs were confirmed) -- see
-- classify.jobAbilityOffense/Defense's own header. Both categories 6
-- (finish) and 14 (unblinkable JA, e.g. Waltz) share the SAME classify
-- functions, since packet_ground_truth.md documents 14 as its own
-- category only because unblinkable JAs skip a client-side animation
-- check, not because they carry a different message vocabulary --
-- CONFIRMED message IDs are shared across both. Category 10 (job
-- ability START/precast) deliberately NOT wired, same as categories 8/
-- 9/12 (magic/item/ranged start) -- packet_ground_truth.md documents
-- these as "no action needed" precast notifications, not real results.
local CLASSIFY_FN_BY_CATEGORY = {
    [combat_router.CATEGORY.MELEE] = {
        offense = classify.offense,
        defense = classify.defense,
    },
    [combat_router.CATEGORY.WEAPONSKILL] = {
        offense = classify.weaponskillOffense,
        defense = classify.weaponskillDefense,
    },
    [combat_router.CATEGORY.JOB_ABILITY] = {
        offense = classify.jobAbilityOffense,
        defense = classify.jobAbilityDefense,
    },
    [combat_router.CATEGORY.UNBLINKABLE_JA] = {
        offense = classify.jobAbilityOffense,
        defense = classify.jobAbilityDefense,
    },
    [combat_router.CATEGORY.RANGED_FINISH] = {
        offense = classify.rangedOffense,
        defense = classify.rangedDefense,
    },
    [combat_router.CATEGORY.PET_ACTION] = {
        offense = classify.petTpMoveOffense,
        defense = classify.petTpMoveDefense,
    },
    [combat_router.CATEGORY.MAGIC_FINISH] = {
        offense = classify.magicOffense,
        defense = classify.magicDefense,
    },
    [combat_router.CATEGORY.MONSTER_FINISH] = {
        offense = classify.monsterTpMoveOffense,
        defense = classify.monsterTpMoveDefense,
    },
    [combat_router.CATEGORY.ITEM_FINISH] = {
        offense = classify.itemUseOffense,
        defense = classify.itemUseDefense,
    },
};

-- Public, read-only view of which categories are in v1 scope --
-- DERIVED from CLASSIFY_FN_BY_CATEGORY above (see that table's own
-- comment for why), not maintained as a separate literal. Exists for
-- any external caller/test that wants a simple boolean-set check
-- without needing to know CLASSIFY_FN_BY_CATEGORY's shape.
combat_router.V1_SCOPED_CATEGORIES = {};
for category in pairs(CLASSIFY_FN_BY_CATEGORY) do
    combat_router.V1_SCOPED_CATEGORIES[category] = true;
end

-- export_log event `type` string per category -- lets exported data
-- distinguish a weaponskill hit from an ordinary melee swing, per user
-- request (2026-07-29): "make sure it's categorized under weapon
-- skill." Deliberately a separate lookup from CLASSIFY_FN_BY_CATEGORY
-- (not folded into the same table) since this is export-shape concern,
-- not classification logic -- keeps the two responsibilities visibly
-- separate even though they're both keyed by category today.
combat_router.EVENT_TYPE_BY_CATEGORY = {
    [combat_router.CATEGORY.MELEE]          = 'melee',
    [combat_router.CATEGORY.WEAPONSKILL]    = 'weaponskill',
    [combat_router.CATEGORY.JOB_ABILITY]    = 'job_ability',
    [combat_router.CATEGORY.UNBLINKABLE_JA] = 'job_ability',
    [combat_router.CATEGORY.RANGED_FINISH]  = 'ranged',
    [combat_router.CATEGORY.PET_ACTION]     = 'pet_tp_move',
    [combat_router.CATEGORY.MAGIC_FINISH]   = 'magic',
    [combat_router.CATEGORY.MONSTER_FINISH] = 'monster_tp_move',
    [combat_router.CATEGORY.ITEM_FINISH]    = 'item_use',
};

-- ===========================================================================
-- PURE LOGIC -- no Ashita dependency, fully testable offline.
-- ===========================================================================

-- 2026-10-29: fields classify.* may return in its 3rd value for a
-- KNOWN outcome, lifted to top-level export fields so consumers don't
-- dig through `raw`. These all replace a param that used to be
-- (wrongly) exported as `damage` -- see classify.lua's 2026-10-29 notes.
combat_router.LIFTED_FIELDS = {
    'statusId',      -- status effect ID (status landed / removed / proc)
    'thLevel',       -- Treasure Hunter level after a TH proc
    'itemId',        -- item taken by Steal
    'effectLevel',   -- DNC daze level
    'effectParam',   -- uninterpreted param (message-0 abilities, e.g. Resonance)
    'counterDamage', -- damage the attacker took from a mob's counter
    'stat',          -- Absorb-* spell stat name (was raw.stat before)
};

-- Puts classify's 3rd return value onto an export row. UNKNOWN /
-- UNKNOWN_ADD_EFFECT rows keep the full `raw` envelope (needed to
-- identify them later); known outcomes get only the lifted fields, so
-- `raw` present on a row once again reliably means "needs identifying".
-- Skillchain rows also keep `raw` (message/animation/baseMessage) as
-- before, since downstream may already read it.
---@param fields table  export row being built (mutated)
---@param outcome string
---@param raw table|nil
function combat_router.attachRaw(fields, outcome, raw)
    if raw == nil then
        return;
    end
    if outcome == classify.OUTCOME.UNKNOWN
        or outcome == classify.OUTCOME.UNKNOWN_ADD_EFFECT
        or outcome == classify.OUTCOME.SKILLCHAIN then
        fields.raw = raw;
        return;
    end
    for _, key in ipairs(combat_router.LIFTED_FIELDS) do
        if raw[key] ~= nil then
            fields[key] = raw[key];
        end
    end
end

-- Determines whether THIS action should be tracked at all, and if so,
-- as offense or defense, from plain boolean facts about the actor/target
-- -- mirrors the same decision logic documented from Metrics' dispatch
-- table (read during this project's earlier packet-ground-truth
-- research): actor-is-tracked-player-or-their-pet => offense;
-- actor-is-a-monster AND target-is-tracked-player-or-their-pet =>
-- defense; actor targeting itself => a mob buff, not combat (excluded);
-- otherwise not tracked.
--
-- Deliberately simpler than Metrics' own version: this project has no
-- "lurk mode" (track everyone's combat, not just the local player's) --
-- out of scope for mobparser's stated purpose (estimating stats for
-- mobs YOU personally fight), and adding it would mean tracking combat
-- involving OTHER players' gear/stats, which mobparser has no way to
-- read anyway (see project file's checkparam/self-probe design -- it
-- only knows the LOCAL player's stats).
--
---@param actorIsTrackedPlayerOrPet boolean
---@param actorIsMonster boolean
---@param targetIsTrackedPlayerOrPet boolean
---@param actorEqualsTarget boolean
---@return string|nil  'offense' | 'defense' | nil (not tracked)
function combat_router.determineSide(actorIsTrackedPlayerOrPet, actorIsMonster,
                                       targetIsTrackedPlayerOrPet, actorEqualsTarget)
    if actorEqualsTarget then
        return nil;  -- self-target (mob buffing itself, etc) -- not combat
    end
    if actorIsTrackedPlayerOrPet then
        return 'offense';
    end
    if actorIsMonster and targetIsTrackedPlayerOrPet then
        return 'defense';
    end
    return nil;
end

-- Given a parsed action (packet_action.build's output) and the side
-- ('offense'/'defense'/nil), routes each per-target result through the
-- right classify.* function for THIS action's category (see
-- CLASSIFY_FN_BY_CATEGORY above). Returns an array of
-- { outcome, damage, raw, targetId, hitIndex, hitCount,
-- addEffectOutcome, addEffectDamage, addEffectRaw } entries, one per
-- result, or an empty array if side is nil (untracked action) or
-- category is out of v1 scope.
--
-- hitIndex/hitCount added 2026-07-29 for multi-hit weaponskill support
-- (per user request: "count each weapon skill hit... a way to tell the
-- difference between the hit, ie: hit 1 land, hit 2 land, hit 3 miss,
-- hit 4 land"). Populated for EVERY result, not just weaponskill --
-- harmless for melee (main-hand is hitIndex=1,hitCount=1 or
-- hitIndex=1,hitCount=2 alongside an off-hand swing) and keeps the
-- result shape uniform across categories rather than having
-- weaponskill-only fields that appear/disappear depending on category.
-- hitCount is the target's OWN result_sum for this action (how many
-- results this target block carries total), not a global count across
-- all targets -- matches how a multi-hit WS is actually structured in
-- the packet (per packet_action.lua's target.actions array).
--
-- addEffectOutcome/addEffectDamage/addEffectRaw added 2026-07-29 for
-- skillchain/enspell/en-effect proc capture -- see classify.addEffect's
-- own header for the full design (why this is a SEPARATE thing from
-- the base outcome, and why it's not yet split by mechanism).
-- addEffectOutcome is nil when this result had no add-effect block at
-- all -- caller (handlePacket below) must check for that before
-- emitting a proc event.
---@param action table  from packet_action.build
---@param side string|nil
---@return table  array of { outcome, damage, raw, animation, targetId, hitIndex, hitCount, addEffectOutcome, addEffectDamage, addEffectRaw }
function combat_router.route(action, side)
    local results = {};

    if side == nil then
        return results;
    end
    local classifyFns = CLASSIFY_FN_BY_CATEGORY[action.category];
    if classifyFns == nil then
        return results;  -- category not yet in v1 scope
    end

    local classifyFn = (side == 'offense') and classifyFns.offense or classifyFns.defense;

    for _, target in ipairs(action.targets) do
        local hitCount = #target.actions;
        for hitIndex, result in ipairs(target.actions) do
            local outcome, damage, raw = classifyFn(result);
            -- addEffectOutcome/addEffectDamage/addEffectRaw (2026-07-29):
            -- independent of the base outcome above -- see
            -- classify.addEffect's own header. addEffectOutcome is nil
            -- (not classify.OUTCOME.UNKNOWN_ADD_EFFECT) when this
            -- result's has_add_effect bit wasn't set at all -- callers
            -- must check for nil, not just falsiness of damage, before
            -- treating this as a real proc.
            local addEffectOutcome, addEffectDamage, addEffectRaw = classify.addEffect(result);
            -- animation (2026-07-30): passed through RAW, unmapped --
            -- per packet_ground_truth.md's Animation IDs table (category
            -- 1/melee only): MELEE_MAIN=0, MELEE_OFFHAND=1, MELEE_KICK=
            -- 2/3, DAKEN=4. Deliberately NOT interpreted here -- this
            -- module is category-agnostic (route() dispatches ALL v1
            -- categories, not just melee), and the animation value means
            -- something different per category (weaponskill/JA/magic
            -- animation IDs are a different vocabulary entirely, not yet
            -- documented). handlePacket's export loop below is where
            -- category is known, so mapping to a hand label belongs
            -- there, not here. NOTE per packet_ground_truth.md's own
            -- "Open items" #1: main-hand (0) is live-confirmed; off-hand
            -- (1)/kick/Daken are structurally parsed but NOT YET
            -- observed in a real capture -- treat off-hand attribution
            -- as unconfirmed until that happens naturally in a fight.
            table.insert(results, {
                outcome  = outcome,
                damage   = damage,
                raw      = raw,       -- nil unless outcome == UNKNOWN
                animation = result.animation,
                targetId = target.id,
                hitIndex = hitIndex,
                hitCount = hitCount,
                addEffectOutcome = addEffectOutcome,
                addEffectDamage  = addEffectDamage,
                addEffectRaw     = addEffectRaw,
            });
        end
    end

    return results;
end

-- ===========================================================================
-- ASHITA-FACING GLUE -- calls AshitaCore, UNTESTED OFFLINE.
-- Needs in-game verification before this is trusted (see project file).
-- ===========================================================================

-- Placeholder hooks -- real implementations depend on Ashita's actual
-- entity/party APIs. IMPLEMENTED 2026-07-28 against the documented
-- Ashita v4 SDK surface (AshitaCore:GetDataManager():GetEntity()/
-- :GetParty(), GetEntity(index).ServerId/.SpawnFlags/.PetTargetIndex),
-- cross-checked against real, currently-maintained addon source
-- (lejar/AshitaTargetInfo, ProjectTako/ffxi-addons -- API SHAPE only,
-- not copied verbatim, same license discipline as the rest of this
-- project) rather than guessed from memory. STILL UNTESTED IN-GAME --
-- see the specific flagged uncertainty below before trusting this.
combat_router.ashita = {};

-- Ashita's packet fields (per packet_ground_truth.md) give SERVER IDs
-- (actor_id, target.id), but AshitaCore:GetDataManager():GetEntity()
-- is indexed by TARGET INDEX, not server ID -- there is no documented
-- direct serverId->index lookup call. The pattern used by real addons
-- (e.g. AshitaTargetInfo's is_combat_target check, which loops party
-- members comparing GetMemberServerId against a claim ID) is a linear
-- scan comparing GetServerId(index) against the target server ID.
-- Applied the same pattern here across the full entity index range.
--
-- FLAGGED UNCERTAINTY, NOT SILENTLY ASSUMED: the exact entity index
-- upper bound (MAX_ENTITY_INDEX below) is written from general
-- knowledge of FFXI's entity table sizing conventions, NOT verified
-- against Ashita's actual current SDK constant or CatsEyeXI
-- specifically. If this is wrong (too low), some entities will be
-- silently invisible to isTrackedPlayerOrPet/isMonster -- same failure
-- shape as the mobstats v1.0 invented-message-ID mistake this project
-- has been careful to avoid elsewhere. MUST be confirmed in-game
-- (either find the real constant in Ashita's SDK headers, or confirm
-- empirically that entities never appear at indices >= this value)
-- before trusting this for real data collection.
local MAX_ENTITY_INDEX = 2304; -- UNVERIFIED, see note above

-- Finds the entity object for a given SERVER ID by linear scan, or nil
-- if not found (e.g. entity out of render range -- a real limitation,
-- not a bug; Ashita only has memory-backed data for entities the
-- client has actually loaded).
--
-- PERFORMANCE FLAG, worth revisiting once this is running in-game: this
-- is called (via isMonster/isTrackedPlayerOrPet) once per TARGET per
-- action packet -- combat_router.handlePacket loops action.targets and
-- calls both for each. A 0..2304 linear scan on every incoming 0x028
-- packet, potentially several times per packet during AOE fights, could
-- be a real per-frame cost. Not optimized preemptively here (no real
-- packet-rate data to know if it matters yet), but if in-game testing
-- shows lag correlated with combat, this is the first place to look --
-- likely fix would be caching entityId->targetIndex for the duration of
-- a single handlePacket call (multiple targets in one packet could
-- share cache hits) rather than rescanning from zero every time.
-- BUGFIX (2026-07-28, caught by THIRD real /addon load attempt, first
-- one to actually process a live 0x028 packet): errored with "attempt
-- to call method 'GetDataManager' (a nil value)" on every real combat
-- packet. Root cause, on inspection: this function fetched
-- `AshitaCore:GetDataManager():GetEntity()` into `entityMgr` but NEVER
-- ACTUALLY USED IT -- the loop below calls the global `GetEntity(index)`
-- function directly, not a method on `entityMgr`. The fetch was dead,
-- unnecessary code from the start; removing it removes the crash
-- entirely rather than needing to diagnose why AshitaCore itself was
-- nil (worth being honest that this specific "why is AshitaCore nil
-- here" question was never actually answered -- the fix sidesteps it
-- by deleting code that didn't need to exist, not by understanding the
-- root scoping/timing issue that made it nil in this context. If
-- AshitaCore access is ever genuinely needed inside combat_router.lua
-- again, that open question would need real investigation, not
-- another assumption).
-- PERF (2026-10-30): serverId -> entity index cache. A cached index is
-- re-checked (the entity there must still carry the same ServerId) before
-- it is trusted, so a despawn/respawn into that slot can never return the
-- wrong entity -- a stale entry just falls through to the full scan.
-- Misses are deliberately NOT cached: after the handlePacket early-out
-- below, this only runs for packets that involve you, and caching a miss
-- could drop a real hit from a mob whose entity hadn't loaded yet.
-- Cleared on zone (combat_router.onZone).
local entityIndexCache = {};

local function findEntityByServerId(serverId)
    if serverId == nil or serverId == 0 then
        return nil;
    end
    local cachedIndex = entityIndexCache[serverId];
    if cachedIndex ~= nil then
        local entity = GetEntity(cachedIndex);
        if entity ~= nil and entity.ServerId == serverId then
            return entity;
        end
        entityIndexCache[serverId] = nil; -- stale -- rescan below
    end
    for index = 0, MAX_ENTITY_INDEX do
        local entity = GetEntity(index);
        if entity ~= nil and entity.ServerId == serverId then
            entityIndexCache[serverId] = index;
            return entity;
        end
    end
    return nil;
end

-- EntitySpawnFlags bit values.
--
-- CORRECTED 2026-07-28, second live-test round, root-caused with real
-- evidence rather than another guess. The original value below (MOB =
-- 0x04) was flagged from the start as "trusted from documented
-- real-addon usage, not independently confirmed" -- and it was WRONG.
-- Confirmed via a temporary diagnostic build logging real SpawnFlags
-- values from an actual live fight:
--   isMonster(17240117): SpawnFlags=16 (entity.Name=Sand Lizard)  -- a
--     real, confirmed monster, whose flags do NOT include 0x04 at all.
--   isMonster(44151): SpawnFlags=525 (entity.Name=Lift)  -- the LOCAL
--     PLAYER's own flags, which DO include 0x04 -- proving 0x04 is not
--     monster-specific and was actively causing isMonster() to
--     misclassify (well, in this direction it happened not to matter,
--     since the PC check already short-circuits first -- but for
--     Sand Lizard, 0x04 not being set meant the MOB branch never fired,
--     falling through to the NPC-flag fallback, which ALSO didn't match
--     -- 16 has neither 0x02 nor the old wrong 0x04 set -- so isMonster
--     returned false for a real monster. This is the root cause of the
--     defense-side classification producing zero output all last
--     session despite confirmed real melee damage taken (see project
--     file "OPEN, CONFIRMED BUG" section).
--
-- Real value confirmed against the actual Ashita v4 SDK source itself
-- this time (AshitaXI/Ashita-v4beta, plugins/sdk/ffxi/entity.h,
-- fetched directly): "SpawnFlags; // The entities spawn flags.
-- [0x01 = PC, 0x02 = NPC, 0x10 = Mob, 0x0D = Local Player]" -- MOB is
-- 0x10, not 0x04. 0x10 = 16 decimal, an EXACT match to Sand Lizard's
-- observed SpawnFlags=16. Also explains why the local player's own
-- flags (525) never matched a clean single bit under the old scheme --
-- "Local Player = 0x0D" is documented as its own composite value
-- (0x01|0x04|0x08), not simply "PC flag set", which is a separate
-- detail worth remembering if PC-detection edge cases ever come up.
local ENTITY_SPAWN_FLAGS = {
    PC     = 0x01,
    NPC    = 0x02,
    MOB    = 0x10, -- CORRECTED from 0x04 -- see note above, confirmed
                    -- against real Ashita v4 SDK source + real
                    -- diagnostic data, not a guess.
    OBJECT = 0x08,
};

function combat_router.ashita.isTrackedPlayerOrPet(entityId)
    -- "Tracked" per this project's stated non-goal of lurk-mode: ONLY
    -- the local player and the local player's own pet, not party
    -- members (see combat_router.lua's own comment on determineSide
    -- for why -- mobparser can't read other players' stats anyway).
    local player = GetPlayerEntity();
    if player == nil then
        return false; -- not logged in / not in a zone yet
    end
    if entityId == player.ServerId then
        return true;
    end

    -- Pet check: player.PetTargetIndex is a TARGET INDEX (not a server
    -- ID) per the entity struct -- resolve it to a server ID via
    -- GetEntity, then compare, rather than assuming entityId (a server
    -- ID, from packet data) can be compared to PetTargetIndex directly.
    if player.PetTargetIndex ~= nil and player.PetTargetIndex ~= 0 then
        local pet = GetEntity(player.PetTargetIndex);
        if pet ~= nil and pet.ServerId == entityId then
            return true;
        end
    end

    return false;
end

-- Added 2026-07-29 (gap 1 fix, pet/player melee split). Same identity
-- check as isTrackedPlayerOrPet above, but tells the two apart instead
-- of collapsing them into one boolean -- needed so combat_router
-- .handlePacket can tag pet melee separately from player melee in the
-- export (see EVENT_TYPE_BY_CATEGORY / handlePacket below). Kept as a
-- SEPARATE function rather than changing isTrackedPlayerOrPet's return
-- shape, since isTrackedPlayerOrPet's boolean contract is already
-- relied on by determineSide() and by isTrackedPlayerOrPet's own
-- existing callers/tests -- changing its shape would be a breaking
-- change to working, verified code for no reason. Real duplication
-- with isTrackedPlayerOrPet's body above is deliberate and small (two
-- comparisons) -- not worth a shared-helper refactor that would touch
-- already-verified code.
---@param entityId number
---@return boolean isPet  true if entityId is specifically the local player's pet (not the player themselves)
function combat_router.ashita.isPet(entityId)
    local player = GetPlayerEntity();
    if player == nil then
        return false;
    end
    if player.PetTargetIndex ~= nil and player.PetTargetIndex ~= 0 then
        local pet = GetEntity(player.PetTargetIndex);
        if pet ~= nil and pet.ServerId == entityId then
            return true;
        end
    end
    return false;
end

-- Added 2026-07-29 (party-member data collection expansion). Resolves
-- entityId to party-member identity, or nil if entityId isn't a party
-- member or a party member's pet. Built specifically to NOT touch
-- isTrackedPlayerOrPet/isPet above (same reasoning as isPet's own
-- header: those are already relied on by determineSide() and their own
-- tests -- this is deliberately a separate, additive function).
--
-- API surface CONFIRMED against the real Ashita.h header (user-supplied
-- this session, not guessed/reconstructed from memory or from stale
-- v3-era wiki/forum hits that kept surfacing during initial research --
-- see project file for that dead end): IParty::GetMemberIsActive,
-- GetMemberServerId, GetMemberName, GetMemberMainJob,
-- GetMemberTargetIndex (all indexed 0-5, 0 = local player). There is
-- NO GetMemberIsPet in the real interface -- pet identity is DERIVED,
-- same pattern as isPet() above: a party member's own entity (via
-- GetMemberTargetIndex -> GetEntity) exposes PetTargetIndex, which
-- resolves to the pet's own entity for ServerId/Name.
--
-- NOT YET IN-GAME VERIFIED -- same disclaimer as the rest of
-- combat_router.ashita.*: written against the confirmed header
-- contract, but this project's own discipline (see isMonster's
-- SpawnFlags correction above) is that header-correctness and
-- in-game-correctness are two different claims. Needs a real party
-- fight before being fully trusted.
---@param entityId number
---@return table|nil  { name, job, isPet, ownerName } or nil if not a party member/pet
function combat_router.ashita.getPartyMemberInfo(entityId)
    local party = AshitaCore:GetMemoryManager():GetParty();
    if party == nil then
        return nil;
    end

    for i = 0, 5 do
        if party:GetMemberIsActive(i) ~= 0 then
            local memberServerId = party:GetMemberServerId(i);

            -- Direct match: entityId IS this party member.
            if memberServerId == entityId then
                return {
                    name = party:GetMemberName(i),
                    job = party:GetMemberMainJob(i),
                    isPet = false,
                    ownerName = nil,
                };
            end

            -- Pet match: resolve this member's own entity, check its
            -- PetTargetIndex, compare THAT entity's ServerId against
            -- entityId. Same PetTargetIndex->GetEntity idiom as
            -- isTrackedPlayerOrPet/isPet above, just sourced from a
            -- party member's entity instead of only the local player's.
            local memberTargetIndex = party:GetMemberTargetIndex(i);
            if memberTargetIndex ~= nil and memberTargetIndex ~= 0 then
                local memberEntity = GetEntity(memberTargetIndex);
                if memberEntity ~= nil and memberEntity.PetTargetIndex ~= nil
                    and memberEntity.PetTargetIndex ~= 0 then
                    local pet = GetEntity(memberEntity.PetTargetIndex);
                    if pet ~= nil and pet.ServerId == entityId then
                        return {
                            name = pet.Name,
                            job = nil, -- pets don't have a job
                            isPet = true,
                            ownerName = party:GetMemberName(i),
                        };
                    end
                end
            end
        end
    end

    return nil;
end

-- 2026-10-29: name for ANY entity by server ID (mob, NPC, non-party PC),
-- read from local client memory only (T2 -- no server query). Fixes the
-- GUI's "(pet/unknown)" row: actorName is only filled for party members,
-- so every mob action on the defense side (mob hits/misses you, mob TP
-- moves) had no name to group under. Cached per server ID so the linear
-- findEntityByServerId scan runs once per entity, not once per packet.
-- Misses (entity out of range / already despawned) are NOT cached, so a
-- later packet can still resolve it. Returns nil rather than guessing.
local entityNameCache = {};
function combat_router.ashita.entityName(serverId)
    if serverId == nil or serverId == 0 then
        return nil;
    end
    local cached = entityNameCache[serverId];
    if cached ~= nil then
        return cached;
    end
    local entity = findEntityByServerId(serverId);
    if entity == nil then
        return nil;
    end
    local name = entity.Name;
    if type(name) ~= 'string' or name == '' then
        return nil;
    end
    entityNameCache[serverId] = name;
    return name;
end

function combat_router.ashita.isMonster(entityId)
    local entity = findEntityByServerId(entityId);
    if entity == nil then
        return false; -- can't confirm -- entity out of render range or
                        -- despawned. Treat as "not confirmed a monster"
                        -- rather than guessing, consistent with this
                        -- function's contract (boolean, not tri-state --
                        -- callers already handle "not tracked" via the
                        -- overall determineSide() logic returning nil).
    end

    -- Spawn-flag check. MOB = 0x10, CONFIRMED (2026-07-28) against real
    -- Ashita v4 SDK source (AshitaXI/Ashita-v4beta, entity.h) and
    -- verified with real diagnostic data from a live fight, then
    -- quantitatively confirmed correct against Metrics (231 damage
    -- taken, 50% evasion proc -- exact match, see project file "Second
    -- live-test round" section). The original 0x04 value was wrong --
    -- see ENTITY_SPAWN_FLAGS's own comment above for the full story.
    --
    -- NOTE: uses bit.band(), not Lua's native `&` operator -- confirmed
    -- from real Ashita v4 addon source (lejar/AshitaTargetInfo uses
    -- bit.band throughout for SpawnFlags checks), which strongly
    -- signals Ashita v4's Lua runtime predates native bitwise operator
    -- support (Lua 5.1/LuaJIT-shaped), not Lua 5.3+. Using `&` here
    -- would have been a silent, untestable-offline bug -- exactly the
    -- kind of thing this project has been careful to avoid elsewhere.
    local flags = entity.SpawnFlags or 0;
    if flags == 0 then
        return false; -- no flags at all -- can't confirm, don't guess
    end

    local isPC = bit.band(flags, ENTITY_SPAWN_FLAGS.PC) ~= 0;
    if isPC then
        return false;
    end
    local isMobFlag = bit.band(flags, ENTITY_SPAWN_FLAGS.MOB) ~= 0;
    if isMobFlag then
        return true;
    end
    -- Fallback: NPC flag set (per the confirmed real SDK layout, this
    -- catches non-PC, non-Mob NPC-type entities -- unclaimable NPCs,
    -- vendors, etc, not monsters, so returning false-via-this-path is
    -- correct, not a monster miss).
    local isNpc = bit.band(flags, ENTITY_SPAWN_FLAGS.NPC) ~= 0;
    return isNpc;
end

-- Canonical slot order, vendored VERBATIM from integration-guide.md
-- §2.3 ("Slot keys are exactly these, in this spelling"). Kept as an
-- explicit ordered list (not just iterated via pairs(env.worn)) so the
-- debug_log signature has a STABLE field order every line -- makes the
-- log actually diffable/greppable across swings, which is the whole
-- point of this diagnostic (see debug_log.lua's own design intent).
-- Order chosen to match the guide's own listing exactly, not
-- re-ordered by "likely to change" -- that was the old (2026-07-28,
-- same day, earlier) 2-slot version's mistake: it scoped down to
-- Main+Ammo specifically because those seemed like the likely-to-change
-- slots for the motivating TP-set-swap case, but real live-test data
-- the SAME day (a deliberate Ammo-only swap, Talon Tathlum -> Morion
-- Tathlum, confirmed cleanly timed in debug_log.txt) also surfaced a
-- direct correction from the user: Main/Sub/Range/Ammo are NOT the only
-- slots that move mid-fight, just the ones that happen to change most
-- often -- Body/Ring/Back/etc can and do matter (e.g. accuracy pieces,
-- magic-eva pieces). Scoping the debug log to a hand-picked subset was
-- an unjustified assumption this project has otherwise been careful to
-- avoid -- fixed by tracking all 16, matching what dlac_listener's
-- mergedWorn already stores underneath (it was NEVER scoped down --
-- only this function's DISPLAY of it was).
local SLOT_ORDER = {
    'Main', 'Sub', 'Range', 'Ammo', 'Head', 'Neck', 'Ear1', 'Ear2',
    'Body', 'Hands', 'Ring1', 'Ring2', 'Back', 'Waist', 'Legs', 'Feet',
};

-- Builds a full-16-slot, human-diffable gear-tag summary for
-- debug_log.lua's gearTag parameter, from a dlac_listener composition
-- lookup. Kept as its own function (rather than inlined into
-- handlePacket) so it's independently testable offline against a fake
-- envelope shape, same pattern as everything else pure-logic in this
-- file.
--
-- Only ever called for melee (v1-scoped) swings right now, so this
-- always uses dlac_listener.currentComposition -- the no-actionId,
-- "newest worn, full stop" lookup -- per the design decision that
-- melee has no dlac-side action anchor to join against at all (see
-- dlac_listener.lua's own currentComposition comment for the full
-- reasoning).
--
-- HISTORY (2026-07-28, both changes same day): originally emitted only
-- Main+Ammo (an unjustified scoping assumption, corrected above).
-- Before that, had a real bug where a `?` could mean "dlac_listener
-- handed us a genuinely partial envelope" rather than "slot truly
-- unworn/unreported" -- fixed upstream in dlac_listener.lua's
-- state.mergedWorn merge logic, not in this function (this function
-- was always correctly reading whatever env.worn it was handed; the
-- bug was in what got handed to it). Both fixes are independent of
-- each other and both are now in effect.
---@param dlacState table|nil  from dlac_listener.newState(), or nil if dlac tracking is disabled
---@return table|nil  { status, signature } for debug_log.record, or nil if dlacState is nil
-- Fetches the current melee-relevant gear composition ONCE (the
-- underlying data both buildGearTag's debug-log DISPLAY string and
-- export_log's REAL gear-state interning need) -- added 2026-07-28
-- alongside export_log.lua's wiring, so handlePacket doesn't call
-- dlac_listener.currentComposition twice per swing for two different
-- consumers of the same lookup. Returns the raw `worn` table (or nil)
-- plus the status string, same two values dlac_listener.
-- currentComposition itself returns -- callers that only need the
-- human-readable debug summary should go through buildGearTag (below,
-- now taking the already-fetched worn/status rather than re-fetching),
-- callers needing the real data for export should use the `worn` table
-- directly.
---@param dlacState table|nil
---@return table|nil worn, string|nil status
-- ---------------------------------------------------------------------------
-- Equipped gear from CLIENT MEMORY (2026-10-30, rebuilt 2026-10-30 night
-- after the afternoon files were lost). Brad: "read all from memory
-- instead of dlac" / "read from memory for armor". dlac only streams the
-- slots its own set decisions change, so a manual swap (e.g. new ammo)
-- was never reported. All 16 slots are now read from memory on every
-- event; dlac's value survives only for a slot memory can't read.
--
-- Read-only (T2), sends nothing. Same calls + decode dlac uses on this
-- Ashita build (dlac gear/gearoracle.lua readWorn, ui/gearui.lua):
--   GetInventory():GetEquippedItem(slotId).Index  (high byte = container,
--   low byte = index) -> GetContainerItem(cont, idx).Id ->
--   GetResourceManager():GetItemById(id).Name[1]
-- Slot ids from dlac ui/gearui.lua EQUIP_SLOTS.
-- Accepted trade-off: memory shows what is on when the result packet
-- arrives; a very fast WS swap-back may already show the TP set.
-- ---------------------------------------------------------------------------
local EQUIP_SLOT_ID = {
    Main = 0, Sub = 1, Range = 2, Ammo = 3, Head = 4, Body = 5, Hands = 6, Legs = 7,
    Feet = 8, Neck = 9, Waist = 10, Ear1 = 11, Ear2 = 12, Ring1 = 13, Ring2 = 14, Back = 15,
};

local memItemNameCache = {};

-- Returns slot -> {name=, id=} for readable worn slots, slot -> false for
-- slots memory says are EMPTY, and leaves unreadable slots absent.
-- Returns nil if memory can't be read at all (zoning, no inventory).
-- PERF (2026-10-30): one shared function instead of a new closure per
-- slot per call (was 16 closures per read).
local function readEquippedSlot(inv, res, sid)
    local eq = inv:GetEquippedItem(sid);
    if eq == nil or eq.Index == nil then return nil; end -- unreadable
    local packed = eq.Index;
    if packed == 0 then return false; end -- nothing equipped
    local cont = bit.rshift(bit.band(packed, 0xFF00), 8);
    local idx = bit.band(packed, 0x00FF);
    local ci = inv:GetContainerItem(cont, idx);
    if ci == nil or ci.Id == nil then return nil; end
    local id = ci.Id;
    if id == 0 or id == 65535 then return false; end
    local name = memItemNameCache[id];
    if name == nil then
        local item = res:GetItemById(id);
        name = item and item.Name and item.Name[1];
        if type(name) ~= 'string' or name == '' then return nil; end
        memItemNameCache[id] = name;
    end
    return { name = name, id = id };
end

function combat_router.ashita.readEquippedFromMemory()
    if AshitaCore == nil then return nil; end
    local mm = AshitaCore:GetMemoryManager();
    local inv = mm and mm:GetInventory();
    local res = AshitaCore:GetResourceManager();
    if inv == nil or res == nil then return nil; end
    local out = {};
    for slot, sid in pairs(EQUIP_SLOT_ID) do
        local ok, val = pcall(readEquippedSlot, inv, res, sid);
        if ok and val ~= nil then out[slot] = val; end
    end
    return out;
end

local function currentGearWorn(dlacState)
    local worn, status = nil, nil;
    if dlacState ~= nil then
        local dlac_listener = require('dlac_listener');
        local env;
        env, status = dlac_listener.currentComposition(dlacState);
        if env ~= nil and env.worn ~= nil then
            -- COPY -- dlac's mergedWorn is never mutated here
            worn = {};
            for slot, item in pairs(env.worn) do worn[slot] = item; end
        end
    end

    local okMem, mem = pcall(combat_router.ashita.readEquippedFromMemory);
    if okMem and mem ~= nil then
        local any = false;
        for slot, val in pairs(mem) do
            any = true;
            worn = worn or {};
            if val == false then
                worn[slot] = nil; -- memory says empty: clears dlac's value
            else
                worn[slot] = val;
            end
        end
        if any and status == nil then status = 'memory'; end
        if any and status == 'cold' then status = 'memory'; end
    end
    return worn, status;
end
combat_router._currentGearWorn = currentGearWorn; -- offline tests only

-- Builds a short, human-diffable gear-tag summary for debug_log.lua's
-- gearTag parameter, from an ALREADY-FETCHED composition (see
-- currentGearWorn above -- this function no longer does its own
-- dlac_listener lookup, to avoid fetching the same data twice per
-- swing now that export_log.lua also needs it).
---@param worn table|nil  from currentGearWorn
---@param status string|nil  from currentGearWorn
---@return table|nil  { status, signature } for debug_log.record, or nil if status is nil (dlac tracking disabled)
local function buildGearTag(worn, status)
    if status == nil then
        return nil;
    end

    if worn == nil then
        -- 'cold' (nothing seen yet) -- still worth recording the
        -- status so a human reviewing the log can tell "dlac tracking
        -- is on but has produced nothing yet" apart from "dlac
        -- tracking wasn't attempted at all" (dlacState == nil, handled
        -- above -- returns nil there, so debug_log.lua omits the field
        -- entirely, a visibly different case from this one).
        return { status = status, signature = 'none' };
    end

    -- Full 16-slot signature, in the guide's own canonical order. A `?`
    -- for a given slot means "genuinely never seen this slot reported
    -- at all this session" -- not a bug, just means dlac hasn't sent a
    -- worn envelope touching that slot yet (e.g. right after
    -- /dl stream on but before the bootstrap query's snapshot has
    -- arrived, or a slot that's simply never changed from whatever was
    -- on before mobparser started listening -- see dlac_listener.lua's
    -- cold-start handling for the snapshot-query mechanics that
    -- minimize this window).
    local parts = {};
    for _, slot in ipairs(SLOT_ORDER) do
        local item = worn[slot];
        table.insert(parts, slot .. '=' .. (item and item.name or '?'));
    end
    return { status = status, signature = table.concat(parts, ',') };
end

-- The actual packet_in handler mobparser registers with Ashita. Calls
-- the (currently stubbed) Ashita glue to answer the offense/defense
-- questions, then delegates to the pure route() logic above.
---@param packetId number
---@param packetData string
---@param dlacState table|nil  from dlac_listener.newState(), passed through from
---                              mobparser.lua's load handler. nil is valid and
---                              means "no dlac gear-tagging this session" -- NOT
---                              an error; the whole combat pipeline must keep
---                              working with dlac's addon absent, per the
---                              project's original one-way, no-load-dependency
---                              design between mobparser and its data sources.
-- Animation -> hand, melee only (see the hand note inside handlePacket).
-- File scope since 2026-10-30 (was rebuilt for every target).
local HAND_BY_ANIMATION = { [0] = 'main', [1] = 'sub', [2] = 'other', [3] = 'other', [4] = 'other' };

function combat_router.handlePacket(packetId, packetData, dlacState)
    if packetId ~= 0x028 then
        return;
    end

    local packet_action = require('packet_action');
    local action, err = packet_action.build(packetData);
    if action == nil then
        -- DIAGNOSTIC (2026-07-28): `err` was previously captured here and
        -- then silently discarded -- every real 0x028 packet that failed
        -- to parse (parse error OR trg_sum==0) returned here with zero
        -- visible signal, indistinguishable from a genuine junk/empty
        -- packet. Given packets_bitreader.lua's field layout is the
        -- single biggest unverified unknown in this project, a silent
        -- parse failure here was a real, live hypothesis for why the
        -- first in-game test produced an empty debug_log.txt with no
        -- errors and no write-failure warning at all. This does NOT fix
        -- any parsing logic -- it only stops swallowing the error so the
        -- NEXT test run actually reveals what's happening. One-time
        -- warning per session so a real fight (many junk packets are
        -- normal/expected) doesn't spam chat.
        if not combat_router._hasWarnedAboutBuildFailure then
            combat_router._hasWarnedAboutBuildFailure = true;
            local okChat, chat = pcall(require, 'chat');
            local msg = '[mobparser] packet_action.build failed on a 0x028 packet: ' ..
                tostring(err) .. ' (this warning only shows once per session -- ' ..
                'if this fires on real combat swings, packet_action.lua\'s field ' ..
                'layout likely needs correcting)';
            if okChat and chat ~= nil then
                print(chat.header('mobparser') .. chat.message(msg));
            else
                print(msg);
            end
        end
        return;  -- junk/empty packet or parse error -- not tracked, not an error state
    end

    -- combat_router.ashita.* is now REAL (2026-07-28) -- see that
    -- section's own comments for what's confirmed vs. still flagged as
    -- uncertain (MAX_ENTITY_INDEX, ENTITY_SPAWN_FLAGS.MOB). Safe to call
    -- in a live environment now, but the flagged uncertainties mean
    -- results should still be treated as "needs in-game verification,"
    -- not blindly trusted -- which is the whole point of this test.
    local actorIsTrackedPlayerOrPet = combat_router.ashita.isTrackedPlayerOrPet(action.actor_id);
    -- PERF (2026-10-30): isMonster is now LAZY -- only asked when the actor
    -- is not you/your party AND the target is you (the only case where
    -- determineSide reads it). Was computed for every action packet in the
    -- zone, including other parties' fights that are thrown away.
    local actorIsMonster = nil;

    -- Party member data collection (2026-07-29 expansion): resolves
    -- once per action, not per target -- "who the actor is" doesn't
    -- vary across an action's target list. nil when action.actor_id is
    -- neither a party member nor a party member's pet (the common
    -- case: most actions are the local player, another player's
    -- unrelated action, or the mob itself -- this ONLY fires for real
    -- party-member/party-pet actors).
    --
    -- Folded into the offense-side boolean ADDITIVELY --
    -- actorIsTrackedPlayerOrPet (local player/own pet) is UNCHANGED and
    -- still checked first; a party member or their pet ALSO counts as
    -- offense now. determineSide() itself is NOT modified -- still the
    -- same pure, already-tested function, just fed a wider boolean from
    -- here. See determineSide's own header for why party members were
    -- previously deliberately excluded (no lurk-mode) -- this is a
    -- scope expansion the user explicitly requested this session, not
    -- an accidental reversal of that design note.
    local actorPartyInfo = combat_router.ashita.getPartyMemberInfo(action.actor_id);
    local actorIsPartyOrPartyPet = (actorPartyInfo ~= nil);

    -- 2026-10-29: plain entity name for the actor (mob / anyone), kept in
    -- its OWN field so actorName keeps meaning "party member". pcall'd so
    -- a lookup failure can never break capture.
    -- PERF (2026-10-30): actor name is now resolved lazily, on the first
    -- target that is actually kept (see the early-out in the loop below).
    local actorEntityName = nil;
    local actorNameResolved = false;

    -- (2026-10-29: the temporary resprobe.lua hook that used to sit here
    -- is retired -- its findings are now implemented in action_names.lua.)
    -- PERF (2026-10-30): requires hoisted out of the per-target loop.
    local action_names = require('action_names');
    local debug_log = require('debug_log');
    local export_log = require('export_log');

    local actorOffense = actorIsTrackedPlayerOrPet or actorIsPartyOrPartyPet;

    -- PERF (2026-10-30): gear read ONCE per action (was once per target --
    -- an AoE read all 16 slots again for every mob it hit), and only when
    -- the gear is yours: your own / your pet's actions, and anything that
    -- targets you (defense -- your DEF/EVA gear matters there). Party
    -- members' actions no longer get YOUR gear stamped on them (it never
    -- described their gear -- see the gearStateId note below); they get
    -- the shared "no gear data" state instead.
    local wornFetched, worn, gearStatus = false, nil, nil;
    local gearTagBuilt, gearTag = false, nil;

    for _, target in ipairs(action.targets) do
        local targetIsTrackedPlayerOrPet = combat_router.ashita.isTrackedPlayerOrPet(target.id);
        local actorEqualsTarget = (action.actor_id == target.id);

        -- PERF (2026-10-30) EARLY-OUT: determineSide can only return
        -- non-nil when the actor is you/party (offense) or the target is
        -- you (defense). Anything else is someone else's fight -- skip it
        -- before any entity scan, name lookup or gear read.
        local side = nil;
        if actorOffense or targetIsTrackedPlayerOrPet then
            if not actorOffense and actorIsMonster == nil then
                actorIsMonster = combat_router.ashita.isMonster(action.actor_id);
            end
            side = combat_router.determineSide(
                actorOffense, actorIsMonster or false,
                targetIsTrackedPlayerOrPet, actorEqualsTarget);
        end

        if side ~= nil then
        local perTargetResults = combat_router.route(
            { category = action.category, targets = { target } }, side);

        if not actorNameResolved then
            actorNameResolved = true;
            local okAN, n = pcall(combat_router.ashita.entityName, action.actor_id);
            if okAN then actorEntityName = n; end
        end

        -- 2026-10-29: target's entity name (the mob, on offense) -- lets the
        -- export aggregate job > mob by name without an ID lookup later.
        local okTN, targetName = pcall(combat_router.ashita.entityName, target.id);
        if not okTN then targetName = nil; end

        if not wornFetched then
            wornFetched = true;
            if actorIsTrackedPlayerOrPet or side == 'defense' then
                worn, gearStatus = currentGearWorn(dlacState);
            end
        end

        -- debug_log.lua: still-active testing diagnostic. PERF
        -- (2026-10-30): the 16-slot gear signature string is only built
        -- while the debug log is actually on.
        if not gearTagBuilt and debug_log.isEnabled() then
            gearTagBuilt = true;
            gearTag = buildGearTag(worn, gearStatus);
        end

        -- type resolution (2026-07-29, gap 1 fix): melee (category 1)
        -- previously always exported as the single string 'melee'
        -- regardless of whether action.actor_id was the tracked player
        -- or their pet -- both landed in the same undifferentiated
        -- bucket downstream (confirmed via real capture data: two
        -- distinct offense-side actorIds under type:'melee' in the
        -- same export session, one of them also the sole actor on all
        -- pet_tp_move events in that session). Pet melee now exports
        -- as 'pet_melee', mirroring how pet TP moves already get their
        -- own 'pet_tp_move' type rather than being folded into a
        -- generic bucket. Every other category's type is unaffected --
        -- only category MELEE branches here; EVENT_TYPE_BY_CATEGORY
        -- remains the single source of truth for all other types.
        -- isPet() is only meaningful for the OFFENSE side (a pet
        -- attacking) -- defense-side melee (something attacking the
        -- tracked player/pet) never needs this branch, since
        -- determineSide() already requires the ATTACKER to be a
        -- monster for the defense case, never the tracked pet.
        -- isPet() covers the local player's own pet (existing gap-1
        -- fix); actorPartyInfo.isPet covers a PARTY MEMBER's pet (new
        -- this session) -- either should export as 'pet_melee', not
        -- just the local player's own pet.
        local eventType = combat_router.EVENT_TYPE_BY_CATEGORY[action.category] or 'melee';
        if action.category == combat_router.CATEGORY.MELEE and side == 'offense'
            and (combat_router.ashita.isPet(action.actor_id)
                or (actorPartyInfo ~= nil and actorPartyInfo.isPet)) then
            eventType = 'pet_melee';
        end

        -- hand (2026-07-30): resolved from the raw animation/sub_kind
        -- field, per packet_ground_truth.md's Animation IDs table --
        -- ONLY meaningful for category MELEE (weaponskill/JA/magic
        -- animation IDs are a different, undocumented vocabulary; do
        -- not resolve a hand label for those categories). MELEE_KICK
        -- (2/3) and DAKEN (4) map to 'other' rather than main/sub --
        -- they're real animation values but neither weapon hand, and
        -- mislabeling a kick as a weapon swing would corrupt any
        -- per-hand damage model downstream (see mobstats_PROJECT.md's
        -- 2026-07-30 DEF-saturation fix, which is what this field
        -- exists to unblock). nil (not a guess) for any animation value
        -- not in the table at all, and for every non-melee category.
        -- CONFIRMATION STATUS per packet_ground_truth.md "Open items"
        -- #1: MELEE_MAIN(0) is live-confirmed; MELEE_OFFHAND(1)/kick/
        -- Daken are structurally parsed but NOT YET observed in a real
        -- capture as of this writing -- downstream consumers should
        -- treat 'sub' attribution as unconfirmed until that happens.
        -- (HAND_BY_ANIMATION now lives at file scope -- PERF 2026-10-30.)

        -- actionId (2026-10-29): which ability/spell/WS/TP move this was.
        -- The export had NO way to tell one job ability from another (256
        -- JA_GENERIC_USE events, all anonymous) -- this is the fix.
        -- Read from packet_action.lua's `cmd_arg` (the 32-bit field right
        -- after category) -- CONFIRMED against packet_action.parse
        -- 2026-10-29; there is no top-level `param` key. Raw ID only --
        -- name lookup via the resource manager is a separate follow-up
        -- (per-category ID offsets aren't verified yet).
        local actionId = action.cmd_arg;

        for _, result in ipairs(perTargetResults) do
            debug_log.record(side, action.actor_id, target.id,
                result.outcome, result.damage, result.raw, gearTag);

            local hand = nil;
            if action.category == combat_router.CATEGORY.MELEE then
                hand = HAND_BY_ANIMATION[result.animation];
            end

            -- `type` was hardcoded 'melee' before category expansion
            -- (2026-07-29) -- now resolved from
            -- combat_router.EVENT_TYPE_BY_CATEGORY (plus the pet-melee
            -- branch above, gap 1 fix) so a weaponskill hit is
            -- correctly tagged 'weaponskill' and a pet's melee swing is
            -- correctly tagged 'pet_melee', rather than either
            -- misleadingly looking like an ordinary player melee swing.
            --
            -- hitIndex/hitCount (2026-07-29, per user request) let a
            -- multi-hit weaponskill's individual hits be told apart in
            -- the export (e.g. hit 1/4 landed, hit 3/4 missed) rather
            -- than producing four indistinguishable rows.
            -- actorName/actorJob/actorIsPet/actorOwnerName (2026-07-29,
            -- party-member expansion): nil for the local player/own
            -- pet (actorPartyInfo is nil in that case) -- only present
            -- when action.actor_id resolved to a real party member or
            -- party-member's pet. export_log.record's own contract
            -- copies every field in `fields` verbatim (see that
            -- function's header) so a nil field here is simply absent
            -- from the exported event, not an explicit null -- no
            -- export_log.lua change needed for this.
            --
            -- gearStateId is DELIBERATELY NOT set for party-member
            -- events -- dlac only sees the LOCAL player's gear, so
            -- `worn` here is still the local player's composition
            -- regardless of who the actor is. Per this session's
            -- explicit decision (not yet resolved how/whether to tag
            -- party gear), party-member events get the same `worn`
            -- passthrough as everyone else today -- which resolves to
            -- the local player's gearStateId, NOT the party member's
            -- (there is no party-member gear data available at all).
            -- Downstream consumers must not assume gearStateId on a
            -- party-member-attributed event describes that party
            -- member's own gear.
            -- actorIsPet built with an explicit if/else, NOT the
            -- `and/or` ternary idiom used for the other fields here --
            -- that idiom silently collapses a real `false` value (a
            -- confirmed party member who is NOT a pet) to `nil` (no
            -- data at all), because Lua's `x and y or z` can't tell
            -- "y is false" apart from "y is nil". Caught before this
            -- shipped: every party-member non-pet event would have
            -- silently lost its "confirmed not a pet" signal otherwise.
            local actorIsPet;
            if actorPartyInfo ~= nil then
                actorIsPet = actorPartyInfo.isPet;
            else
                actorIsPet = nil;
            end

            -- 2026-10-29: Steal arrives on category 3 on AscensionXI, so
            -- it was exporting as type 'weaponskill'. Re-typed by outcome
            -- (narrowly -- only the item-taking THF outcomes, NOT every
            -- JA_* outcome, since gap-3's 317/100/324-on-category-3 events
            -- are believed to be real multi-hit WS lines).
            -- WIDENED same day after resprobe.lua: category 3 carries Steal
            -- (41), Mug (45) AND Despoil (228) as job abilities (resolved at
            -- ability id+512), while real WSs on category 3 come back with
            -- WS_* outcomes (Curilla's Vorpal Blade, id 40). So ANY JA_*
            -- outcome on category 3 -- including the 100/317/324 lines once
            -- assumed to be multi-hit WS hits -- is now typed job_ability,
            -- matching how action_names.lua names it.
            local rowType = eventType;
            if action.category == combat_router.CATEGORY.WEAPONSKILL
                and action_names.isJaOnWsCategory(result.outcome) then
                rowType = 'job_ability';
            end

            -- actionName (2026-10-29): English name for actionId, via the
            -- resprobe-confirmed lookups in action_names.lua. nil (absent
            -- from the export) for melee/ranged and not-yet-probed
            -- categories -- never guessed.
            local okName, actionName = pcall(action_names.actionName,
                action.category, actionId, result.outcome);
            if not okName then actionName = nil; end

            local fields = {
                type = rowType,
                side = side,
                actorId = action.actor_id,
                actorName = actorPartyInfo and actorPartyInfo.name or nil,
                actorJob = actorPartyInfo and actorPartyInfo.job or nil,
                actorIsPet = actorIsPet,
                actorOwnerName = actorPartyInfo and actorPartyInfo.ownerName or nil,
                actorEntityName = actorEntityName,
                targetId = target.id,
                targetName = targetName,
                actionId = actionId,
                actionName = actionName,
                outcome = result.outcome,
                damage = result.damage,
                worn = worn,
                hitIndex = result.hitIndex,
                hitCount = result.hitCount,
                hand = hand, -- 'main'/'sub'/'other'/nil, melee only -- see above
            };
            combat_router.attachRaw(fields, result.outcome, result.raw);
            if fields.statusId ~= nil then
                local okS, sName = pcall(action_names.statusName, fields.statusId);
                if okS then fields.statusName = sName; end
            end
            export_log.record(fields);

            -- Add-effect / skillchain proc (2026-07-29): a SEPARATE
            -- event from the base swing/WS-hit above, per user request
            -- ("skillchain damage should be it's own event"). Only
            -- emitted when this result actually carried an add-effect
            -- block (addEffectOutcome ~= nil) -- most swings don't.
            --
            -- "linked to the person who finished the weaponskill chain"
            -- (user, 2026-07-29): finisherActorId/finisherTargetId are
            -- exactly action.actor_id/target.id -- the same actor/target
            -- as the base swing this proc rode in on, since the add-
            -- effect block lives on that same result entry. This is a
            -- REAL, direct fact from the packet (not an inference).
            --
            -- property (2026-07-29, same day, after skillchain message
            -- IDs were confirmed): surfaced as its own top-level export
            -- field, not just nested in `raw`, so downstream consumers
            -- can filter/group by skillchain property without reaching
            -- into the raw envelope. nil for the two generic/
            -- unpropertied skillchain variants (196/223) and for
            -- non-skillchain UNKNOWN_ADD_EFFECT procs -- see
            -- classify.addEffect's own header for the full mapping.
            --
            -- openerActorId is DELIBERATELY NOT included here -- see
            -- classify.addEffect's own header: the base packet has no
            -- field referencing a different, earlier action/actor at
            -- all, so identifying who OPENED the chain this proc closes
            -- would require a separate recent-WS-history tracker
            -- inferring it from timing, not a fact this event can
            -- honestly report yet. Tracked as an explicit follow-up in
            -- the project file, not silently guessed at here.
            if result.addEffectOutcome ~= nil then
                -- finisherName/finisherJob (2026-07-29, party-member
                -- expansion): same actorPartyInfo as the base event
                -- above -- this proc is attributed to the same actor
                -- who landed the finishing hit (see the existing
                -- comment above on finisherActorId being a real,
                -- direct packet fact, not an inference).
                -- 2026-10-29: EVERY add-effect used to export as type
                -- 'skillchain' -- in the 2026-10-28 capture that was 1,208
                -- "skillchains", of which only 21 were real (the rest:
                -- 934 Drain Samba HP drains, 239 ranged Defense Down
                -- procs, 14 Treasure Hunter procs). Now only a confirmed
                -- SKILLCHAIN outcome keeps type 'skillchain' (and the
                -- finisher* field names); everything else is type
                -- 'add_effect' with the same actor/target field names as
                -- a normal event.
                local aeFields;
                if result.addEffectOutcome == classify.OUTCOME.SKILLCHAIN then
                    aeFields = {
                        type = 'skillchain',
                        finisherActorId = action.actor_id,
                        finisherName = actorPartyInfo and actorPartyInfo.name or nil,
                        finisherJob = actorPartyInfo and actorPartyInfo.job or nil,
                        finisherTargetId = target.id,
                        finisherEntityName = actorEntityName,
                        targetName = targetName,
                        property = result.addEffectRaw and result.addEffectRaw.property or nil,
                    };
                else
                    aeFields = {
                        type = 'add_effect',
                        side = side,
                        actorId = action.actor_id,
                        actorName = actorPartyInfo and actorPartyInfo.name or nil,
                        actorJob = actorPartyInfo and actorPartyInfo.job or nil,
                        actorIsPet = actorIsPet,
                        actorEntityName = actorEntityName,
                        targetId = target.id,
                        targetName = targetName,
                        baseType = rowType, -- what the proc rode on: melee / ranged / weaponskill ...
                    };
                end
                aeFields.actionId = actionId;
                aeFields.actionName = actionName; -- the action the proc rode on
                aeFields.outcome = result.addEffectOutcome;
                aeFields.damage = result.addEffectDamage;
                aeFields.worn = worn;
                aeFields.hitIndex = result.hitIndex;
                aeFields.hitCount = result.hitCount;
                combat_router.attachRaw(aeFields, result.addEffectOutcome, result.addEffectRaw);
                if aeFields.statusId ~= nil then
                    local okS, sName = pcall(action_names.statusName, aeFields.statusId);
                    if okS then aeFields.statusName = sName; end
                end
                export_log.record(aeFields);
            end
        end
        end -- if side ~= nil (PERF early-out, 2026-10-30)
    end
end

-- Zone change (2026-10-30): entity indexes are per zone, so the
-- serverId -> index cache is dropped. Called from mobparser.lua on 0x00A.
function combat_router.onZone()
    entityIndexCache = {};
end

return combat_router;

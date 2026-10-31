--[[
mobparser -- classify.lua

Turns ONE normalized melee action-result (the same shape
Ashita.Packets.Build_Action produces, per packet_ground_truth.md --
{ reaction, animation, param, message, ... }) into a single, unambiguous
outcome bucket: exactly one of HIT / CRIT / MISS / PARRY / SHADOWS /
DODGE / COUNTER / GUARD / SHIELD_BLOCK / UNMITIGATED / MOB_HEAL /
NO_DAMAGE, on BOTH the offense (you attacking) and defense (mob
attacking you) sides.

This is the layer that turns raw packet data into the hits/attempts
counts formula.lua's inverse functions consume, per the sample storage
design (project file question #2).

Ground truth this is built against -- see packet_ground_truth.md, all
CONFIRMED against live CatsEyeXI combat data (2026-07-27):
  - Message IDs: HIT=1, MISS=15, SHADOWS=31, DODGE=32, COUNTER=33,
    CRIT=67, PARRY=70, MOBHEAL3=3, MOBHEAL373=373.
  - Reaction field (SEPARATE from message): GUARD=2, SHIELD_BLOCK=4.
  - Defensive priority order is MUTUALLY EXCLUSIVE and MUST be checked
    in this exact order (confirmed structurally from live Metrics CSV
    cross-check): evade -> parry -> shadows -> counter -> guard ->
    block -> unmitigated hit. Every swing resolves to exactly ONE
    bucket; checking out of order can double-count or mis-bucket.
  - PARRY/SHADOWS/DODGE/COUNTER message IDs are ASSUMED accurate (per
    user decision 2026-07-27) -- structurally verified (same
    Attempt-tracking pattern, same priority chain) but not yet observed
    actually landing in live data. Flag any classification bug reports
    on these four specifically as a first suspect.
]]

local classify = {};

-- ===========================================================================
-- Message / reaction / animation IDs -- vendored from packet_ground_truth.md
-- ===========================================================================
-- 2026-07-29 msg.lua audit: DODGE was 32 (no such real ID), fixed to
-- 30 (real ANTICIPATE -- "<target> anticipates the attack.", the
-- closest and only real analog). MOBHEAL3(3)/COUNTER(33)/DEATH(97)/
-- RANGE_MOBHEAL(382) are commented out below -- none has ANY real
-- equivalent in xi.msg.basic (verified against the full uploaded
-- msg.lua, not guessed). MOBHEAL373(373) DOES correspond to a real
-- entry (SPIKES_EFFECT_RECOVER) and is kept. DEATH(97) was defined
-- but never actually referenced anywhere in this file -- pure dead
-- weight, removed outright rather than commented.
classify.MSG = {
    HIT         = 1,
    -- MOBHEAL3    = 3,  -- REMOVED 2026-07-29: no real xi.msg.basic ID 3 (real ID 3 is a CHAT CHANNEL value, unrelated). Call sites below now fall back to MOBHEAL373 only.
    MOB_KILL    = 6,
    MOBHEAL373  = 373,
    MISS        = 15,
    DEATH_FALL  = 20,
    SHADOWS     = 31,
    DODGE       = 30, -- FIXED 2026-07-29 (was 32, nonexistent): real ANTICIPATE = 30, "<target> anticipates the attack."
    -- COUNTER     = 33,  -- REMOVED 2026-07-29: no "counter-attack" message exists anywhere in xi.msg.basic. classify.defense's spike-effect COUNTER check can never match as-is; left commented rather than guessed at.
    -- SPIKE_COUNTER 33 -- RESTORED 2026-10-29 as a SPIKE-block id (not a
    -- main-message id -- that's why the xi.msg.basic audit missed it).
    -- AscensionXI live capture: 23 melee results with message=0,
    -- has_spike_effect=true, spike_effect_message=33, every one matching
    -- a "[Orc Grappler] 4 counter -> Toosik" line in the chat log at the
    -- same second. Used by classify.offense (mob countered OUR swing).
    SPIKE_COUNTER = 33,
    SPIKE_DMG   = 44,
    CRIT        = 67,
    PARRY       = 70,
    NO_EFFECT   = 75,
    -- TOO_FAR_AWAY 78 -- ADDED 2026-10-29 (AscensionXI). xi.msg.basic
    -- TOO_FAR_AWAY, "<target> is too far away." Live evidence: debug_log
    -- 11:11:28 actor 153 -> Akakabuto, message=78 reaction=0 param 0, and
    -- the chat log at the same second: "[Cooter] (Too Far) -> Akakabuto"
    -- right after "[Cooter] Raging Axe -> Akakabuto" -- a weaponskill
    -- that never went off because the mob was out of range. A use-failure,
    -- not a swing: see classify.OUTCOME.TOO_FAR.
    TOO_FAR_AWAY = 78,
    RESIST      = 85,
    -- DEATH       = 97,  -- REMOVED 2026-07-29: no real xi.msg.basic ID 97, and was never referenced anywhere in this file (dead even before the audit). Real "target defeated" message is MOB_KILL(6)/DEFEATS_TARG, already mapped above.
    EFFECT_FAIL = 114,
    ENDEBUFF    = 160,
    ENDRAIN     = 161,
    ENASPIR     = 162,
    ENDAMAGE    = 163,
    MISS_TP     = 188,
    ENSPELL     = 229,
    RANGEHIT    = 352,
    RANGECRIT   = 353,
    RANGEMISS   = 354,
    RANGE_NO_EFFECT = 355, -- confirmed 2026-07-29 (Windower wiki), ranged attack's no-effect analog to melee's own NO_EFFECT-shaped cases
    -- RANGE_MOBHEAL   = 382,  -- REMOVED 2026-07-29: no real xi.msg.basic ID 382 (real ID 382 doesn't exist at all in the table). No ranged/mob-heal message found anywhere in msg.lua under any name. classify.OUTCOME_BY_RANGE_MSG's dispatch entry for this is now removed too -- see below.
    SQUARE      = 576,
    TRUE        = 577,
    COMP_RESIST = 655,

    -- Skillchain message IDs (2026-07-29) -- CONFIRMED against an
    -- independent, non-Metrics, non-packet_ground_truth.md source: the
    -- Windower/Lua project's own wiki "Message IDs" page
    -- (github.com/Windower/Lua/wiki/Message-IDs, community-maintained,
    -- last edited 2024-10-11 per that page's own revision history).
    -- This is a full, authoritative message-text table (id -> exact
    -- in-game message string), independently corroborating and
    -- SUPERSEDING the earlier UNKNOWN_ADD_EFFECT catch-all's inability
    -- to distinguish skillchain from enspell/en-effect procs -- these
    -- IDs are real, distinct, and NOT shared with the en-effect range
    -- (160-163, 229) documented in packet_ground_truth.md.
    --
    -- *** 2026-07-29 msg.lua audit finding (root cause of confirmed
    -- gap #4 -- 405/408 skillchain events falling to UNKNOWN_ADD_EFFECT):
    -- this ENTIRE 16-entry table (below) was vendored from a wiki page,
    -- not this repo's real msg.lua. Checked against the actual
    -- xi.msg.basic table: ONLY SKILLCHAIN_COSMIC_ELUCIDATION(302)
    -- is real. SKILLCHAIN_GENERIC(196), SKILLCHAIN_GENERIC_2(223), and
    -- all 14 property-specific IDs (288-301) DO NOT EXIST in xi.msg.basic
    -- -- confirmed absent, not just misnamed. Real msg.lua has NO
    -- per-element skillchain message ID at all; the only skillchain-
    -- specific text is Cosmic Elucidation's own line. This means
    -- skillchains must fire on the GENERIC melee-damage-with-add-effect
    -- shape (ADD_EFFECT_DMG=163, already in classify.MSG.ENDAMAGE) and
    -- the ELEMENT has to come from a different packet field entirely
    -- (the skillchain/param block itself), not from classify.MSG. This
    -- is a real design question for combat_router/packet_action (which
    -- field carries the element), not something fixable by swapping an
    -- ID here -- deliberately NOT redesigned in this pass. All 15 fake
    -- IDs kept below, commented out, so the property-name mapping isn't
    -- lost if this gets redesigned later.
    -- ***
    --
    -- SKILLCHAIN_<PROPERTY>: 15 sequential, property-specific damage
    -- messages (288-302) was the ORIGINAL (wrong) assumption -- see
    -- audit finding above. Real: only 302 confirmed.
    --
    -- STILL NOT CAPTURED: the parallel HEAL-variant range (385 =
    -- "Skillchain: Light. <target> recovers <number> hit points!") --
    -- same caveat applies: NOT independently confirmed against real
    -- msg.lua, do not assume this range is real either.
    -- SKILLCHAIN_GENERIC   = 196,   -- REMOVED 2026-07-29: not a real xi.msg.basic ID
    -- SKILLCHAIN_GENERIC_2 = 223,   -- REMOVED 2026-07-29: not a real xi.msg.basic ID
    -- SKILLCHAIN_LIGHT              = 288, -- REMOVED 2026-07-29: not real
    -- SKILLCHAIN_DARKNESS           = 289, -- REMOVED 2026-07-29: not real
    -- SKILLCHAIN_GRAVITATION        = 290, -- REMOVED 2026-07-29: not real
    -- SKILLCHAIN_FRAGMENTATION      = 291, -- REMOVED 2026-07-29: not real
    -- SKILLCHAIN_DISTORTION         = 292, -- REMOVED 2026-07-29: not real
    -- SKILLCHAIN_FUSION             = 293, -- REMOVED 2026-07-29: not real
    -- SKILLCHAIN_COMPRESSION        = 294, -- REMOVED 2026-07-29: not real
    -- SKILLCHAIN_LIQUEFACTION       = 295, -- REMOVED 2026-07-29: not real
    -- SKILLCHAIN_INDURATION         = 296, -- REMOVED 2026-07-29: not real
    -- SKILLCHAIN_TRANSFIXION        = 298, -- REMOVED 2026-07-29: not real
    --
    -- RESTORED 2026-10-29 (AscensionXI live capture, 2026-10-28 XP
    -- parties): the 2026-07-29 audit was right that these are absent from
    -- xi.msg.basic, but WRONG that they don't exist -- they arrive on the
    -- add_effect_message field of a category-3 WS result (baseMessage
    -- 185), and every single one lined up 1:1 with the chat log's
    -- "<Property>: <dmg> -> <mob>" line at the same second, with
    -- add_effect_param == the skillchain damage shown:
    --   297 Reverberation  (2/2 events, e.g. Mtlol Dark Harvest, 35 dmg)
    --   299 Scission       (15/15, e.g. Temper Fast Blade, 18 dmg)
    --   300 Detonation     (1/1, Cooter Raging Axe, 55 dmg)
    --   301 Impaction      (3/3, Toosik/Halestorm Combo, 46/10 dmg)
    -- So the element DOES come from the message ID after all -- the
    -- open "skillchain-element redesign" item is resolved by this.
    -- Only the 4 IDs actually observed are enabled. The rest of the
    -- 288-301 run is very likely the same pattern but stays commented
    -- until a capture shows each one -- unobserved ones still land in
    -- UNKNOWN_ADD_EFFECT with raw kept, so nothing is lost meanwhile.
    SKILLCHAIN_REVERBERATION      = 297, -- CONFIRMED 2026-10-29, live capture + chat log
    SKILLCHAIN_SCISSION           = 299, -- CONFIRMED 2026-10-29, live capture + chat log
    SKILLCHAIN_DETONATION         = 300, -- CONFIRMED 2026-10-29, live capture + chat log
    SKILLCHAIN_IMPACTION          = 301, -- CONFIRMED 2026-10-29, live capture + chat log
    SKILLCHAIN_COSMIC_ELUCIDATION = 302, -- CONFIRMED real (xi.msg.basic)
};

-- Reverse lookup: skillchain message ID -> property name string, for
-- tagging export events with a human-readable property rather than
-- forcing downstream consumers to hardcode the same ID table. Built
-- from classify.MSG above rather than a separate hand-maintained
-- table, so the two can't drift apart.
-- 2026-07-29: property entries below removed to match classify.MSG
-- above -- only COSMIC_ELUCIDATION's underlying ID is real. This means
-- classify.SKILLCHAIN_PROPERTY_BY_MSG can currently only ever resolve
-- a property name for the Cosmic Elucidation case; every other real
-- skillchain (which DOES fire via ADD_EFFECT_DMG per the audit finding
-- above) will land with `property = nil`. Not fixed in this pass --
-- needs the combat_router/packet_action design work described above
-- first (find the real field that carries the element).
classify.SKILLCHAIN_PROPERTY_BY_MSG = {
    -- [classify.MSG.SKILLCHAIN_LIGHT]              = 'Light',           -- REMOVED 2026-07-29: MSG.SKILLCHAIN_LIGHT no longer defined (fabricated ID)
    -- [classify.MSG.SKILLCHAIN_DARKNESS]           = 'Darkness',        -- REMOVED 2026-07-29
    -- [classify.MSG.SKILLCHAIN_GRAVITATION]        = 'Gravitation',     -- REMOVED 2026-07-29
    -- [classify.MSG.SKILLCHAIN_FRAGMENTATION]      = 'Fragmentation',   -- REMOVED 2026-07-29
    -- [classify.MSG.SKILLCHAIN_DISTORTION]         = 'Distortion',      -- REMOVED 2026-07-29
    -- [classify.MSG.SKILLCHAIN_FUSION]             = 'Fusion',          -- REMOVED 2026-07-29
    -- [classify.MSG.SKILLCHAIN_COMPRESSION]        = 'Compression',     -- REMOVED 2026-07-29
    -- [classify.MSG.SKILLCHAIN_LIQUEFACTION]       = 'Liquefaction',    -- REMOVED 2026-07-29
    -- [classify.MSG.SKILLCHAIN_INDURATION]         = 'Induration',      -- REMOVED 2026-07-29
    -- [classify.MSG.SKILLCHAIN_TRANSFIXION]        = 'Transfixion',     -- REMOVED 2026-07-29, not yet observed
    [classify.MSG.SKILLCHAIN_REVERBERATION]      = 'Reverberation',   -- RESTORED 2026-10-29 (live capture)
    [classify.MSG.SKILLCHAIN_SCISSION]           = 'Scission',        -- RESTORED 2026-10-29 (live capture)
    [classify.MSG.SKILLCHAIN_DETONATION]         = 'Detonation',      -- RESTORED 2026-10-29 (live capture)
    [classify.MSG.SKILLCHAIN_IMPACTION]          = 'Impaction',       -- RESTORED 2026-10-29 (live capture)
    [classify.MSG.SKILLCHAIN_COSMIC_ELUCIDATION] = 'Cosmic Elucidation',
};

-- Set of all skillchain message IDs (generic + property-specific),
-- for a single membership check in classify.addEffect. Derived from
-- classify.MSG (same single-source-of-truth discipline as
-- SKILLCHAIN_PROPERTY_BY_MSG above) rather than hand-listed again.
-- 2026-07-29: SKILLCHAIN_GENERIC/_2 removed (fabricated IDs, see
-- classify.MSG comment above) -- this set now only contains whatever
-- classify.SKILLCHAIN_PROPERTY_BY_MSG has (currently just 302).
classify._SKILLCHAIN_MSG_SET = {};
for msgId in pairs(classify.SKILLCHAIN_PROPERTY_BY_MSG) do
    classify._SKILLCHAIN_MSG_SET[msgId] = true;
end

-- Add-effect (proc) message vocabulary -- added 2026-07-29 (msg.lua
-- gap-audit). Rides the SAME add_effect_message field as the
-- skillchain block above (see classify.addEffect), but these are
-- SPECIFIC proc mechanics (en-effect self-buff, add-effect heal/drain/
-- dispel/warp, weapon-spike status/heal) rather than skillchain
-- damage. Each verified individually against real xi.msg.basic before
-- being added -- all 10 confirmed real. The outcome dispatch table for
-- these (classify.ADD_EFFECT_OUTCOME_BY_MSG) is built further below,
-- after classify.OUTCOME is defined -- see classify.addEffect's own
-- comment for where it's consumed.
classify.ADD_EFFECT_MSG = {
    MP_HEAL      = 152,
    STATUS_2     = 164, -- msg.lua's own comment flags this as "(Duplicate?)" of some other status message -- kept as its own entry rather than guessed-merged with another, since msg.lua itself isn't sure
    TP_DRAIN     = 165,
    SELFBUFF     = 166,
    HP_HEAL      = 167,
    DISPEL       = 168,
    WARP         = 169,
    STATUS_SPIKES = 374, -- "striking <defender>'s armor causes <attacker> to become <status>" -- a spike EFFECT causing a status on the ATTACKER, not the defender
    SPIKES_HEAL   = 383,
    HEAL          = 384,

    -- Added 2026-10-29 (AscensionXI live capture, checked line-by-line
    -- against the 2026-10-28 chat log):
    -- HP_DRAIN 161: "Additional effect: <n> HP drained from <mob>." --
    --   934 events (Drain Samba procs on melee, base msg 1 or 67), param
    --   == the drained amount in the log ("[Toosik] 21 HP AE").
    --   Same ID as classify.MSG.ENDRAIN, which was defined but never
    --   wired into addEffect -- that's why these all fell to UNKNOWN.
    -- TREASURE_HUNTER 603: "AE: TH <n> -> <mob>" -- 14 events (THF melee
    --   procs, base msg 1 or 67), param == the TH level shown (3).
    --   This is the TH proc signal the project had on hold.
    -- STATUS_2 164 (above) is also now CONFIRMED in practice: 239
    --   ranged-attack procs (base msg 352/353), log reads "Versiontwo AE
    --   -> Clipper (Defense Down)" and param was 149 == Defense Down's
    --   status ID. So param is a STATUS ID here, not damage -- see
    --   classify.addEffect for the damage=0 / statusId fix.
    HP_DRAIN        = 161,
    TREASURE_HUNTER = 603,
};

-- Job ability message IDs (2026-07-29) -- CONFIRMED against the same
-- Windower/Lua wiki "Message IDs" page used for skillchain IDs above
-- (github.com/Windower/Lua/wiki/Message-IDs). Job abilities have a
-- MUCH wider outcome vocabulary than melee/WS -- damage, self/target
-- heal, buff/debuff landing, status removal, no-effect, miss, plus
-- several job-specific mechanics (Steal, Mug, Charm, Treasure Hunter
-- find) each with their own distinct success/fail message pair. See
-- classify.jobAbilityOffense/Defense's own header for how these are
-- dispatched. Grouped here by semantic shape (matching the message
-- TEXT's actual meaning), not by numeric proximity -- several IDs are
-- near-duplicate phrasings of the same underlying outcome (e.g. 102 and
-- 306/318 all mean "target recovers HP"), kept as separate named
-- constants rather than silently collapsed, since it's not yet
-- understood WHY the game emits multiple IDs for the same-looking
-- outcome (different sub-command paths, different JA categories,
-- etc) -- worth being able to tell them apart later if that turns out
-- to matter.
classify.JA_MSG = {
    -- Generic use / landed-with-no-specific-effect-described
    GENERIC_USE       = 100,
    GENERIC_USE_ON_TARGET = 119,

    -- Damage
    DAMAGE            = 110,
    DAMAGE_2          = 317,
    -- Named-ability damage variants -- 2026-07-29 msg.lua audit: NEITHER
    -- 77 nor 157 exists in real xi.msg.basic under any name. No dedicated
    -- Sange/Barrage damage message found. Real closest analog is just
    -- JA_DAMAGE(110), already covered above. Commented out rather than
    -- guessed at -- if a real capture shows Sange/Barrage using a
    -- different ID than 110/317, add it then.
    -- DAMAGE_SANGE      = 77,   -- REMOVED 2026-07-29: not a real xi.msg.basic ID
    -- DAMAGE_BARRAGE    = 157,  -- REMOVED 2026-07-29: not a real xi.msg.basic ID

    -- Heal (target or self -- message text distinguishes actor/target,
    -- not the ID itself; classify still needs `result.message` context
    -- to know which, see function body)
    HEAL_TARGET       = 102,
    -- HEAL_TARGET_2     = 306,  -- REMOVED 2026-07-29: real ID 306 is NEEDS_2H_WEAPON, unrelated. No second real JA-heal-target variant found under a different ID.
    HEAL_TARGET_3     = 318,
    -- HEAL_SELF         = 122,  -- REMOVED 2026-07-29: real ID 122 is JA_REMOVE_EFFECT, unrelated. Real self-heal message is SELF_HEAL=238 (untested here, not yet added -- see gap list follow-up).

    -- Status effect landed (buff or debuff -- message text doesn't
    -- distinguish which, only the actual <status> value would, which
    -- this project doesn't currently decode)
    -- 2026-07-29 msg.lua audit: STATUS_LANDED_ATTACK_UP(116)/
    -- STATUS_LANDED_ACC_UP(120)/STATUS_LANDED_EVA_UP(121) have NO real
    -- xi.msg.basic equivalent under any name -- no per-stat "X up"
    -- landed-status message was found. Commented out, not guessed.
    -- STATUS_LANDED_ATTACK_UP   = 116,  -- REMOVED 2026-07-29: not a real xi.msg.basic ID
    -- STATUS_LANDED_ACC_UP      = 120,  -- REMOVED 2026-07-29: not a real xi.msg.basic ID
    -- STATUS_LANDED_EVA_UP      = 121,  -- REMOVED 2026-07-29: not a real xi.msg.basic ID
    STATUS_LANDED             = 127,
    -- STATUS_LANDED_2           = 141,  -- REMOVED 2026-07-29: real ID 141 is unrelated (not in the STATUS_LANDED family); real near-dup pattern is STATUS_GAINS(319)/STATUS_RECEIVES(320), already present below.
    STATUS_LANDED_ACC_EVA_UP  = 146,
    STATUS_LANDED_ACC_EVA_UP_NO_ACTOR = 147,
    -- ACC/EVA DOWN (debuff direction) -- added 2026-07-29, gap-audit
    -- follow-up: originally missed alongside the ACC/EVA UP pair above.
    STATUS_LANDED_ACC_EVA_DOWN         = 144,
    -- STATUS_LANDED_ACC_EVA_DOWN_NO_ACTOR = 145,  -- REMOVED 2026-07-29: real ID 145 doesn't exist; ACC_EVA_DOWN(144) has no confirmed _NO_ACTOR pair in real msg.lua (unlike the UP direction, which does have 146/147).
    -- 2026-07-29 msg.lua audit -- FORTIFY block was wrong on both count
    -- and IDs. Real msg.lua only has 2 entries here (no _NO_ACTOR
    -- variants), and the names were wrong too: 149=FORTIFIED_DEMONS
    -- (not "undead"), 151=FORTIFIED_DRAGONS (plural). The real
    -- UNDEAD/ARCANA pair lives at 286/287 -- separate ability entirely,
    -- not a duplicate of 148-151 as originally assumed. 286/287 are new
    -- vocabulary (see handoff doc's gap list), added further below.
    STATUS_LANDED_FORTIFY_DEMONS  = 149, -- FIXED 2026-07-29 (was STATUS_LANDED_FORTIFY_UNDEAD=148, wrong ID AND wrong name)
    STATUS_LANDED_FORTIFY_DRAGONS = 151, -- FIXED 2026-07-29 (was STATUS_LANDED_FORTIFY_DRAGON=150, wrong ID)
    -- STATUS_LANDED_FORTIFY_UNDEAD_NO_ACTOR = 149,  -- REMOVED 2026-07-29: not a real distinct ID -- 149 IS FORTIFIED_DEMONS above, no separate _NO_ACTOR variant exists
    -- STATUS_LANDED_FORTIFY_DRAGON_NO_ACTOR = 151,  -- REMOVED 2026-07-29: not a real distinct ID -- 151 IS FORTIFIED_DRAGONS above, no separate _NO_ACTOR variant exists
    STATUS_GAINS       = 319,
    STATUS_RECEIVES    = 320,
    STATUS_ALL_PARAMS_BOOSTED       = 364,
    STATUS_ALL_PARAMS_BOOSTED_NO_ACTOR = 365,

    -- Status removal (Cure-type JAs that strip a status)
    STATUS_REMOVED_SUCCESS = 123,
    STATUS_WEARS_OFF        = 321,
    -- STATUS_WEARS_OFF_2      = 322,  -- REMOVED 2026-07-29: real ID 322 is JA_NO_EFFECT_2, unrelated. No second real "wears off" variant found under a different ID.

    -- No effect / miss
    NO_EFFECT         = 156,
    NO_EFFECT_2       = 323,
    MISS              = 158,
    MISS_2            = 324,

    -- Steal (THF)
    STEAL_SUCCESS     = 125,
    STEAL_FAIL        = 153,

    -- Mug (THF)
    MUG_SUCCESS       = 129,
    MUG_FAIL          = 244,

    -- Charm (BST and other charm-capable jobs)
    CHARM_SUCCESS     = 136,
    CHARM_FAIL        = 137,

    -- Treasure Hunter-style find (COR Fold/Ransack-adjacent, or similar)
    -- 2026-07-29 msg.lua audit: neither 139 nor 140 is a real find-item
    -- message (139 is actually CHARM_FAIL, 140 doesn't exist). The only
    -- real "finds item/nothing inside" messages in xi.msg.basic are
    -- EATS_FINDS_ITEM(600)/EATS_FINDS_NOTHING(604), which are actually a
    -- DIFFERENT mechanic (eating food items, not a TH-style ability) --
    -- not a safe substitute, so commented out rather than repointed.
    -- FIND_NOTHING      = 139,  -- REMOVED 2026-07-29: real ID 139 is CHARM_FAIL, unrelated
    -- FIND_ITEM         = 140,  -- REMOVED 2026-07-29: real ID 140 doesn't exist

    -- Self-buff-only JAs with no target-effect field in the message at
    -- all (Divine Seal, Elemental Seal, Trick Attack) -- these ONLY
    -- confirm "the ability was used," not any target outcome. Treated
    -- as their own outcome rather than folded into GENERIC_USE, since
    -- knowing SPECIFICALLY that one of these three fired (as opposed
    -- to some other job ability landing with no described effect) may
    -- matter for future analysis.
    -- 2026-07-29 msg.lua audit: 303/304/305 are real Trust-magic SYSTEM
    -- messages (TRUST_SOLO_OR_LEADER etc), completely unrelated to
    -- Divine Seal/Elemental Seal/Trick Attack. No real self-buff-only
    -- JA message found under any ID. Commented out, not guessed.
    -- SELF_BUFF_ONLY    = 303,  -- REMOVED 2026-07-29: real ID 303 is a Trust-magic system message, unrelated
    -- SELF_BUFF_ONLY_2  = 304,  -- REMOVED 2026-07-29: real ID 304 is a Trust-magic system message, unrelated
    -- SELF_BUFF_ONLY_3  = 305,  -- REMOVED 2026-07-29: real ID 305 is a Trust-magic system message, unrelated

    -- Pet-related
    PET_POWER_UP      = 108,

    -- =======================================================================
    -- Added 2026-07-29 (msg.lua gap-audit, see
    -- mobparser_HANDOFF_message_id_gaps.md): all IDs below were verified
    -- individually against the real xi.msg.basic table (not assumed from
    -- the handoff doc's own listing) before being added. None of these
    -- are wired into JA_OUTCOME_BY_MSG's outcome-name grouping the same
    -- way as the pre-existing entries above -- each gets its OWN outcome
    -- name (not folded into JA_STATUS_LANDED etc) so real per-mechanic
    -- data (which charm tier, which roll, which despoil debuff, which
    -- RUN ward) isn't lost by bucketing. See classify.OUTCOME for the
    -- new names and JA_OUTCOME_BY_MSG below for dispatch.
    -- =======================================================================

    -- Charm difficulty tiers -- pre-attempt readout, fires BEFORE
    -- CHARM_SUCCESS/CHARM_FAIL above, not a duplicate of either.
    CHARM_CANNOT          = 210,
    CHARM_VERY_DIFFICULT  = 211,
    CHARM_DIFFICULT       = 212,
    CHARM_MIGHT_BE_ABLE   = 213,
    CHARM_SHOULD_BE_ABLE  = 214,

    -- Fortify (undead/arcana) -- separate ability from the
    -- demons/dragons pair above (149/151), not a duplicate.
    STATUS_LANDED_FORTIFY_UNDEAD = 286,
    STATUS_LANDED_FORTIFY_ARCANA = 287,

    -- Misc single-mechanic JA messages, no existing analog above.
    JA_ATK_ENHANCED    = 285,
    TP_INCREASE        = 409,
    MAGIC_STEAL        = 430, -- despite the name, this is a JA-shaped "<caster> casts <spell>...effects drained" message per msg.lua's own comment -- kept here since msg.lua groups it near the roll/JA block, not with MAGIC_MSG's own drain family
    MAGIC_TP_REDUCE    = 431, -- same caveat as MAGIC_STEAL above
    JA_RECOVERS_MP     = 451,
    WILD_FLOURISH_TP   = 452,
    STEAL_EFFECT       = 453,
    MAGIC_ABSORB_TP    = 454, -- same caveat as MAGIC_STEAL/MAGIC_TP_REDUCE above
    JA_TH_EFFECTIVENESS = 608,
    JA_ENMITY_DECREASE  = 743,

    -- Corsair Roll -- full vocabulary, previously entirely unhandled.
    -- ROLL_MAIN_FAIL/ROLL_SUB_FAIL confirmed for real during this
    -- session's ID-by-ID verification pass (not originally itemized
    -- separately in the handoff doc's own list, but present in
    -- msg.lua immediately next to ROLL_MAIN/ROLL_SUB -- included since
    -- they complete the pattern with real, verified IDs, not a guess).
    ROLL_MAIN            = 420,
    ROLL_SUB             = 421,
    ROLL_MAIN_FAIL       = 422,
    ROLL_SUB_FAIL        = 423,
    DOUBLEUP             = 424,
    DOUBLEUP_FAIL        = 425,
    DOUBLEUP_BUST        = 426,
    DOUBLEUP_BUST_SUB    = 427,
    NO_ELIGIBLE_ROLL     = 428, -- use-failure system message, not a landed outcome -- see JA_OUTCOME_BY_MSG comment on why this one isn't dispatched
    ROLL_ALREADY_ACTIVE  = 429, -- same caveat as NO_ELIGIBLE_ROLL

    -- Despoil (THF) -- stat-down variants, full vocabulary.
    DESPOIL_ATT_DOWN  = 593,
    DESPOIL_DEF_DOWN  = 594,
    DESPOIL_MATT_DOWN = 595,
    DESPOIL_MDEF_DOWN = 596,
    DESPOIL_EVA_DOWN  = 597,
    DESPOIL_ACC_DOWN  = 598,
    DESPOIL_SLOW      = 599,

    -- Rune Fencer (RUN) -- full vocabulary, previously entirely
    -- unhandled. SAME_EFFECT_LUOPAN/LUOPAN_ALREADY_PLACED/
    -- REQUIRE_LUOPAN/HAS_LUOPON_NO_USE/REQUIRE_RUNE are all
    -- use-failure system messages (can't-use-ability text), not landed
    -- outcomes -- kept here for completeness but not dispatched as a
    -- combat outcome, same as NO_ELIGIBLE_ROLL/ROLL_ALREADY_ACTIVE above.
    SAME_EFFECT_LUOPAN     = 660,
    LUOPAN_ALREADY_PLACED  = 661,
    REQUIRE_LUOPAN         = 662,
    LUOPAN_HP_RATE_DOWN    = 663,
    LUOPAN_HP_RATE_UP      = 664,
    HAS_LUOPON_NO_USE      = 665,
    REQUIRE_RUNE           = 666,
    SWORDPLAY_GAIN         = 667,
    VALLATION_GAIN         = 668,
    VALIANCE_GAIN_PARTY    = 669,
    LIEMENT_GAIN           = 670,
    PFLUG_GAIN             = 671,
    GAMBIT_GAIN            = 672,

    -- Added 2026-10-29 (AscensionXI live capture, 2026-10-28 chat log):
    -- HEAL_TARGET_AOE 263: Divine Waltz's secondary targets -- 24
    --   events, log "[Toosik] 72 HP Divine Waltz -> Toosik / 73 HP ->
    --   Lift / 75 HP -> Mindlor", param == each target's HP.
    --   (Same numeric ID as MAGIC_MSG.HEAL_NO_PREFIX; it just also shows
    --   up on job abilities.)
    -- DAZE_LETHARGIC 519: "[Toosik] lv. 1 Quickstep -> Clipper", param
    --   == daze level (1). The other step dazes (Box/Stutter/Feather)
    --   are NOT added -- not observed yet.
    -- NO_MESSAGE 0: 115 events, all from Halestorm's "Resonance"
    --   (AscensionXI custom ability -- not in retail), one result per
    --   party member, message 0, param 817 every time. What 817 means
    --   is unknown, so it's kept as effectParam, not interpreted.
    HEAL_TARGET_AOE = 263,
    DAZE_LETHARGIC  = 519,
    NO_MESSAGE      = 0,
};

-- Magic (category 4) message IDs (2026-07-29) -- CONFIRMED against the
-- same Windower/Lua wiki "Message IDs" page used for skillchain/job
-- ability/ranged IDs above. Magic has the widest, messiest outcome
-- vocabulary of anything built so far in this project: damage, magic
-- burst (damage/status/drain variants), heal, status landed (multiple
-- near-duplicate phrasings), drain, stat absorb, resist/no-effect/fail,
-- erase/dispel, and a couple of genuine edge cases (vanish, falls to
-- ground -- likely gravity/teleport-type spells). Grouped here by
-- semantic shape, same discipline as classify.JA_MSG above. Several
-- pairs are the SAME underlying outcome with/without the "<actor>
-- casts <spell>." prefix in the message text (e.g. 2 vs 264, 7 vs 263)
-- -- kept as separate named constants since it's not yet understood
-- WHY the game emits both forms (different cast paths? AoE tick vs.
-- initial hit? not investigated) -- same "don't silently collapse
-- until the difference is understood" discipline as job ability's
-- near-duplicates.
classify.MAGIC_MSG = {
    -- Damage
    DAMAGE            = 2,
    DAMAGE_NO_PREFIX  = 264,

    -- Magic burst damage
    BURST_DAMAGE           = 252,
    -- BURST_DAMAGE_NO_PREFIX = 265,  -- REMOVED 2026-07-29: real ID 265 doesn't exist in xi.msg.basic under any name
    BURST_DAMAGE_FROM_JA   = 379, -- edge case: a JOB ABILITY (not a spell) triggering a magic burst -- confirmed real message, kept here since the OUTCOME (burst damage landed) is what matters, even though the triggering action was technically category 6, not 4. Only reachable if this message id is ever seen on a category-4 packet; not otherwise routed from job ability capture.

    -- Heal
    HEAL           = 7,
    HEAL_NO_PREFIX = 263,

    -- Status landed (buff or debuff -- message text doesn't distinguish
    -- which, only the actual <status> value would)
    -- STATUS_LANDED_BANG       = 82,  -- REMOVED 2026-07-29: real ID 82 doesn't exist. (Real 83 is MAGIC_REMOVE_EFFECT -- a dispel, different meaning -- not a safe substitute.)
    STATUS_GAINS              = 230,
    STATUS_LANDED              = 236, -- matches ENF_LAND
    STATUS_RECEIVES            = 237, -- matches ENF_LAND_2
    -- 2026-07-29 msg.lua audit: 266/267 below are REAL ids but belong
    -- to JOB ABILITY messages (JA_GAIN_EFFECT/JA_RECEIVES_EFFECT), not
    -- magic -- wrong table, not a wrong ID. Removed from here; not
    -- added to JA_MSG either since classify.JA_MSG already has its own
    -- STATUS_GAINS(319)/STATUS_RECEIVES(320) covering the same concept
    -- under real JA-specific IDs.
    -- STATUS_GAINS_NO_PREFIX     = 266,  -- REMOVED 2026-07-29: real ID 266 is JA_GAIN_EFFECT, a JOB ABILITY message, not magic
    -- 266 RE-ADDED 2026-10-29 for MAGIC too: AscensionXI live capture
    -- shows it on category 4 -- 19 events, Kupipi's Protectra, one per
    -- party member, log "Kupipi Protectra -> {5}: Kupipi, Lift, Cinder,
    -- Mogh, and Toosik (Protect)", param 40 == Protect's status ID. The
    -- audit was right about xi.msg.basic's name for it; it just isn't
    -- JA-only in practice.
    STATUS_GAINS_AOE = 266,
    -- STATUS_RECEIVES_NO_PREFIX  = 267,  -- REMOVED 2026-07-29: real ID 267 is JA_RECEIVES_EFFECT, a JOB ABILITY message, not magic
    STATUS_LANDED_NO_PREFIX    = 277,
    -- STATUS_RECEIVES_NO_PREFIX_2 = 278,  -- REMOVED 2026-07-29: real ID 278 doesn't exist
    -- STATUS_LANDED_NO_PREFIX_2  = 279,   -- REMOVED 2026-07-29: real ID 279 doesn't exist
    -- STATUS_GAINS_NO_PREFIX_2   = 280,   -- REMOVED 2026-07-29: real ID 280 doesn't exist

    -- Magic burst + status
    BURST_STATUS_RECEIVES            = 268,
    -- BURST_STATUS_RECEIVES_NO_PREFIX  = 269,  -- REMOVED 2026-07-29: real ID 269 doesn't exist
    BURST_STATUS_LANDED              = 271, -- matches ENF_BURST
    -- BURST_STATUS_LANDED_NO_PREFIX    = 272,  -- REMOVED 2026-07-29: real ID 272 doesn't exist

    -- Drain (HP/MP)
    DRAIN_HP           = 227,
    DRAIN_MP           = 228,
    -- BURST_DRAIN_HP     = 274,  -- REMOVED 2026-07-29: real ID 274 doesn't exist
    -- BURST_DRAIN_MP     = 275,  -- REMOVED 2026-07-29: real ID 275 doesn't exist
    -- DRAIN_HP_NO_PREFIX = 281,  -- REMOVED 2026-07-29: real ID 281 doesn't exist
    -- DRAIN_MP_NO_PREFIX = 366,  -- REMOVED 2026-07-29: real ID 366 doesn't exist

    -- Stat absorb (Absorb-STR etc) -- matches ABSORB_STR..CHR
    ABSORB_STR = 329,
    ABSORB_DEX = 330,
    ABSORB_VIT = 331,
    ABSORB_AGI = 332,
    ABSORB_INT = 333,
    ABSORB_MND = 334,
    ABSORB_CHR = 335,

    -- Resist / no-effect / fail / evade
    NO_EFFECT           = 75,  -- matches classify.MSG.NO_EFFECT
    RESIST               = 85,  -- matches classify.MSG.RESIST
    EFFECT_FAIL           = 114, -- matches classify.MSG.EFFECT_FAIL
    NO_EFFECT_NO_PREFIX   = 283,
    RESIST_NO_PREFIX       = 284, -- matches classify.MSG.RESIST_2
    -- EVADES (2026-07-29, gap-audit follow-up): "<target> evades." --
    -- bare message, no actor/spell prefix. Distinct semantically from
    -- RESIST (a resist roll failed the spell after targeting
    -- succeeded) -- an evade suggests the spell's accuracy/targeting
    -- itself failed, closer in concept to melee's MISS than to a
    -- resist. Kept as its own outcome rather than folded into
    -- MAGIC_RESIST or MAGIC_NO_EFFECT, since conflating them would
    -- lose a real distinction if it turns out to matter for any future
    -- magic-accuracy-style analysis. Not independently confirmed which
    -- categories/spell types actually produce this message.
    EVADES = 282,

    -- Erase / dispel
    ERASE            = 341, -- matches classify.MSG.MAGIC_ERASE
    -- ERASE_2          = 342,  -- REMOVED 2026-07-29: real ID 342 doesn't exist
    -- ERASE_NO_PREFIX   = 343, -- REMOVED 2026-07-29: real ID 343 doesn't exist
    -- ERASE_NO_PREFIX_2 = 344, -- REMOVED 2026-07-29: real ID 344 doesn't exist

    -- Edge cases -- uncommon, likely gravity/teleport-type spell effects
    VANISHES            = 93,
    FALLS_TO_GROUND      = 20, -- FIXED 2026-07-29 (was 113, wrong ID): real FALL_TO_GROUND = 20, "<n> falls to the ground." (Real 113 is unrelated.)
    -- VANISHES_NO_PREFIX   = 273,  -- REMOVED 2026-07-29: real ID 273 doesn't exist

    -- Generic -- spell confirmed cast on target, no more specific
    -- effect described in the message itself
    -- GENERIC_CAST_ON_TARGET   = 42,  -- REMOVED 2026-07-29: real ID 42 doesn't exist. GENERIC_CAST_ON_TARGET_2(309, real MAGIC_CASTS_ON) below already covers this concept.
    GENERIC_CAST_ON_TARGET_2 = 309,

    -- Added 2026-07-29 (msg.lua gap-audit). MAGIC_MUST_ASTRAL_FLOW(581)
    -- deliberately NOT added -- verified real, but it's a cast-failure
    -- message ("Unable to cast <spell>...") not a landed-result message,
    -- same category as classify.MSG never defining NOT_ENOUGH_MP etc.
    REMOVE_EFFECT       = 83,  -- dispel-type: caster removes target's status (distinct from ERASE=341's own phrasing, real msg.lua has both)
    REMOVE_EFFECT_COUNT = 571, -- "<number> of <target>'s status ailments disappear!"
    ABSORB_AILMENT      = 572,
};

-- Weaponskill-SPECIFIC message IDs (2026-07-29, added after a
-- deliberate audit pass -- see below) -- CONFIRMED against the same
-- Windower/Lua wiki table as everything else. REAL GAP FOUND AND
-- FIXED: classify.weaponskillOffense/Defense originally only reused
-- MELEE's generic message vocabulary (classify.offense/defense's own
-- HIT/MISS/CRIT/etc) -- but the game ALSO emits a genuinely separate,
-- weaponskill-PREFIXED message vocabulary ("<actor> uses <weapon_
-- skill>. <effect>") that is NOT the same as melee's and was
-- completely missed in the original weaponskill work earlier this
-- session. Found via a systematic audit (2026-07-29, prompted by user
-- asking "are there any ids we haven't added") that walked the full
-- 0-391 confirmed range and cross-checked every ID against what had
-- actually been vendored -- this was a real miss, not a hypothetical.
--
-- classify.weaponskillOffense/Defense now check THIS vocabulary FIRST,
-- falling back to melee's generic HIT/MISS/CRIT/etc only if a result's
-- message isn't one of these WS-specific ones -- reflects the
-- (unconfirmed, but reasonable) assumption that per-hit results within
-- a multi-hit WS likely still use plain HIT/MISS/CRIT, while these
-- WS-prefixed messages describe WS-LEVEL effects (status, drain,
-- dispel, "no effect", a resist-but-still-damages variant) riding on
-- the finish as a whole -- not independently confirmed, flagged same
-- as everything else in this function.
classify.WS_MSG = {
    -- Damage / miss / no-effect / resist
    DAMAGE      = 185,
    -- MISS = 188 already exists as classify.MSG.MISS_TP -- not
    -- redefined here, referenced directly by that name in
    -- classifyWeaponskill below.
    NO_EFFECT   = 189,
    -- RESIST_STILL_DAMAGES = 197,  -- REMOVED 2026-07-29: real ID 197 doesn't exist in xi.msg.basic under any name. No "resists but still takes damage" message found.

    -- Status landed
    STATUS_GAINS         = 186,
    -- STATUS_GAINS_2       = 194,  -- REMOVED 2026-07-29: real ID 194 doesn't exist. No second real WS status-gains variant found under a different ID.
    STATUS_ACC_EVA_DOWN  = 142,
    STATUS_LANDED        = 242,
    STATUS_RECEIVES      = 243,

    -- Status removed / dispel
    EFFECTS_DISAPPEAR_COUNT = 231,
    STATUS_DISAPPEARS        = 159,
    STATUS_DRAINED            = 370,

    -- Heal
    HEAL_HP    = 103,
    HEAL_HP_2  = 238,
    HEAL_MP    = 224,
    -- HEAL_MP_AOE 276 -- added 2026-10-29 (AscensionXI live capture):
    -- Kupipi's Moonlight secondary targets, 17 events, log "2 MP -> Lift
    -- and Cinder / 0 MP -> Mogh, Temper, and Toosik", param == MP.
    HEAL_MP_AOE = 276,

    -- Drain
    DRAIN_HP     = 187,
    DRAIN_MP     = 225,
    DRAIN_TP     = 226,
    DRAIN_STAT   = 369,

    -- Misc WS-specific effects
    ABILITIES_RECHARGED = 360,
    TP_REDUCED           = 362,
    -- PET_RELEASED          = 221,  -- REMOVED 2026-07-29: real ID 221 doesn't exist in xi.msg.basic under any name. No "pet released" message found.
    PET_POWER_UP           = 109,
};

-- Item use (category 5 finish) message IDs (2026-07-29, gap-audit
-- follow-up). CONFIRMED against the same Windower/Lua wiki table as
-- everything else. Genuine miss earlier this session: category 5 was
-- incorrectly grouped in with the "no action needed" start-categories
-- (8/9/10/12) in this file's own header comment -- it is NOT a no-op;
-- item use HAS real finish-shaped results (status effects landing,
-- obtaining items, dispel), just a small, simple vocabulary (5
-- messages) compared to job ability/magic.
classify.ITEM_MSG = {
    GENERIC_USE       = 28,  -- "<actor> uses an <item>." -- no more specific effect described
    STATUS_RECEIVES    = 375,
    OBTAIN_ITEM         = 376,
    OBTAIN_ITEM_2        = 377,
    STATUS_DISAPPEARS     = 378,
};

-- Pet TP move (category 13) reaction values -- UNCONFIRMED, per the
-- Windower/Lua wiki's own "Action Category 13" page (github.com/
-- Windower/Lua/wiki/Action-Category-13): "reaction: 8 may indicate
-- success and 9 may indicate failure (like hit and miss for Action
-- Category 01)" -- that page's own hedging language ("may indicate")
-- is preserved here deliberately, not upgraded to confident constants.
-- See classify.petTpMoveOffense/Defense for how this is used.
classify.PET_REACTION = {
    LIKELY_SUCCESS = 8,
    LIKELY_FAILURE = 9,
};

-- General melee `reaction` field values (SEPARATE from PET_REACTION
-- above, which is a different field's vocabulary scoped to category-13
-- pet TP moves only). BUGFIX (2026-07-30): classify.defense() (line
-- ~1056) has referenced classify.REACTION.GUARD/SHIELD_BLOCK since this
-- file's defensive priority chain was written, but this table itself
-- was never actually defined -- every real defense-side packet that
-- reached that branch threw "attempt to index field 'REACTION' (a nil
-- value)" instead of classifying. The values were not missing/unknown,
-- though: this file's OWN header comment (line 20) already documents
-- them as CONFIRMED against live CatsEyeXI combat data (2026-07-27) --
-- "Reaction field (SEPARATE from message): GUARD=2, SHIELD_BLOCK=4."
-- This table just vendors that same confirmed pair into code, the same
-- way PET_REACTION already does for its own field.
classify.REACTION = {
    GUARD        = 2,
    SHIELD_BLOCK = 4,
};

-- Pet TP move (category 13) MESSAGE vocabulary -- CONFIRMED against
-- real CatsEyeXI capture data (2026-07-29 live cross-validation
-- session, 21/21 category-13 events), NOT against the Windower wiki
-- (that page's own text -- "message: Never 0?" -- correctly read as
-- "not always 0", not as "not meaningful"; it never actually documents
-- what non-zero values mean). Every one of the 21 real events captured
-- had reaction=0 (neither PET_REACTION value ever appeared) and
-- message=317 -- so reaction is NOT a usable outcome signal for this
-- category in practice on this server, and message clearly IS.
--
-- 317 is not a new/invented ID -- it's classify.JA_MSG.DAMAGE_2,
-- already independently confirmed against the Windower "Message IDs"
-- wiki page as a "<target> takes N damage" job-ability-damage message.
-- Deliberately NOT reusing classify.JA_MSG wholesale here, though --
-- only 317 has actually been observed on a category-13 packet; every
-- other JA_MSG entry (heal, status, steal, etc) is unconfirmed for
-- this category and would be a guess. Kept as its OWN small table
-- (starts with just DAMAGE) so it only grows as new values are
-- actually observed in real data, not assumed by analogy -- same
-- discipline as WS_MSG's own fix (see that table's header) and this
-- project's general anti-invented-ID stance.
classify.PET_TP_MSG = {
    DAMAGE = 317,
};

-- Outcome bucket names -- the single, unambiguous result of one swing.
classify.OUTCOME = {
    HIT         = 'HIT',
    CRIT        = 'CRIT',
    MISS        = 'MISS',          -- offense: you missed. defense: mob missed (evaded by you).
    PARRY       = 'PARRY',
    SHADOWS     = 'SHADOWS',
    DODGE       = 'DODGE',
    COUNTER     = 'COUNTER',
    GUARD       = 'GUARD',
    SHIELD_BLOCK = 'SHIELD_BLOCK',
    UNMITIGATED = 'UNMITIGATED',   -- defense only: a hit that landed with no defensive mitigation
    MOB_HEAL    = 'MOB_HEAL',      -- offense only: your melee action healed the mob instead
    NO_EFFECT_SELF = 'NO_EFFECT_SELF', -- offense: your own action produced no result to track (e.g. category out of v1 scope)
    UNKNOWN     = 'UNKNOWN',       -- NEVER silently dropped -- see "unknown capture" below.
    UNKNOWN_ADD_EFFECT = 'UNKNOWN_ADD_EFFECT', -- an add-effect/proc block fired (see classify.addEffect, 2026-07-29) that is NOT a confirmed skillchain message -- covers enspell, en-drain/en-aspir/en-damage/en-debuff procs, and anything else riding this mechanism whose specific mechanism isn't yet identified.
    SKILLCHAIN  = 'SKILLCHAIN',    -- an add-effect block carrying a CONFIRMED skillchain message id (196/223/288-302) -- see classify.MSG's skillchain entries for the source. Carries a `property` field in its raw envelope (nil for the two generic/unpropertied variants).

    -- Job ability outcomes (2026-07-29) -- see classify.JA_MSG for the
    -- confirmed message IDs each of these maps from, and
    -- classify.jobAbilityOffense/Defense for the dispatch logic.
    JA_DAMAGE           = 'JA_DAMAGE',
    JA_HEAL              = 'JA_HEAL',           -- covers both target-heal and self-heal shapes; `target` field in the raw envelope distinguishes which (see function body)
    JA_STATUS_LANDED     = 'JA_STATUS_LANDED',   -- a buff/debuff/status effect landed on the target
    JA_STATUS_REMOVED    = 'JA_STATUS_REMOVED',  -- a status was actively stripped (Cure-type JA) or wore off as a JA side effect
    JA_NO_EFFECT         = 'JA_NO_EFFECT',
    JA_MISS              = 'JA_MISS',
    JA_STEAL_SUCCESS     = 'JA_STEAL_SUCCESS',
    JA_STEAL_FAIL        = 'JA_STEAL_FAIL',
    JA_MUG_SUCCESS       = 'JA_MUG_SUCCESS',
    JA_MUG_FAIL          = 'JA_MUG_FAIL',
    JA_CHARM_SUCCESS     = 'JA_CHARM_SUCCESS',
    JA_CHARM_FAIL        = 'JA_CHARM_FAIL',
    JA_FIND_ITEM         = 'JA_FIND_ITEM',
    JA_FIND_NOTHING      = 'JA_FIND_NOTHING',
    JA_SELF_BUFF_ONLY    = 'JA_SELF_BUFF_ONLY',  -- Divine Seal / Elemental Seal / Trick Attack -- confirmed used, no target-effect field to report
    JA_PET_POWER_UP      = 'JA_PET_POWER_UP',
    JA_GENERIC_USE       = 'JA_GENERIC_USE',     -- ability confirmed used, but the message carries no more specific effect than that

    -- Added 2026-07-29 (msg.lua gap-audit) -- see classify.JA_MSG's own
    -- "Added 2026-07-29" comment block for the full provenance note.
    JA_CHARM_CANNOT         = 'JA_CHARM_CANNOT',
    JA_CHARM_VERY_DIFFICULT = 'JA_CHARM_VERY_DIFFICULT',
    JA_CHARM_DIFFICULT      = 'JA_CHARM_DIFFICULT',
    JA_CHARM_MIGHT_BE_ABLE  = 'JA_CHARM_MIGHT_BE_ABLE',
    JA_CHARM_SHOULD_BE_ABLE = 'JA_CHARM_SHOULD_BE_ABLE',
    JA_ATK_ENHANCED         = 'JA_ATK_ENHANCED',
    JA_TP_INCREASE          = 'JA_TP_INCREASE',
    JA_MAGIC_STEAL          = 'JA_MAGIC_STEAL',
    JA_MAGIC_TP_REDUCE      = 'JA_MAGIC_TP_REDUCE',
    JA_RECOVERS_MP          = 'JA_RECOVERS_MP',
    JA_WILD_FLOURISH_TP     = 'JA_WILD_FLOURISH_TP',
    JA_STEAL_EFFECT         = 'JA_STEAL_EFFECT',
    JA_MAGIC_ABSORB_TP      = 'JA_MAGIC_ABSORB_TP',
    JA_TH_EFFECTIVENESS     = 'JA_TH_EFFECTIVENESS',
    JA_ENMITY_DECREASE      = 'JA_ENMITY_DECREASE',
    JA_ROLL_MAIN            = 'JA_ROLL_MAIN',
    JA_ROLL_SUB             = 'JA_ROLL_SUB',
    JA_ROLL_MAIN_FAIL       = 'JA_ROLL_MAIN_FAIL',
    JA_ROLL_SUB_FAIL        = 'JA_ROLL_SUB_FAIL',
    JA_DOUBLEUP             = 'JA_DOUBLEUP',
    JA_DOUBLEUP_FAIL        = 'JA_DOUBLEUP_FAIL',
    JA_DOUBLEUP_BUST        = 'JA_DOUBLEUP_BUST',
    JA_DOUBLEUP_BUST_SUB    = 'JA_DOUBLEUP_BUST_SUB',
    JA_DESPOIL_ATT_DOWN     = 'JA_DESPOIL_ATT_DOWN',
    JA_DESPOIL_DEF_DOWN     = 'JA_DESPOIL_DEF_DOWN',
    JA_DESPOIL_MATT_DOWN    = 'JA_DESPOIL_MATT_DOWN',
    JA_DESPOIL_MDEF_DOWN    = 'JA_DESPOIL_MDEF_DOWN',
    JA_DESPOIL_EVA_DOWN     = 'JA_DESPOIL_EVA_DOWN',
    JA_DESPOIL_ACC_DOWN     = 'JA_DESPOIL_ACC_DOWN',
    JA_DESPOIL_SLOW         = 'JA_DESPOIL_SLOW',
    JA_LUOPAN_HP_RATE_DOWN  = 'JA_LUOPAN_HP_RATE_DOWN',
    JA_LUOPAN_HP_RATE_UP    = 'JA_LUOPAN_HP_RATE_UP',
    JA_SWORDPLAY_GAIN       = 'JA_SWORDPLAY_GAIN',
    JA_VALLATION_GAIN       = 'JA_VALLATION_GAIN',
    JA_VALIANCE_GAIN_PARTY  = 'JA_VALIANCE_GAIN_PARTY',
    JA_LIEMENT_GAIN         = 'JA_LIEMENT_GAIN',
    JA_PFLUG_GAIN           = 'JA_PFLUG_GAIN',
    JA_GAMBIT_GAIN          = 'JA_GAMBIT_GAIN',

    -- Ranged (category 2) outcomes -- see classify.MSG's RANGE* entries
    -- and classify.rangedOffense/Defense for dispatch. Deliberately
    -- separate names from melee's HIT/CRIT/MISS (not reused) since
    -- ranged has its own distinct, confirmed message IDs -- keeping
    -- them separate avoids conflating "a ranged hit" and "a melee hit"
    -- in exported data, which would matter for any future ranged-
    -- specific accuracy/damage analysis.
    RANGED_HIT       = 'RANGED_HIT',
    RANGED_CRIT      = 'RANGED_CRIT',
    RANGED_MISS      = 'RANGED_MISS',
    RANGED_NO_EFFECT = 'RANGED_NO_EFFECT',
    RANGED_MOB_HEAL  = 'RANGED_MOB_HEAL',

    -- Pet TP move (category 13) outcomes -- see classify.petTpMoveOffense/
    -- Defense's own header for the UNCONFIRMED reaction-field caveat
    -- and classify.PET_TP_MSG for the CONFIRMED message-based outcome.
    PET_TP_MOVE_LIKELY_SUCCESS = 'PET_TP_MOVE_LIKELY_SUCCESS',
    PET_TP_MOVE_LIKELY_FAILURE = 'PET_TP_MOVE_LIKELY_FAILURE',
    PET_TP_MOVE_DAMAGE         = 'PET_TP_MOVE_DAMAGE',

    -- Magic (category 4) outcomes -- see classify.MAGIC_MSG for the
    -- confirmed message IDs each maps from, and classify.magicOffense/
    -- Defense for dispatch. Deliberately its own MAGIC_* namespace, not
    -- reusing melee/JA outcome names, for the same reason ranged got
    -- its own RANGED_* namespace -- keeps magic-specific analysis
    -- (resist rates, burst rates, etc) unambiguous in exported data.
    MAGIC_DAMAGE         = 'MAGIC_DAMAGE',
    MAGIC_BURST_DAMAGE   = 'MAGIC_BURST_DAMAGE',
    MAGIC_HEAL           = 'MAGIC_HEAL',
    MAGIC_STATUS_LANDED  = 'MAGIC_STATUS_LANDED',
    MAGIC_BURST_STATUS_LANDED = 'MAGIC_BURST_STATUS_LANDED',
    MAGIC_DRAIN_HP       = 'MAGIC_DRAIN_HP',
    MAGIC_DRAIN_MP       = 'MAGIC_DRAIN_MP',
    MAGIC_BURST_DRAIN_HP = 'MAGIC_BURST_DRAIN_HP',
    MAGIC_BURST_DRAIN_MP = 'MAGIC_BURST_DRAIN_MP',
    MAGIC_ABSORB_STAT    = 'MAGIC_ABSORB_STAT', -- carries a `stat` field in its raw envelope ('STR'/'DEX'/etc)
    MAGIC_NO_EFFECT      = 'MAGIC_NO_EFFECT',
    MAGIC_RESIST         = 'MAGIC_RESIST',
    MAGIC_EFFECT_FAIL    = 'MAGIC_EFFECT_FAIL',
    MAGIC_EVADES         = 'MAGIC_EVADES', -- distinct from MAGIC_RESIST -- see classify.MAGIC_MSG.EVADES's own comment
    MAGIC_ERASE          = 'MAGIC_ERASE',
    MAGIC_VANISHES        = 'MAGIC_VANISHES',       -- edge case -- likely gravity/teleport-type spell
    MAGIC_FALLS_TO_GROUND = 'MAGIC_FALLS_TO_GROUND', -- edge case -- likely gravity-type spell
    MAGIC_GENERIC_CAST   = 'MAGIC_GENERIC_CAST',     -- spell confirmed cast on target, no more specific effect described

    -- Added 2026-07-29 (msg.lua gap-audit) -- see classify.MAGIC_MSG's
    -- own "Added 2026-07-29" comment.
    MAGIC_REMOVE_EFFECT       = 'MAGIC_REMOVE_EFFECT',
    MAGIC_REMOVE_EFFECT_COUNT = 'MAGIC_REMOVE_EFFECT_COUNT',
    MAGIC_ABSORB_AILMENT      = 'MAGIC_ABSORB_AILMENT',

    -- Weaponskill-SPECIFIC outcomes (2026-07-29, gap-audit fix) -- see
    -- classify.WS_MSG for the confirmed message IDs and
    -- classify.weaponskillOffense/Defense for dispatch (checked BEFORE
    -- falling back to melee's generic HIT/MISS/CRIT/etc). Own WS_*
    -- namespace, not reusing melee/magic/JA names, same reasoning as
    -- RANGED_*/MAGIC_*.
    WS_DAMAGE          = 'WS_DAMAGE',
    WS_NO_EFFECT       = 'WS_NO_EFFECT',
    WS_RESIST_STILL_DAMAGES = 'WS_RESIST_STILL_DAMAGES',
    WS_STATUS_LANDED   = 'WS_STATUS_LANDED',
    WS_STATUS_REMOVED  = 'WS_STATUS_REMOVED',
    WS_HEAL            = 'WS_HEAL',
    WS_DRAIN_HP        = 'WS_DRAIN_HP',
    WS_DRAIN_MP        = 'WS_DRAIN_MP',
    WS_DRAIN_TP        = 'WS_DRAIN_TP',
    WS_DRAIN_STAT      = 'WS_DRAIN_STAT',
    WS_ABILITIES_RECHARGED = 'WS_ABILITIES_RECHARGED',
    WS_TP_REDUCED       = 'WS_TP_REDUCED',
    WS_PET_RELEASED      = 'WS_PET_RELEASED',
    WS_PET_POWER_UP       = 'WS_PET_POWER_UP',

    -- Item use (category 5) outcomes (2026-07-29, gap-audit follow-up)
    -- -- see classify.ITEM_MSG for confirmed message IDs and
    -- classify.itemUseOffense/Defense for dispatch.
    ITEM_GENERIC_USE    = 'ITEM_GENERIC_USE',
    ITEM_STATUS_LANDED  = 'ITEM_STATUS_LANDED',
    ITEM_OBTAIN         = 'ITEM_OBTAIN',
    ITEM_STATUS_REMOVED = 'ITEM_STATUS_REMOVED',

    -- Add-effect (proc) outcomes -- added 2026-07-29 (msg.lua
    -- gap-audit). See classify.ADD_EFFECT_MSG for confirmed message IDs
    -- and classify.addEffect's third dispatch tier for where these are
    -- consumed (checked after skillchain, before UNKNOWN_ADD_EFFECT).
    ADD_EFFECT_MP_HEAL     = 'ADD_EFFECT_MP_HEAL',
    ADD_EFFECT_STATUS      = 'ADD_EFFECT_STATUS', -- covers the msg.lua-flagged-as-possible-duplicate STATUS_2(164) entry
    ADD_EFFECT_TP_DRAIN    = 'ADD_EFFECT_TP_DRAIN',
    ADD_EFFECT_SELFBUFF    = 'ADD_EFFECT_SELFBUFF',
    ADD_EFFECT_HP_HEAL     = 'ADD_EFFECT_HP_HEAL',
    ADD_EFFECT_DISPEL      = 'ADD_EFFECT_DISPEL',
    ADD_EFFECT_WARP        = 'ADD_EFFECT_WARP',
    ADD_EFFECT_STATUS_SPIKES = 'ADD_EFFECT_STATUS_SPIKES', -- a spike effect that applies a STATUS to the attacker, not the defender -- see classify.ADD_EFFECT_MSG.STATUS_SPIKES's own comment
    ADD_EFFECT_SPIKES_HEAL   = 'ADD_EFFECT_SPIKES_HEAL',
    ADD_EFFECT_HEAL          = 'ADD_EFFECT_HEAL',
    ADD_EFFECT_HP_DRAIN      = 'ADD_EFFECT_HP_DRAIN',      -- 2026-10-29; damage = HP drained from the mob
    ADD_EFFECT_TREASURE_HUNTER = 'ADD_EFFECT_TREASURE_HUNTER', -- 2026-10-29; damage = 0, thLevel = new TH level

    -- 2026-10-29 additions (AscensionXI live capture) -- see each
    -- message table's own 2026-10-29 note for the log evidence.
    COUNTERED            = 'COUNTERED',            -- offense: the mob countered this swing (spike msg 33). Excluded from hit AND miss tallies.
    MOB_TP_DAMAGE        = 'MOB_TP_DAMAGE',        -- defense: mob TP move hit you (185 primary / 264 AoE secondary)
    MOB_TP_MISS          = 'MOB_TP_MISS',          -- defense: mob TP move missed / failed (188)
    MOB_TP_STATUS_LANDED = 'MOB_TP_STATUS_LANDED', -- defense: mob TP move landed a status on you (242); statusId carries it
    JA_DAZE_LANDED       = 'JA_DAZE_LANDED',       -- DNC step landed a daze; damage = 0, effectLevel = daze level
    TOO_FAR              = 'TOO_FAR',              -- offense: action never went off -- target out of range (msg 78). Excluded from hit AND miss tallies, damage 0.
    JA_NO_MESSAGE        = 'JA_NO_MESSAGE',        -- ability resolved on this target with message 0 (no chat text) -- e.g. AscensionXI custom "Resonance"; raw param kept

    -- Pet-related outcomes -- added 2026-07-29 (msg.lua gap-audit).
    -- NO_EFFECT_ON_PET (msg 336) is the only one of the three gap-list pet
    -- entries dispatched as a landed outcome -- PET_CANNOT_DO_ACTION (574)
    -- and PET_NOT_ENOUGH_TP (575) are use-failure system messages, not
    -- wired into dispatch (same reasoning as the JA use-failure messages
    -- above). (The unused classify.PET_MSG table was removed 2026-10-30.)
    PET_NO_EFFECT = 'PET_NO_EFFECT',
};

-- ---------------------------------------------------------------------
-- UNKNOWN CAPTURE -- 2026-07-27 design correction.
--
-- Previously, anything the classifier didn't recognize fell into a
-- silent 'NO_DAMAGE' catch-all and was effectively discarded with no
-- record. This is wrong: a case like Stoneskin, Invincible, or any
-- spell/ability/mechanic not yet accounted for would vanish invisibly,
-- with no way to notice it happened or investigate later. Neither
-- Stoneskin nor Invincible have a verified message ID anywhere in
-- packet_ground_truth.md as of this writing -- guessing at IDs for them
-- would repeat exactly the mobstats v1.0 mistake this project has been
-- careful to avoid throughout (see mobstats.lua's own header warning
-- about invented message ids).
--
-- New rule: classify.offense/defense NEVER discard an unrecognized
-- result silently. Anything not matched by an explicit, VERIFIED rule
-- returns outcome=UNKNOWN plus a full raw-fields record, so it can be
-- logged, reviewed, and (once a real ID meaning is confirmed against
-- real evidence -- chat log correlation, CSV cross-check, etc, same
-- discipline as the rest of this project) promoted into a real,
-- explicitly-handled case.
--
-- classify.offense/defense return THREE values on an unknown case:
--   outcome (= classify.OUTCOME.UNKNOWN), damage (always 0, since we
--   don't know if the param field even means "damage" for an
--   unrecognized message), raw (a table of every field seen, for
--   logging/inspection).
-- ---------------------------------------------------------------------
local function unknownRaw(result)
    return {
        message  = result.message,
        reaction = result.reaction,
        animation = result.animation,
        param    = result.param,
        hasSpike = result.has_spike_effect,
        spikeMessage = result.spike_effect_message,
        hasAddEffect = result.has_add_effect,
        addEffectMessage = result.add_effect_message,
    };
end

-- ===========================================================================
-- OFFENSE: classify a swing where the tracked player is the attacker.
-- ===========================================================================

-- result: { reaction, animation, param (damage), message, ... } -- the
-- Ashita.Packets.Build_Action per-result shape.
-- Returns: outcome (string, classify.OUTCOME.*), damage (number, 0 if
-- this outcome carries no real damage), raw (table, ONLY present when
-- outcome == UNKNOWN -- nil otherwise, so normal callers never pay for it).
function classify.offense(result)
    local msg = result.message;
    local dmg = result.param or 0;

    -- 2026-07-29: was `MOBHEAL3 or MOBHEAL373` -- MOBHEAL3(3) removed
    -- as fabricated (no real msg.lua ID), so this now only checks the
    -- real one (373 = SPIKES_EFFECT_RECOVER).
    if msg == classify.MSG.MOBHEAL373 then
        return classify.OUTCOME.MOB_HEAL, dmg;
    end
    if msg == classify.MSG.MISS then
        return classify.OUTCOME.MISS, 0;
    end
    if msg == classify.MSG.DODGE then
        return classify.OUTCOME.DODGE, 0;
    end
    if msg == classify.MSG.SHADOWS then
        return classify.OUTCOME.SHADOWS, 0;
    end
    if msg == classify.MSG.CRIT then
        return classify.OUTCOME.CRIT, dmg;
    end
    if msg == classify.MSG.HIT then
        return classify.OUTCOME.HIT, dmg;
    end

    -- 2026-10-29: mob countered this swing. The swing itself carries
    -- message 0 / param 0 (no damage to the mob); the counter damage the
    -- ATTACKER took rides the spike block. Reported as its own outcome,
    -- damage 0 (nothing dealt to the mob), and deliberately NOT in the
    -- GUI's COUNTS_AS_HIT or COUNTS_AS_MISS -- whether a countered swing passed
    -- its accuracy roll isn't knowable from this packet, so it stays out
    -- of the ACC/EVA math entirely rather than skewing it either way.
    -- counterDamage reads spike_effect_param -- CONFIRMED present in
    -- packet_action.parse (14-bit field in the spike block), 2026-10-29.
    if msg == 0 and result.has_spike_effect
        and result.spike_effect_message == classify.MSG.SPIKE_COUNTER then
        return classify.OUTCOME.COUNTERED, 0, { counterDamage = result.spike_effect_param };
    end

    -- 2026-10-29: "<target> is too far away" -- the action (seen on a
    -- weaponskill, which falls through to this function) never went off.
    -- Not an accuracy roll, so it's in neither the GUI's COUNTS_AS_HIT
    -- nor COUNTS_AS_MISS. See classify.MSG.TOO_FAR_AWAY for the evidence.
    if msg == classify.MSG.TOO_FAR_AWAY then
        return classify.OUTCOME.TOO_FAR, 0;
    end

    -- Anything else -- ranged/Daken variants, resist-tier magic messages,
    -- Stoneskin/Invincible-type effects with no verified ID yet, or
    -- anything genuinely new -- is NOT silently discarded. Capture it.
    return classify.OUTCOME.UNKNOWN, 0, unknownRaw(result);
end

-- ===========================================================================
-- DEFENSE: classify a swing where the tracked player is the target.
-- MUST check in this exact priority order -- confirmed mutually exclusive
-- against live CatsEyeXI data (see packet_ground_truth.md).
-- ===========================================================================

function classify.defense(result)
    local msg      = result.message;
    local reaction = result.reaction;
    local dmg      = result.param or 0;

    if msg == classify.MSG.MOBHEAL373 then
        -- mirrors offense's no-damage healing case; this is a KNOWN,
        -- understood outcome (mob's own melee healed itself off you),
        -- not an unknown -- does not carry real damage either way.
        return classify.OUTCOME.NO_EFFECT_SELF, 0;
    end

    -- 1. Evade (message MISS on the defense side)
    if msg == classify.MSG.MISS then
        return classify.OUTCOME.MISS, 0;
    end

    -- 2. Parry
    if msg == classify.MSG.PARRY then
        return classify.OUTCOME.PARRY, dmg;
    end

    -- 3. Shadows (Blink/Utsusemi absorb)
    if msg == classify.MSG.SHADOWS then
        return classify.OUTCOME.SHADOWS, 0;
    end

    -- 4. Counter -- rides on the spike/reaction block, not the main
    -- message field, per packet_ground_truth.md. Caller passes the
    -- spike block's own message as result.spike_effect_message if
    -- present (matches Ashita.Packets.Build_Action's normalized shape).
    -- DISABLED 2026-07-29: classify.MSG.COUNTER (id 33) was fabricated
    -- -- no real xi.msg.basic entry for a counter-attack message was
    -- found anywhere in the source. Left commented (not deleted) so
    -- this is easy to re-enable if a real ID is ever found via a live
    -- capture. classify.OUTCOME.COUNTER stays defined since it's
    -- still a valid outcome name, just currently unreachable.
    -- if result.has_spike_effect and result.spike_effect_message == classify.MSG.COUNTER then
    --     return classify.OUTCOME.COUNTER, dmg;
    -- end

    -- 5. Guard (reaction field, NOT message field)
    if reaction == classify.REACTION.GUARD then
        return classify.OUTCOME.GUARD, dmg;
    end

    -- 6. Shield Block (reaction field, NOT message field)
    if reaction == classify.REACTION.SHIELD_BLOCK then
        return classify.OUTCOME.SHIELD_BLOCK, dmg;
    end

    -- 7. Dodge (Perfect Dodge) -- excluded from hit/miss tally entirely,
    -- but still needs its own bucket so it isn't silently miscounted as
    -- an unmitigated hit.
    if msg == classify.MSG.DODGE then
        return classify.OUTCOME.DODGE, 0;
    end

    if msg == classify.MSG.CRIT then
        -- a critical hit is still "unmitigated" in the sense that none
        -- of the above defensive outcomes fired -- flag it distinctly
        -- so callers can track crit rate taken separately if wanted.
        return classify.OUTCOME.CRIT, dmg;
    end

    if msg == classify.MSG.HIT then
        -- 8. Fallback within KNOWN messages: unmitigated hit -- none of
        -- the above defensive outcomes fired, but this IS a recognized,
        -- ordinary hit message.
        return classify.OUTCOME.UNMITIGATED, dmg;
    end

    -- Anything else: a message ID we have not verified the meaning of
    -- on the defense side (Stoneskin absorption, Invincible, or
    -- anything genuinely new). NOT silently discarded -- capture it.
    -- This is precisely the case that motivated this design correction:
    -- a Stoneskin- or Invincible-absorbed swing must NOT be silently
    -- folded into UNMITIGATED (that would corrupt the hit-rate tally
    -- with damage=0 hits that may not represent a normal accuracy roll
    -- at all) nor dropped without record.
    return classify.OUTCOME.UNKNOWN, 0, unknownRaw(result);
end

-- ===========================================================================
-- WEAPONSKILL (category 3): classify one hit of a (possibly multi-hit)
-- weaponskill finish.
--
-- STATUS (2026-07-29, UPDATED same day after a gap audit): this
-- function originally ONLY reused classify.offense/defense's generic
-- melee vocabulary (HIT/MISS/CRIT/etc) -- see the corroboration
-- evidence below, still valid for THAT part. But a systematic audit
-- (prompted by the user asking "are there any ids we haven't added")
-- found that the game ALSO emits a genuinely separate, WS-PREFIXED
-- message vocabulary ("<actor> uses <weapon_skill>. <effect>",
-- messages 103/109/142/159/185-187/189/194/197/221/224-226/231/
-- 238/242/243/360/362/369/370 -- see classify.WS_MSG) that was
-- completely missed in the original pass. This function now checks
-- WS_MSG FIRST, falling back to melee's generic messages only if the
-- result's message isn't one of the WS-specific ones.
--
-- Original corroboration (still applies to the melee-vocabulary
-- fallback path):
--   - packet_ground_truth.md's own field documentation never scopes
--     message IDs to category 1 specifically.
--   - Independent, non-Metrics corroboration (2026-07-29): the
--     Windower/Lua project's own wiki ("Action Event" page) documents
--     the action packet's per-result `message` field with ONE shared
--     "Message IDs" reference table covering categories 1/2/3/7/8/11
--     together, and separately notes `stagger` "appears with categories
--     3 and 7 as well (physical and magic WS respectively)" -- i.e. the
--     per-result field SHAPE itself is already documented as spanning
--     melee and weaponskill categories, not melee-only.
--   - Windower's own battlemod/parse_action_packet.lua treats message
--     IDs 1 (HIT) and 67 (CRIT) as generic, category-non-specific
--     concepts ("combine kicks and crits") in its own dispatch logic.
-- Still flag any weaponskill classification bug report as a first
-- suspect here, same discipline as PARRY/SHADOWS/DODGE/COUNTER on the
-- melee side. The WS_MSG vocabulary itself is CONFIRMED (same
-- Windower wiki source as everything else), but which of a WS's
-- per-hit results uses WS_MSG vs falls back to melee's generic
-- messages is NOT independently confirmed -- the priority-order
-- assumption (check WS_MSG first) is reasonable but untested.
--
-- Per packet_ground_truth.md's category table: category 3 is the
-- player's OWN weaponskill finish -- in practice this is overwhelmingly
-- an OFFENSE-side action (you performing a WS on a mob). A monster's
-- own TP-move-landing-on-you goes through category 11 instead (a
-- separately-built category -- see classify.monsterTpMoveOffense/
-- Defense) -- so classify.weaponskillDefense exists here for
-- shape-symmetry with the offense/defense pairing used everywhere
-- else in this module, but is expected to see little or no real
-- traffic and is correspondingly even less exercised than the
-- offense path.
-- ===========================================================================

local WS_OUTCOME_BY_MSG = {
    [classify.WS_MSG.DAMAGE]      = classify.OUTCOME.WS_DAMAGE,
    [classify.WS_MSG.NO_EFFECT]   = classify.OUTCOME.WS_NO_EFFECT,
    -- RESIST_STILL_DAMAGES dispatch entry REMOVED 2026-07-29 (constant no longer defined -- no real xi.msg.basic ID found)

    [classify.WS_MSG.STATUS_GAINS]        = classify.OUTCOME.WS_STATUS_LANDED,
    -- STATUS_GAINS_2 dispatch entry REMOVED 2026-07-29 (constant no longer defined)
    [classify.WS_MSG.STATUS_ACC_EVA_DOWN] = classify.OUTCOME.WS_STATUS_LANDED,
    [classify.WS_MSG.STATUS_LANDED]       = classify.OUTCOME.WS_STATUS_LANDED,
    [classify.WS_MSG.STATUS_RECEIVES]     = classify.OUTCOME.WS_STATUS_LANDED,

    [classify.WS_MSG.EFFECTS_DISAPPEAR_COUNT] = classify.OUTCOME.WS_STATUS_REMOVED,
    [classify.WS_MSG.STATUS_DISAPPEARS]        = classify.OUTCOME.WS_STATUS_REMOVED,
    [classify.WS_MSG.STATUS_DRAINED]            = classify.OUTCOME.WS_STATUS_REMOVED,

    [classify.WS_MSG.HEAL_HP]   = classify.OUTCOME.WS_HEAL,
    [classify.WS_MSG.HEAL_HP_2] = classify.OUTCOME.WS_HEAL,
    [classify.WS_MSG.HEAL_MP]   = classify.OUTCOME.WS_HEAL,
    [classify.WS_MSG.HEAL_MP_AOE] = classify.OUTCOME.WS_HEAL, -- 2026-10-29

    [classify.WS_MSG.DRAIN_HP]   = classify.OUTCOME.WS_DRAIN_HP,
    [classify.WS_MSG.DRAIN_MP]   = classify.OUTCOME.WS_DRAIN_MP,
    [classify.WS_MSG.DRAIN_TP]   = classify.OUTCOME.WS_DRAIN_TP,
    [classify.WS_MSG.DRAIN_STAT] = classify.OUTCOME.WS_DRAIN_STAT,

    [classify.WS_MSG.ABILITIES_RECHARGED] = classify.OUTCOME.WS_ABILITIES_RECHARGED,
    [classify.WS_MSG.TP_REDUCED]           = classify.OUTCOME.WS_TP_REDUCED,
    -- PET_RELEASED dispatch entry REMOVED 2026-07-29 (constant no longer defined -- no real xi.msg.basic ID found)
    [classify.WS_MSG.PET_POWER_UP]           = classify.OUTCOME.WS_PET_POWER_UP,

    -- classify.MSG.MISS_TP (188) is DELIBERATELY handled as an
    -- explicit check in classifyWeaponskill below, not listed in this
    -- table -- it's already a real, independently-used constant
    -- elsewhere (classify.MSG.MISS_TP), and giving it a second lookup
    -- path here would make this table's own membership check
    -- ambiguous about which "meaning" a lookup hit represents.
};

-- GAP 3 FIX (2026-07-29): real capture data (84 player-actor
-- 'weaponskill'-type UNKNOWN events, see mobparser_PROJECT.md) showed
-- message IDs 100/317/324 -- none in WS_MSG, none in melee's generic
-- classify.MSG either, so every one of these 84 events fell through
-- to genericFn and came out UNKNOWN. Root cause: these three IDs are
-- not weaponskill-specific OR melee-generic at all -- they're
-- ALREADY-CONFIRMED JA_MSG entries (JA_MSG.GENERIC_USE=100,
-- JA_MSG.DAMAGE_2=317, JA_MSG.MISS_2=324, see classify.JA_MSG above),
-- arriving on category-3 (WEAPONSKILL) events. combat_router.lua's
-- EVENT_TYPE_BY_CATEGORY maps category 3 to 'weaponskill' unconditionally
-- (confirmed by reading combat_router.lua directly this session) --
-- there is no message-based re-routing at the router level, so
-- classify.lua is the only place this can be resolved.
-- 76/84 (~90%) of the captured events were message=317
-- (JA_MSG.DAMAGE_2) specifically -- consistent with these being the
-- secondary/non-primary hit lines of multi-hit weaponskills (e.g.
-- Penta Thrust), which is the hypothesis already recorded in
-- mobparser_PROJECT.md, though still not independently confirmed
-- against a specific named WS. NOT guessing new IDs here -- 100/317/324
-- are the exact three IDs found in the real capture, and JA_MSG's
-- existing definitions for them are reused as-is, not redefined.
-- Priority order: WS_MSG first (unchanged), THEN this JA_MSG fallback,
-- THEN genericFn (melee HIT/MISS/CRIT/etc) as the last resort --
-- preserves the existing, already-corroborated WS_MSG-first behavior
-- for every message id that was already handled correctly.
local function classifyWeaponskill(result, genericFn)
    if result.message == classify.MSG.MISS_TP then
        return classify.OUTCOME.MISS, 0;
    end
    local wsOutcome = WS_OUTCOME_BY_MSG[result.message];
    if wsOutcome == classify.OUTCOME.WS_STATUS_LANDED or wsOutcome == classify.OUTCOME.WS_STATUS_REMOVED then
        -- 2026-10-29: status param is a status ID, not damage
        return wsOutcome, 0, { statusId = result.param };
    elseif wsOutcome ~= nil then
        return wsOutcome, result.param or 0;
    end
    -- 2026-10-29: message 0 is deliberately NOT allowed through the JA
    -- fallback here -- JA_MSG.NO_MESSAGE=0 is only evidenced on JA
    -- categories, and a message-0 WS result should stay UNKNOWN.
    local jaOutcome = (result.message ~= 0) and classify.JA_OUTCOME_BY_MSG[result.message] or nil;
    if jaOutcome ~= nil then
        -- 2026-10-29: Steal arrives on CATEGORY 3 on AscensionXI (5 live
        -- events, all matching "[Lift] Steal -> <mob>" log lines), so the
        -- param->itemId fix has to apply on this path too.
        local paramField = classify.JA_PARAM_FIELD_BY_OUTCOME[jaOutcome];
        if paramField ~= nil then
            return jaOutcome, 0, { [paramField] = result.param };
        end
        return jaOutcome, result.param or 0;
    end
    return genericFn(result);
end

---@param result table  one hit's normalized result (same shape as classify.offense)
---@return string outcome, number damage, table|nil raw
function classify.weaponskillOffense(result)
    return classifyWeaponskill(result, classify.offense);
end

---@param result table  one hit's normalized result (same shape as classify.defense)
---@return string outcome, number damage, table|nil raw
function classify.weaponskillDefense(result)
    return classifyWeaponskill(result, classify.defense);
end

-- ===========================================================================
-- MONSTER TP MOVE (category 11): classify one hit of a monster's own
-- TP-move (weaponskill-equivalent) landing on the player.
--
-- STATUS (2026-07-29): message-ID reuse here is CORROBORATED, same
-- confidence level as weaponskill (classify.weaponskillOffense/
-- Defense above), NOT independently confirmed for category 11
-- specifically. The Windower/Lua wiki's own "Action Event" page lists
-- categories "1/2/3/7/8/11" together under ONE shared "message" field
-- reference (same citation already used for weaponskill's own
-- corroboration) -- category 11 is explicitly included in that list.
-- HOWEVER: the Windower wiki's DEDICATED "Action Category 11" page
-- (github.com/Windower/Lua/wiki/Action-Category-11) describes ONLY
-- `param` (damage) and two `unknown` fields for category 11's
-- per-result shape -- it does NOT mention a `message` field at all,
-- and does not confirm hit/miss/crit semantics specifically for this
-- category. So this function rests on the GENERAL "message field is
-- shared across categories" claim, not a category-11-specific
-- confirmation -- flag this as a first suspect for any monster-TP-move
-- classification bug, same discipline as weaponskill and pet-TP-move.
--
-- This is overwhelmingly a DEFENSE-side action in practice (a mob's TP
-- move landing on the tracked player) -- offense variant provided for
-- shape-symmetry only, expected to see little or no real traffic
-- (would require the tracked player's own pet to be classified as the
-- "monster" actor of a TP move, which isn't how this mechanic works).
--
-- Known, documented quirk NOT handled here (see the Category 11 wiki
-- page): "Overloads are actually two subsequent Category 11 messages.
-- The first contains the right element name, and the second contains
-- the damage information." This function does NOT attempt to
-- correlate a pair of overload-related category 11 packets into one
-- logical event -- each packet is still classified independently, per
-- this project's existing per-packet capture design. Flagged as a
-- real, narrow follow-up if Synergy Furnace overload events turn out
-- to matter for this project's goals (currently: no, out of scope).
-- ===========================================================================

-- 2026-10-29 (AscensionXI live capture): the melee-only fallback above
-- was WRONG for category 11 -- mob TP moves use the WS-prefixed message
-- vocabulary, so all 44 captured TP moves came out UNKNOWN with
-- damage 0. Each ID below was matched to the chat log at the same
-- second, param == the number shown:
--   185 "[Orc Slinger] 11 Ranged Attack"  (26 events) -> damage = param
--   264 "[Greater Pugil] 68 Aqua Ball"    (16 events, AoE) -> damage = param
--   188 "[Jaggedwing Jim] Somersault ... fail" (1 event) -> miss
--   242 "[Greater Pugil] Intimidate"      (1 event, param 13) -> status landed
-- Checked FIRST; anything else still falls back to the melee chain (so
-- an ordinary-looking hit/miss/shadows message keeps working).
local MOB_TP_OUTCOME_BY_MSG = {
    [classify.WS_MSG.DAMAGE]              = classify.OUTCOME.MOB_TP_DAMAGE,  -- 185
    [classify.MAGIC_MSG.DAMAGE_NO_PREFIX] = classify.OUTCOME.MOB_TP_DAMAGE,  -- 264
    [classify.MSG.MISS_TP]                = classify.OUTCOME.MOB_TP_MISS,    -- 188
    [classify.WS_MSG.STATUS_LANDED]       = classify.OUTCOME.MOB_TP_STATUS_LANDED, -- 242
};

local function classifyMonsterTpMove(result, genericFn)
    local outcome = MOB_TP_OUTCOME_BY_MSG[result.message];
    if outcome == classify.OUTCOME.MOB_TP_DAMAGE then
        return outcome, result.param or 0;
    elseif outcome == classify.OUTCOME.MOB_TP_STATUS_LANDED then
        return outcome, 0, { statusId = result.param };
    elseif outcome ~= nil then
        return outcome, 0;
    end
    return genericFn(result);
end

---@param result table  one hit's normalized result (same shape as classify.offense)
---@return string outcome, number damage, table|nil raw
function classify.monsterTpMoveOffense(result)
    return classifyMonsterTpMove(result, classify.offense);
end

---@param result table  one hit's normalized result (same shape as classify.defense)
---@return string outcome, number damage, table|nil raw
function classify.monsterTpMoveDefense(result)
    return classifyMonsterTpMove(result, classify.defense);
end

-- ===========================================================================
-- ADD-EFFECT / PROC detection (2026-07-29): skillchain damage, enspell,
-- en-drain/en-aspir/en-damage/en-debuff procs all ride the SAME optional
-- "add effect" block on the base action-packet result (see
-- packet_ground_truth.md's "Optional add effect / proc block" note) --
-- gated by has_add_effect, with its OWN separate message id
-- (add_effect_message) independent of the base swing's own message.
--
-- This is DELIBERATELY SEPARATE from classify.offense/defense/
-- weaponskillOffense/weaponskillDefense: a proc can ride on ANY base
-- outcome (a perfectly ordinary HIT, a CRIT, in principle even a MISS
-- if the base swing's own accuracy roll failed but some other bit still
-- fired -- unconfirmed either way) so it isn't itself "the outcome of
-- the swing" the other classify.* functions already report -- it's a
-- second, independent thing that happened on the same result entry.
-- Callers should call this ALONGSIDE the normal classify.*Offense/
-- Defense call for the same result, not instead of it.
--
-- UPDATED 2026-07-29 (same day, after initial UNKNOWN_ADD_EFFECT-only
-- version): skillchain message IDs are now CONFIRMED, not guessed --
-- see classify.MSG's skillchain entries for the source (the
-- independently-maintained Windower/Lua wiki "Message IDs" page,
-- github.com/Windower/Lua/wiki/Message-IDs). add_effect_message values
-- 196, 223, and 288-302 are real, distinct skillchain messages, NOT
-- shared with the en-effect range (160-163, 229) -- these now resolve
-- to classify.OUTCOME.SKILLCHAIN with a `property` field (nil for the
-- two generic/unpropertied variants, a real property name string like
-- 'Light'/'Fusion'/'Cosmic Elucidation' for 288-302). Anything else
-- riding the add-effect block (enspell, en-drain/en-aspir/en-damage/
-- en-debuff, or genuinely unidentified) still falls back to
-- UNKNOWN_ADD_EFFECT, same as before -- this update only narrows that
-- bucket by pulling out the now-confirmed skillchain subset, it doesn't
-- claim confidence for anything else.
--
-- Does NOT attempt opener-linking (which player opened the skillchain
-- that THIS add-effect damage closes) -- explicitly deferred (user
-- decision 2026-07-29): the base action packet has no field
-- referencing a different action/actor at all, so any opener link
-- would be an INFERENCE from a separate recent-WS-history tracker, not
-- a fact read off this packet -- real, separate design work, tracked
-- as its own follow-up rather than folded into this capture step.
-- ===========================================================================

-- Reverse lookup for classify.addEffect's second dispatch tier (after
-- skillchain, before the UNKNOWN_ADD_EFFECT fallback) -- added
-- 2026-07-29 (msg.lua gap-audit), see classify.ADD_EFFECT_MSG's own
-- comment for provenance.
local ADD_EFFECT_OUTCOME_BY_MSG = {
    [classify.ADD_EFFECT_MSG.MP_HEAL]       = classify.OUTCOME.ADD_EFFECT_MP_HEAL,
    [classify.ADD_EFFECT_MSG.STATUS_2]      = classify.OUTCOME.ADD_EFFECT_STATUS,
    [classify.ADD_EFFECT_MSG.TP_DRAIN]      = classify.OUTCOME.ADD_EFFECT_TP_DRAIN,
    [classify.ADD_EFFECT_MSG.SELFBUFF]      = classify.OUTCOME.ADD_EFFECT_SELFBUFF,
    [classify.ADD_EFFECT_MSG.HP_HEAL]       = classify.OUTCOME.ADD_EFFECT_HP_HEAL,
    [classify.ADD_EFFECT_MSG.DISPEL]        = classify.OUTCOME.ADD_EFFECT_DISPEL,
    [classify.ADD_EFFECT_MSG.WARP]          = classify.OUTCOME.ADD_EFFECT_WARP,
    [classify.ADD_EFFECT_MSG.STATUS_SPIKES] = classify.OUTCOME.ADD_EFFECT_STATUS_SPIKES,
    [classify.ADD_EFFECT_MSG.SPIKES_HEAL]   = classify.OUTCOME.ADD_EFFECT_SPIKES_HEAL,
    [classify.ADD_EFFECT_MSG.HEAL]          = classify.OUTCOME.ADD_EFFECT_HEAL,
    [classify.ADD_EFFECT_MSG.HP_DRAIN]        = classify.OUTCOME.ADD_EFFECT_HP_DRAIN,        -- 2026-10-29
    [classify.ADD_EFFECT_MSG.TREASURE_HUNTER] = classify.OUTCOME.ADD_EFFECT_TREASURE_HUNTER, -- 2026-10-29
};

---@param result table  one hit's normalized result (has_add_effect, add_effect_animation, add_effect_param, add_effect_message)
---@return string|nil outcome, number|nil damage, table|nil raw  -- outcome is nil (not a real outcome string) if has_add_effect is false -- caller should skip recording anything in that case, not record a spurious zero-damage event.
function classify.addEffect(result)
    if not result.has_add_effect then
        return nil, nil, nil;
    end

    local addMsg = result.add_effect_message;
    local addDamage = result.add_effect_param or 0;

    if classify._SKILLCHAIN_MSG_SET[addMsg] then
        return classify.OUTCOME.SKILLCHAIN, addDamage, {
            message  = addMsg,
            -- property is nil for the two generic/unpropertied variants
            -- (196/223) -- real property name string for 288-302 (see
            -- classify.SKILLCHAIN_PROPERTY_BY_MSG). Callers that don't
            -- care about the property (just want "a skillchain
            -- happened, here's the damage") can ignore this field.
            property = classify.SKILLCHAIN_PROPERTY_BY_MSG[addMsg],
            animation = result.add_effect_animation,
            baseMessage = result.message,
        };
    end

    -- Added 2026-07-29 (msg.lua gap-audit): second tier for specific
    -- proc mechanics (en-effect self-buff, add-effect heal/drain/
    -- dispel/warp, weapon-spike status/heal) -- see
    -- classify.ADD_EFFECT_MSG for the confirmed IDs. Checked AFTER
    -- skillchain (skillchain takes priority if a message id somehow
    -- appeared in both -- it currently can't, the two sets don't
    -- overlap, but priority order is kept explicit anyway) and BEFORE
    -- the UNKNOWN_ADD_EFFECT fallback, narrowing that bucket the same
    -- way the skillchain tier already does.
    local addEffectOutcome = ADD_EFFECT_OUTCOME_BY_MSG[addMsg];
    if addEffectOutcome ~= nil then
        local raw = {
            message = addMsg,
            animation = result.add_effect_animation,
            baseMessage = result.message,
        };
        -- 2026-10-29: param is NOT damage for these two (live capture:
        -- 164's param was 149 = Defense Down's status ID; 603's param was
        -- 3 = the TH level). Previously exported as damage=149 / damage=3,
        -- which would have polluted any damage total. Moved to their own
        -- fields instead.
        if addEffectOutcome == classify.OUTCOME.ADD_EFFECT_STATUS then
            raw.statusId = addDamage;
            return addEffectOutcome, 0, raw;
        elseif addEffectOutcome == classify.OUTCOME.ADD_EFFECT_TREASURE_HUNTER then
            raw.thLevel = addDamage;
            return addEffectOutcome, 0, raw;
        end
        return addEffectOutcome, addDamage, raw;
    end

    return classify.OUTCOME.UNKNOWN_ADD_EFFECT, addDamage, {
        message   = addMsg,
        animation = result.add_effect_animation,
        -- baseMessage included so a later analysis pass can correlate
        -- "what add-effect message ids show up alongside which base
        -- swing outcomes" without needing to re-join against the
        -- original result -- cheap to include, useful for the future
        -- ID-identification work this whole function is deferring.
        baseMessage = result.message,
    };
end

-- ===========================================================================
-- JOB ABILITY (categories 6/finish, 10/start, 14/unblinkable): classify
-- one job-ability result.
--
-- STATUS (2026-07-29): message IDs CONFIRMED against the Windower/Lua
-- wiki "Message IDs" page (same source as skillchain IDs above) -- see
-- classify.JA_MSG for the full table. Unlike weaponskill (which reuses
-- melee's message vocabulary), job abilities have their OWN distinct
-- message IDs (100-158, 303-305, 317-324, 364-365) not shared with
-- melee/magic/WS at all -- these are genuinely confirmed for job
-- abilities specifically, not corroborated-by-analogy.
--
-- Dispatched via a single message-id -> outcome lookup table
-- (JA_OUTCOME_BY_MSG below) rather than an if/elseif chain, since job
-- abilities have no meaningful PRIORITY ORDER the way melee's
-- defensive chain does (evade/parry/shadows/etc) -- each message id
-- means exactly one thing, unambiguously, with no overlap to resolve.
--
-- damage is taken from add_effect_param... no, from result.param (the
-- same field melee/WS/magic all use for their numeric effect) for
-- every outcome that carries a number (damage, heal amount) -- 0
-- otherwise. Job-specific mechanics with no numeric payload (Steal,
-- Mug, Charm, Treasure Hunter find) always report damage=0; the
-- OUTCOME itself is what carries the meaning, not a number.
--
-- Both offense and defense variants are provided for shape-symmetry
-- with every other classify.* pair in this module, though in practice
-- almost all job abilities are OFFENSE-side (you using your own JA) --
-- a monster using something that resembles a job ability would be
-- unusual and is not specifically verified here.
-- ===========================================================================

classify.JA_OUTCOME_BY_MSG = {
    [classify.JA_MSG.GENERIC_USE]          = classify.OUTCOME.JA_GENERIC_USE,
    [classify.JA_MSG.GENERIC_USE_ON_TARGET] = classify.OUTCOME.JA_GENERIC_USE,

    [classify.JA_MSG.DAMAGE]   = classify.OUTCOME.JA_DAMAGE,
    [classify.JA_MSG.DAMAGE_2] = classify.OUTCOME.JA_DAMAGE,
    -- DAMAGE_SANGE/DAMAGE_BARRAGE dispatch entries REMOVED 2026-07-29
    -- (constants no longer defined -- see classify.JA_MSG comment)

    [classify.JA_MSG.HEAL_TARGET]   = classify.OUTCOME.JA_HEAL,
    -- HEAL_TARGET_2 dispatch entry REMOVED 2026-07-29 (constant no longer defined)
    [classify.JA_MSG.HEAL_TARGET_3] = classify.OUTCOME.JA_HEAL,
    -- HEAL_SELF dispatch entry REMOVED 2026-07-29 (constant no longer defined)

    -- STATUS_LANDED_ATTACK_UP/ACC_UP/EVA_UP dispatch entries REMOVED
    -- 2026-07-29 (constants no longer defined)
    [classify.JA_MSG.STATUS_LANDED]            = classify.OUTCOME.JA_STATUS_LANDED,
    -- STATUS_LANDED_2 dispatch entry REMOVED 2026-07-29 (constant no longer defined)
    [classify.JA_MSG.STATUS_LANDED_ACC_EVA_UP] = classify.OUTCOME.JA_STATUS_LANDED,
    [classify.JA_MSG.STATUS_LANDED_ACC_EVA_UP_NO_ACTOR]      = classify.OUTCOME.JA_STATUS_LANDED,
    [classify.JA_MSG.STATUS_LANDED_ACC_EVA_DOWN]             = classify.OUTCOME.JA_STATUS_LANDED,
    -- STATUS_LANDED_ACC_EVA_DOWN_NO_ACTOR dispatch entry REMOVED 2026-07-29 (constant no longer defined)
    [classify.JA_MSG.STATUS_LANDED_FORTIFY_DEMONS]  = classify.OUTCOME.JA_STATUS_LANDED, -- FIXED 2026-07-29 (was STATUS_LANDED_FORTIFY_UNDEAD)
    [classify.JA_MSG.STATUS_LANDED_FORTIFY_DRAGONS] = classify.OUTCOME.JA_STATUS_LANDED, -- FIXED 2026-07-29 (was STATUS_LANDED_FORTIFY_DRAGON)
    -- STATUS_LANDED_FORTIFY_*_NO_ACTOR dispatch entries REMOVED 2026-07-29 (constants no longer defined -- no real _NO_ACTOR variant exists for FORTIFY)
    [classify.JA_MSG.STATUS_GAINS]    = classify.OUTCOME.JA_STATUS_LANDED,
    [classify.JA_MSG.STATUS_RECEIVES] = classify.OUTCOME.JA_STATUS_LANDED,
    [classify.JA_MSG.STATUS_ALL_PARAMS_BOOSTED]          = classify.OUTCOME.JA_STATUS_LANDED,
    [classify.JA_MSG.STATUS_ALL_PARAMS_BOOSTED_NO_ACTOR] = classify.OUTCOME.JA_STATUS_LANDED,

    [classify.JA_MSG.STATUS_REMOVED_SUCCESS] = classify.OUTCOME.JA_STATUS_REMOVED,
    [classify.JA_MSG.STATUS_WEARS_OFF]       = classify.OUTCOME.JA_STATUS_REMOVED,
    -- STATUS_WEARS_OFF_2 dispatch entry REMOVED 2026-07-29 (constant no longer defined)

    [classify.JA_MSG.NO_EFFECT]   = classify.OUTCOME.JA_NO_EFFECT,
    [classify.JA_MSG.NO_EFFECT_2] = classify.OUTCOME.JA_NO_EFFECT,

    [classify.JA_MSG.MISS]   = classify.OUTCOME.JA_MISS,
    [classify.JA_MSG.MISS_2] = classify.OUTCOME.JA_MISS,

    [classify.JA_MSG.STEAL_SUCCESS] = classify.OUTCOME.JA_STEAL_SUCCESS,
    [classify.JA_MSG.STEAL_FAIL]    = classify.OUTCOME.JA_STEAL_FAIL,

    [classify.JA_MSG.MUG_SUCCESS] = classify.OUTCOME.JA_MUG_SUCCESS,
    [classify.JA_MSG.MUG_FAIL]    = classify.OUTCOME.JA_MUG_FAIL,

    [classify.JA_MSG.CHARM_SUCCESS] = classify.OUTCOME.JA_CHARM_SUCCESS,
    [classify.JA_MSG.CHARM_FAIL]    = classify.OUTCOME.JA_CHARM_FAIL,

    -- FIND_ITEM/FIND_NOTHING dispatch entries REMOVED 2026-07-29 (constants no longer defined)

    -- SELF_BUFF_ONLY/_2/_3 dispatch entries REMOVED 2026-07-29 (constants no longer defined)

    [classify.JA_MSG.PET_POWER_UP] = classify.OUTCOME.JA_PET_POWER_UP,

    -- =======================================================================
    -- Added 2026-07-29 (msg.lua gap-audit) -- see classify.JA_MSG's own
    -- provenance comment. NOT dispatched here (deliberately): the
    -- use-failure/system messages found alongside real vocabulary during
    -- verification -- these confirm an ability COULDN'T be used, not a
    -- landed combat outcome, same category as classify.MSG never
    -- defining REQUIRES_SHIELD/etc (TOO_FAR_AWAY=78 was added 2026-10-29
    -- after it showed up live -- see classify.MSG). If a use-failure signal
    -- becomes useful later, add it as its own deliberate feature, not by
    -- accident here: NO_ELIGIBLE_ROLL(428), ROLL_ALREADY_ACTIVE(429),
    -- SAME_EFFECT_LUOPAN(660), LUOPAN_ALREADY_PLACED(661),
    -- REQUIRE_LUOPAN(662), HAS_LUOPON_NO_USE(665), REQUIRE_RUNE(666).
    -- =======================================================================

    [classify.JA_MSG.CHARM_CANNOT]         = classify.OUTCOME.JA_CHARM_CANNOT,
    [classify.JA_MSG.CHARM_VERY_DIFFICULT] = classify.OUTCOME.JA_CHARM_VERY_DIFFICULT,
    [classify.JA_MSG.CHARM_DIFFICULT]      = classify.OUTCOME.JA_CHARM_DIFFICULT,
    [classify.JA_MSG.CHARM_MIGHT_BE_ABLE]  = classify.OUTCOME.JA_CHARM_MIGHT_BE_ABLE,
    [classify.JA_MSG.CHARM_SHOULD_BE_ABLE] = classify.OUTCOME.JA_CHARM_SHOULD_BE_ABLE,

    -- Folded into the existing JA_STATUS_LANDED bucket, consistent with
    -- how the demons/dragons FORTIFY pair (149/151) is handled above --
    -- these are the same "a status landed" shape, just a different
    -- specific status.
    [classify.JA_MSG.STATUS_LANDED_FORTIFY_UNDEAD] = classify.OUTCOME.JA_STATUS_LANDED,
    [classify.JA_MSG.STATUS_LANDED_FORTIFY_ARCANA] = classify.OUTCOME.JA_STATUS_LANDED,

    [classify.JA_MSG.JA_ATK_ENHANCED]  = classify.OUTCOME.JA_ATK_ENHANCED,
    [classify.JA_MSG.TP_INCREASE]      = classify.OUTCOME.JA_TP_INCREASE,
    [classify.JA_MSG.MAGIC_STEAL]      = classify.OUTCOME.JA_MAGIC_STEAL,
    [classify.JA_MSG.MAGIC_TP_REDUCE]  = classify.OUTCOME.JA_MAGIC_TP_REDUCE,
    [classify.JA_MSG.JA_RECOVERS_MP]   = classify.OUTCOME.JA_RECOVERS_MP,
    [classify.JA_MSG.WILD_FLOURISH_TP] = classify.OUTCOME.JA_WILD_FLOURISH_TP,
    [classify.JA_MSG.STEAL_EFFECT]     = classify.OUTCOME.JA_STEAL_EFFECT,
    [classify.JA_MSG.MAGIC_ABSORB_TP]  = classify.OUTCOME.JA_MAGIC_ABSORB_TP,
    [classify.JA_MSG.JA_TH_EFFECTIVENESS] = classify.OUTCOME.JA_TH_EFFECTIVENESS,
    [classify.JA_MSG.JA_ENMITY_DECREASE]  = classify.OUTCOME.JA_ENMITY_DECREASE,

    [classify.JA_MSG.ROLL_MAIN]         = classify.OUTCOME.JA_ROLL_MAIN,
    [classify.JA_MSG.ROLL_SUB]          = classify.OUTCOME.JA_ROLL_SUB,
    [classify.JA_MSG.ROLL_MAIN_FAIL]    = classify.OUTCOME.JA_ROLL_MAIN_FAIL,
    [classify.JA_MSG.ROLL_SUB_FAIL]     = classify.OUTCOME.JA_ROLL_SUB_FAIL,
    [classify.JA_MSG.DOUBLEUP]          = classify.OUTCOME.JA_DOUBLEUP,
    [classify.JA_MSG.DOUBLEUP_FAIL]     = classify.OUTCOME.JA_DOUBLEUP_FAIL,
    [classify.JA_MSG.DOUBLEUP_BUST]     = classify.OUTCOME.JA_DOUBLEUP_BUST,
    [classify.JA_MSG.DOUBLEUP_BUST_SUB] = classify.OUTCOME.JA_DOUBLEUP_BUST_SUB,

    [classify.JA_MSG.DESPOIL_ATT_DOWN]  = classify.OUTCOME.JA_DESPOIL_ATT_DOWN,
    [classify.JA_MSG.DESPOIL_DEF_DOWN]  = classify.OUTCOME.JA_DESPOIL_DEF_DOWN,
    [classify.JA_MSG.DESPOIL_MATT_DOWN] = classify.OUTCOME.JA_DESPOIL_MATT_DOWN,
    [classify.JA_MSG.DESPOIL_MDEF_DOWN] = classify.OUTCOME.JA_DESPOIL_MDEF_DOWN,
    [classify.JA_MSG.DESPOIL_EVA_DOWN]  = classify.OUTCOME.JA_DESPOIL_EVA_DOWN,
    [classify.JA_MSG.DESPOIL_ACC_DOWN]  = classify.OUTCOME.JA_DESPOIL_ACC_DOWN,
    [classify.JA_MSG.DESPOIL_SLOW]      = classify.OUTCOME.JA_DESPOIL_SLOW,

    [classify.JA_MSG.LUOPAN_HP_RATE_DOWN] = classify.OUTCOME.JA_LUOPAN_HP_RATE_DOWN,
    [classify.JA_MSG.LUOPAN_HP_RATE_UP]   = classify.OUTCOME.JA_LUOPAN_HP_RATE_UP,
    [classify.JA_MSG.SWORDPLAY_GAIN]      = classify.OUTCOME.JA_SWORDPLAY_GAIN,
    [classify.JA_MSG.VALLATION_GAIN]      = classify.OUTCOME.JA_VALLATION_GAIN,
    [classify.JA_MSG.VALIANCE_GAIN_PARTY] = classify.OUTCOME.JA_VALIANCE_GAIN_PARTY,
    [classify.JA_MSG.LIEMENT_GAIN]        = classify.OUTCOME.JA_LIEMENT_GAIN,
    [classify.JA_MSG.PFLUG_GAIN]          = classify.OUTCOME.JA_PFLUG_GAIN,
    [classify.JA_MSG.GAMBIT_GAIN]         = classify.OUTCOME.JA_GAMBIT_GAIN,

    -- 2026-10-29 (see classify.JA_MSG's 2026-10-29 note)
    [classify.JA_MSG.HEAL_TARGET_AOE] = classify.OUTCOME.JA_HEAL,
    [classify.JA_MSG.DAZE_LETHARGIC]  = classify.OUTCOME.JA_DAZE_LANDED,
    [classify.JA_MSG.NO_MESSAGE]      = classify.OUTCOME.JA_NO_MESSAGE,
};

-- 2026-10-29: outcomes whose `param` is NOT a damage/heal number. Live
-- capture showed Steal success exporting damage=864/936 -- those are
-- ITEM IDs (864 = fish scales, matching "Steal -> Greater Pugil (handful
-- of fish scales)"). Status-landed params are status IDs the same way.
-- Each entry names the field the param moves to; damage becomes 0.
-- Only covers cases where the log confirmed (or the message text itself
-- states) what param is -- everything else keeps param-as-damage.
classify.JA_PARAM_FIELD_BY_OUTCOME = {
    [classify.OUTCOME.JA_STEAL_SUCCESS] = 'itemId',
    [classify.OUTCOME.JA_STEAL_FAIL]    = 'itemId', -- param was 936 on one fail, 0 on the other; kept off damage either way
    [classify.OUTCOME.JA_STATUS_LANDED] = 'statusId',
    [classify.OUTCOME.JA_STATUS_REMOVED] = 'statusId',
    [classify.OUTCOME.JA_DAZE_LANDED]   = 'effectLevel',
    [classify.OUTCOME.JA_NO_MESSAGE]    = 'effectParam',
};

-- Shared dispatch body for both offense and defense -- job abilities
-- have no offense/defense-specific priority-order logic the way melee
-- does, so both sides genuinely share one implementation (unlike
-- weaponskillOffense/Defense, which are separate wrapper functions
-- for API-shape symmetry -- here there's only one body since there's
-- no side-specific branching to keep separate).
local function classifyJobAbility(result)
    local outcome = classify.JA_OUTCOME_BY_MSG[result.message];
    if outcome == nil then
        -- An unrecognized job-ability message id -- NOT silently
        -- discarded, same "capture, don't drop" discipline as every
        -- other classify.* function in this module. Given the JA
        -- message space is known to be broad and only partially
        -- enumerated here (this covers every JA-shaped message found
        -- in the Windower wiki table, but that table itself may not be
        -- perfectly exhaustive, and CatsEyeXI could differ), a real
        -- UNKNOWN case here is expected to happen sometimes, not a bug
        -- signal the way an UNKNOWN melee swing would be.
        return classify.OUTCOME.UNKNOWN, 0, unknownRaw(result);
    end
    local paramField = classify.JA_PARAM_FIELD_BY_OUTCOME[outcome];
    if paramField ~= nil then
        return outcome, 0, { [paramField] = result.param };
    end
    return outcome, result.param or 0;
end

---@param result table  one job-ability result (same shape as classify.offense)
---@return string outcome, number damage, table|nil raw
function classify.jobAbilityOffense(result)
    return classifyJobAbility(result);
end

---@param result table  one job-ability result (same shape as classify.defense)
---@return string outcome, number damage, table|nil raw
function classify.jobAbilityDefense(result)
    return classifyJobAbility(result);
end

-- ===========================================================================
-- RANGED (category 2 finish): classify one ranged-attack result.
--
-- STATUS (2026-07-29): message IDs CONFIRMED against the Windower/Lua
-- wiki (same source as job ability/skillchain IDs). RANGEHIT(352)/
-- RANGECRIT(353)/RANGEMISS(354) were already vendored in
-- packet_ground_truth.md from the original Metrics-based research;
-- RANGE_NO_EFFECT(355) and RANGE_MOBHEAL(382) are NEW this session,
-- confirmed the same way as the job-ability/skillchain additions
-- above. Deliberately NOT reusing melee's outcome names (HIT/CRIT/MISS)
-- -- see classify.OUTCOME's own RANGED_* comment for why.
--
-- Simpler than melee's defensive chain -- no separate guard/shield-
-- block/parry mitigation mechanics are documented for ranged attacks,
-- so this is a flat message-id lookup, not a priority-ordered chain.
-- SQUARE(576)/TRUE(577) (Daken throwing-weapon variants) are NOT
-- folded in here -- they were already vendored as generic "ranged/
-- throwing hit" concepts in packet_ground_truth.md's own message table,
-- but Daken is a NIN ranged-adjacent mechanic on category 1 (melee),
-- not category 2 -- out of scope for this function specifically.
-- ===========================================================================

local RANGED_OUTCOME_BY_MSG = {
    [classify.MSG.RANGEHIT]         = classify.OUTCOME.RANGED_HIT,
    [classify.MSG.RANGECRIT]        = classify.OUTCOME.RANGED_CRIT,
    [classify.MSG.RANGEMISS]        = classify.OUTCOME.RANGED_MISS,
    [classify.MSG.RANGE_NO_EFFECT]  = classify.OUTCOME.RANGED_NO_EFFECT,
    -- [classify.MSG.RANGE_MOBHEAL]    = classify.OUTCOME.RANGED_MOB_HEAL,
    -- DISABLED 2026-07-29: classify.MSG.RANGE_MOBHEAL (id 382) was
    -- fabricated -- no real xi.msg.basic entry found under any name.
    -- classify.OUTCOME.RANGED_MOB_HEAL stays defined (still a valid
    -- outcome name) but is currently unreachable from this dispatch.
};

local function classifyRanged(result)
    local outcome = RANGED_OUTCOME_BY_MSG[result.message];
    if outcome == nil then
        return classify.OUTCOME.UNKNOWN, 0, unknownRaw(result);
    end
    return outcome, result.param or 0;
end

---@param result table  one ranged-attack result (same shape as classify.offense)
---@return string outcome, number damage, table|nil raw
function classify.rangedOffense(result)
    return classifyRanged(result);
end

---@param result table  one ranged-attack result (same shape as classify.defense) -- a monster's ranged attack on the player is UNVERIFIED to even exist as a real gameplay case; provided for shape-symmetry only.
---@return string outcome, number damage, table|nil raw
function classify.rangedDefense(result)
    return classifyRanged(result);
end

-- ===========================================================================
-- PET TP MOVE (category 13): classify one hit of a pet's TP move.
--
-- STATUS (2026-07-29): GENUINELY LESS CONFIRMED than every other
-- classify.* function in this module -- flagged explicitly rather than
-- presented with false confidence. Per the Windower/Lua wiki's own
-- "Action Category 13" page: "Category for the execution of pet TP
-- moves... reaction: 8 may indicate success and 9 may indicate failure
-- (like hit and miss for Action Category 01)" -- that page's own
-- hedging ("may indicate") is the ENTIRE evidentiary basis for this
-- function's reaction-based branch. This is meaningfully weaker
-- evidence than weaponskill's corroboration (which had two independent
-- sources agreeing on a shared message-vocabulary claim) or job
-- ability's (a direct, confident message-id-to-text mapping) --
-- treat this whole function as a first suspect for ANY pet-related
-- classification bug, more so than any other category built so far.
--
-- Message-id vocabulary: REVISED 2026-07-29 (gap-fix follow-up) after
-- real in-game capture data falsified the previous approach. The prior
-- version fell through to classify.offense/defense (melee's HIT/MISS/
-- CRIT message IDs) whenever reaction wasn't 8/9 -- but 21/21 real
-- category-13 events had reaction=0 (never 8 or 9) and message=317,
-- which melee's classify.offense/defense has no branch for -- hence
-- the 100% UNKNOWN result the project file flagged. See
-- classify.PET_TP_MSG's own header for the full evidence and why 317
-- specifically is used. The reaction 8/9 check is kept and still
-- checked FIRST (harmless -- it simply won't fire given real data so
-- far, but is retained in case some other pet TP move genuinely uses
-- it), THEN the confirmed PET_TP_MSG vocabulary is checked, THEN
-- UNKNOWN with a raw capture -- melee's classify.offense/defense is no
-- longer consulted at all for this category, since real data shows its
-- message space doesn't apply here.
-- ===========================================================================

local function classifyPetTpMove(result)
    if result.reaction == classify.PET_REACTION.LIKELY_SUCCESS then
        return classify.OUTCOME.PET_TP_MOVE_LIKELY_SUCCESS, result.param or 0;
    end
    if result.reaction == classify.PET_REACTION.LIKELY_FAILURE then
        return classify.OUTCOME.PET_TP_MOVE_LIKELY_FAILURE, 0;
    end
    if result.message == classify.PET_TP_MSG.DAMAGE then
        return classify.OUTCOME.PET_TP_MOVE_DAMAGE, result.param or 0;
    end
    -- Not silently discarded -- an unrecognized category-13 message is
    -- genuinely expected sometimes given how little of this category's
    -- vocabulary has been observed so far (only DAMAGE/317 confirmed).
    return classify.OUTCOME.UNKNOWN, 0, unknownRaw(result);
end

function classify.petTpMoveOffense(result)
    return classifyPetTpMove(result);
end

function classify.petTpMoveDefense(result)
    return classifyPetTpMove(result);
end

-- ===========================================================================
-- MAGIC (category 4 finish): classify one spell-resolution result.
--
-- STATUS (2026-07-29): message IDs CONFIRMED against the Windower/Lua
-- wiki (same source as skillchain/job-ability/ranged IDs above) -- see
-- classify.MAGIC_MSG for the full table. This is the WIDEST and
-- messiest message vocabulary built for this project so far (~48
-- distinct IDs across 12 semantic groups) -- see MAGIC_MSG's own
-- header for the grouping rationale and the open question about why
-- so many outcomes have a "with cast-prefix" and "without cast-prefix"
-- pair of message IDs (not yet investigated -- possibly different
-- packet paths for the initial hit vs. an AoE tick, possibly something
-- else entirely).
--
-- Dispatched via a single message-id -> outcome lookup table
-- (MAGIC_OUTCOME_BY_MSG below), same "no meaningful priority order,
-- each message means exactly one thing" reasoning as job ability's
-- dispatch (see classifyJobAbility's own comment).
--
-- Stat-absorb messages (ABSORB_STR..CHR, 329-335) are handled as a
-- SEPARATE branch, not folded into the generic lookup table, since
-- they all share the same MAGIC_ABSORB_STAT outcome but need a `stat`
-- field in their raw envelope to say WHICH stat was drained -- the
-- generic lookup table has no mechanism for attaching extra
-- per-message context like that.
--
-- damage is taken from result.param for every outcome that carries a
-- numeric effect (damage, heal, drain amount) -- 0 otherwise, same
-- convention as every other classify.* function in this module.
-- ===========================================================================

local MAGIC_OUTCOME_BY_MSG = {
    [classify.MAGIC_MSG.DAMAGE]           = classify.OUTCOME.MAGIC_DAMAGE,
    [classify.MAGIC_MSG.DAMAGE_NO_PREFIX] = classify.OUTCOME.MAGIC_DAMAGE,

    [classify.MAGIC_MSG.BURST_DAMAGE]           = classify.OUTCOME.MAGIC_BURST_DAMAGE,
    -- BURST_DAMAGE_NO_PREFIX dispatch entry REMOVED 2026-07-29 (constant no longer defined)
    [classify.MAGIC_MSG.BURST_DAMAGE_FROM_JA]   = classify.OUTCOME.MAGIC_BURST_DAMAGE,

    [classify.MAGIC_MSG.HEAL]           = classify.OUTCOME.MAGIC_HEAL,
    [classify.MAGIC_MSG.HEAL_NO_PREFIX] = classify.OUTCOME.MAGIC_HEAL,

    -- STATUS_LANDED_BANG dispatch entry REMOVED 2026-07-29 (constant no longer defined)
    [classify.MAGIC_MSG.STATUS_GAINS]              = classify.OUTCOME.MAGIC_STATUS_LANDED,
    [classify.MAGIC_MSG.STATUS_LANDED]             = classify.OUTCOME.MAGIC_STATUS_LANDED,
    [classify.MAGIC_MSG.STATUS_RECEIVES]           = classify.OUTCOME.MAGIC_STATUS_LANDED,
    -- STATUS_GAINS_NO_PREFIX/STATUS_RECEIVES_NO_PREFIX dispatch entries REMOVED 2026-07-29 (constants moved out -- real IDs belong to JA messages, not magic; see classify.MAGIC_MSG comment)
    [classify.MAGIC_MSG.STATUS_LANDED_NO_PREFIX]   = classify.OUTCOME.MAGIC_STATUS_LANDED,
    [classify.MAGIC_MSG.STATUS_GAINS_AOE]          = classify.OUTCOME.MAGIC_STATUS_LANDED, -- 2026-10-29
    -- STATUS_RECEIVES_NO_PREFIX_2/STATUS_LANDED_NO_PREFIX_2/STATUS_GAINS_NO_PREFIX_2 dispatch entries REMOVED 2026-07-29 (constants no longer defined)

    [classify.MAGIC_MSG.BURST_STATUS_RECEIVES]           = classify.OUTCOME.MAGIC_BURST_STATUS_LANDED,
    -- BURST_STATUS_RECEIVES_NO_PREFIX dispatch entry REMOVED 2026-07-29 (constant no longer defined)
    [classify.MAGIC_MSG.BURST_STATUS_LANDED]             = classify.OUTCOME.MAGIC_BURST_STATUS_LANDED,
    -- BURST_STATUS_LANDED_NO_PREFIX dispatch entry REMOVED 2026-07-29 (constant no longer defined)

    [classify.MAGIC_MSG.DRAIN_HP]           = classify.OUTCOME.MAGIC_DRAIN_HP,
    -- DRAIN_HP_NO_PREFIX dispatch entry REMOVED 2026-07-29 (constant no longer defined)
    [classify.MAGIC_MSG.DRAIN_MP]           = classify.OUTCOME.MAGIC_DRAIN_MP,
    -- DRAIN_MP_NO_PREFIX/BURST_DRAIN_HP/BURST_DRAIN_MP dispatch entries REMOVED 2026-07-29 (constants no longer defined)

    [classify.MAGIC_MSG.NO_EFFECT]         = classify.OUTCOME.MAGIC_NO_EFFECT,
    [classify.MAGIC_MSG.NO_EFFECT_NO_PREFIX] = classify.OUTCOME.MAGIC_NO_EFFECT,
    [classify.MAGIC_MSG.RESIST]            = classify.OUTCOME.MAGIC_RESIST,
    [classify.MAGIC_MSG.RESIST_NO_PREFIX]  = classify.OUTCOME.MAGIC_RESIST,
    [classify.MAGIC_MSG.EFFECT_FAIL]       = classify.OUTCOME.MAGIC_EFFECT_FAIL,
    [classify.MAGIC_MSG.EVADES]            = classify.OUTCOME.MAGIC_EVADES,

    [classify.MAGIC_MSG.ERASE]            = classify.OUTCOME.MAGIC_ERASE,
    -- ERASE_2/ERASE_NO_PREFIX/ERASE_NO_PREFIX_2 dispatch entries REMOVED 2026-07-29 (constants no longer defined)

    [classify.MAGIC_MSG.VANISHES]           = classify.OUTCOME.MAGIC_VANISHES,
    -- VANISHES_NO_PREFIX dispatch entry REMOVED 2026-07-29 (constant no longer defined)
    [classify.MAGIC_MSG.FALLS_TO_GROUND]    = classify.OUTCOME.MAGIC_FALLS_TO_GROUND, -- FIXED 2026-07-29: MAGIC_MSG.FALLS_TO_GROUND now points at the real ID (20)

    -- GENERIC_CAST_ON_TARGET dispatch entry REMOVED 2026-07-29 (constant no longer defined -- GENERIC_CAST_ON_TARGET_2 below already covers this concept with a real ID)
    [classify.MAGIC_MSG.GENERIC_CAST_ON_TARGET_2] = classify.OUTCOME.MAGIC_GENERIC_CAST,

    -- Added 2026-07-29 (msg.lua gap-audit)
    [classify.MAGIC_MSG.REMOVE_EFFECT]       = classify.OUTCOME.MAGIC_REMOVE_EFFECT,
    [classify.MAGIC_MSG.REMOVE_EFFECT_COUNT] = classify.OUTCOME.MAGIC_REMOVE_EFFECT_COUNT,
    [classify.MAGIC_MSG.ABSORB_AILMENT]      = classify.OUTCOME.MAGIC_ABSORB_AILMENT,
};

-- Stat-absorb message -> stat name, kept separate from
-- MAGIC_OUTCOME_BY_MSG (see function header above for why).
local MAGIC_ABSORB_STAT_BY_MSG = {
    [classify.MAGIC_MSG.ABSORB_STR] = 'STR',
    [classify.MAGIC_MSG.ABSORB_DEX] = 'DEX',
    [classify.MAGIC_MSG.ABSORB_VIT] = 'VIT',
    [classify.MAGIC_MSG.ABSORB_AGI] = 'AGI',
    [classify.MAGIC_MSG.ABSORB_INT] = 'INT',
    [classify.MAGIC_MSG.ABSORB_MND] = 'MND',
    [classify.MAGIC_MSG.ABSORB_CHR] = 'CHR',
};

local function classifyMagic(result)
    local msg = result.message;

    local statName = MAGIC_ABSORB_STAT_BY_MSG[msg];
    if statName ~= nil then
        return classify.OUTCOME.MAGIC_ABSORB_STAT, result.param or 0, { stat = statName };
    end

    local outcome = MAGIC_OUTCOME_BY_MSG[msg];
    if outcome == nil then
        -- An unrecognized magic message id -- NOT silently discarded.
        -- Given magic's message space is the widest and least
        -- exhaustively enumerated of any category built so far, a real
        -- UNKNOWN case here is genuinely expected sometimes (e.g.
        -- job-specific or spell-specific message variants not covered
        -- by the Windower wiki table, or CatsEyeXI-specific
        -- differences), not necessarily a bug signal.
        return classify.OUTCOME.UNKNOWN, 0, unknownRaw(result);
    end
    -- 2026-10-29: status-type outcomes carry a STATUS ID in param, not a
    -- number to total. Previously exported as damage (e.g. a Protect
    -- landing would have read as "40 damage").
    if outcome == classify.OUTCOME.MAGIC_STATUS_LANDED
        or outcome == classify.OUTCOME.MAGIC_BURST_STATUS_LANDED
        or outcome == classify.OUTCOME.MAGIC_REMOVE_EFFECT
        or outcome == classify.OUTCOME.MAGIC_ERASE then
        return outcome, 0, { statusId = result.param };
    end
    return outcome, result.param or 0;
end

---@param result table  one magic result (same shape as classify.offense)
---@return string outcome, number damage, table|nil raw
function classify.magicOffense(result)
    return classifyMagic(result);
end

---@param result table  one magic result (same shape as classify.defense) -- a monster casting a spell on the player IS a real, common case (mob nukes/debuffs) -- unlike ranged/pet-TP-move's defense variants, this side is expected to see real traffic.
---@return string outcome, number damage, table|nil raw
function classify.magicDefense(result)
    return classifyMagic(result);
end

-- ===========================================================================
-- ITEM USE (category 5 finish): classify one item-use result.
--
-- STATUS (2026-07-29, gap-audit follow-up): message IDs CONFIRMED
-- against the Windower/Lua wiki (same source as everything else this
-- session). Small vocabulary (5 messages) -- item use rarely produces
-- combat-relevant numeric effects the way magic/JA do; most items used
-- in combat (Remedies, Silent Oils, Holy Water, etc) either land a
-- status effect, dispel one, or grant/consume an item, none of which
-- carry a `param` damage/heal number the way HIT/JA_DAMAGE/MAGIC_HEAL
-- do. Genuine miss earlier this session -- see classify.ITEM_MSG's own
-- header for why category 5 was originally (incorrectly) treated as a
-- no-op start-category.
-- ===========================================================================

local ITEM_OUTCOME_BY_MSG = {
    [classify.ITEM_MSG.GENERIC_USE]    = classify.OUTCOME.ITEM_GENERIC_USE,
    [classify.ITEM_MSG.STATUS_RECEIVES] = classify.OUTCOME.ITEM_STATUS_LANDED,
    [classify.ITEM_MSG.OBTAIN_ITEM]      = classify.OUTCOME.ITEM_OBTAIN,
    [classify.ITEM_MSG.OBTAIN_ITEM_2]     = classify.OUTCOME.ITEM_OBTAIN,
    [classify.ITEM_MSG.STATUS_DISAPPEARS]  = classify.OUTCOME.ITEM_STATUS_REMOVED,
};

local function classifyItemUse(result)
    local outcome = ITEM_OUTCOME_BY_MSG[result.message];
    if outcome == nil then
        return classify.OUTCOME.UNKNOWN, 0, unknownRaw(result);
    end
    return outcome, result.param or 0;
end

---@param result table  one item-use result (same shape as classify.offense)
---@return string outcome, number damage, table|nil raw
function classify.itemUseOffense(result)
    return classifyItemUse(result);
end

---@param result table  one item-use result (same shape as classify.defense) -- a monster using an item on the player is UNVERIFIED to even exist as a real gameplay case; provided for shape-symmetry only.
---@return string outcome, number damage, table|nil raw
function classify.itemUseDefense(result)
    return classifyItemUse(result);
end

return classify;


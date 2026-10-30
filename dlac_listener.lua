--[[
mobparser -- dlac_listener.lua

Consumes dlac's live equipset stream (plugin_event broadcast, channel
names dlac_worn / dlac_dispatch / dlac_invalidate / dlac_confirm) and
provides mobparser's combat pipeline a way to answer "what was
equipped, for THIS action, at THIS swing" -- see mobparser_PROJECT.md
"Equipset tracking" section for the full design history and the
dlac integration-guide.md this is built against (received 2026-07-28,
transport probe-verified by dlac's own maintainer).

FRESHLY WRITTEN. Not copied from LuaAshitacast's integration.lua or any
other addon -- the guide's own minimal-consumer example (its section 4)
was read as a reference for SHAPE, not copied verbatim; join-key logic,
ring buffer, and query plumbing below are this project's own
implementation against the documented contract.

Split into the same two layers as combat_router.lua, for the same
reason:
  - PURE LOGIC (decode, ring buffer, backwards-search join,
    invalidate/confirm bookkeeping) -- no Ashita API calls beyond what's
    passed in, fully unit-testable offline against synthetic envelopes
    (see test_dlac_listener.lua).
  - ASHITA-FACING GLUE (dlac_listener.ashita.*) -- actually registers
    the plugin_event handler and calls
    AshitaCore:GetPluginManager():RaiseEvent(...) to send queries.
    UNTESTED OFFLINE, same caveat as combat_router.ashita.* and
    unknownlog.ashita.* -- needs in-game verification.

Scope, per project file + guide: v1 only. `worn` + `dispatch` anchors
for the join, `invalidate`/`confirm` bookkeeping per the guide's
gotchas list, `ctx`/`totals` stored and passed through unexamined
(mobparser doesn't need to interpret them yet), `by` intentionally NOT
read (deferred/additive on dlac's side; nothing here assumes it exists).
Reference-data queries (`gear`/`sets`/`item`/`stats`) are NOT
implemented in this file -- only the `worn` bootstrap query, which is
the one thing v1 of mobparser's join logic actually needs. Extending to
the other queries is a separate, later task if a concrete use for them
shows up (same "don't build ahead of a named need" discipline the guide
itself asks for regarding the `by` rule-match trace).
]]

local dlac_listener = {};

-- ===========================================================================
-- Constants -- vendored from integration-guide.md, not guessed.
-- ===========================================================================

-- actionCategory values the guide documents (integration-guide.md §2.3).
-- NOTE: these are dlac's OWN action-category numbering for the outgoing
-- 0x01A packet, NOT the same enumeration as packet_ground_truth.md's
-- combat_router.CATEGORY (which describes the INCOMING 0x028 result
-- packet's category field). Do not conflate the two -- see "Join key
-- caveat" comment on dlac_listener.compositionFor below.
dlac_listener.ACTION_CATEGORY = {
    SPELL = 0x03,
    WEAPONSKILL = 0x07,
    ABILITY = 0x09,
    RANGED = 0x10,
};

-- Ring buffer size -- guide's own recommendation (§2.4: "a ring of 64 is
-- plenty").
dlac_listener.RING_SIZE = 64;

-- ===========================================================================
-- PURE LOGIC -- no Ashita dependency, fully testable offline.
-- ===========================================================================

-- Decodes ONE already-fetched payload string (the Lua-source `return
-- { ... }` body) into a table. Kept separate from the Ashita-facing
-- byte/userdata unwrapping (dlac_listener.ashita.decode) so this half
-- can be exercised offline with a plain string, matching this
-- project's established pattern (e.g. packet_action.parse taking raw
-- bytes vs. combat_router.handlePacket doing the Ashita-facing part).
--
-- Per the guide's own decode() reference (§2.2): the payload is Lua
-- source. `load`/`loadstring` + pcall, exactly as documented -- no
-- reason to deviate here, this isn't a case where "verify against real
-- precedent" applies differently (the guide's own author IS the real
-- precedent for this specific wire format).
---@param payloadString string  the decoded Lua-source `return {...}` body
---@return table|nil  the envelope table, or nil on any decode failure
function dlac_listener.decodePayloadString(payloadString)
    if type(payloadString) ~= 'string' then
        return nil;
    end
    local chunk = (loadstring or load)(payloadString);
    if chunk == nil then
        return nil;
    end
    local ok, t = pcall(chunk);
    if not ok or type(t) ~= 'table' then
        return nil;
    end
    return t;
end

-- Creates a new, empty listener state. Kept as an explicit object
-- (rather than module-level mutable state) so offline tests can create
-- multiple independent instances without cross-contaminating -- same
-- reasoning as unknownlog.lua's `seen` accumulator, made a bit more
-- explicit here since dlac_listener also needs revision-cache state.
---@return table  a new listener state
function dlac_listener.newState()
    return {
        ring = {},           -- array of envelopes, newest last, capped at RING_SIZE
        rev = { sets = nil, job = nil },  -- last-known invalidate revisions, per guide §3/§2.5
        lastSnapshotSeq = nil,
        -- mergedWorn: the running FULL 16-slot picture, maintained by
        -- folding each worn envelope's (possibly PARTIAL) slot entries
        -- on top of what's already known -- see the 2026-07-28
        -- "partial worn table" fix note on onEnvelope below for why
        -- this exists. nil until the first worn envelope of any kind
        -- (including a snapshot) is seen.
        mergedWorn = nil,
    };
end

-- Appends one envelope to the ring, evicting the oldest if over
-- capacity. Internal helper, not part of the public per-envelope
-- dispatch below (kept separate so test_dlac_listener.lua can exercise
-- ring behavior in isolation from decode/dispatch).
---@param state table  from dlac_listener.newState()
---@param env table  a decoded envelope
local function remember(state, env)
    table.insert(state.ring, env);
    if #state.ring > dlac_listener.RING_SIZE then
        table.remove(state.ring, 1);
    end
end

-- Handles ONE decoded envelope, per its `kind`. This is the pure-logic
-- heart of the module -- mirrors the guide's own §4 `onEnv` example,
-- but written independently against the documented contract (guide's
-- version is a minimal illustration, not something to copy verbatim;
-- this version also tracks state.rev and state.lastSnapshotSeq
-- explicitly, which the guide's example only gestures at).
--
-- Per-kind handling, all per guide §2.5 (cited inline, not re-derived):
--   'worn'       -- a real composition change. Goes in the ring.
--   'dispatch'   -- a positive "nothing moved" anchor. Goes in the ring
--                   (guide §2.4: "match your actionId against dispatch
--                   envelopes too"). NOT a worn table, must not be
--                   treated as one by callers.
--   'invalidate' -- cache-staleness signal, NOT a ring entry (nothing to
--                   join against a stat regression). Updates state.rev
--                   per guide §2.5's exact two-key description (sets,
--                   job) -- does NOT invent handling for gear/item revs,
--                   which the guide explicitly says are "v2" (not yet
--                   real) and rev=0 always in v1.
--   'confirm'    -- delta-only correction to an earlier 'worn'. Per
--                   guide §2.5 and the still-OPEN item flagged in the
--                   project file: v1 of this module does NOT retroactively
--                   patch an already-in-ring 'worn' envelope with the
--                   confirm delta (that's project file open-item (b),
--                   "hold samples briefly and apply confirm delta" --
--                   explicitly deferred, not decided). This function
--                   still records confirm envelopes into the ring
--                   (tagged by kind, same as worn/dispatch) so a FUTURE
--                   pass can implement (b) without re-plumbing the
--                   transport layer -- but nothing downstream currently
--                   reads or applies them. Flagged here so this doesn't
--                   look like silent data loss: it's deliberately inert
--                   pending that open decision, not a bug.
--
-- `dropped > 0` and `seq` discontinuities (guide §2.5, "two signals for
-- two different failures... re-pull, never interpolate") are NOT
-- handled inside this function -- they require issuing a query, which
-- is an Ashita-facing side effect. This function returns a boolean
-- `needsResync` instead, so the pure layer stays side-effect-free and
-- the Ashita glue decides what to do with that signal (matches this
-- project's established split -- see combat_router.route vs.
-- combat_router.handlePacket for the same shape of division).
---@param state table  from dlac_listener.newState()
---@param env table  a decoded envelope (any kind)
---@return boolean  needsResync -- true if the caller should issue a fresh 'worn' query
function dlac_listener.onEnvelope(state, env)
    if env.v ~= 1 then
        -- "refuse anything with a major you don't know" -- guide §2.3.
        -- Not an error, just an envelope this version of the module
        -- doesn't understand yet -- ignored, not logged as UNKNOWN (this
        -- is a different failure category from classify.lua's UNKNOWN
        -- capture; that's for combat message IDs we don't recognize,
        -- this is a version mismatch on an entirely different channel).
        return false;
    end

    local needsResync = false;
    if env.dropped ~= nil and env.dropped > 0 then
        needsResync = true;
    end

    if env.kind == 'invalidate' then
        -- Per guide §2.5: v1 only reports 'sets' and 'job' as changed
        -- keys, with rev = { sets = <n> } and a top-level `job` field.
        -- Does not touch the ring -- nothing to join a stat regression
        -- against here.
        if env.rev ~= nil and env.rev.sets ~= nil then
            state.rev.sets = env.rev.sets;
        end
        if env.job ~= nil then
            state.rev.job = env.job;
        end
        return needsResync;
    end

    if env.kind == 'worn' or env.kind == 'dispatch' or env.kind == 'confirm' then
        -- snapshot=true bookkeeping (guide §2.5: "a re-sync envelope is
        -- NOT a gear change" -- tracked here so callers can distinguish
        -- "this ring entry is a real change" from "this ring entry is a
        -- state dump" without re-deriving it from context every time).
        if env.snapshot == true then
            state.lastSnapshotSeq = env.seq;
        end

        -- BUGFIX (2026-07-28, discovered from real session data during
        -- the first successful live test): a 'worn' envelope's `worn`
        -- table is NOT guaranteed to be a full 16-slot picture -- real
        -- captured data showed one envelope with only `Main` populated,
        -- a later one with only `Ammo`, alternating, for the SAME
        -- fight/composition. integration-guide.md is consistent with
        -- this on a close re-read: `snapshot=true` is specifically
        -- called out as a "full envelope"/"state dump" (§2.6, §2.5),
        -- which only makes sense as a meaningful distinction if an
        -- ordinary (snapshot=false) `worn` can be partial -- i.e. only
        -- the slot(s) that actually changed in that decision. The
        -- ORIGINAL version of this function (and combat_router.lua's
        -- buildGearTag, which reads env.worn directly) assumed every
        -- worn envelope was a complete snapshot -- wrong, and it
        -- produced exactly the alternating-slot symptom seen in the
        -- real debug_log.txt. Fixed by maintaining a running merged
        -- picture here: each worn envelope's slots overlay ON TOP of
        -- whatever was already known, rather than replacing it
        -- wholesale. A snapshot=true envelope, being explicitly a full
        -- dump, is safe to treat the same way (its slots simply
        -- overwrite everything, which is correct for a full dump too).
        if env.kind == 'worn' and env.worn ~= nil then
            if state.mergedWorn == nil then
                state.mergedWorn = {};
            end
            for slot, item in pairs(env.worn) do
                state.mergedWorn[slot] = item;
            end
        end

        remember(state, env);
        return needsResync;
    end

    -- Unrecognized kind -- per the guide's own stated design ("adding a
    -- field can never break you... never assume the set of keys is
    -- closed"), an unknown KIND (not just an unknown field) is treated
    -- the same way: ignored, not an error, not silently mis-bucketed
    -- into worn/dispatch/confirm. Still goes through the dropped-based
    -- resync check above since that's orthogonal to knowing the kind.
    return needsResync;
end

-- The join itself -- given an actionId + actionCategory from mobparser's
-- OWN combat-packet parsing (packet_action.lua's action.cmd_arg /
-- action.category, NOT dlac's action-category enum, see caveat below),
-- searches the ring backwards for the matching anchor, per guide §2.4's
-- exact algorithm (reimplemented here against the documented contract,
-- not copied from the guide's illustrative snippet).
--
-- JOIN KEY CAVEAT, IMPORTANT: mobparser's own packet_action.lua parses
-- the INCOMING 0x028 result packet, whose `category` field is
-- documented in packet_ground_truth.md (1=melee, 2=ranged finish,
-- 3=weaponskill, 4=magic finish, etc -- combat_router.CATEGORY). dlac's
-- `actionCategory` in the envelope is documented in THIS guide (§2.3) as
-- coming off the OUTGOING 0x01A packet, using a DIFFERENT enumeration
-- (0x03 Spell, 0x07 WS, 0x09 Ability, 0x10 Ranged). These are not
-- guaranteed to be the same numbering scheme, even though some values
-- look superficially similar (e.g. WEAPONSKILL=3 on the 0x028 side vs
-- WEAPONSKILL=0x07 on dlac's side -- genuinely different numbers, not a
-- typo). DO NOT assume combat_router.CATEGORY.WEAPONSKILL (3) can be
-- passed directly as actionCategory here -- that would silently produce
-- wrong joins. Callers MUST translate via a real mapping. See
-- dlac_listener.CATEGORY_FROM_PACKET_ACTION below for the (currently
-- INCOMPLETE / FLAGGED) translation table -- this is a genuinely open
-- item, not resolved by anything in the guide or project file, and must
-- not be guessed at silently.
--
-- Returns the matched envelope and a status string ('exact' | 'carried'
-- | 'cold'), matching the guide's own three-outcome shape (§2.4) so
-- callers can distinguish a confirmed match from an inferred one from a
-- total miss, same as the guide's own compositionFor() example --
-- reimplemented, not copied, against the documented algorithm.
--
-- FIXED (2026-07-28, before the first real caller was wired in -- see
-- "Open work under the new scope" item 4 in the project file). Reuses
-- the same state.mergedWorn concept as currentComposition, but with an
-- important difference: currentComposition always wants "the picture
-- as of RIGHT NOW", so reading state.mergedWorn directly is correct.
-- This function instead answers "what was worn AS OF A SPECIFIC PAST
-- MATCH in the ring" -- if later envelopes have changed the
-- composition further since that match, state.mergedWorn (which
-- reflects the NEWEST state) would be wrong here. Reconstructs the
-- merged picture AS OF the matched index by folding every 'worn'
-- envelope from the start of the ring up to and including the match,
-- not by reading the running state.mergedWorn.
local function mergedWornAsOf(state, uptoIndex)
    local merged = {};
    for i = 1, uptoIndex do
        local e = state.ring[i];
        if e.kind == 'worn' and e.worn ~= nil then
            for slot, item in pairs(e.worn) do
                merged[slot] = item;
            end
        end
    end
    return merged;
end

-- Returns the matched envelope and a status string ('exact' | 'carried'
-- | 'cold'), matching the guide's own three-outcome shape (§2.4) so
-- callers can distinguish a confirmed match from an inferred one from a
-- total miss, same as the guide's own compositionFor() example --
-- reimplemented, not copied, against the documented algorithm.
--
-- The RETURNED envelope's `worn` table is the correctly-merged,
-- as-of-that-point-in-time composition (via mergedWornAsOf above), not
-- a single envelope's possibly-partial table -- see the FIXED note
-- above for why "as of that point" and not "the current running merge"
-- matters here specifically, unlike currentComposition.
---@param state table  from dlac_listener.newState()
---@param actionId number|nil
---@param actionCategory number|nil  in DLAC's enum, not packet_action's -- see caveat above
---@return table|nil envelope, string status  ('exact'|'carried'|'cold')
function dlac_listener.compositionFor(state, actionId, actionCategory)
    -- Search backwards across BOTH worn and dispatch anchors (guide
    -- §2.4's "NEW capability" update, folded into this project's
    -- earlier "carried" design per the merged project-file resolution).
    for i = #state.ring, 1, -1 do
        local e = state.ring[i];
        if (e.kind == 'worn' or e.kind == 'dispatch') and e.actionId == actionId
        and (actionCategory == nil or e.actionCategory == actionCategory) then
            if e.kind == 'dispatch' then
                -- A dispatch anchor confirms "nothing moved for this
                -- action" -- the actual composition is the newest worn
                -- BEFORE this dispatch entry, not the dispatch entry
                -- itself (which carries no worn table at all).
                for j = i - 1, 1, -1 do
                    if state.ring[j].kind == 'worn' then
                        local synthetic = {};
                        for k, v in pairs(state.ring[j]) do synthetic[k] = v; end
                        synthetic.worn = mergedWornAsOf(state, j);
                        return synthetic, 'exact';
                    end
                end
                -- A dispatch anchor with no earlier worn at all -- cold
                -- start case, nothing to report.
                return nil, 'cold';
            end
            local synthetic = {};
            for k, v in pairs(e) do synthetic[k] = v; end
            synthetic.worn = mergedWornAsOf(state, i);
            return synthetic, 'exact';
        end
    end

    -- Nothing matched this specific action -- per guide §2.4, this means
    -- the composition simply never changed for it, NOT that mobparser
    -- has no data. Fall back to the most recent worn envelope, tagged
    -- 'carried' so callers know this is an inference, not a confirmed
    -- match (mirrors formula.lua's own clamped/unclamped distinction in
    -- spirit -- always tell the caller when a value is less certain).
    -- This fallback is asking the same question currentComposition
    -- asks ("newest state, full stop") so it's correct (not just
    -- convenient) to reuse state.mergedWorn directly here -- no
    -- as-of-a-past-point reconstruction needed, unlike the exact-match
    -- branches above.
    for i = #state.ring, 1, -1 do
        if state.ring[i].kind == 'worn' then
            local synthetic = {};
            for k, v in pairs(state.ring[i]) do synthetic[k] = v; end
            synthetic.worn = state.mergedWorn or {};
            return synthetic, 'carried';
        end
    end

    return nil, 'cold';
end

-- Returns the composition currently in effect, with NO actionId join --
-- for melee swings, which are the only case in this project's v1 scope
-- (combat_router.V1_SCOPED_CATEGORIES) and which have no dlac-side
-- anchor at all to join against.
--
-- WHY THIS EXISTS, SEPARATELY FROM compositionFor(): per
-- integration-guide.md §2.3, dlac's `event` field is exactly one of
-- Default/Precast/Midcast/Ability/Item/Weaponskill/Preshot/Midshot/
-- PetAction -- there is no melee/auto-attack dispatch point. dlac only
-- decides gear at action boundaries; between actions, `Default` fires
-- on a ~0.4s idle tick and re-dresses to whatever idle/TP gear is
-- configured. That `Default` composition -- not any action-specific
-- one -- IS the gear actually on the player during ordinary melee. So
-- for melee, "what's the newest worn in the ring, full stop" is the
-- correct question, not "what's the newest worn matching THIS
-- action's id" -- there is no such id for a melee swing to match.
--
-- compositionFor()'s 'carried' fallback already computes exactly this
-- same "newest worn, no id match" answer as its OWN fallback path when
-- called with actionId=nil -- this function is really just that
-- fallback exposed as its own named entry point, so callers with a
-- melee swing (no actionId at all, not "an actionId that happens not
-- to match") don't have to route through the exact-match machinery
-- only to always land on the fallback. Kept as a separate function
-- rather than silently overloading compositionFor(nil, nil)'s meaning,
-- so a future reader doesn't have to infer "nil id must mean melee" --
-- it's named for what it actually answers.
--
-- STILL FLAGGED, NOT LIVE-VERIFIED: this is correct per the documented
-- contract (dlac only anchors at action boundaries, Default is the
-- between-actions truth), but WHETHER "newest worn in the ring at the
-- moment a melee 0x028 arrives" reliably reflects what was actually
-- equipped for THAT swing -- given the ~0.4s Default tick, and given a
-- melee swing can land at any point relative to an in-flight action's
-- own worn/idle-restore sequence -- has not been checked against real
-- packet timing. Same category of open item as packet_action.lua's
-- field layout: plausible from the spec, unconfirmed until fought
-- in-game with a gear swap mid-fight and diffed against what the
-- debug log actually tagged each swing with. See project file's
-- live-test checklist for the added verification step this requires.
---@param state table  from dlac_listener.newState()
---@return table|nil envelope, string status  ('carried'|'cold') -- never 'exact',
---                    since there is no action id here to match exactly
function dlac_listener.currentComposition(state)
    -- BUGFIX (2026-07-28): previously returned the single most recent
    -- 'worn' envelope's own `env.worn` table directly. Real session
    -- data showed this table can be PARTIAL (only the slot(s) that
    -- changed in that specific decision, not a full 16-slot picture --
    -- see onEnvelope's own note on state.mergedWorn for the evidence
    -- and reasoning). Returns state.mergedWorn instead -- the running,
    -- folded-together full picture -- wrapped in a synthetic envelope
    -- shape so callers (combat_router.buildGearTag) don't need to know
    -- the difference between "a real envelope" and "the merged view."
    -- The synthetic envelope's `seq`/`kind`/etc mirror the most recent
    -- contributing 'worn' envelope in the ring, for any caller that
    -- wants that context; only the `worn` table itself is the merged
    -- one, not a single envelope's raw table.
    for i = #state.ring, 1, -1 do
        if state.ring[i].kind == 'worn' then
            if state.mergedWorn == nil then
                -- Should not happen if a 'worn' envelope is in the ring
                -- (onEnvelope always populates mergedWorn alongside
                -- remember() for kind=='worn') -- defensive fallback
                -- only, not a case expected to actually occur.
                return state.ring[i], 'carried';
            end
            local synthetic = {};
            for k, v in pairs(state.ring[i]) do
                synthetic[k] = v;
            end
            synthetic.worn = state.mergedWorn;
            return synthetic, 'carried';
        end
    end
    return nil, 'cold';
end

-- FLAGGED, INCOMPLETE: no verified mapping exists yet from
-- packet_action.lua's action.category (0x028 incoming) to dlac's
-- actionCategory (0x01A outgoing) enum. Left as an explicit, empty-ish
-- stub rather than guessed at, per this project's standing discipline
-- (packets_bitreader.lua's reconstruction-vs-real-source episode,
-- combat_router's MOB flag episode -- guessing plausible-looking
-- mappings has cost real time twice already in this project). DO NOT
-- fill this in from assumption -- needs either (a) dlac's maintainer
-- confirming the two enums line up 1:1 for the categories mobparser
-- cares about (melee has no dlac-side equivalent at all -- dlac only
-- fires on Spell/WS/Ability/Ranged dispatch, not on ordinary swings,
-- so melee-side joins may not need this mapping at all -- open
-- question), or (b) empirical confirmation via a live capture, same
-- category of work as packet_action.lua's own field-layout
-- verification.
dlac_listener.CATEGORY_FROM_PACKET_ACTION = {
    -- INTENTIONALLY EMPTY pending the resolution above.
};

-- ===========================================================================
-- ASHITA-FACING GLUE -- calls AshitaCore, UNTESTED OFFLINE.
-- Needs in-game verification before this is trusted, same caveat as
-- combat_router.ashita.* and unknownlog.ashita.*.
-- ===========================================================================
dlac_listener.ashita = {};

-- Unwraps the raw plugin_event `e` object into a decodable string, per
-- the guide's PROBED AND VERIFIED note (§2.2): `e` is userdata, `e.data`
-- is already a reassembled string, `e.size` is its length. The guide's
-- own decode() reference also defensively checks `.payload`/
-- `.eventData` and a byte-table fallback for robustness against an
-- unverified environment -- kept here even though the field name is now
-- confirmed, since it costs nothing and the guide's own text still
-- frames `e.data` as "the verified fast path" alongside the defensive
-- version, not a reason to delete the fallback.
---@param e userdata  the raw plugin_event object
---@return string|nil  the raw payload string, or nil if unavailable
function dlac_listener.ashita.extractPayloadString(e)
    local raw = e.data or e.payload or e.eventData;
    if raw == nil then
        return nil;
    end
    if type(raw) == 'string' then
        return raw;
    end
    if type(raw) == 'table' then
        local b = {};
        for i = 1, #raw do
            b[i] = string.char(raw[i]);
        end
        return table.concat(b);
    end
    return nil;
end

-- Serializes a query table into a byte table for RaiseEvent, per guide
-- §3: "the binding refuses plain strings — serialize, then send as a
-- byte table". This is a MINIMAL serializer -- only handles the shapes
-- mobparser's own queries actually need (string/number values in a flat
-- table), not a general Lua serializer. Deliberately narrow scope, same
-- spirit as classify.lua only handling verified message IDs rather than
-- guessing at a general-purpose solution.
---@param t table  flat table of string/number values
---@return string  Lua source, `return { ... }`
local function serializeFlatTable(t)
    local parts = {};
    for k, v in pairs(t) do
        local key = '[' .. string.format('%q', tostring(k)) .. ']';
        local val;
        if type(v) == 'number' then
            val = tostring(v);
        else
            val = string.format('%q', tostring(v));
        end
        table.insert(parts, key .. '=' .. val);
    end
    return 'return {' .. table.concat(parts, ',') .. '}';
end

---@param s string
---@return table  byte table suitable for RaiseEvent
local function toByteTable(s)
    local t = {};
    for i = 1, #s do
        t[i] = s:byte(i);
    end
    return t;
end

-- Sends the 'worn' bootstrap query -- the ONE query v1 of mobparser
-- actually needs (see module header re: gear/sets/item/stats being out
-- of scope for now). Per guide §3 and §2.6: this is how mobparser
-- avoids being permanently blind on load (no automatic greeting exists
-- on this broadcast-only channel) and how it recovers after a detected
-- seq gap / dropped>0 signal from dlac_listener.onEnvelope.
--
-- `replyPrefix` must be unique to this addon per guide §3 ("pick a
-- reply prefix unique to your addon; two consumers must not collide") --
-- 'mobparser' is used as a literal constant here rather than a
-- configurable setting, since this addon has exactly one dlac consumer
-- and no scenario where two mobparser instances would run in the same
-- Ashita process.
function dlac_listener.ashita.askWorn()
    local query = { reply = 'mobparser', what = 'worn' };
    local src = serializeFlatTable(query);
    local bytes = toByteTable(src);
    AshitaCore:GetPluginManager():RaiseEvent('dlac_query', bytes);
end

-- Registers the plugin_event handler. Filters for the four stream
-- channel names PLUS mobparser's own reply channel ('mobparser_r'), per
-- guide §4. Also filters out mobparser's OWN raised events per the
-- guide's "bonus fact" (§2.2: "a state DOES hear its own RaiseEvent") --
-- relevant here because dlac_listener.ashita.askWorn fires
-- 'dlac_query', not one of the listened-for names, so this isn't
-- currently a live hazard, but the check is included defensively in
-- case a future query type reuses a listened-for channel name.
---@param state table  from dlac_listener.newState()
function dlac_listener.ashita.register(state)
    local DLAC_EVENT_NAMES = {
        dlac_worn = true,
        dlac_dispatch = true,
        dlac_invalidate = true,
        dlac_confirm = true,
    };

    ashita.events.register('plugin_event', 'mobparser_dlac_listener', function(e)
        if e.name == 'mobparser_r' then
            -- Reply to our own 'worn' query -- decoded the same way as
            -- a stream envelope (guide §3: "decoded exactly like a
            -- stream envelope"). This is always a snapshot=true 'worn'
            -- envelope per guide §2.6, so onEnvelope's existing
            -- snapshot handling covers it without a separate code path.
            local payload = dlac_listener.ashita.extractPayloadString(e);
            local env = payload and dlac_listener.decodePayloadString(payload);
            if env ~= nil then
                dlac_listener.onEnvelope(state, env);
            end
            return;
        end

        if not DLAC_EVENT_NAMES[e.name] then
            return;
        end

        local payload = dlac_listener.ashita.extractPayloadString(e);
        if payload == nil then
            return;
        end
        local env = dlac_listener.decodePayloadString(payload);
        if env == nil then
            return;
        end

        local needsResync = dlac_listener.onEnvelope(state, env);
        if needsResync then
            -- Per guide §2.5: "re-pull, never interpolate". Fire the
            -- bootstrap query again rather than guessing at what was
            -- missed.
            dlac_listener.ashita.askWorn();
        end
    end);
end

return dlac_listener;

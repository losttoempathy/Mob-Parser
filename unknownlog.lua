--[[
mobparser -- unknownlog.lua

Receives UNKNOWN-outcome captures from classify.lua and:
  1. Always: accumulates them in memory (count + last-N raw examples per
     distinct (message, reaction) pair) and periodically writes to a
     diagnostic log file. This is NEVER mixed into the real sample
     storage (per the authoritative-vs-estimated separation principle
     already established) -- it's purely for identifying new message
     IDs later, same discipline as everything else in this project: no
     invented meanings, only evidence-based additions to classify.lua.
  2. Optionally (setting-gated): correlates each capture's timestamp
     against the player's chat log, attaching nearby system/combat text
     to help identify what the unknown outcome actually was (e.g.
     "Mob is under the effect of Stoneskin!" appearing right before an
     UNKNOWN capture with damage=0 is strong, fast evidence).

CORRECTION (2026-07-28, later same day): the logger is `Spike2D/SimpleLog`,
NOT `Addons/logs` -- confirmed via user screenshots + SimpleLog's own
`configuration.lua` source. SimpleLog REWRITES text via configurable
toggles (condense/simplify/etc) rather than passing raw client text
through. See mobparser project file "MAJOR CORRECTION" note before
trusting anything below as raw-client ground truth -- particularly
before using chat-correlated NUMBERS (damage values) as regression
input rather than presence/absence evidence only.

STATUS (2026-07-28): log format CONFIRMED against real user-provided log
files (6 days, ~178k lines, C:\Games\catseyexi\catseyexi-client\Ashita\
chatlogs\). Chat correlation is still a STUB pending implementation, but
the format facts below are no longer assumptions.

Confirmed facts (see packet_ground_truth.md "Chat log format" section
for the full writeup):
  - Path: `<install>\Ashita\chatlogs\<CharName>_YYYY.MM.DD.log`, one file
    per character per day.
  - Encoding: Shift-JIS (FFXI's native client encoding), NOT UTF-8/CP1252
    -- must open/decode as shift_jis or bytes will mis-split mid-character.
  - Line terminator: CRLF.
  - Each line is DOUBLE-timestamped: `[HH:MM:SS] [HH:MM:SS] <text>` (both
    copies identical in every sample seen; cause unknown, not investigated
    further since it doesn't block parsing -- just take the first one).
    No date in the line itself; date comes from the filename only, so a
    session crossing midnight needs the correlator to know which file
    it's reading, not just parse the line.
  - Actor -> target separator in combat lines is a real Shift-JIS glyph
    (byte pair \x81\xa8, decodes to "→"), not ASCII.
  - Mob/NPC names containing a space are rendered two different ways
    depending on context: as a literal space (0x20) when the name
    appears in free text (e.g. "Savanna Rarab (Lv..."), but as \x81
    followed by a literal ASCII "?" (0x3F) when the SAME name appears
    inside a bracketed actor tag (e.g. "[Savanna\x81?Rarab]"). This is a
    real quirk of the log output, not a decoding error on our end --
    confirmed by inspecting raw bytes. Any actor-tag parser needs to
    handle this specifically (e.g. strip/normalize \x81? to a space)
    rather than assuming bracket-tag names match free-text names
    byte-for-byte.
  - Confirmed real combat outcome line shapes seen in sample data:
    MISS, PARRY, ABSORB, SHADOW-ABSORB, GUARD, SHIELD_BLOCK (see
    packet_ground_truth.md for exact examples). CORRECTED 2026-07-28:
    two earlier passes wrongly concluded GUARD/shadow-absorb, then
    separately SHIELD_BLOCK, were absent -- all are present and common,
    earlier keyword searches just missed them (see packet_ground_truth.md
    "Chat log format" correction note).
  - GUARD and SHIELD_BLOCK both have a DIFFERENT shape from
    MISS/PARRY/ABSORB/SHADOW: `Guarded! ` and `Blocked! ` are literal
    prefixes on the whole line, before the bracketed actor tag, not
    embedded outcome words. Any parser needs a distinct leading-string
    check for BOTH prefixes, and must tell them apart (they're separate
    reaction values).
  - NEW OPEN ITEM (2026-07-28): an "Arm Block" message was found that
    does NOT match any currently-documented outcome shape -- no
    `Blocked!`/`Guarded!` prefix, no damage number, no arrow separator
    in most instances, just `[ActorName] Arm Block` (plus a doubled
    unbracketed variant). NOT yet correlated to a packet message ID --
    do not assume it's a SHIELD_BLOCK variant without evidence. Needs a
    live packet capture correlating this text to a numeric message ID
    before `readChatWindow()`/`classify.lua` can handle it correctly.

STATUS (2026-07-28, later same day): line-matching logic is now REAL and
offline-tested -- see chatlog.lua (pure logic) and test_chatlog.lua (18
checks passing). What's still unresolved: `unknownlog.ashita.*` (finding
the chatlogs directory and the logged-in character's name) is stubbed
with explicit errors, same pattern as `combat_router.ashita.*` -- needs
real AshitaCore calls, untested offline for the same reason (no Ashita
environment available in this dev setup). Do NOT let mobparser.lua call
into chat correlation until `unknownlog.ashita.*` is implemented; until
then `readChatWindow()`'s pcall wrapper makes failures degrade silently
to "no chat context" rather than crashing, but that also means it will
silently do nothing useful, not silently do something wrong -- worth
remembering when testing in-game for the first time.
]]

local unknownlog = {};

-- ===========================================================================
-- Settings
-- ===========================================================================
unknownlog.settings = {
    -- Master switch for automatic chat-log correlation. Per user request
    -- (2026-07-27): default ON, but must be trivially toggleable in case
    -- it proves problematic (unexpected file access issues, performance,
    -- privacy concerns, wrong log format once verified, etc).
    chatCorrelation = true,

    -- How many seconds around an UNKNOWN capture's timestamp to search
    -- the chat log for correlated lines. Kept small deliberately -- we
    -- want the system message that describes THIS swing, not general
    -- nearby conversation.
    correlationWindowSeconds = 3,

    -- How many raw examples to retain per distinct (message, reaction)
    -- pair before we stop accumulating more (avoids unbounded memory
    -- growth if one truly novel case fires constantly in a session).
    maxExamplesPerKey = 5,

    -- Full path to the directory containing the chat logger's output
    -- files (e.g. `<CharName>_YYYY.MM.DD.log`). Deliberately has NO
    -- default -- this is install/logger-specific (per the
    -- "logger-agnostic" design decision, mobparser must not assume any
    -- one path or logger). Must be set explicitly via setChatlogsDir()
    -- before chat correlation will do anything; fails safe to "no
    -- context" until then.
    --
    -- RETIRED (2026-07-29): this previously carried a hardcoded
    -- testing-only default (this user's own SimpleLog install path),
    -- added 2026-07-28 to save typing during active in-game
    -- verification. Removed now that setup is no longer the active
    -- bottleneck -- restores the original fail-safe-to-nil design
    -- rather than shipping a machine-specific path as a real default.
    chatlogsDir = nil,
};

-- Sets the chatlogs directory (see unknownlog.settings.chatlogsDir for
-- the full rationale on why this has no PERMANENT default -- note the
-- TEMPORARY testing default currently set there, flagged for removal).
-- Pass nil to clear it back to unset (chat correlation will then fail
-- safe to "no context").
function unknownlog.setChatlogsDir(path)
    unknownlog.settings.chatlogsDir = path;
end

function unknownlog.setChatCorrelation(enabled)
    unknownlog.settings.chatCorrelation = enabled and true or false;
end

-- ===========================================================================
-- Accumulator state
-- ===========================================================================
-- Keyed by "message:reaction" (both may be nil-ish/0 -- stringify safely).
-- Each entry: { count = N, examples = { {raw, timestamp, chatContext}, ... } }
local seen = {};

local function keyFor(raw)
    return tostring(raw.message) .. ':' .. tostring(raw.reaction);
end

-- ===========================================================================
-- Chat correlation -- line-matching logic REAL (chatlog.lua), Ashita
-- glue (unknownlog.ashita.*) STUBBED -- see status note above.
-- ===========================================================================

local chatlog = require('chatlog');

-- Returns an array of RAW chat-log line strings (not parsed/classified)
-- that fall within correlationWindowSeconds of `timestamp`. Filtered to
-- system/combat-message-looking lines only -- NOT party chat, tells,
-- linkshell, or other private conversation text (privacy-scoping
-- requirement already agreed). Returns an empty table if correlation is
-- off, unavailable, or the chat log can't be read (missing file, no
-- character name available, etc -- failures here should degrade
-- gracefully to "no chat context," never error out and break capture).
-- Callers (unknownlog's diagnostic log, or a human reviewing captures)
-- treat these strings as read-only display text -- never re-parse them
-- for numbers to feed elsewhere.
--
-- SPLIT, same pattern as combat_router.lua: the line-matching logic
-- itself (chatlog.lua) is pure, offline-tested (test_chatlog.lua, 18
-- checks passing). Everything below this point is the Ashita-facing
-- glue -- finding the chatlogs directory, the logged-in character's
-- name, and reading the file -- which is UNTESTED OFFLINE (no Ashita
-- environment available in this dev setup) and needs in-game
-- verification before trusting it, same caveat as
-- combat_router.ashita.*.
local function readChatWindow(timestamp)
    if not unknownlog.settings.chatCorrelation then
        return {};
    end

    local ok, result = pcall(function()
        -- unknownlog.ashita.getChatlogsDir() / getCharacterName() are
        -- the two pieces of real AshitaCore-facing glue this needs.
        -- Neither is implemented yet -- see unknownlog.ashita below.
        -- Calling through unknownlog.ashita.* (rather than inlining
        -- AshitaCore calls here) keeps this function testable by
        -- swapping in a fake unknownlog.ashita table, same technique
        -- ashita_shim.lua already uses elsewhere in this project.
        local dir = unknownlog.ashita.getChatlogsDir();
        if dir == nil then
            return {};
        end
        local charName = unknownlog.ashita.getCharacterName();
        if charName == nil then
            return {};
        end

        local dateStr = os.date('%Y.%m.%d', timestamp);
        local filename = charName .. '_' .. dateStr .. '.log';

        -- BUGFIX (2026-07-28, caught by test_unknownlog.lua's real
        -- end-to-end test -- see that test's comments): a hardcoded
        -- `\` separator silently fails to find the file when this code
        -- runs somewhere `\` isn't the path separator (this dev/test
        -- environment is Linux, real Ashita is Windows). Try `\` first
        -- (the real target environment), fall back to `/` if that
        -- doesn't open -- keeps this correct on the real Windows/Ashita
        -- target while still being genuinely testable offline on this
        -- dev machine, rather than the bug being masked by only ever
        -- testing on Windows.
        local file = io.open(dir .. '\\' .. filename, 'r');
        if file == nil then
            file = io.open(dir .. '/' .. filename, 'r');
        end
        if file == nil then
            -- File not present for this date -- not an error, just no
            -- chat context available (e.g. logger wasn't running, or
            -- wrong path configured). Silent, matches the "degrade
            -- gracefully" contract above.
            return {};
        end

        -- Read as raw bytes (Shift-JIS is not compatible with Lua
        -- string pattern matching across multi-byte sequences in
        -- general, but chatlog.lua's patterns only ever match ASCII
        -- anchors -- `[`, digits, `:`, `]`, `<`, `>` -- which are all
        -- single-byte in Shift-JIS, so byte-wise line splitting and
        -- pattern matching is safe here even without decoding).
        local lines = {};
        for line in file:lines() do
            table.insert(lines, line);
        end
        file:close();

        local targetSecondsOfDay = tonumber(os.date('%H', timestamp)) * 3600
            + tonumber(os.date('%M', timestamp)) * 60
            + tonumber(os.date('%S', timestamp));

        return chatlog.findLinesNearTimestamp(
            lines, targetSecondsOfDay, unknownlog.settings.correlationWindowSeconds);
    end);

    if not ok then
        -- Any failure (bad path, permissions, unexpected file shape)
        -- degrades to "no chat context" rather than propagating an
        -- error into classify.lua's capture path -- chat correlation
        -- is a nice-to-have enrichment, never allowed to break the
        -- primary packet-capture pipeline.
        return {};
    end
    return result;
end

-- ===========================================================================
-- Ashita-facing glue. Both getChatlogsDir() and getCharacterName() are
-- now REAL (2026-07-28) -- getChatlogsDir() resolved as a plain user
-- setting, getCharacterName() implemented against the documented
-- Ashita v4 SDK surface (GetPlayerEntity().Name, confirmed via real
-- addon source -- see comment on the function itself). Kept as a
-- separate, swappable table (same technique as combat_router.lua's
-- combat_router.ashita.*) so readChatWindow's calling logic can still
-- be exercised with a fake implementation in offline tests, without
-- needing a running Ashita client -- and so it CAN be exercised that
-- way now that both functions are real, not just testable-by-omission.
-- ===========================================================================
unknownlog.ashita = {};

-- Returns the chatlogs directory path (no trailing backslash), or nil
-- if it hasn't been configured. RESOLVED (2026-07-28, user-confirmed):
-- implemented as a plain user setting (unknownlog.settings.chatlogsDir
-- / unknownlog.setChatlogsDir()) rather than deriving it from
-- AshitaCore:GetInstallPath() -- that convention is NOT confirmed to
-- hold for SimpleLog (or any other logger) on this or any install, and
-- guessing wrong risks silently reading a stale/unrelated file instead
-- of failing visibly. No real AshitaCore call needed here, so this is
-- fully testable offline (see test_unknownlog.lua).
function unknownlog.ashita.getChatlogsDir()
    return unknownlog.settings.chatlogsDir;
end

-- Returns the currently logged-in character's name (matching the
-- `<CharName>` portion of the log filename), or nil if not available
-- (e.g. not logged in yet / between zones).
--
-- IMPLEMENTED (2026-07-28) against the documented Ashita v4 SDK
-- surface, `GetPlayerEntity().Name` -- confirmed via real, currently-
-- maintained addon source (lejar/AshitaTargetInfo calls
-- `GetPlayerEntity()` and reads `.HealthPercent`/`.Distance`-style
-- fields off the returned entity the same shape combat_router.ashita.*
-- already relies on for `.ServerId`/`.PetTargetIndex`; the `.Name`
-- field itself is the same one `target.Name` uses in that same file's
-- rendering code, just on the player's own entity instead of a
-- target). Same license discipline as the rest of this project: API
-- SHAPE confirmed from real usage, not copied code.
--
-- A second, independent path exists and is NOT used here but is worth
-- recording in case this one needs revisiting: `AshitaCore:
-- GetDataManager():GetParty():GetMemberName(0)` -- the local player is
-- always party member index 0 (confirmed via ProjectTako/ffxi-addons'
-- react.lua, which reads this exact call for its own settings-file
-- naming). `GetPlayerEntity().Name` was chosen as primary because it
-- doesn't require being in an active party at all (GetMemberName(0)
-- may behave differently solo -- untested, hence not chosen as
-- primary), and because combat_router.ashita.* already establishes
-- GetPlayerEntity() as this project's standard way to ask "who am I."
--
-- STILL UNTESTED IN-GAME, same caveat as every other Ashita-facing
-- function in this project -- the real API shape is confirmed from
-- documented usage elsewhere, not independently re-derived from
-- Ashita's own SDK header source this session.
function unknownlog.ashita.getCharacterName()
    local player = GetPlayerEntity();
    if player == nil then
        return nil; -- not logged in / between zones -- fail safe, don't guess
    end
    return player.Name;
end

-- ===========================================================================
-- Public capture API -- called from wherever classify.lua's outputs are
-- consumed (the eventual packet-handling/sample-aggregation layer).
-- ===========================================================================

---@param raw table  the raw-fields table classify.lua returns on UNKNOWN
---@param side string 'offense' or 'defense' (which classify function produced this)
---@param context table|nil  optional extra context the caller has handy
---                            (mobName, zoneId, yourLevel, mobLevel, etc)
---@param timestamp number|nil  os.time()-style timestamp; defaults to now
function unknownlog.capture(raw, side, context, timestamp)
    timestamp = timestamp or os.time();
    local key = keyFor(raw);

    if seen[key] == nil then
        seen[key] = { count = 0, examples = {} };
    end
    local bucket = seen[key];
    bucket.count = bucket.count + 1;

    if #bucket.examples < unknownlog.settings.maxExamplesPerKey then
        local chatContext = readChatWindow(timestamp);
        table.insert(bucket.examples, {
            raw = raw,
            side = side,
            context = context,
            timestamp = timestamp,
            chatContext = chatContext,  -- empty table until correlation is implemented.
                                          -- ALWAYS raw display-text strings (see
                                          -- readChatWindow's design note) -- never
                                          -- parse these for numbers; they're for a
                                          -- human/diagnostic log to read, not for
                                          -- feeding the regression or any other
                                          -- numeric consumer.
        });
    end
end

-- Returns the full accumulated table -- for the eventual write-to-disk /
-- chat-notice layer to consume. Read-only view; callers should not
-- mutate the returned table directly.
function unknownlog.getAll()
    return seen;
end

-- Returns a short, human-readable summary line per distinct unknown
-- (message, reaction) pair seen this session -- e.g. for a chat notice
-- or a `/mobparser unknowns` command.
function unknownlog.summaryLines()
    local lines = {};
    for key, bucket in pairs(seen) do
        table.insert(lines, string.format(
            'mobparser: unrecognized outcome (message=%s) seen %d time(s) -- logged for review',
            key, bucket.count));
    end
    return lines;
end

return unknownlog;

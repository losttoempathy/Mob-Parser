--[[
mobparser -- chatlog.lua

Pure-logic chat-log line finder. Split out from unknownlog.lua following
the same pattern already established by combat_router.lua: pure logic
here (no file I/O, no AshitaCore calls, fully unit-testable offline
against sample log content -- see test_chatlog.lua), Ashita-facing glue
(actually opening the right file on disk, decoding it, finding the
character name) lives in unknownlog.lua's chat-correlation section.

DESIGN DECISION (2026-07-28, user-confirmed): mobparser must work with
SimpleLog, Addons/logs, or any other/future logger, without per-logger
special-casing. This module returns RAW LINE TEXT ONLY -- it never
parses out or exposes a damage/TP/other NUMBER from a line. Its job is
"find lines near this timestamp that look like combat/system output,
not private chat" -- nothing more. See unknownlog.lua's own design note
and the mobparser project file's "DECISION: Option A" entry for the
full reasoning. Do not extend this module to parse outcome semantics
out of lines -- that would reintroduce logger-specific coupling this
design is explicitly avoiding.

Format facts this module leans on (see packet_ground_truth.md "Chat log
format" section -- confirmed against real SimpleLog-produced logs,
NOT independently confirmed for other loggers, treated here as a
starting heuristic rather than a hard assumption):
  - Lines may be double-timestamped: `[HH:MM:SS] [HH:MM:SS] <text>`.
    This module accepts EITHER one or two leading `[HH:MM:SS]` blocks,
    so a differently-behaved logger (single timestamp) still parses.
  - No date in-line -- date comes from which file is being read, not
    from line content. This module takes lines already extracted from
    a single day's file; it doesn't handle cross-midnight file
    selection itself (that's the caller's job, see unknownlog.lua TODO).
  - A line "looks like" combat/system output if it starts (after the
    timestamp block) with a `[ActorName]` bracket, a known whole-line
    prefix (`Guarded! `, `Blocked! ` -- SimpleLog-specific, kept as a
    non-exhaustive starting list), or has no channel-style tag at all
    (unbracketed narrator text). A line "looks like" private chat if it
    starts with a channel-number tag (`[2]<Name>`) or similar
    tell/say/yell/linkshell markup. This heuristic is intentionally
    conservative and UNTESTED against a full channel-tag inventory --
    false negatives (missing a real combat line) are an acceptable
    trade-off against the alternative of leaking private chat into a
    diagnostic log.
]]

local chatlog = {};

-- Non-exhaustive list of whole-line prefixes seen so far that mark a
-- line as combat-outcome-shaped even though they precede the timestamp-
-- adjacent bracket rather than following it. SimpleLog-specific in
-- origin (see packet_ground_truth.md) but harmless to check regardless
-- of logger -- a logger that never emits these strings just never
-- matches this branch.
chatlog.KNOWN_OUTCOME_PREFIXES = {
    'Guarded! ',
    'Blocked! ',
};

-- Matches a leading `[HH:MM:SS] ` block. Returns hours, minutes,
-- seconds (numbers) and the remainder of the line after this block, or
-- nil if the line doesn't start with a timestamp block at all.
local function matchLeadingTimestamp(line)
    local h, m, s, rest = line:match('^%[(%d%d):(%d%d):(%d%d)%]%s*(.*)$');
    if h == nil then
        return nil;
    end
    return tonumber(h), tonumber(m), tonumber(s), rest;
end

-- Strips one or two leading `[HH:MM:SS]` blocks off `line`. Returns
-- the seconds-since-midnight of the FIRST timestamp block found, and
-- the remaining text after all leading timestamp blocks are removed.
-- Returns nil if the line has no leading timestamp at all (not a log
-- line we can correlate -- e.g. a wrapped continuation line from a
-- long message).
function chatlog.stripLeadingTimestamps(line)
    local h, m, s, rest = matchLeadingTimestamp(line);
    if h == nil then
        return nil, line;
    end
    local secondsOfDay = h * 3600 + m * 60 + s;

    -- Try a second consecutive timestamp block (the double-timestamp
    -- quirk seen in every SimpleLog sample so far -- see module header).
    local h2, m2, s2, rest2 = matchLeadingTimestamp(rest);
    if h2 ~= nil then
        rest = rest2;
    end

    return secondsOfDay, rest;
end

-- Returns true if `textAfterTimestamp` (the line content with leading
-- timestamp block(s) already stripped) looks like a combat/system line
-- rather than private chat, per the heuristic described in the module
-- header. This is intentionally simple and conservative.
function chatlog.looksLikeCombatOrSystemLine(textAfterTimestamp)
    if textAfterTimestamp == nil or textAfterTimestamp == '' then
        return false;
    end

    -- Known whole-line outcome prefixes (Guarded!/Blocked!/etc).
    for _, prefix in ipairs(chatlog.KNOWN_OUTCOME_PREFIXES) do
        if textAfterTimestamp:sub(1, #prefix) == prefix then
            return true;
        end
    end

    -- Channel-tag lines look like `[N]<Name> ...` or `[N] [Name] ...`
    -- immediately followed by a DIGIT inside the first bracket -- treat
    -- as private/channel chat and exclude, UNLESS it's immediately
    -- followed by another bracketed actor tag (SimpleLog emits lines
    -- like `[2] [Shadowgod] missed -> Mob` for multi-target combat
    -- messages, which ARE combat lines despite the leading channel-
    -- looking digit -- see packet_ground_truth.md examples). Check for
    -- that combat-shaped case FIRST.
    local channelNum, afterChannel = textAfterTimestamp:match('^%[(%d+)%]%s*(.*)$');
    if channelNum ~= nil then
        if afterChannel:sub(1, 1) == '[' then
            -- e.g. "[2] [Shadowgod] missed -> Mob" -- combat line with a
            -- target-count prefix, not a channel-chat line.
            return true;
        end
        -- e.g. "[2]<PlayerName> some message" -- real channel chat.
        return false;
    end

    -- Bracketed actor tag immediately after the timestamp, e.g.
    -- "[Lift] missed -> Bumblebee" or "[Savanna?Rarab] parried by -> Lift".
    if textAfterTimestamp:sub(1, 1) == '[' then
        return true;
    end

    -- Tell-style markup, e.g. "PlayerName>>You: message" or similar --
    -- not confirmed against real samples, kept as a conservative
    -- exclusion since it's clearly not combat text if it matches.
    if textAfterTimestamp:find('>>', 1, true) ~= nil then
        return false;
    end

    -- Fallback: unbracketed lines with no channel/tell markup are
    -- treated as narrator/system text (e.g. "Shadowgod defeats the
    -- Goblin Gambler.", "AOE 244 -> Shadowgod") and included. This is
    -- the least-confident branch of the heuristic -- if false positives
    -- turn out to be common (party comment lines with no channel tag,
    -- if such a thing exists in practice), revisit here.
    return true;
end

-- Given an array of raw line strings (already read from a log file,
-- e.g. via io.lines()) and a target timestamp (seconds-since-midnight,
-- SAME clock as the log's own [HH:MM:SS] stamps -- caller's job to
-- ensure this, see unknownlog.lua), plus a window in seconds, returns
-- an array of the raw, UNMODIFIED line strings (including their
-- original timestamp block) that both:
--   (a) fall within [timestamp - windowSeconds, timestamp + windowSeconds]
--   (b) pass looksLikeCombatOrSystemLine's filter
-- Lines with no parseable leading timestamp are skipped (can't
-- correlate them). Does NOT handle cross-midnight file boundaries --
-- caller's responsibility to pass in lines from the correct day's file
-- (or files, if the window straddles midnight).
function chatlog.findLinesNearTimestamp(lines, targetSecondsOfDay, windowSeconds)
    local matches = {};
    for _, line in ipairs(lines) do
        local secondsOfDay, rest = chatlog.stripLeadingTimestamps(line);
        if secondsOfDay ~= nil then
            local delta = math.abs(secondsOfDay - targetSecondsOfDay);
            if delta <= windowSeconds and chatlog.looksLikeCombatOrSystemLine(rest) then
                table.insert(matches, line);
            end
        end
    end
    return matches;
end

return chatlog;

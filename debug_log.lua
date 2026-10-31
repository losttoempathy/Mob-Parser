--[[
mobparser -- debug_log.lua

TEMPORARY, TESTING-ONLY module. NOT the sample-aggregation layer the
project file describes -- this exists to give in-game tests something
concrete to write to disk, diffable against Metrics running alongside
for the same fight.

STATUS (2026-07-29): still in active use for testing, not yet retired.
Kept alongside export_log.lua (the real data pipeline) for quick human
sanity-checking. Retire once in-game verification against Metrics
concludes -- don't extend this into becoming the real pipeline.
]]

local debug_log = {};

debug_log.settings = {
    -- No default -- same "fail safe rather than guess a path" logic as
    -- unknownlog.settings.chatlogsDir. Must be set explicitly before
    -- this module writes anything.
    outputPath = nil,

    -- Master on/off switch. (2026-10-30) OFF by default -- turned on
    -- per session with `/mobparser debug on`. Deliberately NOT persisted:
    -- every reload starts off again. The existing debug_log.txt is never
    -- wiped by this module -- it only appends while enabled.
    enabled = false,
};

-- Creates the output directory if it doesn't exist. `io.open(path, 'a')`
-- does not create intermediate directories on its own. Uses
-- ashita.fs.create_directory (ported from GearDB/settings.lua's
-- ensureDir, confirmed-working precedent), guarded so a missing/absent
-- binding fails safe rather than erroring.
local function ensureDirectoryExists(filePath)
    -- Extract the directory portion (everything before the last \ or /).
    local dir = filePath:match('^(.*)[\\/][^\\/]+$');
    if dir == nil then
        return; -- no directory component (bare filename) -- nothing to create
    end
    pcall(function()
        if ashita ~= nil and ashita.fs ~= nil and type(ashita.fs.create_directory) == 'function' then
            ashita.fs.create_directory(dir);
        end
    end);
end

-- Tracks whether the one-time "couldn't write" warning has already
-- been shown this session, so it doesn't spam chat on every packet.
local hasWarnedAboutWriteFailure = false;

function debug_log.setOutputPath(path)
    debug_log.settings.outputPath = path;
    hasWarnedAboutWriteFailure = false; -- new path, allow a fresh warning if it also fails
    if path ~= nil then
        ensureDirectoryExists(path);
    end
end

function debug_log.setEnabled(enabled)
    debug_log.settings.enabled = enabled and true or false;
    hasWarnedAboutWriteFailure = false; -- allow a fresh warning after re-enabling
end

function debug_log.isEnabled()
    return debug_log.settings.enabled == true;
end

-- Appends one line per classified result to the output file. Called
-- from combat_router.handlePacket for every result combat_router.route
-- produces (side ~= nil, in v1-scoped category). Simple, greppable
-- plain text -- not a real data format, just something a human can
-- read next to Metrics' own output.
--
-- Fields: timestamp, side, actor/target server IDs, outcome, damage,
-- the raw message/reaction pair when outcome is UNKNOWN, and an
-- optional gear-tag summary (status + short slot signature) for
-- diffing "what mobparser thinks was worn" during gear-swap testing.
-- Diagnostic-only -- not the real per-sample gear-tagging storage the
-- eventual sample-aggregation layer will need.
--
-- Fails silently (per this project's pattern for optional/diagnostic
-- paths) if outputPath isn't set or the file can't be opened, rather
-- than breaking the primary packet-capture pipeline.
function debug_log.record(side, actorId, targetId, outcome, damage, raw, gearTag)
    if not debug_log.settings.enabled then
        return;
    end
    if debug_log.settings.outputPath == nil then
        return;
    end

    local ok, wroteSuccessfully = pcall(function()
        local file = io.open(debug_log.settings.outputPath, 'a');
        if file == nil then
            return false;
        end

        local line = string.format(
            '%s\tside=%s\tactor=%s\ttarget=%s\toutcome=%s\tdamage=%s',
            os.date('%H:%M:%S'),
            tostring(side),
            tostring(actorId),
            tostring(targetId),
            tostring(outcome),
            tostring(damage));

        if raw ~= nil then
            line = line .. string.format('\tmessage=%s\treaction=%s',
                tostring(raw.message), tostring(raw.reaction));
        end

        -- gearTag: { status = 'exact'|'carried'|'cold', signature = string|nil }
        -- signature is a short, human-diffable stand-in for "what was
        -- worn" -- NOT a full composition dump (that's what the raw
        -- envelope itself carries, if this needs deeper inspection
        -- later; keeping the debug log line-per-swing readable is the
        -- priority here, matching this file's whole design intent).
        if gearTag ~= nil then
            line = line .. string.format('\tgear=%s\tgearSig=%s',
                tostring(gearTag.status), tostring(gearTag.signature));
        end

        file:write(line .. '\n');
        file:close();
        return true;
    end);
    -- Never propagates an error into the packet-handling pipeline, but
    -- does surface a one-time visible warning if the write genuinely
    -- failed (silent failure would defeat this module's purpose).
    -- Guarded so it only fires once per setOutputPath() call.
    if (not ok or wroteSuccessfully ~= true) and not hasWarnedAboutWriteFailure then
        hasWarnedAboutWriteFailure = true;
        local okChat, chat = pcall(require, 'chat');
        local msg = '[debug_log] WARNING: failed to write to "' ..
            tostring(debug_log.settings.outputPath) ..
            '" -- directory may not exist or path may be wrong. ' ..
            '(This warning only shows once per session/path.)';
        if okChat and chat ~= nil then
            print(chat.header('mobparser') .. chat.message(msg));
        else
            print(msg); -- fallback if chat itself somehow isn't available
        end
    end
end

return debug_log;

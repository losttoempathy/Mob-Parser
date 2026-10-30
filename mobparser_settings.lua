--[[
mobparser -- mobparser_settings.lua

Machine-wide (NOT per-character -- chatlogsDir is an install path, not a
per-character value) settings persistence, backing store for
unknownlog.settings.chatlogsDir.

ADAPTED (2026-07-29) from the user's own confirmed-working GearDB/
settings.lua pattern -- same io.open()-based load/save, same
ashita.fs.create_directory guard, same path built from
AshitaCore:GetInstallPath() rather than a bare relative path (the
mistake debug_log.lua's own history already documents). Deliberately
NOT using ashita.settings.load/save -- that API's real v4 signature
could not be confirmed against an authoritative source this session
(GitHub/git.ashitaxi.com both blocked automated fetching), so this
follows the leaner, already-proven-in-this-user's-own-environment
io.open() approach instead of guessing at an unverified API.

File location: <Ashita install>\config\addons\mobparser\settings.lua
-- one shared file, not per-character (per user decision 2026-07-29).
]]

local M = {};

-- ---------------------------------------------------------------------------
-- Defaults
-- ---------------------------------------------------------------------------
local function defaults()
    return {
        -- Mirrors unknownlog.settings.chatlogsDir's own "no default,
        -- fail safe rather than guess wrong" design -- nil here means
        -- "not yet configured," not "forgot to set a value."
        chatlogsDir = nil,
        -- Number of player rows the in-game GUI table shows (1-18).
        guiMaxPlayers = 6,
        -- Show enemy (mob) rows in the GUI's Player view. Off by default
        -- (2026-10-29, user request) -- toggled in the Settings window.
        guiShowEnemies = false,
        -- Chat channel for the GUI "Report" button / `/mobparser report`:
        -- 'say' | 'party' | 'linkshell'. Set in the Settings window.
        guiReportMode = 'party',
        -- Show the Job column next to the player name (2026-10-29).
        guiShowJob = true,
        -- Open the GUI window automatically when the addon loads
        -- (2026-10-29, user request: on by default, toggle in Settings).
        guiOpenOnLoad = true,
    };
end

M.data = defaults();

-- ---------------------------------------------------------------------------
-- Paths
-- ---------------------------------------------------------------------------
-- Machine-wide install directory, NOT keyed by character/server id (that's
-- GearDB's own pattern -- deliberately not followed here since
-- chatlogsDir is a machine-wide value, not a per-character one -- see
-- user decision 2026-07-29).
local function installDir()
    local dir = nil;
    pcall(function()
        if AshitaCore ~= nil and AshitaCore.GetInstallPath ~= nil then
            local base = AshitaCore:GetInstallPath();
            if base ~= nil and base ~= '' then
                dir = base .. 'config\\addons\\mobparser\\';
            end
        end
    end);
    return dir;
end

function M.path()
    local d = installDir();
    return d and (d .. 'settings.lua') or nil;
end

local function ensureDir()
    local d = installDir();
    if d == nil then return false; end
    local ok = false;
    pcall(function()
        if ashita ~= nil and ashita.fs ~= nil and type(ashita.fs.create_directory) == 'function' then
            ashita.fs.create_directory(d);
            ok = true;
        end
    end);
    return ok or (d ~= nil);
end

-- ---------------------------------------------------------------------------
-- Serialisation (plain Lua literal -- readable + hand-editable, same
-- approach as GearDB/settings.lua's own ser(), trimmed to what this
-- module actually needs -- just strings/nil for now, no colour floats).
-- ---------------------------------------------------------------------------
local function ser(v, indent)
    indent = indent or '    ';
    local t = type(v);
    if t == 'number' then
        if v == math.floor(v) then return string.format('%d', v); end
        return string.format('%.4f', v);
    elseif t == 'boolean' then
        return tostring(v);
    elseif t == 'string' then
        return string.format('%q', v);
    elseif t == 'table' then
        local parts = {};
        local keys = {};
        for k in pairs(v) do if type(k) == 'string' then keys[#keys + 1] = k; end end
        table.sort(keys);
        for _, k in ipairs(keys) do
            parts[#parts + 1] = string.format('%s%s = %s,', indent .. '    ', k, ser(v[k], indent .. '    '));
        end
        if #parts == 0 then return '{}'; end
        return '{\n' .. table.concat(parts, '\n') .. '\n' .. indent .. '}';
    end
    return 'nil';
end

-- ---------------------------------------------------------------------------
-- Load / save
-- ---------------------------------------------------------------------------
function M.load()
    M.data = defaults();
    local p = M.path();
    if p == nil then return false; end
    local f = io.open(p, 'r');
    if f == nil then return false; end -- no file yet -- normal on first run
    local txt = f:read('*a');
    f:close();
    local chunk = loadstring or load;
    local ok, fn = pcall(chunk, txt);
    if not ok or fn == nil then return false; end
    local ok2, tbl = pcall(fn);
    if not ok2 or type(tbl) ~= 'table' then return false; end
    if type(tbl.chatlogsDir) == 'string' then
        M.data.chatlogsDir = tbl.chatlogsDir;
    end
    -- Carry every other saved scalar across too (probeEnabled,
    -- autoRefreshEnabled, guiMaxPlayers, ...). Previously only
    -- chatlogsDir survived a reload, so any other saved key was
    -- silently dropped on load and then erased on the next save().
    for k, v in pairs(tbl) do
        if type(k) == 'string' and k ~= 'chatlogsDir' then
            local t = type(v);
            if t == 'boolean' or t == 'number' or t == 'string' then
                M.data[k] = v;
            elseif k == 'guiColors' and t == 'table' then
                -- { slotKey = { r=, g=, b=, a= }, ... } -- numbers only
                local colors = {};
                for slot, col in pairs(v) do
                    if type(slot) == 'string' and type(col) == 'table' then
                        colors[slot] = {
                            r = tonumber(col.r) or 0, g = tonumber(col.g) or 0,
                            b = tonumber(col.b) or 0, a = tonumber(col.a) or 1,
                        };
                    end
                end
                M.data.guiColors = colors;
            end
        end
    end
    return true;
end

function M.save()
    local p = M.path();
    if p == nil then return false; end
    ensureDir();
    local body = {
        '-- mobparser settings. Safe to hand-edit; the addon rewrites it on change.',
        'return ' .. ser(M.data, ''),
        '',
    };
    local f = io.open(p, 'w');
    if f == nil then return false; end
    f:write(table.concat(body, '\n'));
    f:close();
    return true;
end

return M;

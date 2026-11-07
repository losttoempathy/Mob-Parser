--[[
mobparser -- mobparser_keybind.lua (2026-11-07)

The GUI window key. Default Ctrl+M (dlac holds Ctrl+K, Nexus holds
Ctrl+Z). Changeable with `/mobparser bind <key>`, saved in settings as
`keybind`; `/mobparser bind none` removes it.

Modeled on Nexus's core\keybind.lua (the user's own, working in-game):
  - Never overwrites a bind someone else made: IsBound is asked first, in
    every input-state variant, and the key is left alone if taken.
  - Bound with requireInputClosed = true, so it does nothing while the
    FFXI chat line is open.
  - Unbound on unload, only if mobparser made it.

IKeyboard::Bind(key, down, alt, apps, ctrl, shift, win,
                requireInputClosed, requireInputOpened, command)
takes a DirectInput key code (plugins\sdk\Ashita.h).
]]

local M = {};

M.COMMAND = '/mobparser toggle';
M.DEFAULT = '^m';

local DIK = {
    ['1'] = 0x02, ['2'] = 0x03, ['3'] = 0x04, ['4'] = 0x05, ['5'] = 0x06,
    ['6'] = 0x07, ['7'] = 0x08, ['8'] = 0x09, ['9'] = 0x0A, ['0'] = 0x0B,
    q = 0x10, w = 0x11, e = 0x12, r = 0x13, t = 0x14, y = 0x15, u = 0x16, i = 0x17, o = 0x18, p = 0x19,
    a = 0x1E, s = 0x1F, d = 0x20, f = 0x21, g = 0x22, h = 0x23, j = 0x24, k = 0x25, l = 0x26,
    z = 0x2C, x = 0x2D, c = 0x2E, v = 0x2F, b = 0x30, n = 0x31, m = 0x32,
    f1 = 0x3B, f2 = 0x3C, f3 = 0x3D, f4 = 0x3E, f5 = 0x3F, f6 = 0x40,
    f7 = 0x41, f8 = 0x42, f9 = 0x43, f10 = 0x44, f11 = 0x57, f12 = 0x58,
};

-- Ashita's /bind prefixes: ^ Ctrl, ! Alt, + Shift, @ Win, # Apps.
local MODIFIERS = { ['^'] = 'ctrl', ['!'] = 'alt', ['+'] = 'shift', ['@'] = 'win', ['#'] = 'apps' };

local function keyboard()
    return AshitaCore:GetInputManager():GetKeyboard();
end

local ours = nil;

-- '^m' -> { key = DIK, name = 'm', ctrl = true, ... }; 'none' -> { none = true };
-- nil and why for anything else.
function M.parse(spec)
    spec = tostring(spec or ''):lower():gsub('%s', '');
    if spec == '' or spec == 'none' or spec == 'off' then
        return { none = true };
    end
    local b = { ctrl = false, alt = false, shift = false, win = false, apps = false };
    local i = 1;
    while i <= #spec and MODIFIERS[spec:sub(i, i)] do
        b[MODIFIERS[spec:sub(i, i)]] = true;
        i = i + 1;
    end
    local name = spec:sub(i);
    local key = DIK[name];
    if not key then
        return nil, 'unknown key "' .. name .. '" (use a letter, a digit or F1-F12, with ^ Ctrl, ! Alt, + Shift)';
    end
    b.key, b.name = key, name;
    return b;
end

function M.describe(b)
    if not b or b.none then return 'no key'; end
    local parts = {};
    if b.ctrl then parts[#parts + 1] = 'Ctrl'; end
    if b.alt then parts[#parts + 1] = 'Alt'; end
    if b.shift then parts[#parts + 1] = 'Shift'; end
    if b.win then parts[#parts + 1] = 'Win'; end
    if b.apps then parts[#parts + 1] = 'Apps'; end
    parts[#parts + 1] = b.name:upper();
    return table.concat(parts, '+');
end

local function takenByOthers(kb, b)
    for _, closed in ipairs({ false, true }) do
        for _, opened in ipairs({ false, true }) do
            if not (closed and opened)
                and kb:IsBound(b.key, true, b.alt, b.apps, b.ctrl, b.shift, b.win, closed, opened) then
                return true;
            end
        end
    end
    return false;
end

-- Releases mobparser's previous bind, then binds spec. Returns ok, message.
function M.apply(spec)
    M.release();
    local b, why = M.parse(spec);
    if not b then return false, why; end
    if b.none then
        return true, 'mobparser has no window key now; /mobparser gui still opens it.';
    end
    local okKb, kb = pcall(keyboard);
    if not okKb or kb == nil then
        return false, 'the keyboard is not reachable';
    end
    if takenByOthers(kb, b) then
        return false, M.describe(b) .. ' is already bound, so mobparser left it alone. ' ..
            'Pick another key with /mobparser bind <key>, e.g. /mobparser bind ^p.';
    end
    local ok, err = pcall(function()
        kb:Bind(b.key, true, b.alt, b.apps, b.ctrl, b.shift, b.win, true, false, M.COMMAND);
    end);
    if not ok then
        return false, 'binding failed: ' .. tostring(err);
    end
    ours = b;
    return true, M.describe(b) .. ' opens and closes the mobparser window.';
end

function M.release()
    if not ours then return; end
    local b = ours;
    ours = nil;
    pcall(function()
        keyboard():Unbind(b.key, true, b.alt, b.apps, b.ctrl, b.shift, b.win, true, false);
    end);
end

function M.current()
    return ours;
end

return M;

--[[
mobparser -- action_names.lua

Turns an exported actionId (the action packet's cmd_arg) into the
English name of the ability / spell / weaponskill / mob TP move, and a
statusId into a status name. 100% local: reads the client's own
DAT-backed resources through Ashita's resource manager, sends nothing.

## Lookups -- CONFIRMED by resprobe.lua, 2026-10-29 live capture

Every row below was read off resprobe.log against abilities the user
actually used (THF/DNC + Curilla/Kupipi trusts), not guessed:

  category 4  (magic)        GetSpellById(id).Name[1]
                             Kupipi 127=Protectra III, 132=Shellra III,
                             58=Paralyze; Curilla 112=Flash; trust
                             summons 898=Kupipi, 902=Curilla.
  category 6 / 14 (JA)       GetAbilityById(id + 512).Name[1]
                             42=Flee, 76=Trick Attack, 44=Sneak Attack,
                             236=Collaborator, 204=Animated Flourish,
                             201=Quickstep, 190=Curing Waltz, 184=Drain
                             Samba, Curilla 35=Provoke, 48=Sentinel,
                             226=Retaliation. (Plain `id` gives the
                             WEAPONSKILL with that number -- wrong.)
  category 3 (WS category)   SPLIT BY OUTCOME. AscensionXI sends some
                             THF job abilities on category 3:
                             41+512=Steal, 45+512=Mug, 228+512=Despoil.
                             Real weaponskills on category 3 use plain
                             `id` (Curilla WS_DAMAGE id 40 = Vorpal
                             Blade). So: a JA_* outcome -> id + 512,
                             anything else (WS_*, MISS...) -> id.
  category 11 (mob TP move)  GetString('monsters.abilities', id - 256)
                             590 -> Goblin Rush.
  status IDs                 GetString('buffs.names', id)
                             2=sleep, 13=slow, 40=Protect,
                             149=Defense Down.

Name[1] is English; Name[2] is Japanese; Name[3] repeats English (all
three seen in the probe output), so [1] is used with [3] as a fallback.

## Deliberately NOT resolved (not probed yet -- returns nil, no guess)

  category 1 / 2 (melee, ranged): cmd_arg is not an ability id at all
  category 5 (item use), category 13 (pet TP moves / blood pacts)
  id 0 on any category (e.g. a mob's interrupted/started cast)
]]

local action_names = {};

local CAT = { WS = 3, MAGIC = 4, JA = 6, MOB_TP = 11, UNBLINKABLE_JA = 14 };
local JA_OFFSET = 512;
local MOB_TP_OFFSET = 256;

-- ---------------------------------------------------------------------------
-- Pure logic (no Ashita dependency -- testable offline)
-- ---------------------------------------------------------------------------

-- True when a category-3 result is really a job ability (Steal, Mug,
-- Despoil, ...) rather than a weaponskill: classify routes those
-- through its JA fallback, so their outcome carries the JA_ prefix.
function action_names.isJaOnWsCategory(outcome)
    return type(outcome) == 'string' and outcome:sub(1, 3) == 'JA_';
end

-- Which lookup to use: returns kind ('spell' | 'ability' | 'mobAbility')
-- and the id to look up, or nil when this category isn't resolvable.
function action_names.lookupFor(category, id, outcome)
    if type(id) ~= 'number' or id <= 0 then return nil; end
    if category == CAT.MAGIC then
        return 'spell', id;
    elseif category == CAT.JA or category == CAT.UNBLINKABLE_JA then
        return 'ability', id + JA_OFFSET;
    elseif category == CAT.WS then
        if action_names.isJaOnWsCategory(outcome) then
            return 'ability', id + JA_OFFSET;
        end
        return 'ability', id;
    elseif category == CAT.MOB_TP then
        if id <= MOB_TP_OFFSET then return nil; end
        return 'mobAbility', id - MOB_TP_OFFSET;
    end
    return nil;
end

-- ---------------------------------------------------------------------------
-- Resource lookups (cached; every call pcall'd)
-- ---------------------------------------------------------------------------

local cache = {}; -- "kind:id" -> name, or false for "looked up, no name"

local function rm()
    local ok, r = pcall(function() return AshitaCore:GetResourceManager(); end);
    if ok then return r; end
    return nil;
end

local function englishName(obj)
    if obj == nil then return nil; end
    for _, i in ipairs({ 1, 3 }) do
        local ok, n = pcall(function() return obj.Name[i]; end);
        if ok and type(n) == 'string' and n ~= '' then return n; end
    end
    return nil;
end

local function cleanString(s)
    if type(s) ~= 'string' or s == '' then return nil; end
    return s;
end

local function fetch(kind, id)
    local r = rm();
    if r == nil then return nil, false; end -- no resource manager: don't cache
    local ok, name = pcall(function()
        if kind == 'spell' then
            return englishName(r:GetSpellById(id));
        elseif kind == 'ability' then
            return englishName(r:GetAbilityById(id));
        elseif kind == 'mobAbility' then
            return cleanString(r:GetString('monsters.abilities', id));
        elseif kind == 'status' then
            return cleanString(r:GetString('buffs.names', id));
        end
        return nil;
    end);
    if not ok then return nil, true; end
    return name, true;
end

local function cached(kind, id)
    local key = kind .. ':' .. tostring(id);
    local hit = cache[key];
    if hit ~= nil then return hit or nil; end
    local name, cacheable = fetch(kind, id);
    if cacheable then cache[key] = name or false; end
    return name;
end

-- ---------------------------------------------------------------------------
-- Public
-- ---------------------------------------------------------------------------

---@return string|nil  English name, or nil when unresolvable / not covered
function action_names.actionName(category, id, outcome)
    local kind, lookupId = action_names.lookupFor(category, id, outcome);
    if kind == nil then return nil; end
    return cached(kind, lookupId);
end

---@return string|nil
function action_names.statusName(statusId)
    if type(statusId) ~= 'number' or statusId < 0 then return nil; end
    return cached('status', statusId);
end

return action_names;

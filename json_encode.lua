--[[
mobparser -- json_encode.lua

Minimal, dependency-free JSON encoder. Written fresh for this project --
not vendored from any external library, since none was already present
in this codebase (checked before writing this) and pulling in an
unverified third-party JSON library would be exactly the kind of
unverified dependency this project has avoided elsewhere (see
packets_bitreader.lua's real-vs-reconstruction episode for why "found
some code that looks right" isn't good enough on its own).

Scope, deliberately narrow: encodes only what mobparser's export module
actually needs to produce -- nested tables of strings, numbers,
booleans, nil, and arrays (sequential-integer-keyed tables). Does NOT
attempt general-purpose Lua-table-to-JSON correctness (e.g. mixed
array/map tables, which JSON has no native representation for anyway --
callers must not construct those). This narrowness is intentional, same
spirit as dlac_listener.lua's serializeFlatTable being a "MINIMAL
serializer -- only handles the shapes mobparser's own queries actually
need."

Array vs. object detection: a table is treated as a JSON ARRAY if and
only if it has keys 1..N with no gaps and no other keys (a "proper"
Lua sequence, checked via the standard #t plus a key-count comparison,
not just #t alone -- #t is undefined behavior on tables with gaps, so a
gap check catches what #t alone would silently get wrong). Any other
table (string keys, or non-sequential numeric keys) is encoded as a
JSON object. An explicitly empty table `{}` encodes as `{}` (a JSON
object), not `[]` -- ambiguous in Lua (empty array and empty object are
the same value), and JSON object is the safer default since it's valid
wherever ANY object is expected, whereas an empty array is only valid
where arrays are expected. Callers needing an empty JSON array
specifically should use json_encode.EMPTY_ARRAY (a sentinel table this
module recognizes and encodes as `[]`).
]]

local json_encode = {};

-- Sentinel for "encode this as an empty JSON array specifically" --
-- see module header for why plain {} defaults to object instead.
json_encode.EMPTY_ARRAY = setmetatable({}, { __tostring = function() return '[]'; end });

-- Characters requiring escape in a JSON string, per the JSON spec
-- (RFC 8259 §7). Control characters below 0x20 not explicitly listed
-- here are handled by the fallback \u00XX branch in escapeString.
local ESCAPES = {
    ['"']  = '\\"',
    ['\\'] = '\\\\',
    ['\b'] = '\\b',
    ['\f'] = '\\f',
    ['\n'] = '\\n',
    ['\r'] = '\\r',
    ['\t'] = '\\t',
};

local function escapeString(s)
    local out = s:gsub('[%z\1-\31\\"]', function(c)
        if ESCAPES[c] then
            return ESCAPES[c];
        end
        return string.format('\\u%04x', string.byte(c));
    end);
    return '"' .. out .. '"';
end

-- Returns true if `t` is a "proper" Lua sequence (1..N, no gaps, no
-- other keys) -- see module header for why this check (not just #t)
-- is used.
local function isArray(t)
    local count = 0;
    for _ in pairs(t) do
        count = count + 1;
    end
    if count == 0 then
        return false; -- empty table defaults to object, see header
    end
    for i = 1, count do
        if t[i] == nil then
            return false; -- gap -- not a proper sequence
        end
    end
    return true;
end

local encodeValue; -- forward declaration, mutually recursive with encodeTable

local function encodeTable(t)
    if t == json_encode.EMPTY_ARRAY then
        return '[]';
    end
    if isArray(t) then
        local parts = {};
        for i = 1, #t do
            table.insert(parts, encodeValue(t[i]));
        end
        return '[' .. table.concat(parts, ',') .. ']';
    end

    local parts = {};
    for k, v in pairs(t) do
        if type(k) ~= 'string' then
            error('json_encode: object keys must be strings, got ' .. type(k)
                .. ' (value: ' .. tostring(k) .. ') -- mobparser export data '
                .. 'should never construct a table with non-string, '
                .. 'non-sequential keys; this is a bug in the caller, not '
                .. 'something to silently coerce.');
        end
        table.insert(parts, escapeString(k) .. ':' .. encodeValue(v));
    end
    return '{' .. table.concat(parts, ',') .. '}';
end

encodeValue = function(v)
    local t = type(v);
    if v == nil then
        return 'null';
    elseif t == 'boolean' then
        return v and 'true' or 'false';
    elseif t == 'number' then
        -- Reject NaN/inf explicitly rather than emitting invalid JSON
        -- (JSON has no representation for either) -- same "fail loud,
        -- don't silently produce something wrong" discipline as the
        -- rest of this project.
        if v ~= v then
            error('json_encode: cannot encode NaN');
        end
        if v == math.huge or v == -math.huge then
            error('json_encode: cannot encode infinity');
        end
        -- Integers encode without a decimal point (matters for IDs like
        -- actorId/targetId -- "44151" not "44151.0", which some JSON
        -- consumers treat as a different type or reject for an
        -- integer-typed field).
        if v == math.floor(v) and math.abs(v) < 2^53 then
            return string.format('%d', v);
        end
        return string.format('%.14g', v);
    elseif t == 'string' then
        return escapeString(v);
    elseif t == 'table' then
        return encodeTable(v);
    else
        error('json_encode: cannot encode a value of type ' .. t
            .. ' -- mobparser export data should only ever contain '
            .. 'strings, numbers, booleans, nil, and tables.');
    end
end

---@param value any  a Lua value (typically a table) to encode as JSON
---@return string  the JSON text
function json_encode.encode(value)
    return encodeValue(value);
end

return json_encode;

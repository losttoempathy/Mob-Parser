--[[
mobparser -- json_decode.lua

Minimal, dependency-free JSON decoder, written to match json_encode.lua
(same project, same narrow-scope philosophy -- see that file's header
for why this project writes its own rather than vendoring an unverified
third-party library). Built specifically to make export_log.lua's
saveToMasterAndWipe able to genuinely read-merge-write an existing
master file, rather than the refuse-if-exists placeholder it shipped
with initially (see that function's own "KNOWN GAP" comment, now
resolved by this file's existence).

Scope: a standard recursive-descent JSON parser covering the full JSON
grammar (objects, arrays, strings with escapes, numbers, true/false/
null) -- unlike json_encode.lua, this can't be narrowed to "only the
shapes mobparser produces," since its job is specifically to read
mobparser's own previously-exported files back, which by definition
already conform to what json_encode.lua produces, but decoding still
needs to handle the general grammar to be a trustworthy round-trip
partner (a decoder that only handles a subset of JSON would silently
mis-parse a valid file that happened to use a form the encoder doesn't
currently produce, e.g. if a human hand-edited the master file).
]]

local json_decode = {};

local function skipWhitespace(s, pos)
    local _, e = s:find('^[ \t\r\n]*', pos);
    return e + 1;
end

local parseValue; -- forward declaration

local function parseError(msg, s, pos)
    local line = 1;
    for _ in s:sub(1, pos):gmatch('\n') do
        line = line + 1;
    end
    error(string.format('json_decode: %s at position %d (line %d)', msg, pos, line));
end

local ESCAPE_CHARS = {
    ['"']  = '"',
    ['\\'] = '\\',
    ['/']  = '/',
    ['b']  = '\b',
    ['f']  = '\f',
    ['n']  = '\n',
    ['r']  = '\r',
    ['t']  = '\t',
};

local function parseString(s, pos)
    if s:sub(pos, pos) ~= '"' then
        parseError('expected string (opening quote)', s, pos);
    end
    pos = pos + 1;
    local parts = {};
    local start = pos;
    while true do
        local c = s:sub(pos, pos);
        if c == '' then
            parseError('unterminated string', s, pos);
        elseif c == '"' then
            table.insert(parts, s:sub(start, pos - 1));
            return table.concat(parts), pos + 1;
        elseif c == '\\' then
            table.insert(parts, s:sub(start, pos - 1));
            local esc = s:sub(pos + 1, pos + 1);
            if esc == 'u' then
                local hex = s:sub(pos + 2, pos + 5);
                if not hex:match('^%x%x%x%x$') then
                    parseError('invalid \\u escape', s, pos);
                end
                local codepoint = tonumber(hex, 16);
                -- This project's exported data is ASCII-range item
                -- names/outcome strings in practice (see
                -- json_encode.lua's own escaping -- it only emits
                -- \u00XX for control characters below 0x20, never for
                -- ordinary text, since Lua strings here are raw bytes
                -- already, not re-encoded). A full UTF-16
                -- surrogate-pair-aware decode is NOT implemented --
                -- flagged rather than silently wrong: codepoints above
                -- 0xFFFF (requiring surrogate pairs) are not supported,
                -- and this only correctly round-trips what
                -- json_encode.lua itself can produce (control chars
                -- 0x00-0x1F). If mobparser's export ever needs to
                -- round-trip arbitrary Unicode text, this needs
                -- revisiting alongside a matching encoder change.
                if codepoint < 0x80 then
                    table.insert(parts, string.char(codepoint));
                else
                    parseError('non-ASCII \\u escape not supported (see module header)', s, pos);
                end
                pos = pos + 6;
            elseif ESCAPE_CHARS[esc] then
                table.insert(parts, ESCAPE_CHARS[esc]);
                pos = pos + 2;
            else
                parseError('invalid escape \\' .. tostring(esc), s, pos);
            end
            start = pos;
        else
            pos = pos + 1;
        end
    end
end

local function parseNumber(s, pos)
    local numStr = s:match('^-?%d+%.?%d*[eE]?[+-]?%d*', pos);
    if numStr == nil or numStr == '' then
        parseError('invalid number', s, pos);
    end
    return tonumber(numStr), pos + #numStr;
end

local function parseArray(s, pos)
    pos = pos + 1; -- consume '['
    pos = skipWhitespace(s, pos);
    local arr = {};
    if s:sub(pos, pos) == ']' then
        return arr, pos + 1;
    end
    while true do
        local value;
        value, pos = parseValue(s, pos);
        table.insert(arr, value);
        pos = skipWhitespace(s, pos);
        local c = s:sub(pos, pos);
        if c == ',' then
            pos = skipWhitespace(s, pos + 1);
        elseif c == ']' then
            return arr, pos + 1;
        else
            parseError('expected , or ] in array', s, pos);
        end
    end
end

local function parseObject(s, pos)
    pos = pos + 1; -- consume '{'
    pos = skipWhitespace(s, pos);
    local obj = {};
    if s:sub(pos, pos) == '}' then
        return obj, pos + 1;
    end
    while true do
        pos = skipWhitespace(s, pos);
        local key;
        key, pos = parseString(s, pos);
        pos = skipWhitespace(s, pos);
        if s:sub(pos, pos) ~= ':' then
            parseError('expected : after object key', s, pos);
        end
        pos = skipWhitespace(s, pos + 1);
        local value;
        value, pos = parseValue(s, pos);
        obj[key] = value;
        pos = skipWhitespace(s, pos);
        local c = s:sub(pos, pos);
        if c == ',' then
            pos = skipWhitespace(s, pos + 1);
        elseif c == '}' then
            return obj, pos + 1;
        else
            parseError('expected , or } in object', s, pos);
        end
    end
end

parseValue = function(s, pos)
    pos = skipWhitespace(s, pos);
    local c = s:sub(pos, pos);
    if c == '{' then
        return parseObject(s, pos);
    elseif c == '[' then
        return parseArray(s, pos);
    elseif c == '"' then
        return parseString(s, pos);
    elseif c == 't' then
        if s:sub(pos, pos + 3) == 'true' then
            return true, pos + 4;
        end
        parseError('invalid literal (expected true)', s, pos);
    elseif c == 'f' then
        if s:sub(pos, pos + 4) == 'false' then
            return false, pos + 5;
        end
        parseError('invalid literal (expected false)', s, pos);
    elseif c == 'n' then
        if s:sub(pos, pos + 3) == 'null' then
            return nil, pos + 4;
        end
        parseError('invalid literal (expected null)', s, pos);
    elseif c == '-' or c:match('%d') then
        return parseNumber(s, pos);
    else
        parseError('unexpected character "' .. c .. '"', s, pos);
    end
end

-- Decodes a JSON text into a Lua value. Raises an error (via Lua's
-- `error`, catchable with pcall -- matching json_encode.lua's own
-- error-on-invalid-input philosophy rather than returning nil/false on
-- failure) if the input is not valid JSON.
--
-- NOTE: JSON `null` decodes to Lua `nil` -- which means a `null` value
-- inside an object will simply not appear as a key at all in the
-- returned table (Lua cannot distinguish "key absent" from "key present
-- with value nil"), and a `null` inside an array will not increase the
-- array's Lua-visible length (a nil in the middle of a Lua table isn't
-- part of its sequence). This matches json_encode.lua's own encoding
-- of Lua nil AS `null`, so a value that was nil before encoding and
-- decodes back to nil after is a correct, lossless round-trip for this
-- project's actual data shapes (which never intentionally place null
-- inside an array) -- flagged here since it's a genuine, if narrow,
-- limitation of using plain Lua tables to represent JSON.
---@param text string  JSON text
---@return any  the decoded Lua value
function json_decode.decode(text)
    local value, pos = parseValue(text, 1);
    pos = skipWhitespace(text, pos);
    if pos <= #text then
        parseError('trailing content after JSON value', text, pos);
    end
    return value;
end

return json_decode;

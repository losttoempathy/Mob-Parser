--[[
* Addons - Copyright (c) 2023 Ashita Development Team
* Contact: https://www.ashitaxi.com/
* Contact: https://discord.gg/Ashita
*
* This file is part of Ashita.
*
* Ashita is free software: you can redistribute it and/or modify
* it under the terms of the GNU General Public License as published by
* the Free Software Foundation, either version 3 of the License, or
* (at your option) any later version.
*
* Ashita is distributed in the hope that it will be useful,
* but WITHOUT ANY WARRANTY; without even the implied warranty of
* MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
* GNU General Public License for more details.
*
* You should have received a copy of the GNU General Public License
* along with Ashita.  If not, see <https://www.gnu.org/licenses/>.
--]]

--[[
mobparser project note (2026-07-28): this is now the REAL, VERBATIM
Ashita Development Team bit-reader source, fetched directly from
ariel-logos/easyTH (github.com/ariel-logos/easyTH/blob/main/
bitreader.lua), a real addon that credits "bitreader.lua" and
"parser.lua" explicitly to "Ashita Development Team" in its own
README -- same GPLv3 provenance chain already documented in
packet_ground_truth.md's "Provenance note", confirmed via a second,
independent source (this file) rather than taken on faith from the
earlier Metrics-based research alone. Reused UNMODIFIED under its
original GPLv3 license (attribution + share-alike), per this project's
existing license research.

**REPLACES the earlier RECONSTRUCTION.** The prior version of this file
was explicitly flagged as a reconstruction (only the header and first
~20 lines of Metrics' bundled copy were ever actually viewed verbatim;
the read(bits) body was rebuilt from general LSB-first bit-reading
principles). Diffing that reconstruction against this real file found
TWO real, substantive differences -- worth recording so the mistake
isn't repeated:

1. **Bitwise operator syntax.** The reconstruction used Lua's native
   `>>`/`<<`/`&`/`|` operators. The real file uses `bit.lshift`/
   `bit.rshift`/`bit.band`/`bit.bor` throughout -- consistent with
   Ashita v4 running on a Lua/LuaJIT version without native bitwise
   operators (same conclusion independently reached today while writing
   combat_router.ashita.*, cross-checked against a different real addon
   there too -- two independent confirmations of the same fact).
2. **The actual bit-consuming algorithm differs, not just its syntax.**
   The real read(bits) MUTATES self.data[pos+1] by right-shifting it on
   every bit read (`self.data[self.pos+1] = bit.rshift(self.data[self.pos+1], 1)`)
   and always reads bit 0 of the (progressively shifted) byte via
   bit.band(byte, 1). The reconstruction instead tracked self.bit as a
   shift AMOUNT into an unmutated byte (`(byte >> self.bit) & 1`).
   Across one full untouched byte read start-to-finish these produce
   the same sequence of bit values, but the real version's approach
   DESTROYS the source byte as it's consumed -- a real behavioral
   difference the reconstruction didn't have, and exactly the kind of
   subtle bug that would have been very hard to catch without the real
   source, since a byte-scoped test wouldn't necessarily reveal it.

Confirms the original honesty flag was the right call -- this was NOT
byte-identical to the real implementation, and is now fixed by using
the genuine file rather than continuing to trust a plausible-looking
reconstruction.
]]

require('common');

local bitreader = T{
    data = nil,
    bit = 0,
    pos = 0,
};

--[[
* Creates and returns a new bit reader instance.
*
* @param {table} o - The default object table, if provided.
* @return {table} The bit reader instance.
--]]
function bitreader:new(o)
    o = o or T{};
    setmetatable(o, self);
    self.__index = self;
    return o;
end

--[[
* Sets the current reader data.
*
* @param {string|table} data - The data to use with the reader. (Strings are converted to a byte table automatically.)
--]]
function bitreader:set_data(data)
    self.bit = 0;
    self.data = T{};
    self.pos = 0;

    switch(type(data), T{
        ['string'] = function ()
            data:tohex():replace(' ', ''):gsub('(%x%x)', function (x)
                return table.insert(self.data, tonumber(x, 16));
            end);
        end,
        ['table'] = function ()
            self.data = data;
        end,
        [switch.default] = function ()
            error('[BitReader] Invalid data type: ' .. type(data));
        end,
    });
end

--[[
* Sets the current reader position.
*
* @param {number} pos - The byte position to set the reader to. (Resets the bit position.)
--]]
function bitreader:set_pos(pos)
    self.bit = 0;
    self.pos = pos;
end

--[[
* Reads a packed value from the current data.
*
* @param {number} bits - The number of bits to read.
* @return {number} The read value.
--]]
function bitreader:read(bits)
    local ret = 0;

    if (self.data == nil) then
        return ret;
    end

    for x = 0, bits - 1 do
        local val = bit.lshift(bit.band(self.data[self.pos + 1], 1), x);
        self.data[self.pos + 1] = bit.rshift(self.data[self.pos + 1], 1);
        ret = bit.bor(ret, val);

        self.bit = self.bit + 1;
        if (self.bit == 8) then
            self.bit = 0;
            self.pos = self.pos + 1;
        end
    end

    return ret;
end

-- Return the BitReader table..
return bitreader;

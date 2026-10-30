--[[
mobparser -- packet_action.lua

Parses the raw Action Packet (0x028) and normalizes it into the exact
per-result shape classify.lua already expects: { reaction, animation,
param, message, has_spike_effect, spike_effect_message, has_add_effect,
add_effect_message, ... }.

This is FRESHLY WRITTEN code, not copied from Metrics/any other addon.
The field LAYOUT (bit widths, field order) is informed by
packet_ground_truth.md's documented, CatsEyeXI-verified structure --
protocol facts, not copyrightable expression, safe to build against
regardless of Metrics' own unclear license (see packet_ground_truth.md
"Provenance note" for the reasoning this project has held to
throughout).

Depends on packets_bitreader.lua for raw bit extraction -- see that
file's own header for its verification status (FLAGGED, not yet
confirmed byte-identical to Ashita's real implementation).
]]

local bitreader = require('packets_bitreader');

local packet_action = {};

-- ===========================================================================
-- Raw parse: turns the raw packet byte string into the field layout
-- documented in packet_ground_truth.md's "Core packet: Action Packet
-- (0x028)" section.
-- ===========================================================================

---@param packetData string  the raw 0x028 packet bytes (post-header)
---@return table  raw parsed structure (pre-normalization)
function packet_action.parse(packetData)
    local reader = bitreader:new();
    reader:set_data(packetData);
    reader:set_pos(5);  -- skip generic packet header, per documented layout

    local action = {};
    action.actor_id  = reader:read(32);
    action.trg_sum   = reader:read(6);
    action.res_sum   = reader:read(4);   -- NOTE: unused in ground truth doc's
                                           -- field list; retained for parity
                                           -- with the documented structure,
                                           -- not currently consumed downstream.
    action.category  = reader:read(4);
    action.cmd_arg   = reader:read(32);
    action.info      = reader:read(32);
    action.targets   = {};

    for _ = 1, action.trg_sum do
        local target = {};
        target.id          = reader:read(32);
        target.result_sum  = reader:read(4);
        target.actions     = {};

        for _ = 1, target.result_sum do
            local result = {};
            -- Per packet_ground_truth.md's documented per-result field
            -- layout: reaction, animation (sub_kind), effect (info),
            -- stagger (scale), param (value/damage), message, then
            -- optional add-effect and spike/reaction blocks gated by a
            -- single bit flag each.
            result.reaction  = reader:read(3);
            result.kind      = reader:read(2);
            result.animation = reader:read(12);   -- "sub_kind" in raw docs
            result.effect    = reader:read(5);
            result.stagger   = reader:read(5);
            result.param     = reader:read(17);
            result.message   = reader:read(10);
            result.unknown_bits = reader:read(31);

            if reader:read(1) > 0 then
                result.has_add_effect     = true;
                result.add_effect_animation = reader:read(6);
                result.add_effect_effect    = reader:read(4);
                result.add_effect_param     = reader:read(17);
                result.add_effect_message   = reader:read(10);
            else
                result.has_add_effect     = false;
                result.add_effect_animation = 0;
                result.add_effect_effect    = 0;
                result.add_effect_param     = 0;
                result.add_effect_message   = 0;
            end

            if reader:read(1) > 0 then
                result.has_spike_effect     = true;
                result.spike_effect_animation = reader:read(6);
                result.spike_effect_effect    = reader:read(4);
                result.spike_effect_param     = reader:read(14);
                result.spike_effect_message   = reader:read(10);
            else
                result.has_spike_effect     = false;
                result.spike_effect_animation = 0;
                result.spike_effect_effect    = 0;
                result.spike_effect_param     = 0;
                result.spike_effect_message   = 0;
            end

            table.insert(target.actions, result);
        end

        table.insert(action.targets, target);
    end

    return action;
end

-- ===========================================================================
-- Build: the public entry point. Matches classify.lua's expected shape
-- directly (no separate "normalize" step needed -- parse() already
-- produces the right field names, since this is freshly designed against
-- classify.lua rather than adapted from a different addon's field names).
-- ===========================================================================

---@param packetData string  raw 0x028 packet bytes
---@return table|nil  the parsed action, or nil if this looks like a junk/empty packet
function packet_action.build(packetData)
    local ok, action = pcall(packet_action.parse, packetData);
    if not ok then
        return nil, 'parse error: ' .. tostring(action);
    end
    if action.trg_sum == 0 then
        return nil, 'junk packet (no targets)';
    end
    return action;
end

return packet_action;

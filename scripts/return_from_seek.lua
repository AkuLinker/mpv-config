-- return_from_seek.lua
--
-- IMPORTANT: this script does nothing by itself. You must bind a key to it
-- in input.conf, e.g.:
--
--     BS script-binding return_from_seek/return-from-seek
--
-- Remembers the position you seeked away from, if the seek distance was
-- bigger than a configured threshold. Pressing the bound key jumps back
-- to that position. The remembered position expires after a configured
-- amount of time.
--
-- Holding down a seek key (e.g. arrow keys) makes mpv fire many small
-- seeks in quick succession rather than one big seek. This script groups
-- seeks that happen close together in time into a single "burst" and
-- compares the position from before the whole burst to the position
-- after it, instead of comparing each tiny seek individually.
--
-- Install:
--   1. Put this file in ~/.config/mpv/scripts/return_from_seek.lua
--
--   2. (optional) create ~/.config/mpv/script-opts/return_from_seek.conf
--      with:
--
--          seek_threshold=10
--          memory_seconds=15
--          burst_gap=0.3
--
--   3. Bind a key in input.conf as shown above.

local mp = require 'mp'
local options = require 'mp.options'

local opts = {
    -- a seek (or burst of seeks) bigger than this many seconds counts as a "jump"
    seek_threshold = 10,
    -- how long to remember the jump-off point before forgetting it
    memory_seconds = 15,
    -- seeks that happen less than this many seconds apart are treated as
    -- part of the same burst (e.g. holding an arrow key)
    burst_gap = 0.3,
}
options.read_options(opts, "return_from_seek")

-- Cheap, no-logic cache of the current position, kept up to date on every
-- time-pos update. This is just a variable assignment, no branching.
local last_known_pos = nil

-- Whether we're currently inside a burst of seeks.
local burst_active = false
-- Position captured at the very start of the current burst.
local burst_start_pos = nil
-- Timer that finalizes the burst once no new seek arrives for burst_gap seconds.
local burst_end_timer = nil

-- The position the user can jump back to, and its expiry timer.
local remembered_pos = nil
local forget_timer = nil

local function forget()
    remembered_pos = nil
    if forget_timer then
        forget_timer:kill()
        forget_timer = nil
    end
end

local function remember(pos)
    remembered_pos = pos
    if forget_timer then
        forget_timer:kill()
    end
    forget_timer = mp.add_timeout(opts.memory_seconds, forget)
end

-- Cheap observer: just keeps last_known_pos current. No comparisons here.
mp.observe_property("time-pos", "number", function(_, pos)
    last_known_pos = pos
end)

local function finish_burst()
    burst_active = false
    burst_end_timer = nil
    local new_pos = mp.get_property_number("time-pos")
    if burst_start_pos ~= nil and new_pos ~= nil then
        local diff = new_pos - burst_start_pos
        if math.abs(diff) > opts.seek_threshold then
            remember(burst_start_pos)
        end
    end
    burst_start_pos = nil
end

-- "seek" fires once, reliably, for every seek -- including every tiny
-- seek while a key is held down. We only snapshot the position on the
-- FIRST seek of a burst, and keep pushing the "end of burst" timer
-- forward on every subsequent seek. The comparison only happens once,
-- after seeks stop arriving for burst_gap seconds.
mp.register_event("seek", function()
    if not burst_active then
        burst_active = true
        burst_start_pos = last_known_pos
    end
    if burst_end_timer then
        burst_end_timer:kill()
    end
    burst_end_timer = mp.add_timeout(opts.burst_gap, finish_burst)
end)

-- Reset state on file change so we don't jump to a position from a
-- different file.
mp.register_event("start-file", function()
    forget()
    last_known_pos = nil
    burst_active = false
    burst_start_pos = nil
    if burst_end_timer then
        burst_end_timer:kill()
        burst_end_timer = nil
    end
end)

-- Formats seconds as H:MM:SS (or MM:SS if under an hour), like mpv's own OSD.
local function format_time(seconds)
    seconds = math.floor(seconds + 0.5)
    local h = math.floor(seconds / 3600)
    local m = math.floor((seconds % 3600) / 60)
    local s = seconds % 60
    if h > 0 then
        return string.format("%d:%02d:%02d", h, m, s)
    else
        return string.format("%02d:%02d", m, s)
    end
end

local function return_from_seek()
    if remembered_pos ~= nil then
        mp.commandv("seek", remembered_pos, "absolute+exact")
        mp.osd_message("Jumped back to " .. format_time(remembered_pos), 3)
        forget()
    else
        mp.osd_message("No remembered position to jump back to", 3)
    end
end

mp.add_key_binding(nil, "return-from-seek", return_from_seek)

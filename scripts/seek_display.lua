-- seek_display.lua
-- Seeks by a given amount and shows the actual position after the seek completes.
--
-- Usage in input.conf:
--   RIGHT        script-binding seek_display/seek-small-forward
--   LEFT         script-binding seek_display/seek-small-backward
--   Ctrl+RIGHT   script-binding seek_display/seek-medium-forward
--   Ctrl+LEFT    script-binding seek_display/seek-medium-backward
--   Shift+RIGHT  script-binding seek_display/seek-large-forward
--   Shift+LEFT   script-binding seek_display/seek-large-backward
--   Alt+RIGHT    script-binding seek_display/seek-huge-forward
--   Alt+LEFT     script-binding seek_display/seek-huge-backward

-- ============================================================
-- User settings
-- ============================================================

local STEP_SMALL  = 1    -- seconds
local STEP_MEDIUM = 5    -- seconds
local STEP_LARGE  = 10   -- seconds
local STEP_HUGE   = 30   -- seconds

local EXACT = false      -- true = frame-accurate seek (exact), false = keyframe seek (relative) (it's faster)

local OSD_DURATION = 3   -- how long (in seconds) the OSD message stays on screen

-- ============================================================

local OSD_SETTLE_DELAY = 0.07

local last_amount  = 0
local settle_timer = nil

local mp = require 'mp'

local function format_time(seconds)
    if not seconds or seconds < 0 then seconds = 0 end
    local h = math.floor(seconds / 3600)
    local m = math.floor((seconds % 3600) / 60)
    local s = math.floor(seconds % 60)
    if h > 0 then
        return string.format("%d:%02d:%02d", h, m, s)
    else
        return string.format("%02d:%02d", m, s)
    end
end

local function show_osd()
    local pos      = mp.get_property_number("time-pos") or 0
    local duration = mp.get_property_number("duration") or 0

    local arrow = last_amount >= 0 and "⏩" or "⏪"

    if mp.get_property_number("osd-level") >= 3 then
        mp.osd_message(string.format(
            "%s %d sec",
            arrow, math.abs(last_amount)
        ), OSD_DURATION)
        return
    end

    local percent = 0
    if duration > 0 then
        percent = math.floor((pos / duration) * 100 + 0.5)
    end

    mp.osd_message(string.format(
        "%s %d sec   %s / %s  (%d%%)",
        arrow, math.abs(last_amount),
        format_time(pos), format_time(duration), percent
    ), OSD_DURATION)
end

local function do_seek(amount)
    last_amount = amount
    local mode = EXACT and "exact" or "relative"
    mp.commandv("seek", tostring(amount), mode)

    if settle_timer then
        settle_timer:kill()
    end
    settle_timer = mp.add_timeout(OSD_SETTLE_DELAY, function()
        settle_timer = nil
        show_osd()
    end)
end

local bindings = {
    { name = "seek-small-forward",   amount =  STEP_SMALL  },
    { name = "seek-small-backward",  amount = -STEP_SMALL  },
    { name = "seek-medium-forward",  amount =  STEP_MEDIUM },
    { name = "seek-medium-backward", amount = -STEP_MEDIUM },
    { name = "seek-large-forward",   amount =  STEP_LARGE  },
    { name = "seek-large-backward",  amount = -STEP_LARGE  },
    { name = "seek-huge-forward",    amount =  STEP_HUGE   },
    { name = "seek-huge-backward",   amount = -STEP_HUGE   },
}

for _, b in ipairs(bindings) do
    local amount = b.amount
    mp.add_key_binding(nil, b.name, function()
        do_seek(amount)
    end, { repeatable = true })
end

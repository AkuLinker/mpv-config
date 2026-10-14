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
--
-- Works together with osd_progress.lua:
--   osd-level 3 -> status line + bar come from osd_progress, this script adds
--                  only a short "⏩ 5 sec" under them.
--   osd-level 1 -> this script shows its own full message with the same bar.

-- ============================================================
-- User settings
-- ============================================================

local STEP_SMALL  = 1    -- seconds
local STEP_MEDIUM = 5    -- seconds
local STEP_LARGE  = 10   -- seconds
local STEP_HUGE   = 30   -- seconds

local EXACT = false      -- true = frame-accurate seek (exact), false = keyframe seek (relative) (it's faster)

local OSD_DURATION = 3   -- how long (in seconds) the OSD message stays on screen

-- Progress bar under the seek message (keep in sync with osd_progress.lua
-- if you want both to look identical).
local SHOW_BAR    = true
local BAR_WIDTH   = 125      -- bar length in OSD units
local BAR_HEIGHT  = 2        -- bar thickness in OSD units
local BORDER      = 0.5        -- outline thickness (0 = none)
local FILL_COLOR  = "FFFFFF" -- played part, ASS color in BBGGRR order
local EMPTY_COLOR = "FFFFFF" -- remaining part
local EMPTY_ALPHA = "B0"     -- 00 = opaque, FF = invisible

-- ============================================================

local mp = require 'mp'

local last_amount = 0

-- True while we're waiting for our own seek to finish. The OSD is shown
-- from the "playback-restart" event, which mpv fires once a seek has really
-- completed - so the displayed position is always the final one, even on
-- slow disks or network streams (a fixed delay could show a stale value).
local pending_osd = false

-- Safety net: if a seek never completes (unseekable stream, seek past the
-- end of a file), forget about it after this many seconds so a later,
-- unrelated playback-restart doesn't show a stale message.
local PENDING_TIMEOUT = 2
local pending_timer = nil

local function rect(w)
    return string.format("m 0 0 l %d 0 %d %d 0 %d", w, w, BAR_HEIGHT, BAR_HEIGHT)
end

-- ASS drawing of the bar, starting on a new line. Must be used in a
-- message that begins with osd-ass-cc/0 (ASS escaping turned off).
local function bar_ass(pos, duration)
    local fw = math.floor(BAR_WIDTH * pos / duration + 0.5)
    fw = math.max(0, math.min(BAR_WIDTH, fw))
    local ew = BAR_WIDTH - fw

    local s = string.format("\\N{\\r\\bord%g\\shad0\\3c&H000000&}", BORDER)
    if fw > 0 then
        s = s .. "{\\1c&H" .. FILL_COLOR .. "&\\1a&H00&\\p1}" .. rect(fw) .. "{\\p0}"
    end
    if ew > 0 then
        s = s .. "{\\1c&H" .. EMPTY_COLOR .. "&\\1a&H" .. EMPTY_ALPHA .. "&\\p1}"
              .. rect(ew) .. "{\\p0}"
    end
    return s .. "{\\r}"
end

-- When the current seek message disappears (mp.get_time() clock).
-- Used to redraw it in the right style if osd-level is toggled meanwhile.
local msg_until = 0

local function show_osd(show_for)
    show_for  = show_for or OSD_DURATION
    msg_until = mp.get_time() + show_for

    local pos      = mp.get_property_number("time-pos") or 0
    local duration = mp.get_property_number("duration") or 0

    local arrow = last_amount >= 0 and "⏩" or "⏪"

    -- osd-level 3: osd_progress.lua already shows time + bar, keep it short.
    if (mp.get_property_number("osd-level") or 1) >= 3 then
        mp.osd_message(string.format(
            "%s %d sec",
            arrow, math.abs(last_amount)
        ), show_for)
        return
    end

    -- Same formatting mpv uses for the "o" status line (osd_progress.lua),
    -- so both look identical: 00:17:54 / 00:25:03 (72%)
    local text = string.format(
        "%s %d sec   %s / %s (%s%%)",
        arrow, math.abs(last_amount),
        mp.get_property_osd("time-pos", "00:00:00"),
        mp.get_property_osd("duration", "00:00:00"),
        mp.get_property_osd("percent-pos", "0")
    )

    if SHOW_BAR and duration > 0 then
        local ass_on = mp.get_property_osd("osd-ass-cc/0")
        mp.osd_message(ass_on .. text .. bar_ass(pos, duration), show_for)
    else
        mp.osd_message(text, show_for)
    end
end

local function clear_pending()
    pending_osd = false
    if pending_timer then
        pending_timer:kill()
        pending_timer = nil
    end
end

mp.register_event("playback-restart", function()
    if pending_osd then
        clear_pending()
        show_osd()
    end
end)

-- If "o" toggles osd-level while a seek message is still on screen, redraw
-- it in the style for the new level (short at 3, full with bar at 1) for
-- the time it had left, so the two never stack up.
mp.observe_property("osd-level", "number", function()
    local left = msg_until - mp.get_time()
    if left > 0.05 then
        show_osd(left)
    end
end)

-- A new file also fires playback-restart; never show a seek message for it.
mp.register_event("start-file", clear_pending)

local function do_seek(amount)
    last_amount = amount
    local mode = EXACT and "exact" or "relative"

    clear_pending()
    pending_osd = true
    pending_timer = mp.add_timeout(PENDING_TIMEOUT, clear_pending)

    mp.commandv("seek", tostring(amount), mode)
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

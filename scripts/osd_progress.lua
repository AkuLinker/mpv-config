-- osd_progress.lua
-- Adds a thin progress bar under mpv's osd-level 3 status line
-- ("II 00:10:37 / 00:23:40 (45%)").
--
-- Works together with seek_display.lua: when osd-level is 3, seek_display
-- shows its short "⏩ 5 sec" message, which appears right under the bar.
--
-- Toggle stays the same in input.conf:
--   o   no-osd cycle-values osd-level 3 1

-- ============================================================
-- User settings
-- ============================================================

local BAR_WIDTH   = 100      -- bar length in OSD units (scales with the OSD like text does)
local BAR_HEIGHT  = 2        -- bar thickness in OSD units
local BORDER      = 0.5        -- outline thickness (0 = none)

local FILL_COLOR  = "FFFFFF" -- played part, ASS color in BBGGRR order
local EMPTY_COLOR = "FFFFFF" -- remaining part
local EMPTY_ALPHA = "B0"     -- 00 = opaque, FF = invisible

-- The text line above the bar. This mirrors mpv's default level-3 status.
local STATUS = "${osd-sym-cc} ${time-pos} / ${duration} (${percent-pos}%)"

-- ============================================================

local mp = require 'mp'

local active  = false
local last_fw = nil

local function rect(w)
    return string.format("m 0 0 l %d 0 %d %d 0 %d", w, w, BAR_HEIGHT, BAR_HEIGHT)
end

local function build(percent)
    if not percent then return STATUS end  -- live streams etc.: no bar

    local fw = math.floor(BAR_WIDTH * percent / 100 + 0.5)
    fw = math.max(0, math.min(BAR_WIDTH, fw))
    local ew = BAR_WIDTH - fw

    -- osd-ass-cc/0 turns off ASS escaping so we can draw; /1 turns it back on.
    local s = STATUS .. "${osd-ass-cc/0}\\N"
        .. string.format("{\\r\\bord%g\\shad0\\3c&H000000&}", BORDER)
    if fw > 0 then
        s = s .. "{\\1c&H" .. FILL_COLOR .. "&\\1a&H00&\\p1}" .. rect(fw) .. "{\\p0}"
    end
    if ew > 0 then
        s = s .. "{\\1c&H" .. EMPTY_COLOR .. "&\\1a&H" .. EMPTY_ALPHA .. "&\\p1}"
              .. rect(ew) .. "{\\p0}"
    end
    return s .. "{\\r}${osd-ass-cc/1}"
end

-- Only rewrite osd-msg3 when the bar actually changes by a unit,
-- not on every percent-pos tick.
local function on_percent(_, percent)
    local fw = percent and math.floor(BAR_WIDTH * percent / 100 + 0.5) or -1
    if fw == last_fw then return end
    last_fw = fw
    -- osd-msg3 goes through mpv's C-style escape parser, so every
    -- backslash in the ASS tags must be doubled to survive it.
    local msg = build(percent):gsub("%\\", "\\\\")
    mp.set_property("osd-msg3", msg)
end

local function start()
    if active then return end
    active  = true
    last_fw = nil
    mp.observe_property("percent-pos", "number", on_percent)
end

local function stop()
    if not active then return end
    active = false
    mp.unobserve_property(on_percent)
    mp.set_property("osd-msg3", "")   -- back to mpv's default
end

-- Only do work while the status line is actually visible.
mp.observe_property("osd-level", "number", function(_, level)
    if level and level >= 3 then start() else stop() end
end)

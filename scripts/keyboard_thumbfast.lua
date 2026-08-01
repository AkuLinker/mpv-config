-- keyboard_thumbfast.lua
--
-- Dependencies:
-- uosc (https://github.com/tomasklaen/uosc) — renders the timeline and handles hover
-- thumbfast (https://github.com/po5/thumbfast) — generates and displays the preview thumbnail
--
-- Lets you scrub the timeline with the keyboard instead of the mouse, while
-- still getting uosc's timeline hover indicator and thumbfast's thumbnail
-- preview (the picture-in-picture box shown when you hover the seekbar).
--
-- How it works: mpv's built-in "mouse x y" input command only updates mpv's
-- internal mouse position (it does NOT move the real OS cursor - see
-- DOCS/man/input.rst). uosc and thumbfast just read that position to decide
-- what to preview, so we can fake a hover at an arbitrary point on the
-- timeline purely from a keypress, with no real mouse movement at all.
--
-- IMPORTANT: the seek keys are NOT bound by default. Add a binding for
-- these script-message names to your input.conf, e.g.:
--
--   alt+RIGHT  script-binding keyboard_thumbfast/kb-scrub-fwd
--   alt+LEFT   script-binding keyboard_thumbfast/kb-scrub-back
--
-- ENTER and ESC are hardcoded on purpose: they're only force-bound (locking
-- out their normal behavior, e.g. ESC's usual fullscreen-exit) while a
-- scrub preview is actually in progress, and released back to their normal
-- behavior immediately after you commit or cancel.
--
-- Real mouse activity during a preview: the real OS cursor is force-hidden
-- for the whole duration of a preview (see suppress_cursor/restore_cursor
-- below), since our synthetic mouse events would otherwise make it flash
-- into view. If you actually move the real mouse, or trigger any other
-- seek (e.g. plain arrow keys) while a preview is active, the preview is
-- auto-cancelled - same as pressing ESC - which also restores the cursor,
-- so it becomes visible again as soon as you interact normally.
--
-- Calibration: uosc's timeline normally spans the full window width, so X
-- is computed from 0..osd width. TIMELINE_Y below is a guess at the
-- vertical pixel of the timeline area for default uosc settings; if your
-- uosc.conf uses a different timeline size/scale, the preview may miss the
-- hitbox. To calibrate: add a temporary binding that prints
-- mp.get_property_native("mouse-pos") while you hover the timeline by hand,
-- and adjust TIMELINE_Y_OFFSET accordingly.

local mp = require 'mp'

local STEP_SECONDS = 5          -- seconds moved per keypress (holding repeats)
local TIMELINE_Y_OFFSET = 15    -- pixels from the bottom of the window

local preview_active = false
local preview_time = 0

-- coordinates of the last mouse position WE sent, so the mouse-pos
-- observer below can tell our own synthetic moves apart from real ones
local last_synth_x, last_synth_y = nil, nil

local function osd_dim()
    local w, h = mp.get_osd_size()
    return w or 0, h or 0
end

-- Move the fake mouse position away from the timeline hitbox, so uosc and
-- thumbfast register a "mouse left the timeline" and hide the preview.
-- Just clearing our own state isn't enough - uosc still thinks the mouse
-- is hovering wherever we last sent it until we tell it otherwise.
local function move_mouse_off_timeline()
    local w, h = osd_dim()
    local x, y = math.floor(w / 2), math.floor(h / 2)
    last_synth_x, last_synth_y = x, y
    mp.commandv("mouse", x, y)
end

-- forward declarations, defined further down
local commit_preview, cancel_preview

local saved_cursor_autohide = nil

-- Our synthetic "mouse" events are indistinguishable from real mouse motion
-- as far as mpv's cursor-autohide logic is concerned, so without this the
-- real OS cursor pops into view during a preview. cursor-autohide has a
-- special "always" value that keeps the cursor hidden no matter what, so
-- we switch to that for the duration of the preview and restore the
-- user's original setting right after commit/cancel.
local function suppress_cursor()
    saved_cursor_autohide = mp.get_property("cursor-autohide")
    mp.set_property("cursor-autohide", "always")
end

local function restore_cursor()
    if saved_cursor_autohide then
        mp.set_property("cursor-autohide", saved_cursor_autohide)
        saved_cursor_autohide = nil
    end
end

local function lock_confirm_keys()
    mp.add_forced_key_binding("ENTER", "kb-scrub-confirm-lock", function() commit_preview() end)
    mp.add_forced_key_binding("ESC", "kb-scrub-cancel-lock", function() cancel_preview() end)
end

local function unlock_confirm_keys()
    mp.remove_key_binding("kb-scrub-confirm-lock")
    mp.remove_key_binding("kb-scrub-cancel-lock")
end

local function move_preview(delta)
    local dur = mp.get_property_number("duration")
    if not dur or dur <= 0 then return end

    if not preview_active then
        preview_time = mp.get_property_number("time-pos", 0)
        preview_active = true
        lock_confirm_keys()
        suppress_cursor()
    end

    preview_time = math.max(0, math.min(dur, preview_time + delta))

    local w, h = osd_dim()
    local x = math.floor((preview_time / dur) * w)
    local y = h - TIMELINE_Y_OFFSET

    last_synth_x, last_synth_y = x, y
    mp.commandv("mouse", x, y)
    mp.osd_message(mp.format_time(preview_time), 2)
end

commit_preview = function()
    if not preview_active then return end
    preview_active = false
    local target = preview_time
    mp.commandv("seek", target, "absolute", "exact")
    mp.osd_message("Jumped to " .. mp.format_time(target), 2)
    unlock_confirm_keys()
    move_mouse_off_timeline()
    restore_cursor()
end

cancel_preview = function()
    if not preview_active then return end
    preview_active = false
    mp.osd_message("")
    unlock_confirm_keys()
    move_mouse_off_timeline()
    restore_cursor()
end

-- Real mouse movement during a preview: cancel, so the user's actual mouse
-- takes back over instead of fighting our synthetic position.
mp.observe_property("mouse-pos", "native", function(_, pos)
    if not preview_active or not pos then return end
    if pos.x == last_synth_x and pos.y == last_synth_y then return end
    cancel_preview()
end)

-- Any other seek happening while a preview is active (e.g. plain arrow
-- keys) means the user moved on to normal seeking - cancel the preview
-- instead of leaving it stuck showing a stale position. We use the "seek"
-- event rather than watching time-pos, since time-pos changes continuously
-- during normal playback and would cancel the preview instantly.
mp.register_event("seek", function()
    if preview_active then cancel_preview() end
end)

mp.add_key_binding(nil, "kb-scrub-fwd", function() move_preview(STEP_SECONDS) end, { repeatable = true })
mp.add_key_binding(nil, "kb-scrub-back", function() move_preview(-STEP_SECONDS) end, { repeatable = true })

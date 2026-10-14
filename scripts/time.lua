-- time.lua
-- Shows the clock time when the current video will finish playing.
-- Takes playback speed into account (playtime-remaining already does).
--
-- Bind this script in your input.conf:
-- n script-binding show-end-time

local mp = require 'mp'

local osd_duration = 3  -- OSD message duration in seconds

local function show_end_time_fn()
    local remaining = mp.get_property_number("playtime-remaining")
    if not remaining then
        mp.osd_message("Playback end time unknown", osd_duration)
        return
    end

    local end_time = os.time() + math.floor(remaining + 0.5)
    local message = "Playback ends at: " .. os.date("%H:%M", end_time)
    mp.msg.info(message)
    mp.osd_message(message, osd_duration)
end

mp.add_key_binding(nil, "show-end-time", show_end_time_fn)

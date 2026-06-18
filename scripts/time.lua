-- end-time.lua
-- Shows the time when the current video will finish playing.
--
-- Bind this script in your input.conf:
-- n script-binding show-end-time

local function show_end_time_fn()
    local clock_hour    = tonumber(os.date("%H"))
    local clock_minutes = tonumber(os.date("%M"))

    local remaining_seconds = mp.get_property_number("playtime-remaining") or 0
    local remaining_hours   = math.floor(remaining_seconds / 3600)
    local remaining_minutes = (remaining_seconds / 60) % 60

    local end_hour = clock_hour + remaining_hours
    local end_min  = math.floor(clock_minutes + remaining_minutes)

    if end_min >= 60 then
        end_hour = math.floor(end_hour + (end_min / 60))
        end_min  = end_min % 60
    end

    if end_hour >= 24 then
        end_hour = end_hour % 24
    end

    local message = string.format("Playback ends at: %02d:%02d", end_hour, end_min)
        mp.msg.info(message)
        mp.osd_message(message)
end

mp.add_key_binding(nil, "show-end-time", show_end_time_fn)

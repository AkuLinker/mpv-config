-- autoloop.lua
--
-- Loops short files (GIF-like clips) automatically: if a file's duration is
-- at or below autoloop_duration seconds, loop-file=inf is set for that file.
-- Saving the playback position on quit is also disabled for such files.
--
-- Both settings are applied as *file-local* options, so mpv itself restores
-- the previous values as soon as the next file starts. No manual "unloop"
-- logic is needed, and a loop you enable yourself (e.g. with the L key) is
-- never touched by this script.
--
-- Files with unknown or zero duration (still images, live streams) are
-- ignored, so a single image never gets stuck looping in a playlist.
--
-- Configuration: script-opts/autoloop.conf
--     autoloop_duration=5
-- or in mpv.conf:
--     script-opts-append=autoloop-autoloop_duration=5

local mp = require 'mp'
local options = require 'mp.options'

local o = {
    autoloop_duration = 5,
}
options.read_options(o, "autoloop")

mp.register_event("file-loaded", function()
    local duration = mp.get_property_number("duration")
    if not duration or duration <= 0 then return end

    if duration <= o.autoloop_duration then
        mp.set_property("file-local-options/loop-file", "inf")
        mp.set_property_bool("file-local-options/save-position-on-quit", false)
    end
end)

-- toggle-bw.lua
--
-- What this does:
-- Toggles black and white mode and shows the message about it

local mp    = require "mp"

mp.register_script_message("toggle-bw", function()
local sat = mp.get_property_number("saturation")
if sat == -100 then
    mp.set_property("saturation", 0)
    mp.osd_message("B&W: Off", 3)
    else
        mp.set_property("saturation", -100)
        mp.osd_message("B&W: On", 3)
        end
        end)

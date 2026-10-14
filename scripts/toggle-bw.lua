-- toggle-bw.lua
--
-- Toggles black and white mode and shows a message about it.
-- Turning B&W off restores the saturation you had before (instead of
-- always resetting it to 0).
--
-- input.conf example:
--   B script-message toggle-bw

local mp = require "mp"

-- saturation value from before B&W was switched on
local saved_saturation = nil

mp.register_script_message("toggle-bw", function()
    local sat = mp.get_property_number("saturation")
    if sat == -100 then
        mp.set_property_number("saturation", saved_saturation or 0)
        saved_saturation = nil
        mp.osd_message("B&W: Off", 3)
    else
        saved_saturation = sat
        mp.set_property_number("saturation", -100)
        mp.osd_message("B&W: On", 3)
    end
end)

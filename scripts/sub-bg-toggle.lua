-- Bind this script in your input.conf:
-- y script-binding toggle-sub-bg

local enabled = false

local off_values = {
    ["sub-border-style"] = "outline",
    ["sub-outline-size"] = "1.5",
    ["sub-shadow-offset"] = "0",
    ["sub-back-color"] = "0/0/0/0",
}

local on_values = {
    ["sub-border-style"] = "background-box",
    ["sub-outline-size"] = "0",
    ["sub-shadow-offset"] = "4",
    ["sub-back-color"] = "0.0/0.0/0.0/0.75",
}

local function toggle_sub_bg()
    local values = enabled and off_values or on_values

    for prop, val in pairs(values) do
        mp.set_property(prop, val)
    end

    if enabled then
        mp.osd_message("Subtitles background: Off")
    else
        mp.osd_message("Subtitles background: On")
    end

    enabled = not enabled
end

mp.add_key_binding(nil, "toggle-sub-bg", toggle_sub_bg)

-- Bind this script in your input.conf:
-- b script-binding open-google-translate

local mp = require 'mp'

local function translate_current_sub()
    local sub_text = mp.get_property("sub-text")

    if not sub_text or sub_text == "" then
        mp.osd_message("No subtitle to translate", 2)
        return
    end

    -- Strip newlines from two-line subtitles
    local clean_text = sub_text:gsub(" *\n *", " ")

    -- Google Translate: auto-detect language -> Russian
    -- Change "ru" to your target language code if needed
    local base_url = "https://translate.google.com/?sl=auto&tl=ru&op=translate&text="

    -- URL-encode special characters (RFC 3986)
    local encoded_text = clean_text:gsub("([^%w%-_%.%~])", function(c)
        return string.format("%%%02X", string.byte(c))
    end)

    mp.commandv("run", "xdg-open", base_url .. encoded_text)
end

mp.add_key_binding(nil, "open-google-translate", translate_current_sub)

-- google-translate.lua
--
-- Opens the currently shown subtitle line in Google Translate in your
-- default web browser. Works on Linux, Windows and macOS.
--
-- Bind it in input.conf:
--   b script-binding google-translate/open-google-translate
--
-- Options (script-opts/google-translate.conf):
--   source_lang=auto
--   target_lang=ru      (en, fi, de, fr, ...)

local mp = require 'mp'
local msg = require 'mp.msg'

local o = {
    source_lang = "auto",
    target_lang = "ru",
}
require('mp.options').read_options(o, "google-translate")

local platform = mp.get_property_native("platform")
    or (package.config:sub(1, 1) == "\\" and "windows" or "linux")

-- Opens a URL in the default browser. No shell is involved, so characters
-- like & in the URL can't be misinterpreted.
local function open_url(url)
    local args
    if platform == "windows" then
        -- Unlike "cmd /c start", this doesn't break on & in URLs
        args = { "rundll32", "url.dll,FileProtocolHandler", url }
    elseif platform == "darwin" then
        args = { "open", url }
    else
        args = { "xdg-open", url }
    end
    mp.command_native_async({
        name = "subprocess",
        args = args,
        playback_only = false,
        detach = true,
    }, function(success, res, err)
        if not success or (res and res.error_string ~= "" and res.error_string ~= nil) then
            msg.warn("could not open browser: " .. tostring(err or res.error_string))
            mp.osd_message("Could not open browser (" .. args[1] .. ")", 3)
        end
    end)
end

local function translate_current_sub()
    local sub_text = mp.get_property("sub-text")

    if not sub_text or sub_text == "" then
        mp.osd_message("No subtitle to translate", 2)
        return
    end

    -- Strip newlines from two-line subtitles
    local clean_text = sub_text:gsub("%s*\n%s*", " ")

    local base_url = string.format(
        "https://translate.google.com/?sl=%s&tl=%s&op=translate&text=",
        o.source_lang, o.target_lang
    )

    -- URL-encode special characters (RFC 3986)
    local encoded_text = clean_text:gsub("([^%w%-_%.%~])", function(c)
        return string.format("%%%02X", string.byte(c))
    end)

    open_url(base_url .. encoded_text)
end

mp.add_key_binding(nil, "open-google-translate", translate_current_sub)

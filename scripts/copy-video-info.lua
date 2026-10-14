--[[
copy-video-info.lua

Opens a uosc menu that lets you copy various pieces of information about the
currently playing file to the system clipboard (video title, current
subtitle, file path, timestamp, media info, ...).

------------------------------------------------------------------------------
DEPENDENCIES
------------------------------------------------------------------------------
1) uosc (https://github.com/tomasklaen/uosc)
   This script does not draw any UI itself - it sends a menu definition to
   uosc via script messages and lets uosc render it.

2) Clipboard:
   - Linux (Wayland): wl-copy   (package "wl-clipboard")
   - Linux (X11):     xclip     (or xsel as a fallback)
   - Windows / macOS: nothing to install. mpv 0.40+ writes the clipboard
     itself (Unicode-safe, no extra process). On older mpv the script falls
     back to PowerShell (Windows) or pbcopy (macOS).

   On Linux the external tool is used first on purpose: wl-copy/xclip keep
   serving the copied text after mpv quits. mpv's own clipboard is used as
   a fallback there (only works when mpv runs as a native Wayland window).

   NOTE ON IMPLEMENTATION: wl-copy/xclip/xsel fork themselves into the
   background to keep serving the clipboard. If that background process kept
   mpv's output pipes open, mpv would wait on them forever (even on quit).
   The tools are therefore started through a tiny shell wrapper that sends
   their output to /dev/null - the shell exits as soon as the copy is done
   and its exit code tells whether it worked.

------------------------------------------------------------------------------
SETUP / KEYBINDING
------------------------------------------------------------------------------
Not bound to any key by default. Add a line like this to input.conf:

    ctrl+c script-binding copy-video-info/open-copy-menu

------------------------------------------------------------------------------
OPTIONS  (script-opts/copy-video-info.conf)
------------------------------------------------------------------------------
    pause_on_open=yes      pause playback when the menu opens
    resume_on_close=yes    when the menu closes, resume playback if it was
                           playing before (same as sub-search and
                           confirm-delete-file). Set to no to stay paused
                           after copying, like older versions of this script.

------------------------------------------------------------------------------
BEHAVIOR
------------------------------------------------------------------------------
- Opening the menu pauses playback; closing it restores the previous state
  (configurable, see OPTIONS).
- Menu items are numbered; you can either click an item or press the
  corresponding number key (1-7) to select it.
- After copying, an OSD message confirms what was copied.
--]]

local mp = require 'mp'
local msg = require 'mp.msg'
local utils = require 'mp.utils'

local o = {
    pause_on_open = true,
    resume_on_close = true,
}
require('mp.options').read_options(o, 'copy-video-info')

local script_name = mp.get_script_name()

local platform = mp.get_property_native("platform")
    or (package.config:sub(1, 1) == "\\" and "windows" or "linux")

------------------------------------------------------------------------------
-- Small formatting helpers
------------------------------------------------------------------------------

-- Formats seconds as HH:MM:SS
local function format_time(seconds)
    if seconds == nil then return "00:00:00" end
    seconds = math.floor(seconds)
    local h = math.floor(seconds / 3600)
    local m = math.floor((seconds % 3600) / 60)
    local s = seconds % 60
    return string.format("%02d:%02d:%02d", h, m, s)
end

-- Formats a byte count as a human readable string (KB/MB/GB)
local function format_bytes(bytes)
    if bytes == nil then return "N/A" end
    local units = { "B", "KB", "MB", "GB", "TB" }
    local i = 1
    local value = bytes
    while value >= 1024 and i < #units do
        value = value / 1024
        i = i + 1
    end
    return string.format("%.2f %s", value, units[i])
end

local function show_osd(text)
    mp.osd_message(text, 3)
end

------------------------------------------------------------------------------
-- Clipboard handling (cross-platform)
------------------------------------------------------------------------------

-- mpv 0.40+ built-in clipboard. Returns true on success.
local function copy_native(text)
    return mp.set_property("clipboard/text", text) == true
end

-- External tool for the current OS. Text is passed on stdin (stdin_data),
-- so there's no quoting/escaping and no length limit.
local function external_args()
    if platform == "windows" then
        -- Read stdin explicitly as UTF-8, otherwise PowerShell decodes it
        -- with the console codepage and non-ASCII text gets garbled.
        return {
            "powershell", "-NoProfile", "-NonInteractive", "-Command",
            "[Console]::InputEncoding = New-Object System.Text.UTF8Encoding $false; "
            .. "Set-Clipboard -Value ([Console]::In.ReadToEnd())",
        }
    elseif platform == "darwin" then
        -- pbcopy needs a UTF-8 locale, which isn't set when mpv is started
        -- from Finder.
        return { "sh", "-c", "LANG=en_US.UTF-8 pbcopy" }
    end

    -- Linux / BSD: pick the tool matching the session, fall back to others.
    -- Exit code 127 = no tool found.
    return { "sh", "-c", [[
{
  if [ -n "$WAYLAND_DISPLAY" ] && command -v wl-copy >/dev/null 2>&1; then
    wl-copy
  elif command -v xclip >/dev/null 2>&1; then
    xclip -silent -in -selection clipboard
  elif command -v xsel >/dev/null 2>&1; then
    xsel --clipboard --input
  elif command -v wl-copy >/dev/null 2>&1; then
    wl-copy
  else
    exit 127
  fi
} >/dev/null 2>&1
]] }
end

local function copy_external(text)
    local res = mp.command_native({
        name = "subprocess",
        args = external_args(),
        stdin_data = text,
        playback_only = false,
        capture_stdout = false,
        capture_stderr = false,
    })
    if res and res.status == 0 then return true end
    msg.verbose("external clipboard tool failed, status: " .. tostring(res and res.status))
    return false
end

-- Writes text to the clipboard. Returns true on success.
local function copy_to_clipboard(text)
    if platform == "windows" or platform == "darwin" then
        return copy_native(text) or copy_external(text)
    end
    -- Linux: external tool first (survives mpv quitting), native as fallback
    return copy_external(text) or copy_native(text)
end

------------------------------------------------------------------------------
-- Info gathering functions - one per menu item
------------------------------------------------------------------------------

local function get_video_title()
    return mp.get_property("media-title") or mp.get_property("filename") or "N/A"
end

local function get_current_subtitle_plain()
    local text = mp.get_property("sub-text")
    if text == nil or text == "" then
        return nil
    end
    return text
end

local function get_current_subtitle_timed()
    local text = mp.get_property("sub-text")
    if text == nil or text == "" then
        return nil
    end
    local start_time = mp.get_property_number("sub-start")
    local end_time = mp.get_property_number("sub-end")
    return string.format("[%s --> %s] %s",
        format_time(start_time), format_time(end_time), text)
end

local function get_file_path()
    local path = mp.get_property("path")
    if path == nil then return nil end

    -- URLs are returned untouched
    if path:match("^%a[%w+.-]*://") then return path end

    -- mpv 0.39+: let mpv make the path absolute and clean it up
    local normalized = mp.command_native({"normalize-path", path})
    if type(normalized) == "string" and normalized ~= "" then
        return normalized
    end

    -- Older mpv: resolve relative paths against mpv's working directory.
    local is_unix_absolute = path:sub(1, 1) == "/"
    local is_windows_absolute = path:match("^%a:[\\/]") ~= nil
        or path:match("^[\\/][\\/]") ~= nil -- UNC path (\\server\share)

    if not is_unix_absolute and not is_windows_absolute then
        local dir = mp.get_property("working-directory")
        if dir then
            path = utils.join_path(dir, path)
        end
    end

    return path
end

local function get_timestamp()
    local pos = mp.get_property_number("time-pos") or 0
    local dur = mp.get_property_number("duration") or 0
    local percent = mp.get_property_number("percent-pos") or 0
    return string.format("%s/%s (%d%%)",
        format_time(pos), format_time(dur), math.floor(percent))
end

local function get_short_media_info()
    local width = mp.get_property_number("width")
    local height = mp.get_property_number("height")
    local video_format = mp.get_property("video-format")
    local audio_codec = mp.get_property("audio-codec-name")
    local dur = mp.get_property_number("duration")
    local fps = mp.get_property_number("container-fps") or mp.get_property_number("estimated-vf-fps")

    local lines = {}
    table.insert(lines, "Resolution: " .. ((width and height) and (width .. "x" .. height) or "N/A"))
    table.insert(lines, "Video codec: " .. (video_format or "N/A"))
    table.insert(lines, "Audio codec: " .. (audio_codec or "N/A"))
    table.insert(lines, "FPS: " .. (fps and string.format("%.3f", fps) or "N/A"))
    table.insert(lines, "Duration: " .. format_time(dur))

    return table.concat(lines, "\n")
end

local function get_full_media_info()
    local lines = {}

    table.insert(lines, "File: " .. (mp.get_property("filename") or "N/A"))
    table.insert(lines, "Container: " .. (mp.get_property("file-format") or "N/A"))
    table.insert(lines, "Duration: " .. format_time(mp.get_property_number("duration")))
    table.insert(lines, "File size: " .. format_bytes(mp.get_property_number("file-size")))
    table.insert(lines, "")

    local track_list = mp.get_property_native("track-list") or {}

    for _, track in ipairs(track_list) do
        if track.selected then
            table.insert(lines, string.format("[%s track #%d]", track.type, track.id))
            if track.codec then table.insert(lines, "  Codec: " .. track.codec) end
            if track.lang then table.insert(lines, "  Language: " .. track.lang) end
            if track.title then table.insert(lines, "  Title: " .. track.title) end

            if track.type == "video" then
                if track["demux-w"] and track["demux-h"] then
                    table.insert(lines, "  Resolution: " .. track["demux-w"] .. "x" .. track["demux-h"])
                end
                if track["demux-fps"] then
                    table.insert(lines, "  FPS: " .. string.format("%.3f", track["demux-fps"]))
                end
                if track["demux-bitrate"] then
                    table.insert(lines, "  Bitrate: " .. format_bytes(track["demux-bitrate"] / 8) .. "/s")
                end
            elseif track.type == "audio" then
                if track["demux-samplerate"] then
                    table.insert(lines, "  Sample rate: " .. track["demux-samplerate"] .. " Hz")
                end
                if track["demux-channel-count"] then
                    table.insert(lines, "  Channels: " .. track["demux-channel-count"])
                end
                if track["demux-bitrate"] then
                    table.insert(lines, "  Bitrate: " .. format_bytes(track["demux-bitrate"] / 8) .. "/s")
                end
            elseif track.type == "sub" then
                if track.forced then table.insert(lines, "  Forced: yes") end
                if track.default then table.insert(lines, "  Default: yes") end
            end

            table.insert(lines, "")
        end
    end

    return table.concat(lines, "\n")
end

------------------------------------------------------------------------------
-- Menu definition and dispatch
------------------------------------------------------------------------------

-- Ordered list: index in this table = the number key that selects it.
local menu_items = {
    { title = "1. Video title",              value = "title",     label = "Video title" },
    { title = "2. Current subtitle (text)",  value = "sub_plain", label = "Subtitle" },
    { title = "3. Current subtitle (timed)", value = "sub_timed", label = "Timed subtitle" },
    { title = "4. File path",                value = "path",      label = "File path" },
    { title = "5. Current timestamp",        value = "timestamp", label = "Timestamp" },
    { title = "6. Media info (full)",        value = "meta_full", label = "Full media info" },
    { title = "7. Media info (short)",       value = "meta_short",label = "Media info" },
}

-- Looks up the short human-readable label for a menu item value.
local function get_label_for(value)
    for _, item in ipairs(menu_items) do
        if item.value == value then return item.label end
    end
    return "Info"
end

-- Returns the text to copy for a given item value, or nil if there is
-- nothing meaningful to copy right now (e.g. no subtitle currently shown).
local function get_text_for(value)
    if value == "title" then return get_video_title()
    elseif value == "sub_plain" then return get_current_subtitle_plain()
    elseif value == "sub_timed" then return get_current_subtitle_timed()
    elseif value == "path" then return get_file_path()
    elseif value == "timestamp" then return get_timestamp()
    elseif value == "meta_full" then return get_full_media_info()
    elseif value == "meta_short" then return get_short_media_info()
    end
    return nil
end

local function handle_selection(value)
    local text = get_text_for(value)

    if text == nil or text == "" then
        show_osd("Nothing to copy")
        return
    end

    if copy_to_clipboard(text) then
        show_osd(get_label_for(value) .. " copied to clipboard")
    else
        show_osd("Failed to copy to clipboard (no clipboard tool found)")
        msg.warn("Could not copy to clipboard - no working clipboard method.")
    end
end

local MENU_TYPE = "copy_video_info_menu"

-- True if *this script* paused playback when the menu was opened.
local paused_by_us = false

local function restore_pause()
    if paused_by_us and o.resume_on_close then
        mp.set_property_bool("pause", false)
    end
    paused_by_us = false
end

-- Handles all events uosc sends back for our menu (callback mode).
mp.register_script_message("copy-video-info-menu-event", function(json)
    local ok, event = pcall(utils.parse_json, json)
    if not ok or event == nil then return end

    if event.type == "activate" then
        handle_selection(event.value)
        mp.commandv("script-message-to", "uosc", "close-menu", MENU_TYPE)
    elseif event.type == "key" then
        local index = tonumber(event.key) or tonumber(event.id)
        if index and menu_items[index] then
            handle_selection(menu_items[index].value)
            mp.commandv("script-message-to", "uosc", "close-menu", MENU_TYPE)
        end
    elseif event.type == "close" then
        restore_pause()
    end
end)

local function open_menu()
    -- Pause while the menu is open; remember whether we did it, so only our
    -- own pause is undone when the menu closes.
    if o.pause_on_open and not mp.get_property_bool("pause") then
        mp.set_property_bool("pause", true)
        paused_by_us = true
    end

    local menu = {
        type = MENU_TYPE,
        title = "Copy to clipboard",
        -- Disable the search box so number keys (1-7) reach our "key" event
        -- handler instead of being treated as a search query.
        search_style = "disabled",
        -- Let uosc listen for number keys 1-7 even though they aren't
        -- normally bound inside menus.
        bind_keys = { "1", "2", "3", "4", "5", "6", "7" },
        callback = { script_name, "copy-video-info-menu-event" },
        items = {},
    }

    for _, item in ipairs(menu_items) do
        table.insert(menu.items, { title = item.title, value = item.value })
    end

    mp.commandv("script-message-to", "uosc", "open-menu", utils.format_json(menu))
end

-- Not bound to anything by default. Bind it in input.conf, e.g.:
--   ctrl+c script-binding copy-video-info/open-copy-menu
mp.add_key_binding(nil, "open-copy-menu", open_menu)

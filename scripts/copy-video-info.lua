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
   uosc via script messages and lets uosc render it. Without uosc installed
   and running, the menu will simply never appear.

2) A clipboard tool available on PATH, depending on your OS:
   - Linux (Wayland): wl-copy   (package "wl-clipboard")
   - Linux (X11):     xclip     (or xsel as a fallback)
   - Windows:          PowerShell (built in, used via Set-Clipboard)
   - macOS:            pbcopy   (built into macOS, nothing to install)
   The script auto-detects your platform/session once on load and picks the
   most likely tool, falling back to alternatives on Linux if the first one
   isn't found.

   NOTE ON IMPLEMENTATION: clipboard copying is done via Lua's own
   io.popen(cmd, "w") rather than mpv's "subprocess" command. Clipboard
   tools like wl-copy/xclip/xsel fork themselves into the background to
   keep serving the clipboard selection. If we captured their stdout via
   mpv's subprocess command, mpv could hang waiting for that pipe to close
   (which may never happen) - including hanging on player quit. io.popen
   only writes to the process' stdin and doesn't wait on its stdout, so it
   doesn't run into that problem.

------------------------------------------------------------------------------
SETUP / KEYBINDING
------------------------------------------------------------------------------
This script intentionally does NOT bind itself to any key (key = nil below),
as requested. To actually be able to open the menu, add a line like this to
your input.conf:

    ctrl+c script-binding copy-video-info/open-menu

(pick whatever key combination you like; "ctrl+c" is just an example)

------------------------------------------------------------------------------
BEHAVIOR
------------------------------------------------------------------------------
- Opening the menu automatically pauses playback.
- Menu items are numbered; you can either click an item or press the
  corresponding number key (1-7) to select it.
- After copying, an OSD message confirms what was copied.
--]]

local mp = require 'mp'
local msg = require 'mp.msg'
local utils = require 'mp.utils'

local script_name = mp.get_script_name()

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
-- Clipboard handling (cross-platform, via io.popen)
------------------------------------------------------------------------------

-- Pure-Lua way to detect Windows: the standard "package.config" string
-- starts with the directory separator for the current platform ("\" on
-- Windows, "/" everywhere else). This doesn't depend on any mpv property.
local function is_windows()
    return package.config:sub(1, 1) == "\\"
end

-- Checks whether a shell command is available on PATH (unix only; on
-- Windows/macOS we always use tools that are guaranteed to be present).
local function command_exists(cmd)
    local pipe = io.popen("type " .. cmd .. " > /dev/null 2> /dev/null; printf \"$?\"", "r")
    if pipe == nil then return false end
    local exists = pipe:read("*a") == "0"
    pipe:close()
    return exists
end

-- Decides which shell command line to use for copying to the clipboard.
-- Computed once when the script loads (not on every copy).
local function detect_clipboard_cmd()
    if is_windows() then
        -- Read the piped stdin and set it as clipboard content via
        -- PowerShell, which handles multi-line/unicode text better than
        -- passing it as a quoted command-line argument to clip.exe.
        return "powershell -NoProfile -Command \"$input | Set-Clipboard\""
    end

    -- macOS
    if command_exists("pbcopy") then
        return "pbcopy"
    end

    -- Linux / BSD: prefer the tool matching the current session type.
    local session_type = os.getenv("XDG_SESSION_TYPE")
    local is_wayland = session_type == "wayland" or os.getenv("WAYLAND_DISPLAY") ~= nil

    if is_wayland and command_exists("wl-copy") then
        return "wl-copy"
    end
    if command_exists("xclip") then
        return "xclip -silent -in -selection clipboard"
    end
    if command_exists("xsel") then
        return "xsel --clipboard --input"
    end
    if command_exists("wl-copy") then
        return "wl-copy"
    end

    msg.error("No supported clipboard tool found (tried pbcopy/wl-copy/xclip/xsel).")
    return nil
end

local clipboard_cmd = detect_clipboard_cmd()

-- Writes text to the clipboard command's stdin. Returns true on success.
local function copy_to_clipboard(text)
    if clipboard_cmd == nil then return false end

    local pipe = io.popen(clipboard_cmd, "w")
    if pipe == nil then return false end

    pipe:write(text)
    pipe:close()
    return true
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

    -- Leave URLs and already-absolute paths untouched, otherwise resolve
    -- relative paths against mpv's working directory.
    local is_url = path:match("^%a[%w+.-]*://") ~= nil
    local is_unix_absolute = path:sub(1, 1) == "/"
    local is_windows_absolute = path:match("^%a:[\\/]") ~= nil

    if not is_url and not is_unix_absolute and not is_windows_absolute then
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
    table.insert(lines, "Resolution: " .. (width and (width .. "x" .. height) or "N/A"))
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
        msg.warn("Could not copy to clipboard - clipboard_cmd is nil or io.popen failed.")
    end
end

local MENU_TYPE = "copy_video_info_menu"

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
    end
end)

local function open_menu()
    -- Pause playback while the menu is open, as requested.
    mp.set_property_bool("pause", true)

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

-- Registered with key = nil, so it is NOT bound to anything by default.
-- Bind it yourself in input.conf, e.g.:
--   ctrl+c script-binding copy-video-info/open-menu
mp.add_key_binding(nil, "open-copy-menu", open_menu)

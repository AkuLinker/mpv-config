--[[
    sub-search.lua
    Subtitle search with uosc integration for mpv.
    Works on Linux, Windows and macOS.

    Installation:
      Copy to the mpv scripts folder:
        Linux/macOS: ~/.config/mpv/scripts/
        Windows:     %APPDATA%\mpv\scripts\

    Key bindings (add to input.conf):
      ctrl+f        script-binding sub-search-open
      ctrl+F        script-binding sub-search-open-secondary

    Usage:
      Press the bound key — a uosc palette opens with all subtitle lines
      from the current subtitle track (primary or secondary, depending on
      which binding was used). Type to filter. Click or press Enter on a
      result to jump to that moment (sub-delay is taken into account).
      Note: filtering is handled by uosc (fuzzy match on the item title).

    Dependencies:
      - uosc  (https://github.com/tomasklaen/uosc)
      - ffmpeg on PATH (required only for subtitles embedded inside the
        video file, and for re-encoding non-UTF-8 external subtitles)

    Embedded subtitles are extracted in the background, so mpv keeps
    playing smoothly while ffmpeg works; the menu opens when it's done.
--]]

local mp = require 'mp'
local msg = require 'mp.msg'
local utils = require 'mp.utils'

-- ─── Config ───────────────────────────────────────────────────────────────────

local config = {
    -- Maximum number of subtitle lines loaded into the menu
    max_items = 6000,
    -- Pause playback while the search menu is open, and restore the
    -- previous play/pause state when it closes. Set to false to leave
    -- playback running untouched while searching.
    pause_on_open = true,
    -- Codepage to assume for external subtitle files that are not valid
    -- UTF-8 (e.g. "cp1251" for old Russian .srt files). If empty, mpv's own
    -- "sub-codepage" option is used when it names a specific codepage.
    fallback_codepage = "",
}
require('mp.options').read_options(config, "sub-search")

-- ─── Utilities ────────────────────────────────────────────────────────────────

local function timecode_to_seconds(tc)
    tc = tc:gsub(",", ".")
    local h, m, s, ms = tc:match("(%d+):(%d+):(%d+)%.(%d+)")
    if not h then
        m, s, ms = tc:match("(%d+):(%d+)%.(%d+)")
        h = 0
    end
    if not m then return 0 end
    ms = ms or "0"
    while #ms < 3 do ms = ms .. "0" end
    return tonumber(h) * 3600 + tonumber(m) * 60 + tonumber(s) + tonumber(ms) / 1000
end

local function seconds_to_hms(secs)
    secs = math.floor(secs)
    local h = math.floor(secs / 3600)
    local m = math.floor((secs % 3600) / 60)
    local s = secs % 60
    if h > 0 then
        return string.format("%d:%02d:%02d", h, m, s)
    else
        return string.format("%d:%02d", m, s)
    end
end

local function strip_tags(text)
    text = text:gsub("{[^}]*}", "")
    text = text:gsub("<[^>]+>", "")
    text = text:gsub("%s+", " ")
    return text:match("^%s*(.-)%s*$")
end

-- Strict-enough UTF-8 validity check (Lua 5.1 / LuaJIT compatible).
local function is_valid_utf8(s)
    local i, n = 1, #s
    while i <= n do
        local c = s:byte(i)
        local len
        if c < 0x80 then len = 1
        elseif c >= 0xC2 and c <= 0xDF then len = 2
        elseif c >= 0xE0 and c <= 0xEF then len = 3
        elseif c >= 0xF0 and c <= 0xF4 then len = 4
        else return false end
        for j = i + 1, i + len - 1 do
            local cc = s:byte(j)
            if not cc or cc < 0x80 or cc > 0xBF then return false end
        end
        i = i + len
    end
    return true
end

local temp_counter = 0

-- Unique temp file path. os.tmpname() is avoided on purpose: on Windows it
-- returns a path in the drive root (usually not writable), and on Linux it
-- creates an empty file that would be left behind.
local function temp_path(ext)
    temp_counter = temp_counter + 1
    local dir = os.getenv("TEMP") or os.getenv("TMP") or os.getenv("TMPDIR") or "/tmp"
    return utils.join_path(dir, string.format("mpv-sub-search-%d-%d.%s",
        utils.getpid(), temp_counter, ext))
end

local function read_file(path)
    -- binary mode: on Windows, text mode would stop at a 0x1A byte
    local f = io.open(path, "rb")
    if not f then return nil end
    local content = f:read("*all")
    f:close()
    return content
end

-- ─── In-memory subtitle cache ──────────────────────────────────────────────────
-- Two fixed slots: one for the primary subtitle track, one for the
-- secondary one. Each holds the parsed subtitle list for whatever file/track
-- it currently belongs to — not a growing table keyed by every file/track
-- ever opened, so memory use stays flat regardless of session length.
-- Both are cleared on "start-file" (see below) so a new file never reuses
-- another file's cached lines.

local sub_cache = {
    primary   = { key = nil, subs = nil }, -- key: "<video_path>|<sid>"
    secondary = { key = nil, subs = nil }, -- key: "<video_path>|<secondary-sid>"
}

local function make_cache_key(video_path, sid)
    return video_path .. "|" .. tostring(sid)
end

-- Set while an extraction is running, so pressing the key again doesn't
-- start a second ffmpeg for the same thing.
local loading_key = nil

local function clear_sub_cache()
    sub_cache.primary.key    = nil
    sub_cache.primary.subs   = nil
    sub_cache.secondary.key  = nil
    sub_cache.secondary.subs = nil
    loading_key = nil
end

-- ─── Subtitle parsers ─────────────────────────────────────────────────────────

local function parse_srt(content)
    local subs = {}
    content = content:gsub("\r\n", "\n"):gsub("\r", "\n")
    for block in (content .. "\n\n"):gmatch("(.-)\n\n") do
        local start_tc = block:match("%d+:%d+:%d+[,.]%d+")
        if start_tc then
            local time = timecode_to_seconds(start_tc)
            -- timing line may carry extra position data after the end time
            local text_part = block:match("%d+:%d+:%d+[,.%d]+ %-%-> [^\n]+\n(.+)$")
            if text_part then
                local text = strip_tags(text_part:gsub("\n", " "))
                if text ~= "" then
                    table.insert(subs, { time = time, text = text })
                end
            end
        end
    end
    return subs
end

local function parse_ass(content)
    local subs = {}
    content = content:gsub("\r\n", "\n"):gsub("\r", "\n")
    local in_events = false
    local format_fields = {}
    for line in (content .. "\n"):gmatch("([^\n]*)\n") do
        if line:match("^%[Events%]") then
            in_events = true
        elseif line:match("^%[") then
            in_events = false
        elseif in_events then
            local fmt = line:match("^Format:%s*(.+)$")
            if fmt then
                format_fields = {}
                for field in (fmt .. ","):gmatch("([^,]*),?") do
                    table.insert(format_fields, field:match("^%s*(.-)%s*$"))
                end
            end
            local dlg = line:match("^Dialogue:%s*(.+)$")
            if dlg and #format_fields > 0 then
                local idx_text = #format_fields
                for i, f in ipairs(format_fields) do
                    if f == "Text" then idx_text = i; break end
                end
                local parts = {}
                local remaining = dlg
                for i = 1, idx_text - 1 do
                    local val, rest = remaining:match("^([^,]*),(.*)")
                    if val then parts[i] = val; remaining = rest end
                end
                parts[idx_text] = remaining or ""

                local start_idx = 1
                for i, f in ipairs(format_fields) do
                    if f == "Start" then start_idx = i; break end
                end

                local start_tc = parts[start_idx] or ""
                local text = parts[idx_text] or ""
                text = text:gsub("\\N", " "):gsub("\\n", " "):gsub("\\h", " ")
                text = strip_tags(text)
                local time = timecode_to_seconds(start_tc)
                if text ~= "" and time > 0 then
                    table.insert(subs, { time = time, text = text })
                end
            end
        end
    end
    table.sort(subs, function(a, b) return a.time < b.time end)
    return subs
end

local function parse_content(content, ext)
    content = content:gsub("^\239\187\191", "") -- strip UTF-8 BOM
    if ext == "ass" or ext == "ssa"
        or (ext ~= "srt" and content:find("%[Events%]")) then
        return parse_ass(content)
    end
    return parse_srt(content)
end

-- ─── ffmpeg helpers (async) ───────────────────────────────────────────────────

-- Runs ffmpeg with input_args, converting the selected stream into a temp
-- file. Tries .ass first, then .srt. Calls done(content, ext) or done(nil).
local function ffmpeg_convert(input_args, done, formats, idx)
    formats = formats or { "ass", "srt" }
    idx = idx or 1
    local ext = formats[idx]
    if not ext then return done(nil) end

    local tmp = temp_path(ext)
    local args = { "ffmpeg", "-nostdin", "-y", "-loglevel", "error" }
    for _, a in ipairs(input_args) do args[#args + 1] = a end
    args[#args + 1] = tmp

    mp.command_native_async({
        name = "subprocess",
        args = args,
        playback_only = false,
        capture_stdout = false,
        capture_stderr = true,
    }, function(success, res)
        local content
        if success and res and res.status == 0 then
            content = read_file(tmp)
        elseif res and res.error_string == "init" then
            -- process could not be started at all: ffmpeg isn't installed
            os.remove(tmp)
            return done(nil, nil, "ffmpeg not found")
        end
        os.remove(tmp)
        if content and content ~= "" then
            return done(content, ext)
        end
        ffmpeg_convert(input_args, done, formats, idx + 1)
    end)
end

local function codepage_for_reencode()
    if config.fallback_codepage ~= "" then return config.fallback_codepage end
    local cp = mp.get_property("sub-codepage") or ""
    cp = cp:gsub("^%+", "")
    if cp == "" or cp:lower():find("^auto") or cp:lower():find("^utf%-?8") then
        return nil
    end
    return cp
end

-- ─── Loading ──────────────────────────────────────────────────────────────────

-- Finds the track and loads its lines. Calls on_ready(subs) on success.
local function load_active_subtitles(secondary, on_ready)
    local video_path = mp.get_property("path")
    if not video_path then
        mp.osd_message("sub-search: no file is open", 3)
        return
    end

    -- "sid" selects the primary subtitle track, "secondary-sid" the secondary one.
    local target_sid = mp.get_property_number(secondary and "secondary-sid" or "sid")
    if not target_sid or target_sid == 0 then
        mp.osd_message(
            secondary and "sub-search: no secondary subtitle track selected"
                       or "sub-search: no subtitle track selected",
            3)
        return
    end

    local cache_slot = secondary and sub_cache.secondary or sub_cache.primary

    -- Serve from cache if we already parsed this exact file/track combo.
    local cache_key = make_cache_key(video_path, target_sid)
    if cache_slot.key == cache_key and cache_slot.subs then
        return on_ready(cache_slot.subs)
    end
    if loading_key == cache_key then
        mp.osd_message("sub-search: still extracting subtitles…", 2)
        return
    end

    local track_list = mp.get_property_native("track-list") or {}
    local active_track = nil
    local sub_track_index = 0 -- fallback if ff-index isn't available

    for _, track in ipairs(track_list) do
        if track.type == "sub" then
            if track.id == target_sid then
                active_track = track
                break
            end
            if not track.external then
                sub_track_index = sub_track_index + 1
            end
        end
    end

    if not active_track then
        mp.osd_message("sub-search: active subtitle track not found", 3)
        return
    end

    -- Shared ending: parse, cache and hand over the result.
    local function finish(content, ext)
        loading_key = nil
        -- user may have switched files while ffmpeg was running
        if mp.get_property("path") ~= video_path then return end
        if not content then
            mp.osd_message("sub-search: could not read subtitles "
                .. "(image-based subtitles, or ffmpeg missing?)", 4)
            return
        end
        local subs = parse_content(content, ext)
        if #subs == 0 then
            mp.osd_message("sub-search: subtitles are empty or could not be parsed", 3)
            return
        end
        cache_slot.key = cache_key
        cache_slot.subs = subs
        mp.osd_message("", 0)
        on_ready(subs)
    end

    if active_track.external then
        local ext_path = active_track["external-filename"] or ""
        local ext = (ext_path:match("%.(%w+)$") or ""):lower()
        local content = read_file(ext_path)
        if not content then
            mp.osd_message("sub-search: could not read " .. ext_path, 3)
            return
        end

        if is_valid_utf8((content:gsub("^\239\187\191", ""))) then
            return finish(content, ext)
        end

        -- Not UTF-8: let ffmpeg re-encode it, if we know the codepage.
        local cp = codepage_for_reencode()
        if not cp then
            msg.warn("external subtitle is not UTF-8; set fallback_codepage "
                .. "in script-opts/sub-search.conf to convert it")
            return finish(content, ext)
        end
        loading_key = cache_key
        mp.osd_message("sub-search: converting subtitles…", 30)
        ffmpeg_convert({ "-sub_charenc", cp, "-i", ext_path }, function(converted, conv_ext)
            if converted then
                finish(converted, conv_ext)
            else
                finish(content, ext) -- show it as-is rather than nothing
            end
        end)
        return
    end

    -- Embedded track: extract with ffmpeg in the background.
    local map = active_track["ff-index"] and ("0:" .. active_track["ff-index"])
        or ("0:s:" .. sub_track_index)
    loading_key = cache_key
    mp.osd_message("sub-search: extracting subtitles…", 30)
    ffmpeg_convert({ "-i", video_path, "-map", map }, function(content, ext, err)
        if err then
            loading_key = nil
            mp.osd_message("sub-search: ffmpeg not found (install it and add it to PATH)", 4)
            return
        end
        finish(content, ext)
    end)
end

-- Drop the cache as soon as a new file starts loading.
mp.register_event("start-file", clear_sub_cache)

-- ─── uosc integration ─────────────────────────────────────────────────────────

local was_paused = false

local function show_menu(secondary, subs)
    -- Pause playback while the menu is open; remember the original state.
    if config.pause_on_open then
        was_paused = mp.get_property_bool("pause")
        if not was_paused then
            mp.set_property_bool("pause", true)
        end
    end

    local items = {}
    for i, sub in ipairs(subs) do
        table.insert(items, {
            title = sub.text,
            hint  = seconds_to_hms(sub.time),
            value = string.format("script-message sub-search-jump %s", tostring(sub.time)),
        })
        if i >= config.max_items then break end
    end

    -- Primary and secondary each get their own uosc menu type and callback
    -- message name, so activating/closing one never targets the other menu.
    local menu_type   = secondary and "sub_search_secondary" or "sub_search"
    local menu_title  = secondary and "Secondary subtitle search" or "Subtitle search"
    local event_name  = secondary and "sub-search-event-secondary" or "sub-search-event"

    mp.commandv("script-message-to", "uosc", "open-menu", utils.format_json({
        type         = menu_type,
        title        = string.format("%s  (%d lines)", menu_title, #subs),
        search_style = "palette",
        -- callback receives all menu events including 'close'
        callback     = { mp.get_script_name(), event_name },
        items        = items,
    }))
end

local function open_search_menu(secondary)
    load_active_subtitles(secondary, function(subs)
        show_menu(secondary, subs)
    end)
end

-- Delay that is actually applied to a track, so jumping lands on the moment
-- the line is shown on screen.
local function current_delay(secondary)
    if secondary then
        local d = mp.get_property_number("secondary-sub-delay")
        if d then return d end
    end
    return mp.get_property_number("sub-delay") or 0
end

-- Handles item activation (seek) and menu close events via uosc callback
-- mode. Shared logic for both primary and secondary menus.
local function make_search_event_handler(menu_type, secondary)
    return function(json)
        local ok, event = pcall(utils.parse_json, json)
        if not ok or not event then return end

        if event.type == "activate" then
            local time = tonumber(tostring(event.value):match("([%d%.]+)$"))
            if time then
                mp.commandv("script-message-to", "uosc", "close-menu", menu_type)
                mp.commandv("seek", math.max(0, time + current_delay(secondary)), "absolute+exact")
            end
            if config.pause_on_open and not was_paused then
                mp.set_property_bool("pause", false)
            end
        elseif event.type == "close" then
            -- Menu was closed without selecting anything — restore playback state
            if config.pause_on_open and not was_paused then
                mp.set_property_bool("pause", false)
            end
        end
    end
end

mp.register_script_message("sub-search-event", make_search_event_handler("sub_search", false))
mp.register_script_message("sub-search-event-secondary", make_search_event_handler("sub_search_secondary", true))

-- ─── Script binding (configure in input.conf) ─────────────────────────────────

mp.add_key_binding(nil, "sub-search-open", function() open_search_menu(false) end)
mp.add_key_binding(nil, "sub-search-open-secondary", function() open_search_menu(true) end)

msg.info("sub-search loaded. Bind 'script-binding sub-search-open' (and optionally "
    .. "'script-binding sub-search-open-secondary') in input.conf to use.")

--[[
    sub-search.lua
    Subtitle search with uosc integration for mpv.

    Installation:
      Copy to ~/.config/mpv/scripts/sub-search.lua

    Key bindings (add to ~/.config/mpv/input.conf):
      ctrl+f        script-binding sub-search-open
      ctrl+F        script-binding sub-search-open-secondary

    Usage:
      Press the bound key — a uosc palette opens with all subtitle lines
      from the current subtitle track (primary or secondary, depending on
      which binding was used). Type to filter. Click or press Enter on a
      result to jump to that moment.
      Note: filtering is handled by uosc (fuzzy match on the item title).

    Dependencies:
      - uosc  (https://github.com/tomasklaen/uosc)
      - ffmpeg (required only for subtitles embedded inside mkv)
--]]

local mp = require 'mp'
local utils = require("mp.utils")

-- ─── Config ───────────────────────────────────────────────────────────────────

local config = {
    -- Maximum number of subtitle lines loaded into the menu
    max_items = 6000,
    -- Pause playback while the search menu is open, and restore the
    -- previous play/pause state when it closes. Set to false to leave
    -- playback running untouched while searching.
    pause_on_open = true,
}

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

-- ─── In-memory subtitle cache ──────────────────────────────────────────────────
-- Two fixed slots: one for the primary subtitle track, one for the
-- secondary one. Each holds the parsed subtitle list for whatever file/track
-- it currently belongs to — not a growing table keyed by every file/track
-- ever opened, so memory use stays flat regardless of session length.
-- Separate slots mean searching the secondary track never evicts the
-- already-parsed primary track from the cache, and vice versa.
-- Both are cleared on "start-file" (see below) so a new file never reuses
-- another file's cached lines while the search menu hasn't been reopened yet.

local sub_cache = {
    primary   = { key = nil, subs = nil }, -- key: "<video_path>|<sid>"
    secondary = { key = nil, subs = nil }, -- key: "<video_path>|<secondary-sid>"
}

local function make_cache_key(video_path, sid)
    return video_path .. "|" .. tostring(sid)
end

local function clear_sub_cache()
    sub_cache.primary.key    = nil
    sub_cache.primary.subs   = nil
    sub_cache.secondary.key  = nil
    sub_cache.secondary.subs = nil
end

-- ─── Subtitle parsers ─────────────────────────────────────────────────────────

local function parse_srt(content)
    local subs = {}
    content = content:gsub("\r\n", "\n"):gsub("\r", "\n")
    for block in (content .. "\n\n"):gmatch("(.-)\n\n") do
        local start_tc = block:match("%d+:%d+:%d+[,.]%d+")
        if start_tc then
            local time = timecode_to_seconds(start_tc)
            local text_part = block:match("%d+:%d+:%d+[,.%d]+ %-%-> [%d:,. ]+\n(.+)$")
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

local function read_file(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local content = f:read("*all")
    f:close()
    return content
end

local function extract_embedded_subs(video_path, track_id)
    for _, ext in ipairs({ "ass", "srt" }) do
        local tmp = os.tmpname() .. "." .. ext
        local res = utils.subprocess({
            args = { "ffmpeg", "-y", "-loglevel", "error",
                     "-i", video_path, "-map", "0:s:" .. track_id, tmp },
            cancellable = false,
        })
        if not res.error and res.status == 0 then
            local content = read_file(tmp)
            os.remove(tmp)
            return content, ext
        end
        os.remove(tmp)
    end
    return nil
end

local function load_active_subtitles(secondary)
    local video_path = mp.get_property("path")
    if not video_path then
        mp.osd_message("sub-search: no file is open", 3)
        return nil
    end

    -- "sid" selects the primary subtitle track, "secondary-sid" the secondary
    -- one. Both are plain track ids, so the rest of the function treats them
    -- identically from here on.
    local target_sid = mp.get_property_number(secondary and "secondary-sid" or "sid")
    if not target_sid or target_sid == 0 then
        mp.osd_message(
            secondary and "sub-search: no secondary subtitle track selected"
                       or "sub-search: no subtitle track selected",
            3)
        return nil
    end

    local cache_slot = secondary and sub_cache.secondary or sub_cache.primary

    -- Serve from cache if we already parsed this exact file/track combo.
    -- Avoids re-running ffmpeg and re-parsing on every menu open.
    local cache_key = make_cache_key(video_path, target_sid)
    if cache_slot.key == cache_key and cache_slot.subs then
        return cache_slot.subs
    end

    local track_list = mp.get_property_native("track-list") or {}
    local active_track = nil
    local sub_track_index = 0

    for _, track in ipairs(track_list) do
        if track.type == "sub" then
            if track.id == target_sid then
                active_track = track
                break
            end
            sub_track_index = sub_track_index + 1
        end
    end

    if not active_track then
        mp.osd_message("sub-search: active subtitle track not found", 3)
        return nil
    end

    local content, ext

    if active_track["external"] then
        local ext_path = active_track["external-filename"]
        content = read_file(ext_path)
        ext = ext_path:match("%.(%w+)$"):lower()
    else
        mp.osd_message("sub-search: extracting subtitles…", 2)
        content, ext = extract_embedded_subs(video_path, sub_track_index)
        if not content then
            mp.osd_message("sub-search: could not extract subtitles (is ffmpeg installed?)", 4)
            return nil
        end
    end

    local subs
    if ext == "ass" or ext == "ssa" then
        subs = parse_ass(content)
    else
        subs = parse_srt(content)
    end

    if #subs == 0 then
        mp.osd_message("sub-search: subtitles are empty or could not be parsed", 3)
        return nil
    end

    -- Cache for subsequent opens of the same file/track.
    cache_slot.key = cache_key
    cache_slot.subs = subs

    return subs
end

-- Drop the cache as soon as a new file starts loading, so a stale subtitle
-- list from the previous video can't be served if the user hasn't reopened
-- the search menu yet (mpv sessions commonly move on to the next episode
-- without ever closing).
mp.register_event("start-file", clear_sub_cache)

-- ─── uosc integration ─────────────────────────────────────────────────────────

local was_paused = false

local function open_search_menu(secondary)
    local subs = load_active_subtitles(secondary)
    if not subs then return end

    -- Pause playback while the menu is open; remember the original state.
    -- Skipped entirely when pause_on_open is off, so playback is never
    -- touched and the restore step below has nothing to undo.
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

-- Handles item activation (seek) and menu close events via uosc callback
-- mode. Shared logic for both primary and secondary menus; menu_type is
-- baked in per-instance so closing always targets the right uosc menu.
local function make_search_event_handler(menu_type)
    return function(json)
        local ok, event = pcall(utils.parse_json, json)
        if not ok or not event then return end

        if event.type == "activate" then
            local time = tonumber(tostring(event.value):match("([%d%.]+)$"))
            if time then
                mp.commandv("script-message-to", "uosc", "close-menu", menu_type)
                mp.commandv("seek", time, "absolute+exact")
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

mp.register_script_message("sub-search-event", make_search_event_handler("sub_search"))
mp.register_script_message("sub-search-event-secondary", make_search_event_handler("sub_search_secondary"))

-- ─── Script binding (configure in input.conf) ─────────────────────────────────

mp.add_key_binding(nil, "sub-search-open", function() open_search_menu(false) end)
mp.add_key_binding(nil, "sub-search-open-secondary", function() open_search_menu(true) end)

mp.msg.info("sub-search loaded. Bind 'script-binding sub-search-open' (and optionally "
    .. "'script-binding sub-search-open-secondary') in input.conf to use.")

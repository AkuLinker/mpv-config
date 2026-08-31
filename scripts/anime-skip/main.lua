--[[
================================================================================
 anime-skip.lua — automatic opening/ending skipper for mpv
================================================================================

READ BEFORE USE:

  1. This script does NOT bind any key by default (on purpose). You must add
     a binding yourself in your input.conf, for example:

         F skript-binding anime-skip      -- (example, pick any key)
         F script-binding anime-skip

     (script-binding name is "anime-skip", matching this file's name)

  2. Dependencies that must be installed and available in PATH:
       - curl       (all HTTP requests go through it, mpv Lua has no networking)
       - mkdir      (POSIX "mkdir -p" is used to create the cache directory;
                     this assumes a Linux/macOS environment)
       - python3    (used to run the anitopy filename-parsing wrapper)
       - anitopy    (pip package; https://github.com/igorcafe/anitopy or
                     https://github.com/kaonashi-2/anitopy)
     Also requires the "lookup.py" wrapper script (thin CLI wrapper that
     calls anitopy.parse() and prints the result as JSON) to be present at
     ANITOPY_LOOKUP_PATH below (default: "<mpv config dir>/scripts/anitopy/lookup.py").

  3. Cache location: "<mpv config dir>/cache/anime-skip_cache"
     (usually ~/.config/mpv/cache/anime-skip_cache). One small JSON file is
     stored per source filename so repeated keypresses on the same episode
     never repeat the network lookups.

  HOW IT WORKS (on keypress):
    1. Parse the current filename via anitopy (through lookup.py) to get
       the anime title, season (if present) and episode number.
    2. Search Shikimori for the title (+ season, if present), take the
       best match.
    3. Resolve the matching MyAnimeList ID via Shikimori's external_links.
    4. Query the AniSkip API (api.aniskip.com) for op/ed timestamps.
    5. If the current playback position falls inside an op/ed interval,
       seek to the end of it. Otherwise show a message and do nothing.

  KNOWN LIMITATIONS:
    - Filename parsing quality depends on anitopy; very unusual naming
      schemes may still fail.
    - Relies on Shikimori's search returning the correct title as result #1.
    - All OSD messages are in English, as requested.
================================================================================
]]

local mp = mp
local utils = require 'mp.utils'
local msg = require 'mp.msg'

----------------------------------------------------------------------
-- Configuration
----------------------------------------------------------------------

local SHIKIMORI_ANIMES_URL = "https://shikimori.io/api/animes"
local ANISKIP_API_URL = "https://api.aniskip.com/v2/skip-times"
-- Shikimori asks API clients to identify themselves with a descriptive
-- User-Agent (their own docs/wrappers all set one explicitly); a generic
-- one is more likely to get blocked by their anti-bot protection.
local USER_AGENT = "anime-skip.lua/1.0 (mpv script; https://github.com/synacktraa/ani-skip)"

-- anitopy filename-parsing wrapper (see header comment for setup)
local PYTHON_CMD = "python3" -- change to "python" if that's what your system provides
local ANITOPY_LOOKUP_PATH = utils.join_path(
    mp.command_native({"expand-path", "~~/"}), "scripts/anime-skip/lookup.py")

-- cache dir: "<mpv config dir>/cache/anime-skip_cache"
local function get_cache_dir()
    local config_dir = mp.command_native({"expand-path", "~~/"})
    return utils.join_path(utils.join_path(config_dir, "cache"), "anime-skip_cache")
end

local CACHE_DIR = get_cache_dir()

----------------------------------------------------------------------
-- Per-file state (reset whenever a new file starts playing)
----------------------------------------------------------------------

local state = {
    resolved = false,   -- true once resolution was attempted for this file
    found = false,       -- true if title/episode/skip-times were resolved ok
    title_guess = nil,
    episode = nil,
    mal_id = nil,
    op_start = nil, op_end = nil,
    ed_start = nil, ed_end = nil,
}

local function reset_state()
    state = {
        resolved = false, found = false,
        title_guess = nil, episode = nil, mal_id = nil,
        op_start = nil, op_end = nil, ed_start = nil, ed_end = nil,
    }
end

mp.register_event("start-file", reset_state)

----------------------------------------------------------------------
-- OSD helper (English only, per request)
----------------------------------------------------------------------

local function osd(text, duration)
    mp.osd_message("[anime-skip] " .. text, duration or 3)
    msg.info(text)
end

----------------------------------------------------------------------
-- HTTP helper: runs curl as a subprocess and parses JSON stdout
----------------------------------------------------------------------

-- Writes the raw (failed) response body to a debug file in the cache dir
-- so the actual server reply can be inspected after the fact, instead of
-- guessing blindly why JSON parsing failed (Cloudflare challenge page,
-- rate limit message, unexpected format, etc).
local function dump_debug_response(label, body)
    mp.command_native({
        name = "subprocess", capture_stdout = true, capture_stderr = true,
        args = {"mkdir", "-p", CACHE_DIR},
    })
    local path = utils.join_path(CACHE_DIR, "last_error_" .. label .. ".txt")
    local f = io.open(path, "w")
    if f then
        f:write(body or "")
        f:close()
    end
    return path
end

local function http_get_json(url)
    local res = mp.command_native({
        name = "subprocess",
        capture_stdout = true,
        capture_stderr = true,
        args = {
            "curl", "-s", "-L", "-A", USER_AGENT,
            "-H", "Accept: application/json",
            "--max-time", "10", url,
        },
    })

    if res == nil then
        return nil, "failed to start curl"
    end
    if res.status ~= 0 then
        return nil, "curl exited with status " .. tostring(res.status)
            .. (res.stderr and (" (" .. res.stderr .. ")") or "")
    end
    if not res.stdout or res.stdout == "" then
        return nil, "empty response from " .. url
    end

    local ok, data = pcall(utils.parse_json, res.stdout)
    if not ok or data == nil then
        local path = dump_debug_response("response", res.stdout)
        local snippet = res.stdout:sub(1, 120):gsub("%s+", " ")
        msg.error("anime-skip: non-JSON response from " .. url)
        msg.error("anime-skip: first 120 chars: " .. snippet)
        msg.error("anime-skip: full body saved to " .. path)
        return nil, "server returned non-JSON data (see mpv log / " .. path .. ")"
    end
    return data, nil
end

local function url_encode(str)
    str = str:gsub("([^%w %-%_%.%~])", function(c)
        return string.format("%%%02X", string.byte(c))
    end)
    str = str:gsub(" ", "+")
    return str
end

----------------------------------------------------------------------
-- Cache helpers (one JSON file per source filename)
----------------------------------------------------------------------

local function ensure_cache_dir()
    mp.command_native({
        name = "subprocess",
        capture_stdout = true,
        capture_stderr = true,
        args = {"mkdir", "-p", CACHE_DIR},
    })
end

local function cache_path_for(filename)
    -- sanitize filename into a safe file name for the cache directory
    local key = filename:gsub("[^%w%-%_%.]", "_")
    return utils.join_path(CACHE_DIR, key .. ".json")
end

local function load_cache(filename)
    local f = io.open(cache_path_for(filename), "r")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    if not content or content == "" then return nil end
    local ok, data = pcall(utils.parse_json, content)
    if not ok then return nil end
    return data
end

local function save_cache(filename, data)
    ensure_cache_dir()
    local f = io.open(cache_path_for(filename), "w")
    if not f then
        msg.warn("anime-skip: could not write cache file")
        return
    end
    f:write(utils.format_json(data))
    f:close()
end

----------------------------------------------------------------------
-- Filename parsing (delegated to anitopy via lookup.py)
--
-- Calls "python3 lookup.py <filename>", which internally runs
-- anitopy.parse() and prints the result as JSON. Anitopy reliably
-- separates release-group tags, technical info (resolution, checksum,
-- codec) and the episode number from the actual title, which is far
-- more robust than a hand-rolled regex parser.
--
-- Returns: search_title (title + " S<season>" if a season was detected,
-- used for the Shikimori query), display_title (title only, for OSD/cache),
-- episode (number or nil).
----------------------------------------------------------------------

local function parse_filename(filename)
    local res = mp.command_native({
        name = "subprocess",
        capture_stdout = true,
        capture_stderr = true,
        args = {PYTHON_CMD, ANITOPY_LOOKUP_PATH, filename},
    })

    if res == nil or res.status ~= 0 then
        msg.error("anime-skip: anitopy lookup failed"
            .. (res and res.stderr and (": " .. res.stderr) or ""))
        return nil, nil, nil
    end
    if not res.stdout or res.stdout == "" then
        msg.error("anime-skip: anitopy lookup returned empty output")
        return nil, nil, nil
    end

    local ok, info = pcall(utils.parse_json, res.stdout)
    if not ok or type(info) ~= "table" then
        msg.error("anime-skip: failed to parse anitopy JSON output")
        return nil, nil, nil
    end

    local title = info.anime_title
    if not title or title == "" then
        return nil, nil, nil
    end

    -- anitopy may return a list for batch releases (e.g. "01-02");
    -- just take the first episode in that case.
    local episode = info.episode_number
    if type(episode) == "table" then episode = episode[1] end
    episode = episode and tonumber(episode) or nil

    local season = info.anime_season
    if type(season) == "table" then season = season[1] end

    local search_title = title
    if season and tostring(season) ~= "" then
        search_title = title .. " S" .. tostring(season)
    end

    return search_title, title, episode
end

----------------------------------------------------------------------
-- Shikimori + AniSkip resolution
----------------------------------------------------------------------

local function shikimori_search(title)
    local url = SHIKIMORI_ANIMES_URL .. "?search=" .. url_encode(title) .. "&limit=5"
    local data, err = http_get_json(url)
    if err then return nil, err end
    if type(data) ~= "table" or #data == 0 then
        return nil, "no matches on Shikimori"
    end
    return data[1], nil -- best (first) match
end

local function shikimori_mal_id(shiki_id)
    local url = SHIKIMORI_ANIMES_URL .. "/" .. tostring(shiki_id) .. "/external_links"
    local data, err = http_get_json(url)
    if err then return nil, err end
    if type(data) ~= "table" then return nil, "unexpected external_links response" end

    for _, link in ipairs(data) do
        if link.kind == "myanimelist" and link.url then
            local mal_id = link.url:match("(%d+)%s*$")
            if mal_id then return tonumber(mal_id), nil end
        end
    end
    return nil, "no MyAnimeList link found"
end

local function fetch_skip_times(mal_id, episode, episode_length)
    local url = ANISKIP_API_URL .. "/" .. tostring(mal_id) .. "/" .. tostring(episode)
        .. "?types[]=op&types[]=ed"
    if episode_length and episode_length > 0 then
        url = url .. "&episodeLength=" .. string.format("%.0f", episode_length)
    end

    local data, err = http_get_json(url)
    if err then return nil, err end
    if not data.found then
        return nil, "AniSkip has no data for this episode"
    end

    local result = {}
    for _, r in ipairs(data.results or {}) do
        if r.skipType == "op" and r.interval then
            result.op_start, result.op_end = r.interval.startTime, r.interval.endTime
        elseif r.skipType == "ed" and r.interval then
            result.ed_start, result.ed_end = r.interval.startTime, r.interval.endTime
        end
    end
    return result, nil
end

----------------------------------------------------------------------
-- Main resolution flow (cached per source filename)
----------------------------------------------------------------------

local function fail(filename, title, episode, message, extra)
    osd(message, 4)
    state.resolved = true
    state.found = false
    local cache_data = {found = false, title_guess = title, episode = episode}
    if extra then
        for k, v in pairs(extra) do cache_data[k] = v end
    end
    save_cache(filename, cache_data)
end

local function apply_cached(cached)
    state.resolved = true
    state.found = cached.found
    state.title_guess = cached.title_guess
    state.episode = cached.episode
    state.mal_id = cached.mal_id
    state.op_start, state.op_end = cached.op_start, cached.op_end
    state.ed_start, state.ed_end = cached.ed_start, cached.ed_end
end

local function resolve_current_anime()
    local filename = mp.get_property("filename")
    if not filename then
        osd("No file is currently playing", 3)
        return false
    end

    local cached = load_cache(filename)
    if cached then
        apply_cached(cached)
        return state.found
    end

    local search_title, display_title, episode = parse_filename(filename)
    state.title_guess, state.episode = display_title, episode

    if not search_title or not episode then
        fail(filename, display_title, episode,
            "Could not determine anime title or episode from filename")
        return false
    end

    local anime, search_err = shikimori_search(search_title)
    if not anime then
        fail(filename, display_title, episode, "Anime not found: " .. tostring(search_err))
        return false
    end

    local mal_id, mal_err = shikimori_mal_id(anime.id)
    if not mal_id then
        fail(filename, display_title, episode,
            "Anime not found: could not resolve MyAnimeList ID (" .. tostring(mal_err) .. ")")
        return false
    end

    local episode_length = mp.get_property_number("duration")
    local skip_times, skip_err = fetch_skip_times(mal_id, episode, episode_length)
    if not skip_times then
        fail(filename, display_title, episode,
            "Anime not found: " .. tostring(skip_err), {mal_id = mal_id})
        return false
    end

    state.found = true
    state.resolved = true
    state.mal_id = mal_id
    state.op_start, state.op_end = skip_times.op_start, skip_times.op_end
    state.ed_start, state.ed_end = skip_times.ed_start, skip_times.ed_end

    save_cache(filename, {
        found = true, title_guess = display_title, episode = episode, mal_id = mal_id,
        op_start = state.op_start, op_end = state.op_end,
        ed_start = state.ed_start, ed_end = state.ed_end,
    })

    osd("Identified: " .. display_title .. ", episode " .. tostring(episode), 3)
    return true
end

----------------------------------------------------------------------
-- Keybinding entry point
----------------------------------------------------------------------

local function do_skip()
    if not state.resolved then
        if not resolve_current_anime() then
            return -- failure message already shown
        end
    elseif not state.found then
        osd("Anime not found for this file", 3)
        return
    end

    local pos = mp.get_property_number("time-pos")
    if not pos then
        osd("Playback position unavailable", 3)
        return
    end

    if state.op_start and state.op_end and pos >= state.op_start and pos < state.op_end then
        mp.set_property_number("time-pos", state.op_end)
        osd("Skipped opening", 2)
        return
    end

    if state.ed_start and state.ed_end and pos >= state.ed_start and pos < state.ed_end then
        mp.set_property_number("time-pos", state.ed_end)
        osd("Skipped ending", 2)
        return
    end

    osd("Not currently in an opening or ending", 3)
end

-- No default key binding (nil) — bind via input.conf, e.g.:
--   F script-binding anime-skip
mp.add_key_binding(nil, "anime-skip", do_skip)

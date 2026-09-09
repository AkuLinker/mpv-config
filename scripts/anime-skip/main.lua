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
       - python3    (used to run the anitopy filename-parsing wrapper and the
                     fuzzy title-matching helper; both use only the standard
                     library plus anitopy, no extra pip packages beyond that)
       - anitopy    (pip package; https://github.com/igorcafe/anitopy or
                     https://github.com/kaonashi-2/anitopy)
     Also requires two small wrapper scripts to be present next to each other:
       - "lookup.py" (calls anitopy.parse() on the filename, prints JSON)
       - "match.py"  (scores Shikimori candidates against our title using
                      difflib.SequenceMatcher, prints the best index + score)
     Default location for both: "<mpv config dir>/scripts/anime-skip/"
     (see ANITOPY_LOOKUP_PATH / MATCH_SCRIPT_PATH below).

  3. Cache location: "<mpv config dir>/cache/anime-skip_cache"
     (usually ~/.config/mpv/cache/anime-skip_cache). One small JSON file is
     stored per source filename so repeated keypresses on the same episode
     never repeat the network lookups.

  HOW IT WORKS (on keypress):
    1. Parse the current filename via anitopy (through lookup.py) to get
       the anime title, season (if present) and episode number.
    2. Query Shikimori's GraphQL API for up to 5 candidates matching the
       title, each with all of its name variants (name/russian/japanese/
       english/synonyms) and its MyAnimeList ID (malId) in the same response.
    3. Fuzzy-match our title against every name variant of every candidate
       (via match.py) and take the best-scoring one, provided it clears a
       minimum similarity threshold; below that, treat it as not found.
    4. Query the AniSkip API (api.aniskip.com) for op/ed timestamps using
       the MAL ID from step 3.
    5. If the current playback position falls inside an op/ed interval,
       seek to the end of it. Otherwise show a message and do nothing.

  KNOWN LIMITATIONS:
    - Filename parsing quality depends on anitopy; very unusual naming
      schemes may still fail.
    - The fuzzy match threshold is a heuristic; very obscure/short titles
      could still be mismatched or wrongly rejected.
    - All OSD messages are in English, as requested.
================================================================================
]]

local mp = mp
local utils = require 'mp.utils'
local msg = require 'mp.msg'

----------------------------------------------------------------------
-- Configuration
----------------------------------------------------------------------

local SHIKIMORI_GRAPHQL_URL = "https://shikimori.io/api/graphql"
local ANISKIP_API_URL = "https://api.aniskip.com/v2/skip-times"
-- Shikimori asks API clients to identify themselves with a descriptive
-- User-Agent (their own docs/wrappers all set one explicitly); a generic
-- one is more likely to get blocked by their anti-bot protection.
local USER_AGENT = "anime-skip.lua/1.0 (mpv script; https://github.com/synacktraa/ani-skip)"

-- Minimum difflib.SequenceMatcher ratio (0-1) for a Shikimori candidate to
-- be accepted; below this, we report "not found" rather than risk skipping
-- based on the wrong anime.
local FUZZY_MATCH_THRESHOLD = 0.6

-- anitopy filename-parsing wrapper and fuzzy-matching helper (see header)
local PYTHON_CMD = "python3" -- change to "python" if that's what your system provides
local SCRIPTS_DIR = utils.join_path(
    mp.command_native({"expand-path", "~~/"}), "scripts/anime-skip")
local ANITOPY_LOOKUP_PATH = utils.join_path(SCRIPTS_DIR, "lookup.py")
local MATCH_SCRIPT_PATH = utils.join_path(SCRIPTS_DIR, "match.py")

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
    season = nil,
    episode = nil,
    mal_id = nil,
    err_kind = nil,      -- reason code for the last failure (nil if found)
    op_start = nil, op_end = nil,
    ed_start = nil, ed_end = nil,
}

local function reset_state()
    state = {
        resolved = false, found = false,
        title_guess = nil, season = nil, episode = nil, mal_id = nil, err_kind = nil,
        op_start = nil, op_end = nil, ed_start = nil, ed_end = nil,
    }
end

mp.register_event("start-file", reset_state)

----------------------------------------------------------------------
-- OSD helper (English only, per request)
----------------------------------------------------------------------

local function osd(text, duration)
    mp.osd_message("[anime-skip]\n" .. text, duration or 3)
    msg.info(text)
end

----------------------------------------------------------------------
-- Diagnostic messages for failures
--
-- Every failure is tagged with a short "kind" string (see call sites
-- below). The actual wording lives here in one place, and the OSD
-- shown to the user is built as:
--   Name: <title>
--   Season: <n>  Episode: <n>   (only the parts we actually have)
--   <reason, from the table below>
-- If we don't even have a title (anitopy itself failed), only the
-- reason is shown.
----------------------------------------------------------------------

local ERROR_MESSAGES = {
    anitopy_failed = "anitopy failed to parse this filename",
    shikimori_unavailable = "Shikimori is unavailable",
    shikimori_not_found = "Shikimori found no match for this title",
    shikimori_no_mal_link = "Shikimori entry has no linked MyAnimeList ID",
    aniskip_unavailable = "AniSkip is unavailable",
    aniskip_no_data = "AniSkip has no data for this episode",
}

local function format_diagnostic(title, season, episode, mal_id, err_kind)
    local reason = ERROR_MESSAGES[err_kind] or tostring(err_kind or "unknown error")
    if not title then
        return reason
    end

    local lines = {"Name: " .. title}
    local info_parts = {}
    if season then table.insert(info_parts, "Season: " .. tostring(season)) end
    if episode then table.insert(info_parts, "Episode: " .. tostring(episode)) end
    if #info_parts > 0 then
        table.insert(lines, table.concat(info_parts, "  "))
    end
    table.insert(lines, reason)
    if mal_id then
        table.insert(lines, "MAL ID: " .. tostring(mal_id))
    end

    return table.concat(lines, "\n")
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
            "curl", "-s", "-L", "-g", "-A", USER_AGENT,
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
-- season (string or nil), episode (number; defaults to 1 if anitopy found
-- a title but no episode marker, e.g. movies/OVAs with a single segment).
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
        return nil, nil, nil, nil
    end
    if not res.stdout or res.stdout == "" then
        msg.error("anime-skip: anitopy lookup returned empty output")
        return nil, nil, nil, nil
    end

    local ok, info = pcall(utils.parse_json, res.stdout)
    if not ok or type(info) ~= "table" then
        msg.error("anime-skip: failed to parse anitopy JSON output")
        return nil, nil, nil, nil
    end

    local title = info.anime_title
    if not title or title == "" then
        return nil, nil, nil, nil
    end

    -- anitopy may return a list for batch releases (e.g. "01-02");
    -- just take the first episode in that case. If no episode marker was
    -- found at all (typical for movies/single-segment OVAs), default to
    -- episode 1 rather than treating it as a failure.
    local episode = info.episode_number
    if type(episode) == "table" then episode = episode[1] end
    episode = episode and tonumber(episode) or 1

    local season = info.anime_season
    if type(season) == "table" then season = season[1] end
    season = season and tostring(season) or nil

    local search_title = title
    if season then
        search_title = title .. " S" .. season
    end

    return search_title, title, season, episode
end

----------------------------------------------------------------------
-- Shikimori + AniSkip resolution
----------------------------------------------------------------------

local SHIKIMORI_GRAPHQL_QUERY = [[
query($s: String) {
  animes(search: $s, limit: 5) {
    malId
    name
    russian
    japanese
    english
    synonyms
  }
}
]]

-- Queries Shikimori's GraphQL API for up to 5 candidates. Returns the raw
-- list of anime objects (each with malId + all name variants), or nil+err.
local function shikimori_graphql_search(search_title)
    local body = utils.format_json({query = SHIKIMORI_GRAPHQL_QUERY, variables = {s = search_title}})
    local res = mp.command_native({
        name = "subprocess",
        capture_stdout = true,
        capture_stderr = true,
        args = {
            "curl", "-s", "-g", "-A", USER_AGENT,
            "-H", "Content-Type: application/json",
            "-H", "Accept: application/json",
            "--max-time", "10",
            "-d", body,
            SHIKIMORI_GRAPHQL_URL,
        },
    })

    if res == nil or res.status ~= 0 then
        return nil, "shikimori_unavailable"
    end
    if not res.stdout or res.stdout == "" then
        return nil, "shikimori_unavailable"
    end

    local ok, data = pcall(utils.parse_json, res.stdout)
    if not ok or type(data) ~= "table" then
        local path = dump_debug_response("shikimori_graphql", res.stdout)
        msg.error("anime-skip: non-JSON Shikimori GraphQL response, saved to " .. path)
        return nil, "shikimori_unavailable"
    end
    if data.errors then
        msg.error("anime-skip: Shikimori GraphQL error: "
            .. (data.errors[1] and data.errors[1].message or "unknown"))
        return nil, "shikimori_unavailable"
    end
    if not data.data or not data.data.animes or #data.data.animes == 0 then
        return nil, "shikimori_not_found"
    end

    return data.data.animes, nil
end

-- Scores every candidate's name variants against `title` via match.py
-- (difflib.SequenceMatcher, run once for the whole batch) and returns the
-- best-scoring candidate's 1-based index and score.
local function fuzzy_match_index(title, animes)
    local candidates = {}
    for i, a in ipairs(animes) do
        local fields = {}
        if a.name then table.insert(fields, a.name) end
        if a.russian then table.insert(fields, a.russian) end
        if a.japanese then table.insert(fields, a.japanese) end
        if a.english then table.insert(fields, a.english) end
        if type(a.synonyms) == "table" then
            for _, syn in ipairs(a.synonyms) do table.insert(fields, syn) end
        end
        table.insert(candidates, {index = i, fields = fields})
    end

    local payload = utils.format_json({title = title, candidates = candidates})
    local res = mp.command_native({
        name = "subprocess",
        capture_stdout = true,
        capture_stderr = true,
        stdin_data = payload,
        args = {PYTHON_CMD, MATCH_SCRIPT_PATH},
    })

    if res == nil or res.status ~= 0 or not res.stdout or res.stdout == "" then
        msg.error("anime-skip: match.py failed"
            .. (res and res.stderr and (": " .. res.stderr) or ""))
        return nil, 0
    end

    local ok, data = pcall(utils.parse_json, res.stdout)
    if not ok or type(data) ~= "table" then
        msg.error("anime-skip: failed to parse match.py output")
        return nil, 0
    end

    return data.best_index, data.score or 0
end

-- Full Shikimori resolution: search candidates, pick the best fuzzy match
-- (rejecting anything below FUZZY_MATCH_THRESHOLD), return its MAL ID.
-- Matching is done against search_title (title + season, if any) since
-- Shikimori's own name/english fields usually bake the season into the
-- text too (e.g. "Clevatess Season 2") - matching the bare title against
-- those systematically under-scores due to the length difference.
local function shikimori_resolve(search_title)
    local animes, err = shikimori_graphql_search(search_title)
    if not animes then return nil, err end

    local best_index, score = fuzzy_match_index(search_title, animes)
    if not best_index or score < FUZZY_MATCH_THRESHOLD then
        return nil, "shikimori_not_found"
    end

    local best = animes[best_index]
    if not best.malId then
        return nil, "shikimori_no_mal_link"
    end

    return tonumber(best.malId), nil
end

local function fetch_skip_times(mal_id, episode, episode_length)
    local url = ANISKIP_API_URL .. "/" .. tostring(mal_id) .. "/" .. tostring(episode)
        .. "?types[]=op&types[]=ed"
    if episode_length and episode_length > 0 then
        url = url .. "&episodeLength=" .. string.format("%.0f", episode_length)
    end

    local data, err = http_get_json(url)
    if err then return nil, "aniskip_unavailable" end
    if not data.found then
        return nil, "aniskip_no_data"
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

local function fail(filename, title, season, episode, mal_id, err_kind, extra)
    osd(format_diagnostic(title, season, episode, mal_id, err_kind), 5)
    state.resolved = true
    state.found = false
    state.mal_id = mal_id
    state.err_kind = err_kind
    local cache_data = {
        found = false, title_guess = title, season = season, episode = episode,
        mal_id = mal_id, err_kind = err_kind,
    }
    if extra then
        for k, v in pairs(extra) do cache_data[k] = v end
    end
    save_cache(filename, cache_data)
end

local function apply_cached(cached)
    state.resolved = true
    state.found = cached.found
    state.title_guess = cached.title_guess
    state.season = cached.season
    state.episode = cached.episode
    state.mal_id = cached.mal_id
    state.err_kind = cached.err_kind
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

    local search_title, display_title, season, episode = parse_filename(filename)
    state.title_guess, state.season, state.episode = display_title, season, episode

    if not search_title then
        fail(filename, nil, nil, nil, nil, "anitopy_failed")
        return false
    end

    local mal_id, resolve_err = shikimori_resolve(search_title)
    if not mal_id then
        fail(filename, display_title, season, episode, nil, resolve_err)
        return false
    end

    local episode_length = mp.get_property_number("duration")
    local skip_times, skip_err = fetch_skip_times(mal_id, episode, episode_length)
    if not skip_times then
        fail(filename, display_title, season, episode, mal_id, skip_err)
        return false
    end

    state.found = true
    state.resolved = true
    state.mal_id = mal_id
    state.op_start, state.op_end = skip_times.op_start, skip_times.op_end
    state.ed_start, state.ed_end = skip_times.ed_start, skip_times.ed_end

    save_cache(filename, {
        found = true, title_guess = display_title, season = season, episode = episode, mal_id = mal_id,
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
        osd(format_diagnostic(state.title_guess, state.season, state.episode, state.mal_id, state.err_kind), 5)
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

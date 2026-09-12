--[[
================================================================================
 anime-skip.lua — automatic opening/ending skipper for mpv
================================================================================

READ BEFORE USE:

  1. This script does NOT bind any key by default (on purpose). You must add
     bindings yourself in your input.conf, for example:

         F script-binding anime-skip         -- perform the skip
         G script-binding anime-skip-menu    -- open the submit/vote menu

     (script-binding names are "anime-skip" and "anime-skip-menu")

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
     A separate file, "<mpv config dir>/cache/anime-skip_id", holds a random
     submitter ID used when submitting/voting on timestamps (see step 6).
     It's a plain file, not inside anime-skip_cache, so it survives cache
     auto-cleaning scripts that sweep that directory.

  4. Optional: the "anime-skip-menu" keybinding opens a uosc menu (requires
     uosc: https://github.com/tomasklaen/uosc) showing what was resolved for
     the current file (title/season/episode/MAL ID/timestamps or the reason
     it failed), plus:
       - If AniSkip has NO data for this episode: buttons to stage an A-B
         loop (set with mpv's default "l" key) as the opening or ending,
         then submit it to AniSkip.
       - If AniSkip DOES have data: buttons to upvote/downvote its accuracy.

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

-- submitter id file: "<mpv config dir>/cache/anime-skip_id" - deliberately
-- a plain file OUTSIDE of CACHE_DIR, so cache auto-cleaning scripts that
-- sweep anime-skip_cache don't wipe it out from under us.
local SUBMITTER_ID_PATH = utils.join_path(
    mp.command_native({"expand-path", "~~/"}), "cache/anime-skip_id")

-- list of skipIds we've personally submitted (JSON array), so we can tell
-- "this is my own timestamp" apart from someone else's without the API
-- exposing submitter identity on reads (it doesn't - submitterId is
-- write-only, accepted on POST but never returned on GET). Also kept
-- outside CACHE_DIR, same reasoning as SUBMITTER_ID_PATH above.
local SUBMITTED_IDS_PATH = utils.join_path(
    mp.command_native({"expand-path", "~~/"}), "cache/anime-skip_submitted_ids")

-- uosc menu integration
local UOSC_MENU_TYPE = "anime_skip_menu"
local SCRIPT_NAME = mp.get_script_name()

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
    shiki_id = nil,      -- Shikimori's own id (usually, but not always, == mal_id)
    err_kind = nil,      -- reason code for the last failure (nil if found)
    op_start = nil, op_end = nil,
    ed_start = nil, ed_end = nil,
    op_skip_id = nil, ed_skip_id = nil,   -- AniSkip's own IDs, needed to vote
    op_is_own = false, ed_is_own = false, -- true if WE submitted this timestamp
    op_voted = nil, ed_voted = nil,       -- "upvote" / "downvote" / nil (not voted yet)
    pending = {},         -- draft timestamps staged for submission (uosc menu)
}

local function reset_state()
    state = {
        resolved = false, found = false,
        title_guess = nil, season = nil, episode = nil, mal_id = nil, shiki_id = nil, err_kind = nil,
        op_start = nil, op_end = nil, ed_start = nil, ed_end = nil,
        op_skip_id = nil, ed_skip_id = nil,
        op_is_own = false, ed_is_own = false,
        op_voted = nil, ed_voted = nil,
        pending = {},
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
-- Source name resolution
--
-- For local files, "filename" (the actual file's basename) is what we
-- want - it follows fansub naming conventions anitopy expects.
-- For network streams (e.g. ani-cli piping an HLS stream into mpv),
-- "filename" is just the last path segment of the stream URL, which for
-- HLS is almost always the literal "index.m3u8" - identical for every
-- single episode, useless for parsing AND dangerous as a cache key (every
-- episode would collide on the same cache entry). ani-cli passes a proper
-- human-readable title via mpv's --force-media-title, exposed as the
-- "media-title" property, so we use that instead when streaming.
----------------------------------------------------------------------

local function get_source_name()
    if mp.get_property_bool("demuxer-via-network", false) then
        local media_title = mp.get_property("media-title")
        if media_title and media_title ~= "" then
            return media_title
        end
    end
    return mp.get_property("filename")
end

-- Builds a "run" command (for a uosc Item.value) that opens `url` in the
-- system's default browser, on whichever OS we're running on. mpv embeds
-- LuaJIT, which exposes jit.os ("Windows"/"OSX"/"Linux"/"BSD"/"POSIX"/
-- "Other") for exactly this kind of check, without shelling out just to
-- detect the platform.
local function open_url_command(url)
    local os_name = (jit and jit.os) or "Linux"
    if os_name == "Windows" then
        -- "start" is a cmd builtin, not a real executable; the empty ""
        -- argument is required because "start" treats the first quoted
        -- argument as the window title, not the thing to open.
        return {"run", "cmd", "/c", "start", "", url}
    elseif os_name == "OSX" then
        return {"run", "open", url}
    else
        return {"run", "xdg-open", url}
    end
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
    id
    malId
    name
    russian
    japanese
    english
    synonyms
    episodes
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

-- Scores every candidate's name variants against `title`/`season` via
-- match.py (run once for the whole batch) and returns the best-scoring
-- candidate's 1-based index and score. Title and season are sent
-- separately (not pre-combined into one string) so match.py can treat
-- them as two independent signals - see match.py for why that matters.
-- `episode` (the absolute episode number from anitopy) is passed through
-- too so match.py can resolve multi-part seasons (e.g. "Season 2 Part 1"
-- + "Season 2 Part 2" both existing as separate MAL entries with their
-- own 1-based episode numbering, while fansub groups number the whole
-- season 1..N straight through) - see match.py for the actual logic.
-- Returns: best_index, score, resolved_episode (nil if no part-offset
-- adjustment applied - meaning the original episode number is correct).
local function fuzzy_match_index(title, season, episode, animes)
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
        table.insert(candidates, {index = i, fields = fields, episodes = a.episodes})
    end

    local payload_table = {title = title, candidates = candidates}
    if season then
        payload_table.season = tonumber(season)
    end
    if episode then
        payload_table.episode = tonumber(episode)
    end
    local payload = utils.format_json(payload_table)
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
        return nil, 0, nil
    end

    local ok, data = pcall(utils.parse_json, res.stdout)
    if not ok or type(data) ~= "table" then
        msg.error("anime-skip: failed to parse match.py output")
        return nil, 0, nil
    end

    return data.best_index, data.score or 0, data.episode
end

-- Full Shikimori resolution: search candidates, pick the best fuzzy match
-- (rejecting anything below FUZZY_MATCH_THRESHOLD), return its Shikimori
-- id AND its MAL ID - these are usually, but not always, the same number,
-- so both are tracked separately (Shikimori's own id for their URL, MAL
-- id for AniSkip and MAL's URL). Also returns the episode number to
-- actually use (may differ from `episode` if a multi-part season offset
-- was applied - see fuzzy_match_index).
-- The Shikimori query itself still uses search_title (title + season, if
-- any) since that helps THEIR ranking surface relevant candidates in the
-- top 5 - but our own disambiguation (fuzzy_match_index) scores title and
-- season as two separate signals, since plain text similarity alone can't
-- reliably tell "no season" apart from "wrong season" (a season-less name
-- is textually closer to "title S4" than a real "4th Season" name is).
local function shikimori_resolve(search_title, base_title, season, episode)
    local animes, err = shikimori_graphql_search(search_title)
    if not animes then return nil, nil, episode, err end

    local best_index, score, resolved_episode = fuzzy_match_index(base_title, season, episode, animes)
    if not best_index or score < FUZZY_MATCH_THRESHOLD then
        return nil, nil, episode, "shikimori_not_found"
    end

    local best = animes[best_index]
    if not best.malId then
        return nil, nil, episode, "shikimori_no_mal_link"
    end

    return tonumber(best.id), tonumber(best.malId), resolved_episode or episode, nil
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
            result.op_skip_id = r.skipId
        elseif r.skipType == "ed" and r.interval then
            result.ed_start, result.ed_end = r.interval.startTime, r.interval.endTime
            result.ed_skip_id = r.skipId
        end
    end
    return result, nil
end

----------------------------------------------------------------------
-- Main resolution flow (cached per source filename)
----------------------------------------------------------------------

-- Serializes the current `state` for the currently-playing file into its
-- cache entry. Used by fail(), the successful resolution path, and later
-- by submit/vote handlers, so cache writes always carry the full picture
-- (including votes) instead of each call site re-building a partial table.
local function persist_state()
    local filename = get_source_name()
    if not filename then return end
    save_cache(filename, {
        found = state.found,
        title_guess = state.title_guess, season = state.season, episode = state.episode,
        mal_id = state.mal_id, shiki_id = state.shiki_id, err_kind = state.err_kind,
        op_start = state.op_start, op_end = state.op_end,
        op_skip_id = state.op_skip_id, op_voted = state.op_voted,
        ed_start = state.ed_start, ed_end = state.ed_end,
        ed_skip_id = state.ed_skip_id, ed_voted = state.ed_voted,
    })
end

----------------------------------------------------------------------
-- Own-submission tracking
--
-- AniSkip's GET response never exposes who submitted a timestamp
-- (submitterId is write-only, only accepted on POST) - so instead of
-- asking the server "is this mine", we keep our own local record of
-- skipIds we've submitted and check against that.
----------------------------------------------------------------------

local cached_submitted_ids = nil -- Lua set: {[skip_id] = true, ...}

local function load_submitted_ids()
    if cached_submitted_ids then return cached_submitted_ids end
    cached_submitted_ids = {}

    local f = io.open(SUBMITTED_IDS_PATH, "r")
    if f then
        local content = f:read("*a")
        f:close()
        if content and content ~= "" then
            local ok, list = pcall(utils.parse_json, content)
            if ok and type(list) == "table" then
                for _, id in ipairs(list) do
                    cached_submitted_ids[id] = true
                end
            end
        end
    end
    return cached_submitted_ids
end

local function is_own_submission(skip_id)
    if not skip_id then return false end
    return load_submitted_ids()[skip_id] == true
end

local function mark_submitted(skip_id)
    if not skip_id then return end
    local ids = load_submitted_ids()
    if ids[skip_id] then return end -- already recorded, nothing to do
    ids[skip_id] = true

    local list = {}
    for id, _ in pairs(ids) do table.insert(list, id) end

    local dir = utils.split_path(SUBMITTED_IDS_PATH)
    mp.command_native({
        name = "subprocess", capture_stdout = true, capture_stderr = true,
        args = {"mkdir", "-p", dir},
    })
    local out = io.open(SUBMITTED_IDS_PATH, "w")
    if out then
        out:write(utils.format_json(list))
        out:close()
    else
        msg.warn("anime-skip: could not persist submitted id to " .. SUBMITTED_IDS_PATH)
    end
end

-- Recomputes state.op_is_own/ed_is_own from the current op/ed skip_ids.
-- Not cached in the per-file cache - recomputed every time so that files
-- revisited later still reflect submissions made since (e.g. in a later
-- session after this exact file was already cached as "found").
local function refresh_own_flags()
    state.op_is_own = is_own_submission(state.op_skip_id)
    state.ed_is_own = is_own_submission(state.ed_skip_id)
end

local function fail(filename, title, season, episode, mal_id, shiki_id, err_kind)
    osd(format_diagnostic(title, season, episode, mal_id, err_kind), 5)
    state.resolved = true
    state.found = false
    state.title_guess = title
    state.season = season
    state.episode = episode
    state.mal_id = mal_id
    state.shiki_id = shiki_id
    state.err_kind = err_kind
    persist_state()
end

local function apply_cached(cached)
    state.resolved = true
    state.found = cached.found
    state.title_guess = cached.title_guess
    state.season = cached.season
    state.episode = cached.episode
    state.mal_id = cached.mal_id
    state.shiki_id = cached.shiki_id
    state.err_kind = cached.err_kind
    state.op_start, state.op_end = cached.op_start, cached.op_end
    state.ed_start, state.ed_end = cached.ed_start, cached.ed_end
    state.op_skip_id, state.ed_skip_id = cached.op_skip_id, cached.ed_skip_id
    state.op_voted, state.ed_voted = cached.op_voted, cached.ed_voted
    refresh_own_flags()
end

local function resolve_current_anime()
    local filename = get_source_name()
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
        fail(filename, nil, nil, nil, nil, nil, "anitopy_failed")
        return false
    end

    local shiki_id, mal_id, resolved_episode, resolve_err = shikimori_resolve(search_title, display_title, season, episode)
    if not mal_id then
        fail(filename, display_title, season, episode, nil, nil, resolve_err)
        return false
    end
    episode = resolved_episode
    state.episode = episode

    local episode_length = mp.get_property_number("duration")
    local skip_times, skip_err = fetch_skip_times(mal_id, episode, episode_length)
    if not skip_times then
        fail(filename, display_title, season, episode, mal_id, shiki_id, skip_err)
        return false
    end

    state.found = true
    state.resolved = true
    state.mal_id = mal_id
    state.shiki_id = shiki_id
    state.op_start, state.op_end = skip_times.op_start, skip_times.op_end
    state.ed_start, state.ed_end = skip_times.ed_start, skip_times.ed_end
    state.op_skip_id, state.ed_skip_id = skip_times.op_skip_id, skip_times.ed_skip_id
    refresh_own_flags()
    persist_state()

    osd("Identified: " .. display_title .. ", episode " .. tostring(episode), 3)
    return true
end

----------------------------------------------------------------------
-- Submitter ID persistence
--
-- A random ID generated once and kept in SUBMITTER_ID_PATH. AniSkip uses
-- this purely for rate-limiting/abuse prevention on their end, same as
-- SponsorBlock's model - it is NOT an account or any form of real auth.
----------------------------------------------------------------------

local cached_submitter_id = nil

local function generate_submitter_id()
    math.randomseed(os.time() + math.floor(os.clock() * 1e6) % 1000000)
    -- Proper UUID v4 format (8-4-4-4-12, version nibble "4", variant nibble
    -- in [8-b]) - AniSkip's own skipId values look like UUIDs, so
    -- submitterId is likely validated as one too; a flat 32-char hex string
    -- (no dashes) probably fails that validation.
    local template = "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"
    return (template:gsub("[xy]", function(c)
        local v
        if c == "x" then
            v = math.random(0, 15)
        else
            v = math.random(8, 11) -- variant bits: 8, 9, a, or b
        end
        return string.format("%x", v)
    end))
end

local function get_submitter_id()
    if cached_submitter_id then return cached_submitter_id end

    local f = io.open(SUBMITTER_ID_PATH, "r")
    if f then
        local content = f:read("*a")
        f:close()
        content = content and content:gsub("%s+", "") or ""
        if content ~= "" then
            cached_submitter_id = content
            return cached_submitter_id
        end
    end

    local id = generate_submitter_id()
    local dir = utils.split_path(SUBMITTER_ID_PATH)
    mp.command_native({
        name = "subprocess", capture_stdout = true, capture_stderr = true,
        args = {"mkdir", "-p", dir},
    })
    local out = io.open(SUBMITTER_ID_PATH, "w")
    if out then
        out:write(id)
        out:close()
    else
        msg.warn("anime-skip: could not persist submitter id to " .. SUBMITTER_ID_PATH
            .. " - a new one will be generated next session")
    end
    cached_submitter_id = id
    return id
end

----------------------------------------------------------------------
-- A-B loop reading
--
-- Timestamps for submission are staged from mpv's own A-B loop (default
-- key "l" sets point A, then B) instead of a separate mark-start/mark-end
-- mechanism - it's already the standard, visual way to mark a region in
-- mpv/uosc, so we just read it rather than reinventing it.
----------------------------------------------------------------------

local function get_ab_loop()
    local a = mp.get_property_number("ab-loop-a")
    local b = mp.get_property_number("ab-loop-b")
    if a and b and b > a then
        return a, b
    end
    return nil, nil
end

----------------------------------------------------------------------
-- AniSkip submit/vote requests
----------------------------------------------------------------------

local function http_post_json(url, body)
    local res = mp.command_native({
        name = "subprocess",
        capture_stdout = true,
        capture_stderr = true,
        args = {
            "curl", "-s", "-g", "-A", USER_AGENT,
            "-H", "Content-Type: application/json",
            "-H", "Accept: application/json",
            "--max-time", "10",
            "-X", "POST", "-d", body,
            url,
        },
    })

    if res == nil or res.status ~= 0 then
        return nil, "network error"
    end
    if not res.stdout or res.stdout == "" then
        return nil, "empty response"
    end

    local ok, data = pcall(utils.parse_json, res.stdout)
    if not ok or type(data) ~= "table" then
        return nil, "invalid response"
    end
    return data, nil
end

-- API error "message" fields are sometimes a single string, sometimes an
-- array of validation error strings - normalize either into one string.
local function stringify_message(message)
    if type(message) == "string" then
        return message
    end
    if type(message) == "table" then
        return table.concat(message, "; ")
    end
    return nil
end

-- Submits one op/ed segment. Returns true+skipId on success, false+reason
-- otherwise. skip_type is "op" or "ed".
local function aniskip_submit(mal_id, episode, skip_type, start_time, end_time, episode_length)
    local body = utils.format_json({
        skipType = skip_type,
        providerName = "anime-skip.lua",
        submitterId = get_submitter_id(),
        startTime = start_time,
        endTime = end_time,
        episodeLength = episode_length,
    })
    local url = ANISKIP_API_URL .. "/" .. tostring(mal_id) .. "/" .. tostring(episode)

    local data, err = http_post_json(url, body)
    if not data then return false, err end
    if data.statusCode == 201 then
        return true, data.skipId
    end
    local path = dump_debug_response("submit_failed", utils.format_json(data))
    return false, (stringify_message(data.message) or ("status " .. tostring(data.statusCode))) .. " (see " .. path .. ")"
end

-- vote_type is "upvote" or "downvote".
local function aniskip_vote(skip_id, vote_type)
    local body = utils.format_json({voteType = vote_type})
    local url = ANISKIP_API_URL .. "/vote/" .. tostring(skip_id)

    local data, err = http_post_json(url, body)
    if not data then return false, err end
    if data.statusCode == 201 then
        return true, nil
    end
    local path = dump_debug_response("vote_failed", utils.format_json(data))
    return false, (stringify_message(data.message) or ("status " .. tostring(data.statusCode))) .. " (see " .. path .. ")"
end

----------------------------------------------------------------------
-- uosc menu: shows what was resolved for the current file, and lets you
-- submit missing timestamps or vote on existing ones.
--
-- Submit controls only appear when AniSkip has NO data for this episode
-- (state.found == false) - if timestamps already exist, staging/submitting
-- more would just create noise/duplicates for everyone else.
-- Vote controls only appear when timestamps DO exist (state.found == true)
-- and we actually have a skip_id to vote on.
----------------------------------------------------------------------

-- Display-only formatting: raw seconds are what the API and A-B loop
-- actually work with everywhere else in the script - this is purely
-- for making menu text readable ("1284.3s" -> "21:24").
local function fmt_time(t)
    t = math.floor(t + 0.5) -- round to nearest whole second for display
    local h = math.floor(t / 3600)
    local m = math.floor((t % 3600) / 60)
    local s = t % 60
    if h > 0 then
        return string.format("%d:%02d:%02d", h, m, s)
    end
    return string.format("%d:%02d", m, s)
end

local function build_menu_items()
    local items = {}

    -- Informational / non-interactive row. uosc's Item.value is a required
    -- field even for display-only rows, so we point it at mpv's built-in
    -- "ignore" command (a real no-op) rather than leaving it unset.
    local function info(title)
        return {title = title, value = "ignore", selectable = false, muted = true}
    end
    local function separator()
        return {value = "ignore", selectable = false, separator = true}
    end

    -- Info block: everything currently known/cached for this file.
    if not state.resolved then
        table.insert(items, info("Not resolved yet - open this menu again after a moment"))
    else
        if state.title_guess then
            table.insert(items, {title = "Name: " .. state.title_guess, value = "ignore", selectable = false})
        end
        local info_parts = {}
        if state.season then table.insert(info_parts, "Season " .. tostring(state.season)) end
        if state.episode then table.insert(info_parts, "Episode " .. tostring(state.episode)) end
        if #info_parts > 0 then
            table.insert(items, info(table.concat(info_parts, ", ")))
        end
        if state.mal_id then
            table.insert(items, info("MAL ID: " .. tostring(state.mal_id)))
        end

        if state.found then
            if state.op_start then
                table.insert(items, info("Opening: " .. fmt_time(state.op_start) .. " - " .. fmt_time(state.op_end)))
            end
            if state.ed_start then
                table.insert(items, info("Ending: " .. fmt_time(state.ed_start) .. " - " .. fmt_time(state.ed_end)))
            end
        elseif state.err_kind then
            table.insert(items, info("Issue: " .. (ERROR_MESSAGES[state.err_kind] or state.err_kind)))
        end
    end

    local can_submit_op = state.resolved and state.mal_id and not state.op_start
    local can_submit_ed = state.resolved and state.mal_id and not state.ed_start
    local has_submit = can_submit_op or can_submit_ed
    local has_vote = state.found and (state.op_skip_id or state.ed_skip_id)
    local has_shiki_button = state.shiki_id ~= nil
    local has_mal_button = state.mal_id ~= nil

    if has_submit or has_vote or has_shiki_button or has_mal_button then
        table.insert(items, separator())
    end

    if has_shiki_button then
        table.insert(items, {
            title = "Open on Shikimori",
            value = open_url_command("https://shikimori.io/animes/" .. tostring(state.shiki_id)),
        })
    end

    if has_mal_button then
        table.insert(items, {
            title = "Open on MAL",
            value = open_url_command("https://myanimelist.net/anime/" .. tostring(state.mal_id)),
        })
    end

    -- Submit section: shown per-segment - Opening and Ending are entirely
    -- independent submissions, so a segment only appears here if AniSkip
    -- doesn't already have data for THAT specific segment (submitting a
    -- duplicate for one that already exists would just be noise).
    if has_submit then
        local a, b = get_ab_loop()
        local loop_hint = (a and b) and ("loop: " .. fmt_time(a) .. " - " .. fmt_time(b)) or "no A-B loop set (press 'l' twice)"

        if can_submit_op then
            table.insert(items, {
                title = "Stage current loop as Opening", hint = loop_hint,
                value = {"script-message-to", SCRIPT_NAME, "anime-skip-stage", "op"},
                keep_open = true,
            })
            if state.pending.op_start then
                table.insert(items, info("Staged Opening: " .. fmt_time(state.pending.op_start) .. " - " .. fmt_time(state.pending.op_end)))
                table.insert(items, {
                    title = "Submit Opening", icon = "check",
                    value = {"script-message-to", SCRIPT_NAME, "anime-skip-submit", "op"},
                })
            end
        end

        if can_submit_ed then
            table.insert(items, {
                title = "Stage current loop as Ending", hint = loop_hint,
                value = {"script-message-to", SCRIPT_NAME, "anime-skip-stage", "ed"},
                keep_open = true,
            })
            if state.pending.ed_start then
                table.insert(items, info("Staged Ending: " .. fmt_time(state.pending.ed_start) .. " - " .. fmt_time(state.pending.ed_end)))
                table.insert(items, {
                    title = "Submit Ending", icon = "check",
                    value = {"script-message-to", SCRIPT_NAME, "anime-skip-submit", "ed"},
                })
            end
        end
    end

    -- Vote section: only when AniSkip actually has data (and a skip_id) to vote on.
    if has_vote then
        if state.op_skip_id then
            if state.op_is_own then
                table.insert(items, info("Opening timestamp: submitted by you"))
            elseif state.op_voted then
                table.insert(items, info("Opening timestamp: rated "
                    .. (state.op_voted == "upvote" and "correct" or "wrong")))
            else
                table.insert(items, {
                    title = "Opening timestamp correct",
                    value = {"script-message-to", SCRIPT_NAME, "anime-skip-vote", "op", "upvote"},
                })
                table.insert(items, {
                    title = "Opening timestamp wrong",
                    value = {"script-message-to", SCRIPT_NAME, "anime-skip-vote", "op", "downvote"},
                })
            end
        end
        if state.ed_skip_id then
            if state.ed_is_own then
                table.insert(items, info("Ending timestamp: submitted by you"))
            elseif state.ed_voted then
                table.insert(items, info("Ending timestamp: rated "
                    .. (state.ed_voted == "upvote" and "correct" or "wrong")))
            else
                table.insert(items, {
                    title = "Ending timestamp correct",
                    value = {"script-message-to", SCRIPT_NAME, "anime-skip-vote", "ed", "upvote"},
                })
                table.insert(items, {
                    title = "Ending timestamp wrong",
                    value = {"script-message-to", SCRIPT_NAME, "anime-skip-vote", "ed", "downvote"},
                })
            end
        end
    end

    return items
end

local function send_menu(is_open)
    local menu = {
        type = UOSC_MENU_TYPE,
        title = "anime-skip",
        keep_open = true,
        items = build_menu_items(),
    }
    local json = utils.format_json(menu)
    if is_open then
        mp.commandv("script-message-to", "uosc", "open-menu", json)
    else
        mp.commandv("script-message-to", "uosc", "update-menu", json)
    end
end

mp.register_script_message("anime-skip-stage", function(kind)
    local a, b = get_ab_loop()
    if not a or not b then
        osd("No A-B loop set - press 'l' twice to mark start and end first", 3)
        return
    end
    if kind == "op" then
        state.pending.op_start, state.pending.op_end = a, b
    elseif kind == "ed" then
        state.pending.ed_start, state.pending.ed_end = a, b
    end
    send_menu(false)
end)

mp.register_script_message("anime-skip-submit", function(kind)
    if not state.mal_id or not state.episode then return end
    local pending = state.pending[kind .. "_start"] and {
        start_time = state.pending[kind .. "_start"],
        end_time = state.pending[kind .. "_end"],
    } or nil
    if not pending then
        osd("Nothing staged to submit", 3)
        return
    end

    local episode_length = mp.get_property_number("duration")
    local ok, result = aniskip_submit(state.mal_id, state.episode, kind,
        pending.start_time, pending.end_time, episode_length)

    if ok then
        -- We already know exactly what we just submitted - update state
        -- directly instead of deleting the cache and re-querying AniSkip.
        state[kind .. "_start"], state[kind .. "_end"], state[kind .. "_skip_id"] = pending.start_time, pending.end_time, result
        state[kind .. "_is_own"] = true
        mark_submitted(result)
        -- only this segment's draft is consumed - the other one (if any) is untouched
        state.pending[kind .. "_start"] = nil
        state.pending[kind .. "_end"] = nil
        state.found = true
        state.err_kind = nil
        persist_state()
        osd((kind == "op" and "Opening" or "Ending") .. " submitted successfully, thank you!", 3)
    else
        osd((kind == "op" and "Opening" or "Ending") .. " submit failed: " .. tostring(result), 5)
    end

    send_menu(false) -- refresh in place: this segment's submit controls disappear, vote controls appear
end)

mp.register_script_message("anime-skip-vote", function(kind, vote_type)
    local skip_id = (kind == "op") and state.op_skip_id or state.ed_skip_id
    if not skip_id then return end
    local is_own = (kind == "op") and state.op_is_own or state.ed_is_own
    if is_own then return end -- can't vote on your own submission

    local ok, err = aniskip_vote(skip_id, vote_type)
    if ok then
        if kind == "op" then state.op_voted = vote_type else state.ed_voted = vote_type end
        persist_state()
        osd("Vote submitted, thanks!", 2)
    else
        osd("Vote failed: " .. tostring(err), 3)
    end

    send_menu(false) -- refresh in place: shows the rated status instead of the buttons
end)

mp.add_key_binding(nil, "anime-skip-menu", function()
    if not state.resolved then
        resolve_current_anime()
    end
    send_menu(true)
end)

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

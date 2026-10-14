--[[
================================================================================
 anime-skip.lua — automatic opening/ending skipper for mpv
================================================================================

Works on Linux, Windows and macOS.

READ BEFORE USE:

  1. This script does NOT bind any key by default (on purpose). You must add
     bindings yourself in your input.conf, for example:

         F1 script-binding anime-skip         # perform the skip
         F2 script-binding anime-skip-menu    # open/close the info/submit/vote menu

     (input.conf comments start with "#" - anything after "--" would be
     passed to script-binding as extra arguments.)

  2. Dependencies:
       - curl       (all HTTP requests go through it, mpv Lua has no
                     networking; ships by default on Windows 10+, macOS and
                     most Linux distributions)
       - Python 3.7+ (runs the filename parser and the title matcher).
                     Found automatically: "python3"/"python" on Linux/macOS,
                     the "py" launcher, "python" or "python3" on Windows.
                     Override with python_cmd (see OPTIONS) if needed.
     The script folder must contain (all included):
       - "lookup.py" (calls anitopy.parse() on the filename, prints JSON)
       - "match.py"  (scores Shikimori candidates against our title via
                      difflib.SequenceMatcher + explicit season-marker
                      detection, and - when a season is split into
                      multiple "Part N" MAL/Shikimori entries - resolves
                      which part + local episode number a fansub group's
                      absolute episode number actually falls into.)
       - "anitopy/"  (the anitopy package itself, bundled - no pip install)
     Default location: "~~/scripts/anime-skip/".

  3. Cache location: "~~/cache/anime-skip_cache"
     (usually ~/.config/mpv/cache/anime-skip_cache). One small JSON file is
     stored per source filename so repeated keypresses on the same episode
     never repeat the network lookups. "Not found" results are re-checked
     after recheck_days (see OPTIONS), so data added to AniSkip later is
     picked up automatically.
     A separate file, "~~/cache/anime-skip_id", holds a random
     submitter ID used when submitting/voting on timestamps.

  4. Optional: the "anime-skip-menu" keybinding opens a uosc menu (requires
     uosc: https://github.com/tomasklaen/uosc) showing what was resolved for
     the current file (title/season/episode/MAL ID/timestamps or the reason
     it failed), plus:
       - If AniSkip has NO data for this episode: buttons to stage an A-B
         loop (set with mpv's default "l" key) as the opening or ending,
         then submit it to AniSkip. The A-B loop is cleared after a
         successful submit.
       - If AniSkip DOES have data: buttons to upvote/downvote its accuracy.

  OPTIONS (script-opts/anime-skip.conf, all optional):
     python_cmd=                 e.g. "python3", "py -3", or a full path;
                                 empty = detect automatically
     fuzzy_match_threshold=0.6   minimum title similarity (0-1)
     skip_tolerance=2            seconds BEFORE an opening/ending start
                                 where the skip key already works
                                 (AniSkip timestamps are often a bit late)
     recheck_days=7              re-check cached "not found" results after
                                 this many days (0 = never re-check)

  HOW IT WORKS (on keypress or when opening the menu - never automatically):
    1. Parse the current filename via anitopy (through lookup.py) to get
       the anime title, season (if present) and episode number.
    2. Query Shikimori's GraphQL API for up to SHIKIMORI_SEARCH_LIMIT
       candidates matching the title, each with all of its name variants
       (name/russian/japanese/english/synonyms) and its MyAnimeList ID
       (malId) in the same response.
    3. Fuzzy-match our title against every name variant of every candidate
       (via match.py) and take the best-scoring one, provided it clears a
       minimum similarity threshold; below that, treat it as not found.
    4. Query the AniSkip API (api.aniskip.com) for op/ed timestamps using
       the MAL ID.
    5. If the current playback position falls inside an op/ed interval,
       seek to the end of it. Otherwise show a message and do nothing.
    All of this runs in the background - mpv keeps playing and stays
    responsive while the lookups are in progress.

  KNOWN LIMITATIONS:
    - Filename parsing quality depends on anitopy; very unusual naming
      schemes may still fail.
    - The fuzzy match threshold is a heuristic; very obscure/short titles
      could still be mismatched or wrongly rejected.
================================================================================
]]

local mp = require 'mp'
local utils = require 'mp.utils'
local msg = require 'mp.msg'

----------------------------------------------------------------------
-- Configuration
----------------------------------------------------------------------

local opts = {
    python_cmd = "",
    fuzzy_match_threshold = 0.6,
    skip_tolerance = 2,
    recheck_days = 7,
}
require('mp.options').read_options(opts, "anime-skip")

local SHIKIMORI_GRAPHQL_URL = "https://shikimori.io/api/graphql"
local ANISKIP_API_URL = "https://api.aniskip.com/v2/skip-times"
-- Shikimori asks API clients to identify themselves with a descriptive
-- User-Agent (their own docs/wrappers all set one explicitly); a generic
-- one is more likely to get blocked by their anti-bot protection.
local USER_AGENT = "anime-skip.lua/1.0 (mpv script; https://github.com/AkuLinker/mpv-config)"

-- Same platform detection as every other script in this config. Falls
-- back to the path separator if mpv is too old to have the property.
local PLATFORM = mp.get_property_native("platform")
    or (package.config:sub(1, 1) == "\\" and "windows" or "linux")

local CONFIG_DIR = mp.command_native({"expand-path", "~~/"})

-- anitopy filename-parsing wrapper and fuzzy-matching helper (see header)
local SCRIPTS_DIR = utils.join_path(CONFIG_DIR, "scripts/anime-skip")
local ANITOPY_LOOKUP_PATH = utils.join_path(SCRIPTS_DIR, "lookup.py")
local MATCH_SCRIPT_PATH = utils.join_path(SCRIPTS_DIR, "match.py")

-- cache dir: "~~/cache/anime-skip_cache"
local CACHE_DIR = utils.join_path(utils.join_path(CONFIG_DIR, "cache"), "anime-skip_cache")

-- submitter id file: "~~/cache/anime-skip_id" - deliberately
-- a plain file OUTSIDE of CACHE_DIR, so cache auto-cleaning scripts that
-- sweep anime-skip_cache don't wipe it out from under us.
local SUBMITTER_ID_PATH = utils.join_path(CONFIG_DIR, "cache/anime-skip_id")

-- list of skipIds we've personally submitted (JSON array), so we can tell
-- "this is my own timestamp" apart from someone else's without the API
-- exposing submitter identity on reads (it doesn't - submitterId is
-- write-only, accepted on POST but never returned on GET). Also kept
-- outside CACHE_DIR, same reasoning as SUBMITTER_ID_PATH above.
local SUBMITTED_IDS_PATH = utils.join_path(CONFIG_DIR, "cache/anime-skip_submitted_ids")

-- uosc menu integration
local UOSC_MENU_TYPE = "anime_skip_menu"
local SCRIPT_NAME = mp.get_script_name()

----------------------------------------------------------------------
-- Per-file state (reset whenever a new file starts playing)
----------------------------------------------------------------------

local state

-- Incremented on every new file. Every background callback captures the
-- value it started with and drops its result if it changed meanwhile, so
-- a slow lookup for the previous episode can never overwrite the state of
-- the current one.
local generation = 0

-- True while a submit/vote/refresh request is in flight, to avoid sending
-- the same request twice on a double click.
local busy = false

-- Whether our uosc menu is currently open (so finished background lookups
-- know to refresh it).
local menu_open = false

local function reset_state()
    generation = generation + 1
    busy = false
    state = {
        resolved = false,   -- true once resolution was attempted for this file
        resolving = false,  -- true while the background lookup is running
        found = false,      -- true if title/episode/skip-times were resolved ok
        title_guess = nil, season = nil, episode = nil,
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
end

reset_state()
mp.register_event("start-file", reset_state)

----------------------------------------------------------------------
-- OSD helper
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
-- system's default browser, on whichever OS we're running on.
local function open_url_command(url)
    if PLATFORM == "windows" then
        -- rundll32 opens the default browser without a console window and,
        -- unlike "cmd /c start", never misreads characters like & in URLs.
        return {"run", "rundll32", "url.dll,FileProtocolHandler", url}
    elseif PLATFORM == "darwin" then
        return {"run", "open", url}
    else
        return {"run", "xdg-open", url}
    end
end

-- Creates `dir` (and any missing parent directories). Does nothing - and
-- starts no process - if it already exists, which is the normal case.
local function ensure_dir_exists(dir)
    if not dir or dir == "" then return end
    local info = utils.file_info(dir)
    if info and info.is_dir then return end

    local args
    if PLATFORM == "windows" then
        -- cmd's mkdir creates intermediate folders by itself, but reads a
        -- forward slash as the start of a command switch - so convert.
        args = {"cmd", "/d", "/c", "mkdir", (dir:gsub("/", "\\"))}
    else
        args = {"mkdir", "-p", dir}
    end
    mp.command_native({
        name = "subprocess", playback_only = false,
        capture_stdout = true, capture_stderr = true,
        args = args,
    })
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
    python_missing = "Python 3 was not found (install it, or set python_cmd in script-opts/anime-skip.conf)",
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
-- Background process helpers
----------------------------------------------------------------------

-- Runs a process without blocking mpv. cb(res) receives mpv's subprocess
-- result table (status, stdout, stderr, error_string) or nil.
local function run_async(args, stdin_data, cb)
    mp.command_native_async({
        name = "subprocess",
        args = args,
        stdin_data = stdin_data,
        playback_only = false,
        capture_stdout = true,
        capture_stderr = true,
    }, function(success, res)
        cb(success and res or nil)
    end)
end

-- Writes the raw (failed) response body to a debug file in the cache dir
-- so the actual server reply can be inspected after the fact, instead of
-- guessing blindly why JSON parsing failed (Cloudflare challenge page,
-- rate limit message, unexpected format, etc).
local function dump_debug_response(label, body)
    ensure_dir_exists(CACHE_DIR)
    local path = utils.join_path(CACHE_DIR, "last_error_" .. label .. ".txt")
    local f = io.open(path, "wb")
    if f then
        f:write(body or "")
        f:close()
    end
    return path
end

----------------------------------------------------------------------
-- Python detection
--
-- "python3" is the norm on Linux/macOS, but on Windows it usually doesn't
-- exist - or is only the Microsoft Store placeholder that just fails. So
-- the candidates are tried once per session and the first working one is
-- remembered. Every Python call runs with "-X utf8" so text is exchanged
-- as UTF-8 on every OS (Windows would otherwise use its ANSI codepage and
-- garble Japanese/Cyrillic titles).
----------------------------------------------------------------------

local python_prefix = nil -- e.g. {"python3"} or {"py", "-3"} once found

local function python_candidates()
    if opts.python_cmd ~= "" then
        local cmd = {}
        for word in opts.python_cmd:gmatch("%S+") do table.insert(cmd, word) end
        return {cmd}
    end
    if PLATFORM == "windows" then
        return {{"py", "-3"}, {"python"}, {"python3"}}
    end
    return {{"python3"}, {"python"}}
end

local function with_python(cb)
    if python_prefix then return cb(python_prefix) end

    local candidates = python_candidates()
    local i = 0
    local function try_next()
        i = i + 1
        local cand = candidates[i]
        if not cand then
            msg.error("anime-skip: no working Python 3.7+ found (tried "
                .. #candidates .. " command(s))")
            return cb(nil)
        end
        local args = {}
        for _, a in ipairs(cand) do table.insert(args, a) end
        table.insert(args, "-c")
        table.insert(args, "import sys; sys.exit(0 if sys.version_info >= (3, 7) else 1)")
        run_async(args, nil, function(res)
            if res and res.status == 0 then
                python_prefix = cand
                msg.verbose("anime-skip: using Python: " .. table.concat(cand, " "))
                cb(cand)
            else
                try_next()
            end
        end)
    end
    try_next()
end

-- Runs one of our .py helpers. cb(res) or cb(nil, "python_missing").
local function run_python(script_path, extra_args, stdin_data, cb)
    with_python(function(prefix)
        if not prefix then return cb(nil, "python_missing") end
        local args = {}
        for _, a in ipairs(prefix) do table.insert(args, a) end
        table.insert(args, "-X")
        table.insert(args, "utf8")
        table.insert(args, script_path)
        for _, a in ipairs(extra_args or {}) do table.insert(args, a) end
        run_async(args, stdin_data, function(res) cb(res, nil) end)
    end)
end

----------------------------------------------------------------------
-- HTTP helper: runs curl in the background
--
-- POST bodies go through stdin (--data-binary @-) instead of the command
-- line: no length limit, and non-ASCII text (Japanese titles) survives on
-- Windows too. "-sS" = quiet, but still report errors on stderr so the
-- diagnostics have an actual reason in them.
----------------------------------------------------------------------

local function curl_async(method, url, body, cb)
    local args = {"curl", "-sS", "-g", "-A", USER_AGENT,
                  "-H", "Accept: application/json", "--max-time", "10"}
    if method == "POST" then
        table.insert(args, "-H"); table.insert(args, "Content-Type: application/json")
        table.insert(args, "-X"); table.insert(args, "POST")
        table.insert(args, "--data-binary"); table.insert(args, "@-")
    else
        table.insert(args, "-L")
    end
    table.insert(args, url)
    run_async(args, method == "POST" and (body or "") or nil, cb)
end

local function describe_curl_failure(res, url)
    if res == nil or res.error_string == "init" then
        return "failed to start curl (is it installed?)"
    end
    if res.status ~= 0 then
        local stderr = res.stderr and res.stderr:gsub("%s+$", "") or ""
        return "curl exited with status " .. tostring(res.status)
            .. (stderr ~= "" and (" (" .. stderr .. ")") or "")
    end
    return "empty response from " .. url
end

-- cb(data, err)
local function http_json(method, url, body, debug_label, cb)
    curl_async(method, url, body, function(res)
        if res == nil or res.status ~= 0 or not res.stdout or res.stdout == "" then
            local err = describe_curl_failure(res, url)
            msg.error("anime-skip: " .. err)
            return cb(nil, err)
        end

        local ok, data = pcall(utils.parse_json, res.stdout)
        if not ok or type(data) ~= "table" then
            local path = dump_debug_response(debug_label, res.stdout)
            local snippet = res.stdout:sub(1, 120):gsub("%s+", " ")
            msg.error("anime-skip: non-JSON response from " .. url)
            msg.error("anime-skip: first 120 chars: " .. snippet)
            msg.error("anime-skip: full body saved to " .. path)
            return cb(nil, "server returned non-JSON data (see mpv log / " .. path .. ")")
        end
        cb(data, nil)
    end)
end

----------------------------------------------------------------------
-- Cache helpers (one JSON file per source filename)
----------------------------------------------------------------------

-- Two independent 32-bit string hashes -> 16 hex chars. Plain arithmetic,
-- so it works on any Lua version (no bit library needed).
local function hash_string(s)
    local h1, h2 = 5381, 0
    for i = 1, #s do
        local b = s:byte(i)
        h1 = (h1 * 33 + b) % 4294967296
        h2 = (h2 * 65599 + b) % 4294967296
    end
    return string.format("%08x%08x", h1, h2)
end

local CACHE_KEY_MAX_LEN = 150

local function cache_path_for(filename)
    -- Sanitize into a safe file name. Plain ASCII names keep exactly the
    -- same cache file name as before, so existing cache entries stay valid.
    -- If sanitizing had to replace anything (e.g. Japanese/Cyrillic
    -- characters all become "_"), or the name is very long, a hash of the
    -- ORIGINAL name is appended - otherwise two different titles could end
    -- up sharing one cache file.
    local key = filename:gsub("[^%w%-%_%.]", "_")
    if key ~= filename or #key > CACHE_KEY_MAX_LEN then
        key = key:sub(1, CACHE_KEY_MAX_LEN) .. "_" .. hash_string(filename)
    end
    return utils.join_path(CACHE_DIR, key .. ".json")
end

-- "We asked and the answer was no" results: cached, but re-checked after
-- opts.recheck_days, since someone may add the data later.
local RECHECKABLE_ERROR_KINDS = {
    aniskip_no_data = true,
    shikimori_not_found = true,
    shikimori_no_mal_link = true,
}

local function load_cache(filename)
    local f = io.open(cache_path_for(filename), "rb")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    if not content or content == "" then return nil end
    local ok, data = pcall(utils.parse_json, content)
    if not ok or type(data) ~= "table" then return nil end

    if not data.found and RECHECKABLE_ERROR_KINDS[data.err_kind] and opts.recheck_days > 0 then
        local age_days = (os.time() - (tonumber(data.cached_at) or 0)) / 86400
        if age_days >= opts.recheck_days then
            msg.verbose("anime-skip: cached '" .. tostring(data.err_kind)
                .. "' result is old, checking again")
            return nil
        end
    end
    return data
end

local function save_cache(filename, data)
    ensure_dir_exists(CACHE_DIR)
    data.cached_at = os.time()
    local f = io.open(cache_path_for(filename), "wb")
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
-- Runs "python lookup.py <filename>", which internally calls
-- anitopy.parse() and prints the result as JSON. Anitopy reliably
-- separates release-group tags, technical info (resolution, checksum,
-- codec) and the episode number from the actual title, which is far
-- more robust than a hand-rolled regex parser.
--
-- cb(info, err): info = {search_title, title, season, episode,
-- episode_explicit} or nil. search_title is title + " S<season>" if a
-- season was detected (used for the Shikimori query); episode defaults
-- to 1 if anitopy found a title but no episode marker (movies/OVAs).
----------------------------------------------------------------------

local function parse_filename(filename, cb)
    run_python(ANITOPY_LOOKUP_PATH, {filename}, nil, function(res, err)
        if err then return cb(nil, err) end

        if res == nil or res.status ~= 0 then
            msg.error("anime-skip: anitopy lookup failed"
                .. (res and res.stderr and (": " .. res.stderr) or ""))
            return cb(nil, "anitopy_failed")
        end
        if not res.stdout or res.stdout == "" then
            msg.error("anime-skip: anitopy lookup returned empty output")
            return cb(nil, "anitopy_failed")
        end

        local ok, info = pcall(utils.parse_json, res.stdout)
        if not ok or type(info) ~= "table" then
            msg.error("anime-skip: failed to parse anitopy JSON output")
            return cb(nil, "anitopy_failed")
        end

        local title = info.anime_title
        if type(title) == "table" then title = title[1] end
        if not title or title == "" then
            return cb(nil, "anitopy_failed")
        end

        -- anitopy may return a list for batch releases (e.g. "01-02");
        -- just take the first episode in that case. If no episode marker was
        -- found at all (typical for movies/single-segment OVAs), default to
        -- episode 1 rather than treating it as a failure. episode_explicit
        -- records which case this was - a movie has no episode marker in its
        -- filename at all, so the DEFAULTED episode=1 should never be treated
        -- as evidence of a numbered-episode context (see its use further
        -- down, gating the season/part grouping in match.py).
        local episode = info.episode_number
        local episode_explicit = episode ~= nil
        if type(episode) == "table" then episode = episode[1] end
        episode = episode and tonumber(episode) or 1

        local season = info.anime_season
        if type(season) == "table" then season = season[1] end
        season = season and tostring(season) or nil

        local search_title = title
        if season then
            search_title = title .. " S" .. season
        end

        cb({
            search_title = search_title, title = title, season = season,
            episode = episode, episode_explicit = episode_explicit,
        }, nil)
    end)
end

----------------------------------------------------------------------
-- Shikimori + AniSkip resolution
----------------------------------------------------------------------

-- How many Shikimori search results to consider. Our own fuzzy-match
-- threshold and the stricter part-grouping threshold already filter out
-- low-quality candidates, so a larger pool just gives obscure/short
-- titles more of a chance to be found at all without risking noisier
-- results getting through.
local SHIKIMORI_SEARCH_LIMIT = 10

local SHIKIMORI_GRAPHQL_QUERY = [[
query($s: String, $limit: Int) {
  animes(search: $s, limit: $limit) {
    id
    malId
    name
    russian
    japanese
    english
    synonyms
    episodes
    kind
  }
}
]]

-- Queries Shikimori's GraphQL API for up to SHIKIMORI_SEARCH_LIMIT
-- candidates. cb(animes, err): the raw list of anime objects (each with
-- malId + all name variants), or nil + error kind.
local function shikimori_graphql_search(search_title, cb)
    local body = utils.format_json({
        query = SHIKIMORI_GRAPHQL_QUERY,
        variables = {s = search_title, limit = SHIKIMORI_SEARCH_LIMIT},
    })
    http_json("POST", SHIKIMORI_GRAPHQL_URL, body, "shikimori_graphql", function(data, err)
        if not data then return cb(nil, "shikimori_unavailable") end
        if data.errors then
            msg.error("anime-skip: Shikimori GraphQL error: "
                .. (data.errors[1] and data.errors[1].message or "unknown"))
            return cb(nil, "shikimori_unavailable")
        end
        if not data.data or not data.data.animes or #data.data.animes == 0 then
            return cb(nil, "shikimori_not_found")
        end
        cb(data.data.animes, nil)
    end)
end

-- Scores every candidate's name variants against `title`/`season` via
-- match.py (run once for the whole batch). Title and season are sent
-- separately (not pre-combined into one string) so match.py can treat
-- them as two independent signals - see match.py for why that matters.
-- `episode` (the absolute episode number from anitopy) is passed through
-- too so match.py can resolve multi-part seasons (e.g. "Season 2 Part 1"
-- + "Season 2 Part 2" both existing as separate MAL entries with their
-- own 1-based episode numbering, while fansub groups number the whole
-- season 1..N straight through) - see match.py for the actual logic.
-- cb(best_index, score, resolved_episode, err): resolved_episode is nil
-- if no part-offset adjustment applied (the original number is correct).
local function fuzzy_match_index(title, season, episode, episode_explicit, animes, cb)
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
        table.insert(candidates, {index = i, fields = fields, episodes = a.episodes, kind = a.kind})
    end

    local payload_table = {title = title, candidates = candidates}
    if season then
        payload_table.season = tonumber(season)
    end
    -- Only send `episode` when it was actually found in the filename, not
    -- when we defaulted it to 1 (typical for movies/one-off releases with
    -- no episode marker at all). match.py's season/part grouping treats a
    -- missing `episode` as "don't try to place this in a sequence".
    if episode and episode_explicit then
        payload_table.episode = tonumber(episode)
    end

    run_python(MATCH_SCRIPT_PATH, {}, utils.format_json(payload_table), function(res, err)
        if err then return cb(nil, 0, nil, err) end
        if res == nil or res.status ~= 0 or not res.stdout or res.stdout == "" then
            msg.error("anime-skip: match.py failed"
                .. (res and res.stderr and (": " .. res.stderr) or ""))
            return cb(nil, 0, nil, nil)
        end

        local ok, data = pcall(utils.parse_json, res.stdout)
        if not ok or type(data) ~= "table" then
            msg.error("anime-skip: failed to parse match.py output")
            return cb(nil, 0, nil, nil)
        end
        cb(data.best_index, data.score or 0, data.episode, nil)
    end)
end

-- Full Shikimori resolution: search candidates, pick the best fuzzy match
-- (rejecting anything below the threshold), return its Shikimori id AND
-- its MAL ID - usually, but not always, the same number, so both are
-- tracked separately (Shikimori's own id for their URL, MAL id for AniSkip
-- and MAL's URL). Also returns the episode number to actually use (may
-- differ from `episode` if a multi-part season offset was applied).
-- The Shikimori query itself still uses search_title (title + season, if
-- any) since that helps THEIR ranking surface relevant candidates - but our
-- own disambiguation scores title and season as two separate signals.
-- cb(result, err): result = {shiki_id, mal_id, episode, title}
local function shikimori_resolve(p, cb)
    shikimori_graphql_search(p.search_title, function(animes, err)
        if not animes then return cb(nil, err) end

        fuzzy_match_index(p.title, p.season, p.episode, p.episode_explicit, animes,
            function(best_index, score, resolved_episode, match_err)
                if match_err then return cb(nil, match_err) end
                if not best_index or score < opts.fuzzy_match_threshold then
                    return cb(nil, "shikimori_not_found")
                end

                local best = animes[best_index]
                if not best then
                    msg.error("anime-skip: match.py returned an out-of-range index ("
                        .. tostring(best_index) .. ")")
                    return cb(nil, "shikimori_not_found")
                end
                if not best.malId then
                    return cb(nil, "shikimori_no_mal_link")
                end

                -- Shikimori's "name" field is the romaji (Latin-script)
                -- title of the exact entry we matched (e.g. "... 2nd
                -- Season"), which is far less confusing next to a
                -- part-offset-corrected episode number than the generic,
                -- season-less anitopy title would be.
                cb({
                    shiki_id = tonumber(best.id),
                    mal_id = tonumber(best.malId),
                    episode = resolved_episode or p.episode,
                    title = best.name,
                }, nil)
            end)
    end)
end

-- cb(result, err)
local function fetch_skip_times(mal_id, episode, episode_length, cb)
    local url = ANISKIP_API_URL .. "/" .. tostring(mal_id) .. "/" .. tostring(episode)
        .. "?types[]=op&types[]=ed"
    if episode_length and episode_length > 0 then
        url = url .. "&episodeLength=" .. string.format("%.0f", episode_length)
    end

    http_json("GET", url, nil, "response", function(data, err)
        if err then return cb(nil, "aniskip_unavailable") end
        if not data.found then
            return cb(nil, "aniskip_no_data")
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
        cb(result, nil)
    end)
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
-- AniSkip's GET response doesn't expose who submitted a timestamp
-- (submitterId is write-only, only accepted on POST) - so instead of
-- asking the server "is this mine", we keep our own local record of
-- skipIds we've submitted and check against that.
----------------------------------------------------------------------

local cached_submitted_ids = nil -- Lua set: {[skip_id] = true, ...}

local function load_submitted_ids()
    if cached_submitted_ids then return cached_submitted_ids end
    cached_submitted_ids = {}

    local f = io.open(SUBMITTED_IDS_PATH, "rb")
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
    table.sort(list)

    local dir = utils.split_path(SUBMITTED_IDS_PATH)
    ensure_dir_exists(dir)
    local out = io.open(SUBMITTED_IDS_PATH, "wb")
    if out then
        out:write(utils.format_json(list))
        out:close()
    else
        msg.warn("anime-skip: could not persist submitted id to " .. SUBMITTED_IDS_PATH)
    end
end

-- Recomputes state.op_is_own/ed_is_own from the current op/ed skip_ids.
-- Not cached in the per-file cache - recomputed every time so that files
-- revisited later still reflect submissions made since.
local function refresh_own_flags()
    state.op_is_own = is_own_submission(state.op_skip_id)
    state.ed_is_own = is_own_submission(state.ed_skip_id)
end

-- Failures that are never written to the per-file cache:
--  * "the service didn't answer right now" (a transient outage must not
--    get stuck in the cache forever);
--  * local problems (Python missing, filename not parsed) - those are
--    cheap to retry, and caching them could pin a bad result, e.g. when a
--    stream's real title hadn't arrived yet at the moment of the keypress.
local NOT_CACHED_ERROR_KINDS = {
    shikimori_unavailable = true,
    aniskip_unavailable = true,
    anitopy_failed = true,
    python_missing = true,
}

local function fail(title, season, episode, mal_id, shiki_id, err_kind)
    osd(format_diagnostic(title, season, episode, mal_id, err_kind), 5)
    state.resolved = true
    state.found = false
    state.title_guess = title
    state.season = season
    state.episode = episode
    state.mal_id = mal_id
    state.shiki_id = shiki_id
    state.err_kind = err_kind
    if not NOT_CACHED_ERROR_KINDS[err_kind] then
        persist_state()
    end
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

local send_menu -- forward declaration (defined in the menu section)

-- Resolves the current file in the background. on_done(found, from_cache)
-- is called
-- once it's finished - unless a different file was opened meanwhile, in
-- which case the result is silently discarded.
-- Returns false (and does nothing) if a lookup is already running.
local function resolve_current_anime(on_done)
    if state.resolving then return false end

    local filename = get_source_name()
    if not filename then
        osd("No file is currently playing", 3)
        on_done(false)
        return true
    end

    local cached = load_cache(filename)
    if cached then
        apply_cached(cached)
        on_done(state.found, true)
        return true
    end

    local gen = generation
    state.resolving = true

    local function current() return gen == generation end

    local function finish(found)
        state.resolving = false
        if menu_open then send_menu(false) end
        on_done(found)
    end

    osd("Looking up this episode...", 10)

    parse_filename(filename, function(p, parse_err)
        if not current() then return end
        if not p then
            fail(nil, nil, nil, nil, nil, parse_err or "anitopy_failed")
            return finish(false)
        end
        state.title_guess, state.season, state.episode = p.title, p.season, p.episode

        shikimori_resolve(p, function(r, resolve_err)
            if not current() then return end
            if not r then
                fail(p.title, p.season, p.episode, nil, nil, resolve_err)
                return finish(false)
            end
            state.episode = r.episode
            state.title_guess = r.title or p.title

            local episode_length = mp.get_property_number("duration")
            fetch_skip_times(r.mal_id, r.episode, episode_length, function(skip_times, skip_err)
                if not current() then return end
                if not skip_times then
                    fail(state.title_guess, p.season, r.episode, r.mal_id, r.shiki_id, skip_err)
                    return finish(false)
                end

                state.found = true
                state.resolved = true
                state.err_kind = nil
                state.mal_id = r.mal_id
                state.shiki_id = r.shiki_id
                state.op_start, state.op_end = skip_times.op_start, skip_times.op_end
                state.ed_start, state.ed_end = skip_times.ed_start, skip_times.ed_end
                state.op_skip_id, state.ed_skip_id = skip_times.op_skip_id, skip_times.ed_skip_id
                refresh_own_flags()
                persist_state()

                osd("Identified: " .. state.title_guess .. ", episode " .. tostring(r.episode), 3)
                finish(true)
            end)
        end)
    end)
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
    -- submitterId is likely validated as one too.
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

    local f = io.open(SUBMITTER_ID_PATH, "rb")
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
    ensure_dir_exists(dir)
    local out = io.open(SUBMITTER_ID_PATH, "wb")
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

-- Clears the A-B loop, but only if it's still exactly the one that was
-- just submitted (if you've already set a different loop, it's left alone).
local function clear_ab_loop_if(start_time, end_time)
    local a, b = get_ab_loop()
    if a and math.abs(a - start_time) < 0.01 and math.abs(b - end_time) < 0.01 then
        mp.set_property("ab-loop-a", "no")
        mp.set_property("ab-loop-b", "no")
    end
end

----------------------------------------------------------------------
-- AniSkip submit/vote requests
----------------------------------------------------------------------

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

-- Submits one op/ed segment. cb(true, skipId) on success, cb(false, reason)
-- otherwise. skip_type is "op" or "ed".
local function aniskip_submit(mal_id, episode, skip_type, start_time, end_time, episode_length, cb)
    local body = utils.format_json({
        skipType = skip_type,
        providerName = "anime-skip.lua",
        submitterId = get_submitter_id(),
        startTime = start_time,
        endTime = end_time,
        episodeLength = episode_length,
    })
    local url = ANISKIP_API_URL .. "/" .. tostring(mal_id) .. "/" .. tostring(episode)

    http_json("POST", url, body, "post_response", function(data, err)
        if not data then return cb(false, err) end
        if data.statusCode == 201 then
            return cb(true, data.skipId)
        end
        local path = dump_debug_response("submit_failed", utils.format_json(data))
        cb(false, (stringify_message(data.message) or ("status " .. tostring(data.statusCode)))
            .. " (see " .. path .. ")")
    end)
end

-- vote_type is "upvote" or "downvote". cb(ok, err)
local function aniskip_vote(skip_id, vote_type, cb)
    local body = utils.format_json({voteType = vote_type})
    local url = ANISKIP_API_URL .. "/vote/" .. tostring(skip_id)

    http_json("POST", url, body, "post_response", function(data, err)
        if not data then return cb(false, err) end
        if data.statusCode == 201 then
            return cb(true, nil)
        end
        local path = dump_debug_response("vote_failed", utils.format_json(data))
        cb(false, (stringify_message(data.message) or ("status " .. tostring(data.statusCode)))
            .. " (see " .. path .. ")")
    end)
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

-- Wraps `text` at word boundaries so no single line exceeds `width`
-- characters. uosc computes the menu's width from its widest line, so
-- this is how we keep a very long anime title from blowing the whole
-- menu out to an unreasonable size - relies on uosc 5.13.0's multi-line
-- menu label support (fixed in #1210).
local MENU_TITLE_WRAP_WIDTH = 60

local function wrap_text(text, width)
    local lines = {}
    local line = ""
    for word in text:gmatch("%S+") do
        if line == "" then
            line = word
        elseif #line + 1 + #word <= width then
            line = line .. " " .. word
        else
            table.insert(lines, line)
            line = word
        end
    end
    if line ~= "" then table.insert(lines, line) end
    return table.concat(lines, "\n")
end

-- The menu is built as separate groups (info, links, refresh, opening,
-- ending). uosc draws a separator line under an item that has
-- separator = true, so the last item of every group gets one - this keeps
-- the groups visually apart without empty filler rows.
local function build_menu_items()
    -- Informational / non-interactive row. uosc's Item.value is a required
    -- field even for display-only rows, so we point it at mpv's built-in
    -- "ignore" command (a real no-op) rather than leaving it unset.
    local function info(title, hint)
        return {title = title, hint = hint, value = "ignore", selectable = false, muted = true}
    end
    -- Bold, non-selectable heading of a group.
    local function heading(title, hint)
        return {title = title, hint = hint, value = "ignore", selectable = false, bold = true}
    end
    local function message(...)
        return {"script-message-to", SCRIPT_NAME, ...}
    end

    local groups = {}

    -- 1. Info: everything currently known/cached for this file.
    local info_group = {}
    if state.resolving then
        table.insert(info_group, info("Looking up this episode..."))
    elseif not state.resolved then
        table.insert(info_group, info("Not resolved yet"))
    else
        if state.title_guess then
            table.insert(info_group, {
                title = wrap_text(state.title_guess, MENU_TITLE_WRAP_WIDTH),
                value = "ignore", selectable = false, bold = true,
            })
        end
        local info_parts = {}
        if state.season then table.insert(info_parts, "Season " .. tostring(state.season)) end
        if state.episode then table.insert(info_parts, "Episode " .. tostring(state.episode)) end
        if #info_parts > 0 or state.mal_id then
            table.insert(info_group, info(table.concat(info_parts, ", "),
                state.mal_id and ("MAL ID " .. tostring(state.mal_id)) or nil))
        end
        if not state.found and state.err_kind then
            table.insert(info_group, info(ERROR_MESSAGES[state.err_kind] or state.err_kind))
        end
    end
    table.insert(groups, info_group)

    -- 2. Links
    local links = {}
    if state.shiki_id then
        table.insert(links, {
            title = "Open on Shikimori", icon = "open_in_new",
            value = open_url_command("https://shikimori.io/animes/" .. tostring(state.shiki_id)),
        })
    end
    if state.mal_id then
        table.insert(links, {
            title = "Open on MyAnimeList", icon = "open_in_new",
            value = open_url_command("https://myanimelist.net/anime/" .. tostring(state.mal_id)),
        })
    end
    table.insert(groups, links)

    local can_submit = {
        op = state.resolved and state.mal_id and not state.op_start,
        ed = state.resolved and state.mal_id and not state.ed_start,
    }

    -- 3. Refresh: re-query AniSkip only (mal_id and episode are already
    -- known) - lets you pick up timestamps someone else just submitted
    -- without waiting for a new mpv session. Only useful while something
    -- is still missing.
    if can_submit.op or can_submit.ed then
        table.insert(groups, {{
            title = "Refresh from AniSkip", icon = "refresh",
            value = message("anime-skip-refresh"),
        }})
    end

    -- 4./5. Opening and Ending: one group each, with the timestamp as the
    -- heading and the matching actions below it.
    --  * AniSkip has data   -> vote buttons (or your vote / "submitted by you")
    --  * AniSkip has none   -> stage the A-B loop, then submit it
    if state.resolved and state.mal_id then
        local a, b = get_ab_loop()
        local loop_hint = (a and b) and (fmt_time(a) .. " - " .. fmt_time(b)) or "no A-B loop (press 'l' twice)"

        for _, kind in ipairs({"op", "ed"}) do
            local label = kind == "op" and "Opening" or "Ending"
            local group = {}
            local s_start, s_end = state[kind .. "_start"], state[kind .. "_end"]

            if s_start then
                table.insert(group, heading(label, fmt_time(s_start) .. " - " .. fmt_time(s_end)))
                if state[kind .. "_skip_id"] then
                    if state[kind .. "_is_own"] then
                        table.insert(group, info("Submitted by you"))
                    elseif state[kind .. "_voted"] then
                        table.insert(group, info("You rated it "
                            .. (state[kind .. "_voted"] == "upvote" and "correct" or "wrong")))
                    else
                        table.insert(group, {
                            title = "Timestamp is correct", icon = "thumb_up",
                            value = message("anime-skip-vote", kind, "upvote"),
                        })
                        table.insert(group, {
                            title = "Timestamp is wrong", icon = "thumb_down",
                            value = message("anime-skip-vote", kind, "downvote"),
                        })
                    end
                end
            elseif can_submit[kind] then
                table.insert(group, heading(label, "no data"))
                table.insert(group, {
                    title = "Use current A-B loop", hint = loop_hint,
                    value = message("anime-skip-stage", kind),
                    keep_open = true,
                })
                local p_start = state.pending[kind .. "_start"]
                if p_start then
                    table.insert(group, {
                        title = "Submit " .. label:lower(), icon = "check",
                        hint = fmt_time(p_start) .. " - " .. fmt_time(state.pending[kind .. "_end"]),
                        value = message("anime-skip-submit", kind),
                    })
                end
            end
            table.insert(groups, group)
        end
    end

    -- Flatten, putting a separator under the last item of each group
    -- (except the very last group). The info block (always the first
    -- group) gets an empty spacer row before its separator instead, so
    -- the information part sits a bit further away from the buttons.
    local nonempty = {}
    for _, g in ipairs(groups) do
        if #g > 0 then table.insert(nonempty, g) end
    end
    local items = {}
    for gi, g in ipairs(nonempty) do
        for ii, item in ipairs(g) do
            table.insert(items, item)
            if ii == #g and gi < #nonempty then
                if g == info_group then
                    table.insert(items, {title = "", value = "ignore",
                        selectable = false, separator = true})
                else
                    item.separator = true
                end
            end
        end
    end
    return items
end

send_menu = function(is_open)
    local menu = {
        type = UOSC_MENU_TYPE,
        title = "anime-skip",
        keep_open = true,
        -- no search box: nothing to search here, and this way uosc doesn't
        -- grab letter keys for typing (so the menu key can close it again)
        search_style = "disabled",
        -- lets us know when the menu is closed, so background lookups only
        -- refresh it while it's actually on screen
        on_close = "script-message-to " .. SCRIPT_NAME .. " anime-skip-menu-closed",
        items = build_menu_items(),
    }
    local json = utils.format_json(menu)
    if is_open then
        menu_open = true
        mp.commandv("script-message-to", "uosc", "open-menu", json)
    else
        mp.commandv("script-message-to", "uosc", "update-menu", json)
    end
end

mp.register_script_message("anime-skip-menu-closed", function()
    menu_open = false
end)

-- Shared guard for network actions started from the menu. Returns the
-- generation to check against when the request finishes, or nil if
-- another request is still running.
local function begin_request()
    if busy then
        osd("Please wait - the previous request is still running", 2)
        return nil
    end
    busy = true
    return generation
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
    local start_time = state.pending[kind .. "_start"]
    local end_time = state.pending[kind .. "_end"]
    if not start_time then
        osd("Nothing staged to submit", 3)
        return
    end

    local gen = begin_request()
    if not gen then return end
    local label = kind == "op" and "Opening" or "Ending"
    osd("Submitting " .. label:lower() .. "...", 10)

    local episode_length = mp.get_property_number("duration")
    aniskip_submit(state.mal_id, state.episode, kind, start_time, end_time, episode_length,
        function(ok, result)
            if gen ~= generation then return end
            busy = false
            if ok then
                -- We already know exactly what we just submitted - update
                -- state directly instead of re-querying AniSkip.
                state[kind .. "_start"], state[kind .. "_end"], state[kind .. "_skip_id"] = start_time, end_time, result
                state[kind .. "_is_own"] = true
                mark_submitted(result)
                state.pending[kind .. "_start"] = nil
                state.pending[kind .. "_end"] = nil
                state.found = true
                state.err_kind = nil
                persist_state()
                clear_ab_loop_if(start_time, end_time)
                osd(label .. " submitted successfully, thank you!", 3)
            else
                osd(label .. " submit failed: " .. tostring(result), 5)
            end
            -- refresh in place: this segment's submit controls disappear, vote controls appear
            if menu_open then send_menu(false) end
        end)
end)

mp.register_script_message("anime-skip-vote", function(kind, vote_type)
    local skip_id = (kind == "op") and state.op_skip_id or state.ed_skip_id
    if not skip_id then return end
    local is_own = (kind == "op") and state.op_is_own or state.ed_is_own
    if is_own then return end -- can't vote on your own submission

    local gen = begin_request()
    if not gen then return end

    aniskip_vote(skip_id, vote_type, function(ok, err)
        if gen ~= generation then return end
        busy = false
        if ok then
            if kind == "op" then state.op_voted = vote_type else state.ed_voted = vote_type end
            persist_state()
            osd("Vote submitted, thanks!", 2)
        else
            osd("Vote failed: " .. tostring(err), 3)
        end
        -- refresh in place: shows the rated status instead of the buttons
        if menu_open then send_menu(false) end
    end)
end)

-- Re-queries AniSkip for the already-known mal_id/episode - no need to
-- re-parse the filename or re-search Shikimori, neither has changed.
-- Useful when AniSkip had no data a moment ago but someone may have
-- submitted timestamps since.
mp.register_script_message("anime-skip-refresh", function()
    if not state.mal_id or not state.episode then return end

    local gen = begin_request()
    if not gen then return end
    osd("Checking AniSkip...", 10)

    local episode_length = mp.get_property_number("duration")
    fetch_skip_times(state.mal_id, state.episode, episode_length, function(skip_times, skip_err)
        if gen ~= generation then return end
        busy = false
        if not skip_times then
            state.err_kind = skip_err
            if not NOT_CACHED_ERROR_KINDS[skip_err] then
                persist_state()
            end
            osd(format_diagnostic(state.title_guess, state.season, state.episode, state.mal_id, skip_err), 5)
            if menu_open then send_menu(false) end
            return
        end

        if skip_times.op_start then
            state.op_start, state.op_end, state.op_skip_id = skip_times.op_start, skip_times.op_end, skip_times.op_skip_id
        end
        if skip_times.ed_start then
            state.ed_start, state.ed_end, state.ed_skip_id = skip_times.ed_start, skip_times.ed_end, skip_times.ed_skip_id
        end
        refresh_own_flags()
        state.found = true
        state.err_kind = nil
        persist_state()
        osd("Refreshed - AniSkip now has data for this episode", 3)
        if menu_open then send_menu(false) end
    end)
end)

-- No default key binding (nil) — bind via input.conf, e.g.:
--   F2 script-binding anime-skip-menu
-- The same key opens and closes the menu.
-- Pressing the same key again closes the menu.
mp.add_key_binding(nil, "anime-skip-menu", function()
    if menu_open then
        menu_open = false
        mp.commandv("script-message-to", "uosc", "close-menu", UOSC_MENU_TYPE)
        return
    end
    if not state.resolved and not state.resolving then
        -- runs in the background; the open menu updates itself when done
        resolve_current_anime(function() end)
    end
    send_menu(true)
end)

----------------------------------------------------------------------
-- Keybinding entry point
----------------------------------------------------------------------

local function skip_if_inside()
    local pos = mp.get_property_number("time-pos")
    if not pos then
        osd("Playback position unavailable", 3)
        return
    end

    -- AniSkip timestamps are often a second or two late, so the key also
    -- works slightly BEFORE the recorded start.
    local tol = math.max(0, tonumber(opts.skip_tolerance) or 0)

    if state.op_start and state.op_end and pos >= state.op_start - tol and pos < state.op_end then
        mp.set_property_number("time-pos", state.op_end)
        osd("Skipped opening", 2)
        return
    end

    if state.ed_start and state.ed_end and pos >= state.ed_start - tol and pos < state.ed_end then
        mp.set_property_number("time-pos", state.ed_end)
        osd("Skipped ending", 2)
        return
    end

    osd("Not currently in an opening or ending", 3)
end

local function do_skip()
    if state.resolving then
        osd("Still looking up this episode...", 2)
        return
    end
    if not state.resolved then
        -- Look up in the background, then skip if we're (still) inside an
        -- opening/ending. Failure messages are shown by the lookup itself.
        resolve_current_anime(function(found, from_cache)
            if found then
                skip_if_inside()
            elseif from_cache then
                -- a fresh lookup shows its own failure message; a cached
                -- "not found" needs one too
                osd(format_diagnostic(state.title_guess, state.season, state.episode,
                    state.mal_id, state.err_kind), 5)
            end
        end)
        return
    end
    if not state.found then
        osd(format_diagnostic(state.title_guess, state.season, state.episode, state.mal_id, state.err_kind), 5)
        return
    end
    skip_if_inside()
end

-- No default key binding (nil) — bind via input.conf, e.g.:
--   F1 script-binding anime-skip
mp.add_key_binding(nil, "anime-skip", do_skip)

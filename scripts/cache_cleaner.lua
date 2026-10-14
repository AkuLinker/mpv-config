-- cache_cleaner.lua
-- Deletes old files from configured cache folders on player shutdown.
-- Runs at most once per day (configurable). File scanning and deletion use
-- only native mpv/Lua APIs. The only external process ever started is a
-- one-time "mkdir" when a needed folder does not exist yet.
--
-- Works on Linux, macOS and Windows.
--
-- When verbose=yes, also writes a per-session log file to the log_dir folder
-- and auto-deletes old log files from that folder.
--
-- Folders to clean are defined in the "dirs" option as a semicolon-separated
-- list of "path:days" pairs, e.g.:
--   dirs=cache/watch_later:90;cache/shaders_cache:30;cache/other:14

local mp    = require "mp"
local utils = require "mp.utils"
local opts  = require "mp.options"
local msg   = require "mp.msg"

-- ============================================================
--  OPTIONS  (override in script-opts/cache_cleaner.conf)
-- ============================================================
local options = {
    -- Semicolon-separated list of "path:days" pairs (path relative to mpv config dir).
    -- Files older than "days" days will be deleted. days=0 disables that folder.
    -- Example: cache/watch_later:90;cache/shaders_cache:30
    dirs = "cache/watch_later:90;cache/shaders_cache:30",

    -- Minimum interval between cleanup runs, in hours
    check_interval_hours = 24,

    -- Marker file that stores the Unix timestamp of the last run
    last_run_file = "cache/cache_cleaner_last_run",

    -- Enable detailed logging to mpv log and a per-session log file (yes/no)
    -- When no: only a brief summary (if anything was deleted) goes to the mpv log
    verbose = false,

    -- Folder for per-session log files (relative to mpv config directory)
    log_dir = "cache/cache_cleaner_logs",

    -- How many days to keep log files (0 = keep forever)
    log_keep_days = 30,
}

opts.read_options(options, "cache_cleaner")

local platform = mp.get_property_native("platform")
    or (package.config:sub(1, 1) == "\\" and "windows" or "linux")
local is_windows = platform == "windows"

-- ============================================================
--  HELPERS
-- ============================================================
-- Expand ~~/<rel> to an absolute path inside the mpv config directory.
local function cfg(rel)
    return mp.command_native({"expand-path", "~~/" .. rel})
end

local function dir_exists(path)
    local info = utils.file_info(path)
    return info ~= nil and info.is_dir
end

-- Creates a directory (including parents) if it doesn't exist yet.
-- Does nothing - and starts no process - when it already exists, which is
-- the normal case after the very first run.
local function ensure_dir(path)
    if not path or path == "" or dir_exists(path) then return true end

    local args
    if is_windows then
        -- cmd's mkdir creates intermediate folders too, but needs backslashes
        args = {"cmd", "/d", "/c", "mkdir", (path:gsub("/", "\\"))}
    else
        args = {"mkdir", "-p", path}
    end

    -- subprocess runs without a shell and without a console window on Windows
    mp.command_native({
        name = "subprocess",
        args = args,
        playback_only = false,
        capture_stdout = false,
        capture_stderr = false,
    })

    if dir_exists(path) then return true end
    msg.warn(("cache_cleaner: could not create folder '%s'"):format(path))
    return false
end

-- ============================================================
--  SESSION LOG
-- ============================================================
local log_file = nil      -- io file handle, opened lazily on first write
local log_path = nil      -- absolute path of this session's log file

local function open_log_file()
    if log_file then return true end

    local dir = cfg(options.log_dir)
    if not ensure_dir(dir) then return false end

    local ts = os.date("%Y-%m-%d_%H-%M-%S")
    log_path = utils.join_path(dir, ts .. ".log")
    log_file = io.open(log_path, "w")
    if not log_file then
        msg.warn("cache_cleaner: cannot open log file: " .. log_path)
        return false
    end
    return true
end

-- Write a formatted line to the session log file (the file must already be open).
local function write_to_log(line)
    if log_file then
        log_file:write(os.date("[%H:%M:%S] ") .. line .. "\n")
    end
end

-- Write a line to both mpv log and the session log file (when verbose).
local function log(fmt, ...)
    local line = fmt:format(...)
    msg.info(line)
    if options.verbose and open_log_file() then
        write_to_log(line)
    end
end

-- Write only when verbose=yes.
local function dbg(fmt, ...)
    if not options.verbose then return end
    log(fmt, ...)
end

local function close_log()
    if log_file then
        log_file:close()
        log_file = nil
    end
end

-- ============================================================
--  PARSE DIRS OPTION
-- ============================================================
-- Returns a list of {path, days} tables from the "dirs" string.
local function parse_dirs(dirs_str)
    local result = {}
    for entry in (dirs_str .. ";"):gmatch("([^;]+);") do
        local path, days = entry:match("^%s*(.-):(%d+)%s*$")
        if path and path ~= "" and days then
            result[#result + 1] = {
                path = path,
                days = tonumber(days),
            }
        else
            msg.warn("cache_cleaner: invalid dirs entry, expected 'path:days' - got: " .. entry)
        end
    end
    return result
end

-- ============================================================
--  INTERVAL CHECK
-- ============================================================
local function should_run()
    local marker = cfg(options.last_run_file)
    local f = io.open(marker, "r")
    if f then
        local ts = tonumber(f:read("*l") or "0") or 0
        f:close()
        local hours_passed = (os.time() - ts) / 3600
        if hours_passed < options.check_interval_hours then
            -- Use msg.info directly to avoid open_log_file() being triggered
            if options.verbose then
                msg.info(("cache_cleaner: skipping - only %.1f h passed (threshold: %d h)")
                    :format(hours_passed, options.check_interval_hours))
            end
            return false
        end
    end
    return true
end

local function save_last_run_time()
    local marker = cfg(options.last_run_file)
    local dir    = utils.split_path(marker)
    ensure_dir(dir)
    local f = io.open(marker, "w")
    if f then
        f:write(tostring(os.time()) .. "\n")
        f:close()
    end
end

-- ============================================================
--  CLEANUP  - pure Lua, no external processes
-- ============================================================
local function clean_dir(dir_path, max_days)
    if max_days <= 0 then
        dbg("cache_cleaner: skipping '%s' (days=0)", dir_path)
        return 0
    end

    local cutoff = os.time() - max_days * 86400
    local entries = utils.readdir(dir_path, "files")
    if not entries then
        dbg("cache_cleaner: '%s' - folder does not exist or is empty", dir_path)
        return 0
    end

    local deleted = 0
    for _, name in ipairs(entries) do
        local full = utils.join_path(dir_path, name)
        local info = utils.file_info(full)
        -- info.mtime is integer Unix seconds per the mpv Lua API docs
        if info and info.mtime and info.mtime < cutoff then
            local ok, err = os.remove(full)
            if ok then
                deleted = deleted + 1
                dbg("cache_cleaner: deleted '%s'", name)
            else
                msg.warn(("cache_cleaner: failed to delete '%s': %s"):format(full, tostring(err)))
            end
        end
    end
    return deleted
end

-- ============================================================
--  LOG ROTATION
-- ============================================================
local function clean_old_logs()
    if options.log_keep_days <= 0 then return end

    local dir     = cfg(options.log_dir)
    local cutoff  = os.time() - options.log_keep_days * 86400
    local entries = utils.readdir(dir, "files")
    if not entries then return end

    local removed = 0
    for _, name in ipairs(entries) do
        -- Skip the log file we are currently writing to
        local full = utils.join_path(dir, name)
        if full ~= log_path then
            local info = utils.file_info(full)
            if info and info.mtime and info.mtime < cutoff then
                if os.remove(full) then
                    removed = removed + 1
                    dbg("cache_cleaner: removed old log: %s", name)
                end
            end
        end
    end
    if removed > 0 then
        dbg("cache_cleaner: removed %d old log file(s)", removed)
    end
end

-- ============================================================
--  MAIN - called on player shutdown
-- ============================================================
local function run_cleanup()
    -- If the interval hasn't passed, only log to mpv (no log file created)
    if not should_run() then return end

    -- Open the log file only when cleanup actually runs
    if options.verbose then
        open_log_file()
        log("cache_cleaner: session started - %s", os.date("%Y-%m-%d %H:%M:%S"))
    end

    local folders = parse_dirs(options.dirs)
    if #folders == 0 then
        dbg("cache_cleaner: no folders configured, nothing to do")
        close_log()
        return
    end

    local total = 0
    for _, entry in ipairs(folders) do
        local abs_path = cfg(entry.path)
        dbg("cache_cleaner: checking '%s' (max %d days)", entry.path, entry.days)
        total = total + clean_dir(abs_path, entry.days)
    end

    save_last_run_time()

    if total > 0 then
        log("cache_cleaner: deleted %d file(s) total", total)
    else
        dbg("cache_cleaner: nothing to delete")
    end

    if options.verbose then
        clean_old_logs()
        log("cache_cleaner: done")
    end
    close_log()
end

-- Register on shutdown so cleanup runs after playback is fully done,
-- and mpv waits for this function to return before it actually exits.
mp.register_event("shutdown", run_cleanup)

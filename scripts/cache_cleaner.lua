-- cache_cleaner.lua
-- Deletes old files from cache/watch_later and cache/shaders_cache on player shutdown.
-- Runs at most once per day (configurable). Uses only native mpv Lua APIs —
-- no external processes, so mpv shutdown is not delayed.
--
-- When verbose=yes, also writes a per-session log file to cache/cache_cleaner_logs/
-- and auto-deletes old log files from that folder.

local mp    = require "mp"
local utils = require("mp.utils")
local opts  = require("mp.options")
local msg   = require("mp.msg")

-- ============================================================
--  OPTIONS  (override in script-opts/cache_cleaner.conf)
-- ============================================================
local options = {
    -- Maximum age in days before a file is deleted (0 = disabled for that folder)
    watch_later_days   = 90,
    shaders_cache_days = 30,

    -- Minimum interval between cleanup runs, in hours
    check_interval_hours = 24,

    -- Paths relative to the mpv config directory (~~/)
    watch_later_dir   = "cache/watch_later",
    shaders_cache_dir = "cache/shaders_cache",

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

-- ============================================================
--  SESSION LOG
-- ============================================================
local log_file = nil      -- io file handle, opened lazily on first write
local log_path = nil      -- absolute path of this session's log file

local function open_log_file()
    if log_file then return true end

    local dir = mp.command_native({"expand-path", "~~/" .. options.log_dir})

    -- Create the log directory (pure-Lua fallback not possible, but this is
    -- a one-time mkdir at shutdown — instant and safe)
    local sep = package.config:sub(1, 1)
    if sep == "\\" then
        os.execute(string.format('md "%s" 2>nul', dir))
    else
        os.execute(string.format('mkdir -p "%s" 2>/dev/null', dir))
    end

    local ts   = os.date("%Y-%m-%d_%H-%M-%S")
    log_path   = utils.join_path(dir, ts .. ".log")
    log_file   = io.open(log_path, "w")
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

-- Write only to mpv log regardless of verbose setting.
local function log_always(fmt, ...)
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

-- ============================================================
--  HELPERS
-- ============================================================
-- Expand ~~/<rel> to an absolute path inside the mpv config directory.
local function cfg(rel)
    return mp.command_native({"expand-path", "~~/" .. rel})
end

local function ensure_dir(path)
    local sep = package.config:sub(1, 1)
    if sep == "\\" then
        os.execute(string.format('md "%s" 2>nul', path))
    else
        os.execute(string.format('mkdir -p "%s" 2>/dev/null', path))
    end
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
            dbg("cache_cleaner: skipping — only %.1f h passed (threshold: %d h)",
                hours_passed, options.check_interval_hours)
            return false
        end
    end
    return true
end

local function save_last_run_time()
    local marker = cfg(options.last_run_file)
    local dir    = utils.split_path(marker)
    if dir and dir ~= "" then ensure_dir(dir) end
    local f = io.open(marker, "w")
    if f then
        f:write(tostring(os.time()) .. "\n")
        f:close()
    end
end

-- ============================================================
--  CLEANUP  — pure Lua, no external processes
-- ============================================================
local function clean_dir(dir_path, max_days, label)
    if max_days <= 0 then
        dbg("cache_cleaner: skipping %s (max_days=0)", label)
        return 0
    end

    local cutoff = os.time() - max_days * 86400
    local entries = utils.readdir(dir_path, "files")
    if not entries then
        dbg("cache_cleaner: %s — folder does not exist or is empty", label)
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
                dbg("cache_cleaner: deleted [%s] %s", label, name)
            else
                msg.warn("cache_cleaner: failed to delete '%s': %s", full, tostring(err))
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
--  MAIN — called on player shutdown
-- ============================================================
local function run_cleanup()
    local cleanup_needed = should_run()

    -- Open the log file first if verbose, so we can log even the "skipping" case
    if options.verbose then
        open_log_file()
        log("cache_cleaner: session started — %s", os.date("%Y-%m-%d %H:%M:%S"))
    end

    if not cleanup_needed then
        if options.verbose then
            -- Still rotate old logs even when main cleanup is skipped
            clean_old_logs()
            if log_file then log_file:close() end
        end
        return
    end

    dbg("cache_cleaner: running cleanup")
    local total = 0

    total = total + clean_dir(cfg(options.watch_later_dir),   options.watch_later_days,   "watch_later")
    total = total + clean_dir(cfg(options.shaders_cache_dir), options.shaders_cache_days,  "shaders_cache")

    save_last_run_time()

    if total > 0 then
        log_always("cache_cleaner: deleted %d file(s) total", total)
    else
        dbg("cache_cleaner: nothing to delete")
    end

    if options.verbose then
        clean_old_logs()
        log("cache_cleaner: done")
        if log_file then log_file:close() end
    end
end

-- Register on shutdown so cleanup runs after playback is fully done,
-- and mpv waits for this function to return before it actually exits.
mp.register_event("shutdown", run_cleanup)

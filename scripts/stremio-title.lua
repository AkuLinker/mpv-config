-- stremio-title.lua
-- Sets a readable media-title for streams served by a Stremio streaming server.
--
-- Why: a Stremio stream URL looks like
--   https://host/<40-hex info hash>/<file index>?tr=...
-- and carries no file name, so mpv falls back to the tail of the URL
-- (tracker junk, or just "0"). Files without an embedded Title tag then
-- end up with a useless media-title. The server knows the real file name
-- (see <stream url>/stats.json), so we ask it and use that instead.
--
-- Does nothing unless ALL of these hold:
--   * the path looks like a Stremio stream URL (.../<40-hex hash>/<index>)
--   * the file has no embedded Title tag
--   * nobody has already forced a title (mpv.conf, another script)

local mp    = require "mp"
local utils = require "mp.utils"
local msg = require "mp.msg"

-- True only while force-media-title holds a value that WE set.
local title_set_by_us = false

-- Matches ".../<40-hex hash>/<file index>" (query string ignored).
-- Returns the URL without the query string and the zero-based file index.
local function parse_stream_url(url)
    local base = url:match("^(https?://[^?]+)")
    if not base then return nil end
    local hash, idx = base:match("/(%x+)/(%d+)$")
    if not hash or #hash ~= 40 then return nil end
    return base, tonumber(idx)
end

-- True if the container carries its own non-empty Title tag.
local function has_title_tag()
    local meta = mp.get_property_native("metadata") or {}
    for key, value in pairs(meta) do
        if key:lower() == "title" and value ~= "" then
            return true
        end
    end
    return false
end

-- force-media-title is a global option and would otherwise stay set for the
-- next file in the playlist. Undo our override as soon as a new file starts.
mp.register_event("start-file", function()
    if title_set_by_us then
        mp.set_property("force-media-title", "")
        title_set_by_us = false
    end
end)

mp.register_event("file-loaded", function()
    local path = mp.get_property("path", "")
    local base, idx = parse_stream_url(path)
    if not base then return end
    if has_title_tag() then return end
    if mp.get_property("force-media-title", "") ~= "" then return end

    -- Async so playback never waits on this request.
    mp.command_native_async({
        name = "subprocess",
        args = {"curl", "-s", "--max-time", "5", base .. "/stats.json"},
        capture_stdout = true,
    }, function(success, res)
        -- Ignore a late answer if another file has been opened meanwhile.
        if mp.get_property("path", "") ~= path then return end

        -- Never log the URL: it contains the secret path.
        if not success or not res or res.status ~= 0 then
            msg.warn("stats request failed")
            return
        end

        local data = utils.parse_json(res.stdout)
        if type(data) ~= "table" then
            msg.warn("stats response is not valid JSON")
            return
        end

        -- Prefer the per-file name (multi-file torrents), fall back to the torrent name.
        local name
        local entry = type(data.files) == "table" and data.files[idx + 1]
        if type(entry) == "table" then
            name = entry.name
        end
        name = name or data.name

        if type(name) == "string" and name ~= "" then
            mp.set_property("force-media-title", name)
            title_set_by_us = true
            msg.info("media-title set to: " .. name)
        end
    end)
end)

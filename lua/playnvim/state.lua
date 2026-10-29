local config = require("playnvim.config")

local M = {}

local playlist = {}
local current_index = 1

local is_loaded = false
local playlist_version = 0

function M.load()
  is_loaded = true
  playlist_version = playlist_version + 1
  if config.opts.playlist then
    playlist = vim.deepcopy(config.opts.playlist)
    return
  end
  playlist = vim.deepcopy(config.defaults.playlist)
end

function M.get_playlist_version()
  return playlist_version
end

function M.get_playlist()
  if not is_loaded then
    M.load()
  end
  return playlist
end

function M.get_current_index()
  return current_index
end

function M.set_current_index(idx)
  local count = #M.get_playlist()
  if count == 0 then
    current_index = 1
    return
  end
  current_index = math.max(1, math.min(idx, count))
end

function M.get_current_track()
  local list = M.get_playlist()
  return (#list > 0) and list[current_index] or nil
end

function M.next_track()
  local list = M.get_playlist()
  local count = #list
  if count == 0 then
    return nil
  end
  current_index = (current_index % count) + 1
  return list[current_index]
end

function M.prev_track()
  local list = M.get_playlist()
  local count = #list
  if count == 0 then
    return nil
  end
  current_index = ((current_index - 2 + count) % count) + 1
  return list[current_index]
end

return M

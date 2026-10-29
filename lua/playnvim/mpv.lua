local config = require("playnvim.config")
local state = require("playnvim.state")

local M = {}

local uv = vim.uv or vim.loop
local sock_path = "/tmp/playnvim_" .. uv.getpid() .. ".sock"

local mpv_handle = nil
local mpv_pid = nil
local pipe = nil
local is_connecting = false
local request_id = 0
local callbacks = {}

-- Playback state
local playback = {
  status = "stopped", -- "stopped", "playing", "paused", "buffering"
  time_pos = 0,
  duration = 0,
  percent = 0,
  volume = config.defaults.volume or 30,
  title = "",
  short_title = "Áudio",
  url = "",
}

local function make_short_title(title)
  if not title or title == "" then
    return "Áudio"
  end
  local num_chars = vim.fn.strchars(title)
  if num_chars > 25 then
    local byte_len = vim.str_byteindex(title, 24)
    return title:sub(1, byte_len) .. "…"
  end
  return title
end

local poll_timer = nil
local tick_listeners = {}

local function next_req_id()
  request_id = request_id + 1
  return request_id
end

local function clean_socket_file()
  pcall(uv.fs_unlink, sock_path)
end

local time_cache = {}
local time_cache_count = 0
local function format_time(seconds)
  if not seconds or seconds < 0 or seconds ~= seconds then
    return "00:00"
  end
  local sec = math.floor(seconds)
  local cached = time_cache[sec]
  if cached then
    return cached
  end
  local h = math.floor(sec / 3600)
  local m = math.floor((sec % 3600) / 60)
  local s = sec % 60
  local res
  if h > 0 then
    res = string.format("%02d:%02d:%02d", h, m, s)
  else
    res = string.format("%02d:%02d", m, s)
  end
  if time_cache_count > 1024 then
    time_cache = {}
    time_cache_count = 0
  end
  time_cache[sec] = res
  time_cache_count = time_cache_count + 1
  return res
end

local notify_scheduled = false
local function notify_listeners()
  if notify_scheduled then
    return
  end
  notify_scheduled = true
  vim.schedule(function()
    notify_scheduled = false
    for cb in pairs(tick_listeners) do
      pcall(cb, playback)
    end
  end)
end

local function send_cmd(cmd_table, cb)
  if not pipe or pipe:is_closing() then
    if cb then
      cb(false, "Pipe not connected")
    end
    return
  end

  local msg
  if cb then
    local id = next_req_id()
    callbacks[id] = cb
    msg = { command = cmd_table, request_id = id }
  else
    msg = { command = cmd_table }
  end

  local encoded = vim.json.encode(msg) .. "\n"
  pipe:write(encoded, function(err)
    if err and msg.request_id and callbacks[msg.request_id] then
      callbacks[msg.request_id](false, err)
      callbacks[msg.request_id] = nil
    end
  end)
end

local EVENT_HANDLERS = {
  ["start-file"] = function(_)
    if playback.status ~= "paused" then
      playback.status = "buffering"
    end
    notify_listeners()
  end,
  ["playback-restart"] = function(_)
    if playback.status ~= "paused" then
      playback.status = "playing"
      M.start_polling()
    end
    notify_listeners()
  end,
  ["file-loaded"] = function(_)
    if playback.status == "buffering" then
      playback.status = "playing"
      M.start_polling()
    end
    notify_listeners()
  end,
  ["pause"] = function(_)
    playback.status = "paused"
    M.stop_polling()
    notify_listeners()
  end,
  ["unpause"] = function(_)
    playback.status = "playing"
    M.start_polling()
    notify_listeners()
  end,
  ["end-file"] = function(json)
    M.stop_polling()
    if json.reason == "eof" and config.opts.auto_next then
      vim.schedule(function()
        M.next()
      end)
    elseif json.reason == "error" then
      playback.status = "stopped"
      playback.time_pos = 0
      vim.schedule(function()
        local track_name = playback.title ~= "" and playback.title or playback.url
        vim.notify("PlayNvim: Falha ao carregar áudio de: " .. tostring(track_name), vim.log.levels.WARN)
        notify_listeners()
      end)
    else
      playback.status = "stopped"
      playback.time_pos = 0
      notify_listeners()
    end
  end,
}

local function handle_ipc_message(line)
  if not line or line == "" then
    return
  end
  local ok, json = pcall(vim.json.decode, line)
  if not ok or not json then
    return
  end

  -- Response to a command
  if json.request_id and callbacks[json.request_id] then
    local cb = callbacks[json.request_id]
    callbacks[json.request_id] = nil
    cb(json.error == "success", json.data)
  end

  -- Events from mpv (O(1) table dispatch)
  if json.event then
    if json.event == "property-change" then
      if json.name == "pause" then
        if playback.status ~= "stopped" then
          if json.data == true then
            playback.status = "paused"
            M.stop_polling()
          elseif json.data == false then
            playback.status = "playing"
            M.start_polling()
          end
          notify_listeners()
        end
      elseif json.name == "paused-for-cache" then
        if playback.status ~= "stopped" and playback.status ~= "paused" then
          if json.data == true then
            playback.status = "buffering"
          elseif json.data == false and playback.status == "buffering" then
            playback.status = "playing"
          end
          notify_listeners()
        end
      end
    else
      local handler = EVENT_HANDLERS[json.event]
      if handler then
        handler(json)
      end
    end
  end
end

local is_starting = false
local pending_start_cbs = {}
local check_timer = nil

local function fire_start_callbacks(ok, err)
  is_starting = false
  local cbs = pending_start_cbs
  pending_start_cbs = {}
  vim.schedule(function()
    for i = 1, #cbs do
      cbs[i](ok, err)
    end
  end)
end

local function connect_pipe()
  if pipe and not pipe:is_closing() then
    fire_start_callbacks(true)
    return
  end

  pipe = uv.new_pipe(false)
  local buffer = ""

  pipe:connect(sock_path, function(err)
    if err then
      if pipe and not pipe:is_closing() then
        pipe:close()
      end
      pipe = nil
      fire_start_callbacks(false, err)
      return
    end

    pipe:read_start(function(rerr, chunk)
      if chunk then
        buffer = buffer .. chunk
        while true do
          local nl = buffer:find("\n")
          if not nl then
            break
          end
          local line = buffer:sub(1, nl - 1)
          buffer = buffer:sub(nl + 1)
          vim.schedule(function()
            handle_ipc_message(line)
          end)
        end
      else
        -- Pipe closed (EOF) or error
        if pipe and not pipe:is_closing() then
          pipe:close()
        end
        pipe = nil
      end
    end)

    send_cmd({ "observe_property", 1, "pause" })
    send_cmd({ "observe_property", 2, "paused-for-cache" })
    fire_start_callbacks(true)
  end)
end

local function detect_cookies_arg(user_setting)
  if user_setting == false or user_setting == "none" then
    return nil
  end

  local home = vim.fn.expand("~")

  if type(user_setting) == "string" and user_setting ~= "auto" then
    if uv.fs_stat(user_setting) then
      return "--ytdl-raw-options-append=cookies=" .. user_setting
    elseif user_setting:find("/") then
      return "--ytdl-raw-options-append=cookies=" .. user_setting
    else
      return "--ytdl-raw-options-append=cookies-from-browser=" .. user_setting
    end
  end

  local cookie_files = {
    home .. "/.config/playnvim/cookies.txt",
    home .. "/.config/mpv/cookies.txt",
  }
  for _, path in ipairs(cookie_files) do
    if uv.fs_stat(path) then
      return "--ytdl-raw-options-append=cookies=" .. path
    end
  end

  local browser_checks = {
    {
      cookie = home .. "/.var/app/com.brave.Browser/config/BraveSoftware/Brave-Browser/Default/Cookies",
      arg = "--ytdl-raw-options-append=cookies-from-browser=brave:" .. home .. "/.var/app/com.brave.Browser/config/BraveSoftware/Brave-Browser",
    },
    {
      cookie = home .. "/.config/BraveSoftware/Brave-Browser/Default/Cookies",
      arg = "--ytdl-raw-options-append=cookies-from-browser=brave",
    },
    {
      cookie = home .. "/.config/google-chrome/Default/Cookies",
      arg = "--ytdl-raw-options-append=cookies-from-browser=chrome",
    },
    {
      cookie = home .. "/.var/app/com.google.Chrome/config/google-chrome/Default/Cookies",
      arg = "--ytdl-raw-options-append=cookies-from-browser=chrome:" .. home .. "/.var/app/com.google.Chrome/config/google-chrome",
    },
    {
      cookie = home .. "/.mozilla/firefox",
      arg = "--ytdl-raw-options-append=cookies-from-browser=firefox",
    },
  }
  for _, item in ipairs(browser_checks) do
    if uv.fs_stat(item.cookie) then
      return item.arg
    end
  end

  return nil
end

function M.ensure_running(callback)
  if mpv_handle and pipe and not pipe:is_closing() then
    if callback then
      callback(true)
    end
    return
  end

  if callback then
    table.insert(pending_start_cbs, callback)
  end

  if is_starting then
    return
  end
  is_starting = true

  clean_socket_file()

  local args = {
    "--idle",
    "--input-ipc-server=" .. sock_path,
    "--volume=" .. tostring(playback.volume or config.opts.volume or 30),
  }

  local custom_args = config.opts.mpv_args or config.defaults.mpv_args
  for _, a in ipairs(custom_args) do
    table.insert(args, a)
  end

  local has_cookies = false
  for _, a in ipairs(custom_args) do
    if a:find("cookies") then
      has_cookies = true
      break
    end
  end
  if not has_cookies then
    local cookie_arg = detect_cookies_arg(config.opts.cookies or config.defaults.cookies)
    if cookie_arg then
      table.insert(args, cookie_arg)
    end
  end

  mpv_handle, mpv_pid = uv.spawn("mpv", {
    args = args,
    stdio = { nil, nil, nil },
  }, function(code, signal)
    mpv_handle = nil
    mpv_pid = nil
    is_starting = false
    callbacks = {}
    if pipe and not pipe:is_closing() then
      pipe:close()
    end
    pipe = nil
    clean_socket_file()
    playback.status = "stopped"
    vim.schedule(notify_listeners)
  end)

  if not mpv_handle then
    fire_start_callbacks(false, "Failed to spawn mpv process")
    return
  end

  -- Wait for socket to become available
  local retries = 0
  if check_timer and not check_timer:is_closing() then
    check_timer:stop()
    check_timer:close()
  end
  check_timer = uv.new_timer()
  check_timer:start(50, 50, function()
    retries = retries + 1
    if uv.fs_stat(sock_path) then
      check_timer:stop()
      if not check_timer:is_closing() then
        check_timer:close()
      end
      check_timer = nil
      connect_pipe()
    elseif retries >= 40 then
      check_timer:stop()
      if not check_timer:is_closing() then
        check_timer:close()
      end
      check_timer = nil
      fire_start_callbacks(false, "Timeout waiting for mpv socket")
    end
  end)
end

local duration_queries = 0

local function poll_status()
  if not pipe or pipe:is_closing() or playback.status == "stopped" then
    return
  end

  send_cmd({ "get_property", "time-pos" }, function(ok, val)
    if ok and type(val) == "number" then
      playback.time_pos = val
      if playback.status == "buffering" and val > 0 then
        playback.status = "playing"
      end
      if playback.duration > 0 then
        playback.percent = math.min(100, math.max(0, (val / playback.duration) * 100))
      end
      notify_listeners()
    end
  end)

  if playback.duration <= 0 then
    duration_queries = duration_queries + 1
    -- Query duration on first 10 polls, then only once every 25 polls (~10s) to avoid live stream IPC spam
    if duration_queries <= 10 or (duration_queries % 25 == 0) then
      send_cmd({ "get_property", "duration" }, function(ok, val)
        if ok and type(val) == "number" and val > 0 then
          playback.duration = val
          if playback.time_pos > 0 then
            playback.percent = math.min(100, math.max(0, (playback.time_pos / val) * 100))
          end
          notify_listeners()
        end
      end)
    end
  end

  if playback.title == "" or playback.title == playback.url then
    send_cmd({ "get_property", "media-title" }, function(ok, val)
      if ok and type(val) == "string" and #val > 0 then
        playback.title = val
        playback.short_title = make_short_title(val)
        notify_listeners()
      end
    end)
  end
end

function M.start_polling()
  if poll_timer then
    return
  end
  poll_timer = uv.new_timer()
  poll_timer:start(400, 400, vim.schedule_wrap(poll_status))
end

function M.stop_polling()
  if poll_timer then
    poll_timer:stop()
    if not poll_timer:is_closing() then
      poll_timer:close()
    end
    poll_timer = nil
  end
end

function M.play(track)
  track = track or state.get_current_track()
  if not track or not track.url then
    return
  end

  duration_queries = 0
  playback.status = "buffering"
  playback.time_pos = 0
  playback.duration = 0
  playback.percent = 0
  playback.title = track.title or track.url
  playback.short_title = make_short_title(playback.title)
  playback.url = track.url
  notify_listeners()

  M.ensure_running(function(ok, err)
    if not ok then
      playback.status = "stopped"
      vim.schedule(function()
        vim.notify("PlayNvim: Erro ao iniciar mpv: " .. tostring(err), vim.log.levels.ERROR)
        notify_listeners()
      end)
      return
    end

    send_cmd({ "loadfile", track.url, "replace" }, function(load_ok)
      if load_ok then
        if playback.status ~= "paused" then
          playback.status = "buffering"
        end
        M.start_polling()
      else
        playback.status = "stopped"
      end
      vim.schedule(notify_listeners)
    end)
  end)
end

function M.pause()
  if playback.status == "stopped" then
    return
  end
  playback.status = "paused"
  M.stop_polling()
  send_cmd({ "set_property", "pause", true })
  notify_listeners()
end

function M.resume()
  if playback.status == "stopped" then
    local cur = state.get_current_track()
    if cur then
      M.play(cur)
    end
    return
  end
  playback.status = "playing"
  M.start_polling()
  send_cmd({ "set_property", "pause", false })
  notify_listeners()
end

function M.toggle_pause()
  if playback.status == "stopped" then
    local cur = state.get_current_track()
    if cur then
      M.play(cur)
    end
    return
  end

  if playback.status == "paused" then
    M.resume()
  else
    M.pause()
  end
end

function M.stop()
  M.stop_polling()
  playback.status = "stopped"
  playback.time_pos = 0
  playback.percent = 0
  send_cmd({ "stop" })
  notify_listeners()
end

function M.next()
  local next_t = state.next_track()
  if next_t then
    M.play(next_t)
  else
    M.stop()
  end
end

function M.prev()
  local prev_t = state.prev_track()
  if prev_t then
    M.play(prev_t)
  else
    M.stop()
  end
end

function M.seek(delta)
  if playback.status == "stopped" then
    return
  end
  send_cmd({ "seek", delta, "relative" }, function()
    poll_status()
  end)
end

function M.set_volume(vol)
  vol = math.min(100, math.max(0, math.floor(vol)))
  playback.volume = vol
  send_cmd({ "set_property", "volume", vol }, function()
    notify_listeners()
  end)
end

function M.volume_up(step)
  step = step or 5
  M.set_volume((playback.volume or 30) + step)
end

function M.volume_down(step)
  step = step or 5
  M.set_volume((playback.volume or 30) - step)
end

local playback_info = {
  status = "stopped",
  time_pos = 0,
  formatted_time = "00:00",
  duration = 0,
  formatted_duration = "00:00",
  percent = 0,
  volume = 30,
  title = "",
  short_title = "Áudio",
  url = "",
}

function M.get_playback_info()
  playback_info.status = playback.status
  playback_info.time_pos = playback.time_pos
  playback_info.formatted_time = format_time(playback.time_pos)
  playback_info.duration = playback.duration
  playback_info.formatted_duration = format_time(playback.duration)
  playback_info.percent = playback.percent
  playback_info.volume = playback.volume
  playback_info.title = playback.title
  playback_info.short_title = playback.short_title
  playback_info.url = playback.url
  return playback_info
end

function M.add_tick_listener(cb)
  if cb then
    tick_listeners[cb] = true
  end
end

function M.remove_tick_listener(cb)
  if cb then
    tick_listeners[cb] = nil
  end
end

function M.quit()
  M.stop_polling()
  if check_timer then
    check_timer:stop()
    if not check_timer:is_closing() then
      check_timer:close()
    end
    check_timer = nil
  end
  callbacks = {}
  if mpv_handle then
    pcall(send_cmd, { "quit" })
    if mpv_pid then
      pcall(uv.kill, mpv_pid, 15)
    end
    mpv_handle = nil
    mpv_pid = nil
  end
  if pipe and not pipe:is_closing() then
    pipe:close()
    pipe = nil
  end
  clean_socket_file()
  playback.status = "stopped"
  notify_listeners()
end

-- Auto cleanup when Neovim exits
vim.api.nvim_create_autocmd("VimLeavePre", {
  callback = function()
    M.quit()
  end,
})

return M

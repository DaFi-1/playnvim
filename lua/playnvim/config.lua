local M = {}

M.defaults = {
  keymap = false,      -- tecla global opcional para alternar o player (ex: "<space>a"). false para desativar
  volume = 30,
  layout = "embedded", -- "classic" (padrão antigo), "external" (janela externa), "embedded" (embutido no player)
  width = 76,
  height = 18,
  border = "rounded",
  auto_next = true,
  thumbnail = true,
  thumb_width = 30,
  cookies = "auto", -- "auto" (detecta Brave/Chrome/Firefox/cookies.txt), arquivo de cookies, ou false para desativar
  mpv_args = {
    "--no-video",
    "--ytdl-format=bestaudio/best",
  },
  playlist = {
    {
      playlist = "LOFI",
      title = "Final Fantasy VII ~ lofi hip hop mix (1 hour) Rebirth",
      url = "https://www.youtube.com/watch?v=_PEQhKUDRNU",
    },
    {
      playlist = "LOFI",
      title = "Chrono Trigger OST mix",
      url = "https://www.youtube.com/watch?v=QKrG7nw5cak",
    },
    {
      playlist = "LOFI",
      title = "Mozart Música Clássica para Estudar e Memorizar",
      url = "https://www.youtube.com/watch?v=jIFaKHyYEh8",
    },
    {
      playlist = "SYNTHWAVE",
      title = "Synthwave Radio - chill synth / retro beats",
      url = "https://www.youtube.com/watch?v=4xDzrJKXOOY",
    },
  },
}

M.opts = {}

function M.setup(opts)
  opts = opts or {}
  if opts.default_playlist and not opts.playlist then
    opts.playlist = opts.default_playlist
  end
  M.opts = vim.tbl_deep_extend("force", M.defaults, opts)
end

M.setup()

return M

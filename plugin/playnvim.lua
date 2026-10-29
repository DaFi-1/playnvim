if vim.g.loaded_playnvim then
  return
end
vim.g.loaded_playnvim = 1

local play = require("playnvim")

-- Comandos principais: PlayNvim / Play
vim.api.nvim_create_user_command("PlayNvim", function()
  play.open()
end, { desc = "Abrir interface centralizada do PlayNvim" })

vim.api.nvim_create_user_command("Play", function()
  play.open()
end, { desc = "Abrir interface centralizada do PlayNvim" })

vim.api.nvim_create_user_command("PlayToggle", function()
  play.toggle()
end, { desc = "Alternar interface do PlayNvim" })

vim.api.nvim_create_user_command("PlayResume", function()
  play.play()
end, { desc = "Retomar reprodução no PlayNvim" })

vim.api.nvim_create_user_command("PlayPause", function()
  play.toggle_pause()
end, { desc = "Pausar/retomar reprodução no PlayNvim" })

vim.api.nvim_create_user_command("PlayStop", function()
  play.stop()
end, { desc = "Parar reprodução no PlayNvim" })

vim.api.nvim_create_user_command("PlayNext", function()
  play.next()
end, { desc = "Próxima música no PlayNvim" })

vim.api.nvim_create_user_command("PlayPrev", function()
  play.prev()
end, { desc = "Música anterior no PlayNvim" })

local function handle_volume(opts)
  local vol = tonumber(opts.args)
  if vol then
    play.set_volume(vol)
  end
end

local function handle_layout(opts)
  if opts.args and opts.args ~= "" then
    play.set_layout(opts.args)
  else
    play.cycle_layout()
  end
end

local function complete_layout()
  return { "classic", "external", "embedded" }
end

local layout_opts = {
  nargs = "?",
  complete = complete_layout,
  desc = "Alternar layout do PlayNvim (classic, external, embedded)",
}

vim.api.nvim_create_user_command("PlayVolume", handle_volume, { nargs = 1, desc = "Definir volume no PlayNvim (0 a 100)" })
vim.api.nvim_create_user_command("PlayLayout", handle_layout, layout_opts)
vim.api.nvim_create_user_command("PlayNvimLayout", handle_layout, layout_opts)

-- Aliases retrocompatíveis: Music*
vim.api.nvim_create_user_command("MusicNvim", function() play.open() end, { desc = "Alias para PlayNvim" })
vim.api.nvim_create_user_command("Music", function() play.open() end, { desc = "Alias para Play" })
vim.api.nvim_create_user_command("MusicToggle", function() play.toggle() end, { desc = "Alias para PlayToggle" })
vim.api.nvim_create_user_command("MusicPause", function() play.toggle_pause() end, { desc = "Alias para PlayPause" })
vim.api.nvim_create_user_command("MusicStop", function() play.stop() end, { desc = "Alias para PlayStop" })
vim.api.nvim_create_user_command("MusicNext", function() play.next() end, { desc = "Alias para PlayNext" })
vim.api.nvim_create_user_command("MusicPrev", function() play.prev() end, { desc = "Alias para PlayPrev" })
vim.api.nvim_create_user_command("MusicVolume", handle_volume, { nargs = 1, desc = "Alias para PlayVolume" })
vim.api.nvim_create_user_command("MusicLayout", handle_layout, vim.tbl_extend("force", layout_opts, { desc = "Alias para PlayLayout" }))

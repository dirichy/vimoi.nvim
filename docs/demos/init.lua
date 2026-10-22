-- Isolated recording setup: no personal Neovim config, dotfiles, or chezmoi state.
vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.g.mapleader = " "
vim.opt.swapfile = false
vim.opt.backup = false
vim.opt.writebackup = false
vim.opt.shadafile = "NONE"
vim.opt.termguicolors = true
vim.opt.number = true
vim.opt.relativenumber = false
vim.opt.signcolumn = "no"
vim.opt.laststatus = 3
vim.opt.showmode = false
vim.opt.showcmd = false
vim.opt.shortmess:append("I")
vim.opt.fillchars = { eob = " " }
vim.opt.scrolloff = 3
vim.opt.wrap = false
vim.cmd.colorscheme("habamax")
vim.api.nvim_set_hl(0, "Normal", { bg = "#1e2030", fg = "#c8d3f5" })
vim.api.nvim_set_hl(0, "NormalNC", { bg = "#1e2030", fg = "#c8d3f5" })
vim.api.nvim_set_hl(0, "WinSeparator", { bg = "#1e2030", fg = "#545c7e" })
vim.api.nvim_set_hl(0, "DemoLabel", { bg = "#2d3f76", fg = "#d5e3ff", bold = true })
vim.api.nvim_set_hl(0, "StatusLine", { bg = "#2f334d", fg = "#c8d3f5" })
vim.opt.winbar =
  "%#DemoLabel# %{expand('%:t') == 'dot_app.yaml.tmpl' ? ' SOURCE / app.yaml.tmpl ' : (&readonly ? ' RENDERED / read only ' : ' TARGET / app.yaml ')}%*"
local readd = vim.env.VIMOI_DEMO == "readd"
vim.opt.statusline = " vimoi.nvim   /   " .. (readd and "TEMPLATE DIFF + RE-ADD" or "LIVE PREVIEW") .. " %= %m  %l:%c "

local root = vim.fn.tempname()
local source_root, target_root = root .. "/source", root .. "/target"
vim.fn.mkdir(source_root, "p")
vim.fn.mkdir(target_root, "p")
local config = root .. "/chezmoi.toml"
vim.fn.writefile({
  "sourceDir = " .. vim.json.encode(source_root),
  "destDir = " .. vim.json.encode(target_root),
  "[data]",
  'name = "workstation"',
  'servers = ["alpha", "beta"]',
}, config)
local wrapper = root .. "/chezmoi"
vim.fn.writefile({
  "#!/bin/sh",
  "exec " .. vim.fn.shellescape(vim.fn.exepath("chezmoi")) .. " --persistent-state " .. vim.fn.shellescape(
    root .. "/state.boltdb"
  ) .. ' "$@"',
}, wrapper)
assert(vim.uv.fs_chmod(wrapper, 493))
local source = source_root .. "/dot_app.yaml.tmpl"
vim.fn.writefile(vim.fn.readfile("docs/demos/app.yaml.tmpl"), source)
if readd then
  local target = target_root .. "/.app.yaml"
  local rendered = vim.system({ wrapper, "--config", config, "cat", target }, { text = true }):wait()
  assert(rendered.code == 0, rendered.stderr)
  local changed = rendered.stdout:gsub('"workstation"', '"laptop"'):gsub("notifications: true", "notifications: false")
  vim.fn.writefile(vim.split(changed, "\n", { plain = true }), target, "b")
end
require("vimoi").setup({ chezmoi_executable = wrapper, chezmoi_config_path = config })
vim.cmd.edit(vim.fn.fnameescape(source))
vim.api.nvim_create_autocmd("VimLeavePre", {
  once = true,
  callback = function()
    vim.fn.delete(root, "rf")
  end,
})

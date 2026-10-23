-- Isolated recording setup: no personal Neovim config, dotfiles, or chezmoi state.
vim.opt.runtimepath:prepend(vim.fn.getcwd())
local root = vim.fn.tempname()
vim.cmd("filetype plugin indent on")
vim.cmd("syntax enable")
vim.g.mapleader = " "
vim.opt.swapfile = false
vim.opt.backup = false
vim.opt.writebackup = false
vim.opt.shadafile = "NONE"
vim.opt.termguicolors = true
vim.opt.number = true
vim.opt.relativenumber = false
vim.opt.cursorline = true
vim.opt.hlsearch = false
vim.opt.signcolumn = "no"
vim.opt.laststatus = 3
vim.opt.showmode = false
vim.opt.showcmd = false
vim.opt.shortmess:append("I")
vim.opt.fillchars = { eob = " " }
vim.opt.scrolloff = 3
vim.opt.wrap = false
local theme = vim.env.VIMOI_DEMO_TOKYONIGHT or vim.fn.stdpath("data") .. "/lazy/tokyonight.nvim"
if vim.fn.isdirectory(theme) == 1 then
  vim.opt.runtimepath:prepend(theme)
end
require("tokyonight").setup({ style = "storm" })
vim.cmd.colorscheme("tokyonight-storm")
local screenkey = vim.env.VIMOI_DEMO_SCREENKEY or vim.fn.stdpath("data") .. "/lazy/screenkey.nvim"
if vim.fn.isdirectory(screenkey) == 1 then
  vim.opt.runtimepath:prepend(screenkey)
end
vim.api.nvim_create_autocmd("VimEnter", {
  once = true,
  callback = function()
    require("screenkey").setup({
      clear_after = 3,
      log = { filepath = root .. "/screenkey.log" },
      keys = { ["<CR>"] = "Enter", ["<TAB>"] = "Tab", ["<BS>"] = "BS" },
    })
    require("screenkey").toggle_statusline_component()
    vim.opt.showtabline = 2
    vim.opt.tabline = "%#Title# KEYS  %{v:lua.require'screenkey'.get_keys()}"
    vim.api.nvim_create_autocmd("User", {
      pattern = { "ScreenkeyUpdated", "ScreenkeyCleared" },
      callback = function()
        vim.cmd.redrawtabline()
      end,
    })
  end,
})
vim.api.nvim_create_autocmd("FileType", {
  pattern = "yaml",
  callback = function(args)
    vim.treesitter.start(args.buf, "yaml")
  end,
})
vim.api.nvim_set_hl(0, "DemoLabel", { link = "TabLineSel" })
vim.opt.winbar =
  "%#DemoLabel# %{&filetype == 'gotmpl' ? ' SOURCE / app.yaml.tmpl ' : (&readonly ? ' RENDERED / read only ' : ' TARGET / app.yaml ')}%*"
local demo = vim.env.VIMOI_DEMO or "preview"
local titles = {
  preview = "LIVE PREVIEW / RENDERED HIGHLIGHTING",
  diff = "DIFF / SYNC SCROLL / HUNK TRANSFER / CHOICE",
  readd = "RE-ADD / STATIC CHANGES",
}
vim.opt.statusline = " vimoi.nvim   /   " .. assert(titles[demo], "unknown demo: " .. demo) .. " %= %m  %l:%c "

local source_root, target_root = root .. "/source", root .. "/target"
vim.fn.mkdir(source_root, "p")
vim.fn.mkdir(target_root, "p")
vim.api.nvim_create_autocmd("VimLeavePre", {
  once = true,
  callback = function()
    vim.fn.delete(root, "rf")
  end,
})
local config = root .. "/chezmoi.toml"
vim.fn.writefile({
  "sourceDir = " .. vim.json.encode(source_root),
  "destDir = " .. vim.json.encode(target_root),
  "[data]",
  'name = "workstation"',
  "servers = " .. vim.json.encode(demo == "diff" and vim.tbl_map(function(index)
    return ("node-%02d"):format(index)
  end, vim.fn.range(1, 24)) or { "alpha", "beta" }),
}, config)
local wrapper = root .. "/chezmoi"
vim.fn.writefile({
  "#!/bin/sh",
  "exec " .. vim.fn.shellescape(vim.fn.exepath("chezmoi")) .. " --persistent-state " .. vim.fn.shellescape(
    root .. "/state.boltdb"
  ) .. ' "$@"',
}, wrapper)
assert(vim.uv.fs_chmod(wrapper, 493))
local source = source_root .. "/app.yaml.tmpl"
local fixture = demo == "diff" and "diff.yaml.tmpl" or "app.yaml.tmpl"
vim.fn.writefile(vim.fn.readfile("docs/demos/" .. fixture), source)
if demo ~= "preview" then
  local target = target_root .. "/app.yaml"
  local rendered = vim.system({ wrapper, "--config", config, "cat", target }, { text = true }):wait()
  assert(rendered.code == 0, rendered.stderr)
  local changed
  if demo == "diff" then
    changed =
      rendered.stdout:gsub("theme: light", "theme: dark"):gsub("  sync: true\n", "  sync: true\n  search: true\n")
  else
    changed = rendered.stdout:gsub('"workstation"', '"laptop"'):gsub("notifications: true", "notifications: false")
  end
  vim.fn.writefile(vim.split(changed, "\n", { plain = true }), target, "b")
end
require("vimoi").setup({
  chezmoi_executable = wrapper,
  chezmoi_config_path = config,
  diagnostics = { host = false },
  highlight = { mode = "rendered" },
})
vim.cmd.edit(vim.fn.fnameescape(source))

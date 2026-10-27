-- Isolated recording setup: no personal Neovim config, dotfiles, or chezmoi state.
vim.opt.runtimepath:prepend(vim.fn.getcwd())
local root = vim.fn.tempname()
local demo = vim.env.VIMOI_DEMO or "preview"
local deps = {
  blink = "blink.cmp",
  lint = "nvim-lint",
  matchup = "vim-matchup",
  picker = "snacks.nvim",
}
for key, directory in pairs(deps) do
  local path = vim.env["VIMOI_DEMO_" .. key:upper()] or vim.fn.stdpath("data") .. "/lazy/" .. directory
  if
    (key == "blink" and demo == "completion")
    or (key == "lint" and demo == "diagnostics")
    or (key == "matchup" and demo == "navigation")
    or (key == "picker" and demo == "diff")
  then
    assert(vim.fn.isdirectory(path) == 1, "missing demo dependency: " .. path)
    vim.opt.runtimepath:prepend(path)
  end
end
if demo == "navigation" then
  vim.g.matchup_treesitter_enabled = true
  vim.g.matchup_matchparen_offscreen = { method = "status_manual" }
end
if demo == "diff" then
  require("snacks").setup({ picker = { enabled = true, ui_select = true } })
  require("snacks.picker").setup()
end
vim.cmd("filetype plugin indent on")
vim.cmd("syntax enable")
vim.g.mapleader = " "
vim.opt.hidden = true
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
require("tokyonight").setup({ style = "night" })
vim.cmd.colorscheme("tokyonight-night")
local screenkey = vim.env.VIMOI_DEMO_SCREENKEY or vim.fn.stdpath("data") .. "/lazy/screenkey.nvim"
if vim.fn.isdirectory(screenkey) == 1 then
  vim.opt.runtimepath:prepend(screenkey)
end
vim.api.nvim_create_autocmd("VimEnter", {
  once = true,
  callback = function()
    require("screenkey").setup({
      clear_after = 1,
      log = { filepath = root .. "/screenkey.log" },
      keys = { ["<CR>"] = "Enter", ["<TAB>"] = "Tab", ["<BS>"] = "BS" },
    })
    require("screenkey").toggle_statusline_component()
    vim.opt.showtabline = 2
    vim.opt.tabline = "%#Comment# Keys  %#Normal#%{v:lua.require'screenkey'.get_keys()}"
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
vim.api.nvim_set_hl(0, "DemoLabel", { link = "WinBar" })
vim.opt.winbar = "%#DemoLabel# %{&filetype} / %t %{&readonly ? '[read only]' : ''}%*"
local titles = {
  preview = "Live preview",
  diff = "Template diff",
  readd = "Static write-back",
  completion = "Completion",
  diagnostics = "Template / host diagnostics",
  highlighting = "Host highlighting",
  dependencies = "Dependency refresh",
  navigation = "Source / target, gf / gF and %",
  plain = "Plain files: native diff and write-back",
  buffers = "Unnamed buffers / horizontal diff",
  cancel = "Cancel slow work and keep editing",
  injection = "Injection highlighting / both branches",
  disabled = "Template highlighting / host colors disabled",
}
vim.g.vimoi_demo_stage = ""
vim.opt.statusline = " vimoi.nvim / %{g:vimoi_demo_stage == '' ? "
  .. vim.fn.string((assert(titles[demo], "unknown demo: " .. demo)))
  .. " : g:vimoi_demo_stage} %= %m %l:%c "

local observed = { diagnostics = {}, completion_menus = 0, host_lines = {}, scroll = {}, visits = {}, matches = {} }
-- Observe real UI events; verify.lua reads the accumulated evidence after playback.
vim.api.nvim_create_autocmd("DiagnosticChanged", {
  callback = function(args)
    for _, diagnostic in ipairs(args.data.diagnostics) do
      observed.diagnostics[diagnostic.message] = true
      if diagnostic.message:find("[host:lua]", 1, true) then
        observed.host_lines[diagnostic.lnum] = true
      end
    end
  end,
})
vim.api.nvim_create_autocmd("User", {
  pattern = "BlinkCmpMenuOpen",
  callback = function()
    observed.completion_menus = observed.completion_menus + 1
  end,
})
vim.api.nvim_create_autocmd("WinScrolled", {
  callback = function()
    if vim.g.vimoi_demo_stage == "" then
      return
    end
    local views = package.loaded["vimoi.compare"]
    local view = views and views.current()
    if not view or view.loading or not view.map then
      return
    end
    local active = vim.api.nvim_get_current_win()
    local side = active == view.source_win and "source" or "output"
    local peer = side == "source" and view.target_win or view.source_win
    local position = vim.api.nvim_win_call(peer, vim.fn.winsaveview)
    local previous = observed.scroll[side]
    observed.scroll[side] = {
      topline = position.topline,
      moved = previous and (previous.moved or previous.topline ~= position.topline) or false,
    }
  end,
})
vim.api.nvim_create_autocmd({ "BufEnter", "CursorMoved" }, {
  callback = function(args)
    local name = vim.api.nvim_buf_get_name(args.buf)
    observed.visits[name] = true
    if demo == "navigation" and vim.g.vimoi_demo_stage == "Match template blocks with %" then
      observed.matches[vim.api.nvim_win_get_cursor(0)[1]] = true
    end
  end,
})
-- g: tables are copied by the API; retain the live observations for verification.
_G.vimoi_demo_observed = observed
---@type { cancelled: boolean }?
_G.vimoi_demo_cancel_job = nil
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
  "servers = "
    .. vim.json.encode((demo == "diff" or demo == "preview" or demo == "readd") and vim.tbl_map(function(index)
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
local fixture = { config = config, source_root = source_root, target_root = target_root }

local template_fixture = demo == "diff" and "diff.yaml.tmpl" or "app.yaml.tmpl"
vim.fn.writefile(vim.fn.readfile("docs/demos/" .. template_fixture), source)
if demo == "diff" or demo == "readd" then
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
if demo == "completion" then
  vim.fn.mkdir(source_root .. "/.chezmoitemplates", "p")
  vim.fn.writefile({ "theme: shared" }, source_root .. "/.chezmoitemplates/settings.yaml")
  vim.fn.writefile({
    "# Complete data, functions, locals, paths and blocks",
    '{{ $greeting := "hello" }}',
    "name: {{ .name }}",
    "quoted: {{ quote .name }}",
    "local: {{ $greeting }}",
    '{{ template "settings.yaml" . }}',
    "",
  }, source)
  require("blink.cmp").setup({
    fuzzy = { implementation = "lua", frecency = { enabled = false } },
    keymap = { preset = "default" },
    completion = {
      documentation = { auto_show = true, auto_show_delay_ms = 0 },
      accept = { auto_brackets = { enabled = false } },
    },
    sources = {
      default = { "vimoi" },
      providers = { vimoi = { name = "Vimoi", module = "vimoi.blink" } },
    },
    cmdline = { enabled = false },
    signature = { enabled = false },
  })
elseif demo == "diagnostics" then
  source = source_root .. "/app.lua.tmpl"
  vim.fn.writefile({
    "-- Template and rendered-Lua diagnostics",
    "local name = {{ .name | quote }}",
    'local count = {{ "1" }}',
    "print(name, count)",
  }, source)
  require("lint").linters_by_ft = { lua = { "luac" } }
  vim.diagnostic.config({ virtual_text = true, signs = false, update_in_insert = false })
elseif demo == "navigation" then
  vim.fn.mkdir(source_root .. "/.chezmoitemplates", "p")
  vim.fn.writefile(
    { "# Shared settings", "theme: shared", "enabled: true" },
    source_root .. "/.chezmoitemplates/settings.yaml"
  )
  vim.fn.writefile({ "# Notes", "one", "two", "three", "four" }, source_root .. "/notes.txt")
  vim.fn.writefile({ "# Notes", "one", "two", "three", "four" }, target_root .. "/notes.txt")
  vim.fn.writefile({
    "# Follow shared templates with gf",
    '{{ template "settings.yaml" . }}',
    "",
    "# Follow source includes with gf",
    '{{ include "notes.txt" }}',
    "",
    "# Follow a managed destination and line with gF",
    "# " .. target_root .. "/notes.txt:4",
    "",
    "{{ if true }}",
    "enabled: true",
    "{{ else }}",
    "enabled: false",
    "{{ end }}",
  }, source)
  vim.fn.writefile({ "# Deployed settings", "theme: deployed" }, target_root .. "/app.yaml")
elseif demo == "plain" then
  source = source_root .. "/dot_zshrc"
  vim.fn.writefile({ "# Plain source: detected as zsh", "export EDITOR=nvim", "export PAGER=less" }, source)
  vim.fn.writefile(
    { "# Plain source: detected as zsh", "export EDITOR=vim", "export PAGER=more" },
    target_root .. "/.zshrc"
  )
elseif demo == "cancel" then
  -- The tape adds a real slow function after the normal disk baseline is ready.
  vim.fn.writefile({ "# Cancel a slow template function", "theme: light" }, source)
elseif demo == "dependencies" then
  vim.fn.mkdir(source_root .. "/.chezmoitemplates", "p")
  vim.fn.writefile({ "theme: light" }, source_root .. "/.chezmoitemplates/settings.yaml")
  vim.fn.writefile({ "name: {{ .name | quote }}", '{{ template "settings.yaml" . }}' }, source)
end
fixture.source = source
require("vimoi").setup({
  chezmoi_executable = wrapper,
  chezmoi_config_path = config,
  split = demo == "buffers" and "horizontal" or "vertical",
  diagnostics = { host = demo == "diagnostics", enabled = demo ~= "cancel" },
  highlight = {
    mode = (demo == "injection" or demo == "disabled") and demo or "rendered",
    template_bg = demo == "highlighting" and "Visual" or "NormalFloat",
  },
})
if demo == "buffers" then
  fixture.source_buf = vim.api.nvim_create_buf(true, true)
  fixture.target_buf = vim.api.nvim_create_buf(true, true)
  vim.api.nvim_buf_set_lines(fixture.source_buf, 0, -1, false, { "name: {{ .name | quote }}", "theme: light" })
  vim.api.nvim_buf_set_lines(fixture.target_buf, 0, -1, false, { 'name: "workstation"', "theme: dark" })
  vim.api.nvim_set_current_buf(fixture.source_buf)
else
  vim.cmd.edit(vim.fn.fnameescape(source))
end

vim.g.vimoi_demo = fixture

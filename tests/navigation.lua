vim.opt.swapfile = false
vim.opt.hidden = true
vim.cmd("filetype plugin on")
local fixture = vim.fn.getcwd() .. "/tests/fixtures/environment"
local root = vim.fn.tempname() .. " navigation"
local source_root, target_root = root .. "/source", root .. "/target"
vim.fn.mkdir(source_root .. "/private_dot_config", "p")
vim.fn.mkdir(source_root .. "/.chezmoitemplates", "p")
vim.fn.mkdir(target_root .. "/.config", "p")
local source = source_root .. "/private_dot_config/demo file.lua.tmpl"
local target = target_root .. "/.config/demo file.lua"
vim.fn.writefile({ "return {{ 1 }}" }, source)
vim.fn.writefile({ "return 2" }, target)
vim.env.VIMOI_TEST_CONFIG = fixture .. "/empty.toml"
vim.env.VIMOI_TEST_SOURCE = source_root
vim.env.VIMOI_TEST_DESTINATION = target_root
local api = require("vimoi.api")
require("vimoi").setup({ chezmoi_executable = fixture .. "/chezmoi-wrapper.sh", diagnostics = { enabled = false } })
assert(vim.fn.maparg("<leader>cs", "n") == "")
assert(vim.fn.maparg("<leader>ct", "n", false, true).desc == "Switch between chezmoi source and target")
assert(rawget(api, "source") == nil and rawget(api, "target") == nil)
assert(vim.fn.exists(":VimoiSource") == 0 and vim.fn.exists(":VimoiTarget") == 0)

assert(api.toggle(target) == source)
local source_buf = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(source_buf, 0, -1, false, { "return {{ 3 }}" })
assert(api.toggle() == target)
assert(api.toggle() == source and vim.api.nvim_get_current_buf() == source_buf)
assert(vim.bo[source_buf].modified and vim.fn.readfile(source)[1] == "return {{ 1 }}")
assert(vim.fn.readfile(target)[1] == "return 2", "navigation applied or saved a file")
assert(package.loaded["vimoi.gotmpl"] == nil, "navigation unnecessarily loaded the view module")

vim.cmd("VimoiToggle " .. vim.fn.fnameescape(source))
assert(vim.api.nvim_buf_get_name(0) == target)
vim.cmd("VimoiToggle " .. vim.fn.fnameescape(target))
assert(vim.api.nvim_buf_get_name(0) == source)
assert(#vim.api.nvim_tabpage_list_wins(0) == 1, "navigation opened a split")

-- Native modified-buffer protections remain in charge.
vim.opt.hidden = false
local ok, err = pcall(api.toggle)
assert(not ok and tostring(err):find("E37", 1, true))
assert(vim.api.nvim_get_current_buf() == source_buf and vim.bo[source_buf].modified)
vim.opt.hidden = true

-- A preview URI resolves through its owning source, never as a real file.
api.preview({ source = source })
local sessions = require("vimoi.gotmpl.view")
local session = assert(sessions.by_window[vim.api.nvim_get_current_win()])
assert(vim.wait(5000, function()
  return not session.loading
end))
vim.api.nvim_set_current_win(session.target_win)
assert(api.toggle() == source)
assert(session.closed and vim.fn.readfile(target)[1] == "return 2")
assert(vim.bo[source_buf].modified)
assert(api.toggle() == target)
assert(api.toggle() == source)

local notices = {}
local notify = vim.notify
vim.notify = function(message)
  notices[#notices + 1] = message
end
local before = vim.api.nvim_get_current_buf()
assert(api.toggle(root .. "/unmanaged") == nil)
assert(vim.api.nvim_get_current_buf() == before and #notices == 1)
local shared = source_root .. "/.chezmoitemplates/shared"
vim.fn.writefile({ "shared" }, shared)
assert(api.toggle(shared) == nil and vim.api.nvim_get_current_buf() == before)
vim.cmd("enew")
assert(api.toggle() == nil)
vim.cmd.edit(vim.fn.fnameescape(source))
api.preview({ source = source })
session = assert(sessions.by_window[vim.api.nvim_get_current_win()])
assert(vim.wait(5000, function()
  return not session.loading
end))
vim.api.nvim_buf_set_name(source_buf, root .. "/renamed.lua.tmpl")
before = vim.api.nvim_get_current_buf()
assert(api.toggle() == nil)
assert(not session.closed and vim.api.nvim_get_current_buf() == before, "failed navigation retired its view")
vim.notify = notify
print("navigation: commands, source-only files, preview ownership, unsaved edits and native protections verified")

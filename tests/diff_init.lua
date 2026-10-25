local view_for_buffer = dofile("tests/helpers/view.lua")
local root = vim.fn.getcwd()
local fixture = root .. "/tests/fixtures/init"
local source = fixture .. "/source/.chezmoi.toml.tmpl"
local target = fixture .. "/empty.toml"
local wrapper = root .. "/tests/fixtures/environment/chezmoi-wrapper.sh"
local original_system = vim.system
local config_path_queries = 0
---@diagnostic disable-next-line: duplicate-set-field -- Count config queries while using the real CLI.
vim.system = function(args, ...)
  if args[2] == "execute-template" and args[3] == "{{ .chezmoi.configFile }}" then
    config_path_queries = config_path_queries + 1
  end
  return original_system(args, ...)
end

vim.env.VIMOI_TEST_CONFIG = target
vim.env.VIMOI_TEST_SOURCE = fixture .. "/source"
vim.opt.swapfile = false
require("vimoi").setup({ chezmoi_executable = wrapper })

local cli = require("vimoi.core.cli")
-- Both directions must resolve independently, without a previous diff session.
assert(cli.counterpart_path(target) == source)
cli.invalidate()
assert(cli.counterpart_path(source) == target)
assert(cli.counterpart_path(target) == source)

-- Opening from the special source template resolves to .chezmoi.configFile
-- and renders with execute-template --init (promptChoiceOnce would otherwise fail).
vim.cmd("edit " .. vim.fn.fnameescape(source))
vim.cmd("VimoiDiff")
dofile("tests/helpers/diff.lua")()
local source_buf = vim.fn.bufnr(source)
local target_buf = vim.fn.bufnr(target)
assert(source_buf >= 0 and target_buf >= 0)
assert(assert(view_for_buffer(source_buf)).target_buf == target_buf)

local source_win
for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
  if vim.api.nvim_win_get_buf(win) == source_buf then
    source_win = win
  end
end
assert(source_win)
vim.api.nvim_win_close(source_win, true)

-- The config file also resolves back to the init template even though it is
-- not a normal managed target.
assert(vim.api.nvim_get_current_buf() == target_buf)
cli.invalidate()
vim.cmd("VimoiDiff")
dofile("tests/helpers/diff.lua")()
assert(assert(view_for_buffer(target_buf)).source_buf == source_buf)
assert(config_path_queries == 1, "invalidating the cache must retain the setup-time init mapping")
vim.system = original_system

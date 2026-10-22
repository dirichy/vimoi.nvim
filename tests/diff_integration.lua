local view_for_buffer = dofile("tests/helpers/view.lua")
local root = vim.fn.getcwd()
local fixture = root .. "/tests/fixtures/environment"
local destination = vim.env.VIMOI_TEST_DESTINATION
local target = destination .. "/.diff_target"
local source = fixture .. "/source/dot_diff_target.tmpl"

vim.env.VIMOI_TEST_CONFIG = fixture .. "/empty.toml"
vim.env.VIMOI_TEST_SOURCE = fixture .. "/source"
vim.env.VIMOI_TEST_DESTINATION = destination
require("vimoi").setup({
  chezmoi_executable = fixture .. "/chezmoi-wrapper.sh",
  keymaps = {
    diff_get = "gG",
    diff_put = false,
    fold_open = "zx",
  },
})

vim.opt.swapfile = false
vim.cmd("edit " .. vim.fn.fnameescape(target))
vim.api.nvim_buf_set_lines(0, 1, 2, false, { "timeout = 20" })
local target_buf = vim.api.nvim_get_current_buf()
vim.cmd("VimoiDiff")
dofile("tests/helpers/diff.lua")()

assert(#vim.api.nvim_list_wins() == 2)
local source_buf = vim.api.nvim_get_current_buf()
assert(vim.api.nvim_buf_get_name(source_buf) == source)
assert(vim.bo[source_buf].filetype == "gotmpl", vim.bo[source_buf].filetype)
assert(assert(view_for_buffer(source_buf)).target_buf == target_buf)
assert(assert(view_for_buffer(target_buf)).source_buf == source_buf)
local source_win = vim.api.nvim_get_current_win()
local target_win
for _, win in ipairs(vim.api.nvim_list_wins()) do
  if vim.api.nvim_win_get_buf(win) == target_buf then
    target_win = win
  end
end
assert(target_win)
assert(vim.wo[source_win].diff and vim.wo[target_win].diff)
assert(not vim.wo[source_win].scrollbind and not vim.wo[target_win].scrollbind)
assert(not vim.wo[source_win].cursorbind and not vim.wo[target_win].cursorbind)
assert(vim.wo[source_win].foldmethod == "diff")
assert(vim.wo[target_win].foldmethod == "diff")
vim.api.nvim_buf_call(source_buf, function()
  assert(vim.fn.maparg("gG", "n", false, true).desc == "Get chezmoi target hunk into source template")
  assert(vim.fn.maparg("zx", "n", false, true).desc == "Synchronize chezmoi diff fold zo")
end)
vim.api.nvim_buf_call(target_buf, function()
  assert(vim.fn.maparg("dp", "n", false, true).buffer ~= 1)
end)
local source_highlight = vim.api.nvim_win_call(source_win, function()
  return vim.fn.synIDattr(vim.fn.diff_hlID(2, 1), "name")
end)
local target_highlight = vim.api.nvim_win_call(target_win, function()
  return vim.fn.synIDattr(vim.fn.diff_hlID(2, 1), "name")
end)
assert(source_highlight == "DiffChange", source_highlight)
assert(target_highlight == "DiffChange", target_highlight)
local profile = assert(require("vimoi.gotmpl.session").last_profile)
assert(profile.render_ms > 0)
assert(profile.validation_ms == 0)

vim.api.nvim_set_current_win(target_win)
vim.api.nvim_win_set_cursor(target_win, { 2, 0 })
assert(require("vimoi.api").put_hunk())
local merged_source = table.concat(vim.api.nvim_buf_get_lines(source_buf, 0, -1, false), "\n")
assert(merged_source:find("timeout = 20", 1, true), merged_source)
assert(not merged_source:find("timeout = 10", 1, true), merged_source)

vim.api.nvim_win_close(source_win, true)
assert(not vim.wo[target_win].diff)
assert(vim.b[target_buf].snacks_scroll == nil)
assert(vim.fn.exists("#vimoi-view-" .. source_win .. "-" .. target_win) == 0, "session autocmds were not cleared")

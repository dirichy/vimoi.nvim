local fixture = vim.fn.getcwd() .. "/tests/fixtures/environment"
local root = vim.fn.tempname() .. " window sessions"
local source_root, destination = root .. "/source", root .. "/destination"
vim.fn.mkdir(source_root, "p")
vim.fn.mkdir(destination, "p")
vim.env.VIMOI_TEST_CONFIG = fixture .. "/empty.toml"
vim.env.VIMOI_TEST_SOURCE = source_root
vim.env.VIMOI_TEST_DESTINATION = destination
vim.opt.swapfile = false
local api = require("vimoi.api")
require("vimoi").setup({ chezmoi_executable = fixture .. "/chezmoi-wrapper.sh" })
local sessions = require("vimoi.gotmpl.session")
local util = require("vimoi.util")
local source, target = source_root .. "/dot_demo.lua.tmpl", destination .. "/.demo.lua"
vim.fn.writefile({ "local value = 1", '{{ "-- dynamic" }}' }, source)
vim.fn.writefile({ "local value = 2", "-- changed" }, target)
local function current()
  return assert(sessions.by_window[vim.api.nvim_get_current_win()])
end
local function await(session)
  assert(vim.wait(5000, function()
    return not session.loading
  end))
  assert(not session.closed and sessions.is_valid(session))
end
local function count()
  return #vim.api.nvim_tabpage_list_wins(0)
end

-- Repeated opens and both mode transitions keep the same two windows. An
-- unrelated window and unsaved text on both real files must remain untouched.
local unrelated = vim.api.nvim_get_current_win()
local unrelated_buf = vim.api.nvim_get_current_buf()
vim.cmd("vsplit")
vim.cmd.edit(source)
api.diff()
local session = current()
await(session)
local source_win, target_win = session.source_win, session.target_win
util.set_buffer_text(session.source_buf, 'local value = 3\n{{ "-- dynamic" }}\n')
util.set_buffer_text(session.target_buf, "local value = 4\n-- changed\n")
for index = 1, 12 do
  vim.api.nvim_set_current_win(index % 2 == 0 and session.source_win or session.target_win)
  if index % 3 == 0 then
    api.preview()
  elseif index % 3 == 1 then
    api.diff_files(source, target)
  else
    api.diff()
  end
  session = current()
  await(session)
  assert(count() == 3, "repeat open created another window")
  assert(session.source_win == source_win and session.target_win == target_win, "repeat open replaced a window")
  assert(vim.api.nvim_win_get_buf(unrelated) == unrelated_buf and not vim.wo[unrelated].diff)
end
assert(util.buffer_text(session.source_buf) == 'local value = 3\n{{ "-- dynamic" }}\n')
local target_buf = vim.fn.bufnr(target)
assert(util.buffer_text(target_buf) == "local value = 4\n-- changed\n")

-- A second tab can independently preview the same source buffer. Its close
-- must not retire the original diff, restore shared scroll options too early,
-- or replace user mappings when that buffer is focused outside the diff.
vim.api.nvim_set_current_win(source_win)
api.diff()
local diff = current()
await(diff)
local original_map = function() end
vim.cmd("tabnew")
vim.api.nvim_win_set_buf(0, diff.source_buf)
vim.keymap.set("n", "do", original_map, { buffer = diff.source_buf })
api.preview()
local preview = current()
await(preview)
assert(preview.source_buf == diff.source_buf and preview ~= diff)
assert(sessions.by_window[diff.source_win] == diff and sessions.by_window[preview.source_win] == preview)
assert(vim.fn.maparg("do", "n", false, true).callback == original_map)
vim.api.nvim_set_current_win(diff.source_win)
assert(vim.fn.maparg("do", "n", false, true).callback == api.get_hunk)
vim.api.nvim_set_current_win(preview.source_win)
assert(vim.fn.maparg("do", "n", false, true).callback == original_map)
sessions.close(preview)
assert(sessions.is_valid(diff) and vim.b[diff.source_buf].snacks_scroll == false)
assert(vim.fn.maparg("do", "n", false, true).callback == original_map)

-- Another unbound window displaying the same buffer creates its own diff;
-- operations resolve by the focused window and preserve the other session.
vim.cmd("tabnew")
vim.api.nvim_win_set_buf(0, diff.source_buf)
api.diff_files(source, target)
local second = current()
await(second)
assert(second ~= diff and sessions.is_valid(diff))
assert(second.source_win ~= diff.source_win and second.target_win ~= diff.target_win)
assert(count() == 2)
vim.api.nvim_set_current_win(second.target_win)
vim.api.nvim_win_set_cursor(0, { 1, 0 })
assert(api.get_hunk())
assert(not second.closed and not diff.closed)
-- The target buffer is intentionally shared, so the other view refreshes too.
vim.api.nvim_exec_autocmds("TextChanged", { buffer = target_buf })
assert(vim.wait(3000, function()
  return diff.target_text == util.buffer_text(target_buf)
end))
sessions.close(second)
assert(sessions.is_valid(diff) and vim.b[diff.source_buf].snacks_scroll == false)
vim.api.nvim_set_current_win(diff.source_win)
assert(vim.fn.maparg("do", "n", false, true).callback == api.get_hunk)
sessions.close(diff)
assert(vim.b[diff.source_buf].snacks_scroll == nil)
assert(vim.fn.maparg("do", "n", false, true).callback == original_map)

-- Native plain diff also reuses visible windows without creating a session.
vim.cmd("tabnew")
local plain_source, plain_target = source_root .. "/plain", destination .. "/plain"
vim.fn.writefile({ "source" }, plain_source)
vim.fn.writefile({ "target" }, plain_target)
for _ = 1, 5 do
  api.diff_files(plain_source, plain_target)
  assert(count() == 2 and sessions.by_window[vim.api.nvim_get_current_win()] == nil)
end
vim.fn.delete(root, "rf")

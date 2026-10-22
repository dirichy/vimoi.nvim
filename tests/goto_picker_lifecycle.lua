---@diagnostic disable: duplicate-set-field -- Hold picker results after navigation context changes.
local navigation = require("vimoi.goto")
local original_resolve, original_select = navigation.resolve, vim.ui.select
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
local source, first, second = root .. "/source", root .. "/first", root .. "/second"
for _, path in ipairs({ source, first, second }) do
  vim.fn.writefile({ path }, path)
end
vim.opt.hidden = true
local choose
navigation.resolve = function()
  return { first, second }
end
vim.ui.select = function(_, _, callback)
  choose = callback
end
for _, change in ipairs({ "none", "dismiss", "edit", "replace", "window", "close" }) do
  vim.cmd("tabnew")
  vim.cmd.edit(source)
  local win, buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
  navigation.open()
  assert(choose)
  if change == "edit" then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "edited" })
  elseif change == "replace" then
    vim.api.nvim_win_set_buf(win, vim.api.nvim_create_buf(false, true))
  elseif change == "window" then
    vim.cmd("vnew")
  elseif change == "close" then
    vim.api.nvim_win_close(win, true)
  end
  local before_win, before_buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
  choose(change ~= "dismiss" and second or nil)
  if change == "none" then
    assert(vim.api.nvim_buf_get_name(0) == second)
  else
    assert(
      vim.api.nvim_get_current_win() == before_win and vim.api.nvim_get_current_buf() == before_buf,
      change .. " picker result navigated in a stale window/buffer"
    )
  end
  vim.bo[buf].modified = false
end
navigation.resolve, vim.ui.select = original_resolve, original_select
vim.fn.delete(root, "rf")
print("goto picker: current selection, dismissal and stale window/buffer results verified")

-- Redraw a different source viewport after deleting its preview's parser buffer.
if not dofile("tests/helpers/tui.lua")("tests/session_output_lifecycle_ui.lua") then
  return
end
local api, util = vim.api, require("vimoi.util")
local function finish(err)
  vim.fn.writefile({ err or "OK" }, vim.env.VIMOI_UI_RESULT)
  vim.cmd("qa!")
end
local function later(callback)
  vim.defer_fn(function()
    local ok, err = xpcall(callback, debug.traceback)
    if not ok then
      finish(err)
    end
  end, 350)
end
vim.cmd("set noswapfile nonumber norelativenumber signcolumn=no laststatus=0")
require("vimoi").setup({ diagnostics = { enabled = false } })
local source = api.nvim_get_current_buf()
api.nvim_buf_set_name(source, vim.fn.tempname() .. ".lua.tmpl")
local lines = { 'local value = {{ "1" }}' }
for row = 2, 120 do
  lines[row] = "local value" .. row .. ' = "text"'
end
util.set_buffer_text(source, table.concat(lines, "\n") .. "\n")
require("vimoi.api").preview()
local view = assert(require("vimoi.gotmpl.view").by_window[api.nvim_get_current_win()])
later(function()
  assert(not view.loading and view.map)
  api.nvim_set_current_win(view.target_win)
  vim.cmd("bdelete")
  api.nvim_set_current_win(view.source_win)
  api.nvim_win_set_cursor(0, { 100, 0 })
  vim.cmd("normal! zt")
  later(function()
    local messages = api.nvim_exec2("messages", { output = true }).output
    assert(messages == "", messages)
    local state = require("vimoi.gotmpl.session").get(source)
    assert(state.map and require("vimoi.gotmpl.session").is_current(source, state.map))
    finish()
  end)
end)

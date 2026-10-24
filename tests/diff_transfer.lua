vim.opt.swapfile = false
require("vimoi").setup({ diagnostics = { enabled = false } })
local api = require("vimoi.api")
local util = require("vimoi.util")
local sessions = require("vimoi.gotmpl.view")
local source_text = 'name={{ "old" }}\ncount=1\n'
local target_text = "name=old\ncount=2\n"

-- APIs and commands use the focused window for both transfer directions.
for _, entry in ipairs({ "api", "command" }) do
  for _, case in ipairs({
    { side = "source", operation = "put", source = source_text, target = "name=old\ncount=1\n" },
    { side = "target", operation = "get", source = source_text, target = "name=old\ncount=1\n" },
    { side = "source", operation = "get", source = 'name={{ "old" }}\ncount=2\n', target = target_text },
    { side = "target", operation = "put", source = 'name={{ "old" }}\ncount=2\n', target = target_text },
  }) do
    vim.cmd("tabnew")
    local source_buf = vim.api.nvim_get_current_buf()
    local target_buf = vim.api.nvim_create_buf(true, false)
    util.set_buffer_text(source_buf, source_text)
    util.set_buffer_text(target_buf, target_text)
    api.diff_buffers(source_buf, target_buf)
    dofile("tests/helpers/diff.lua")()
    local session = assert(sessions.by_window[vim.api.nvim_get_current_win()])
    vim.api.nvim_set_current_win(session[case.side .. "_win"])
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    if entry == "api" then
      assert(api[case.operation .. "_hunk"]())
    else
      vim.cmd(case.operation == "put" and "VimoiDiffPut" or "VimoiDiffGet")
    end
    assert(util.buffer_text(source_buf) == case.source, entry .. "/" .. case.side .. "/" .. case.operation)
    assert(util.buffer_text(target_buf) == case.target, entry .. "/" .. case.side .. "/" .. case.operation)
    sessions.close(session)
  end
end
print("diff transfers: put/get APIs and commands follow the focused source/target window")

vim.opt.swapfile = false
vim.opt.hidden = true
local fixture = vim.fn.getcwd() .. "/tests/fixtures/environment"
vim.env.VIMOI_TEST_CONFIG = fixture .. "/empty.toml"
vim.env.VIMOI_TEST_SOURCE = fixture .. "/source"
local api = require("vimoi.api")
require("vimoi").setup({ chezmoi_executable = fixture .. "/chezmoi-wrapper.sh", diagnostics = { enabled = false } })
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
local sessions = require("vimoi.gotmpl.session")
for _, name in ipairs({ "file[1]", "file?", "file$VIMOI_TEST_DESTINATION", "file | spaced", "file[" }) do
  vim.cmd("tabnew")
  local source, target = root .. "/" .. name .. ".lua.tmpl", root .. "/" .. name .. ".lua"
  local unrelated_source = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(unrelated_source, root .. "/file1.lua.tmpl")
  vim.api.nvim_buf_set_lines(unrelated_source, 0, -1, false, { "unrelated source edits" })
  local unrelated_target = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(unrelated_target, root .. "/file1.lua")
  vim.api.nvim_buf_set_lines(unrelated_target, 0, -1, false, { "unrelated target edits" })
  vim.api.nvim_set_current_buf(unrelated_target)
  vim.fn.writefile({ "return {{ 42 }}" }, source)
  api.diff_files(source, target)
  local session = assert(sessions.by_window[vim.api.nvim_get_current_win()])
  assert(vim.wait(5000, function()
    return not session.loading
  end))
  assert(sessions.is_valid(session), name .. " aliased a different buffer")
  assert(vim.api.nvim_buf_get_name(session.source_buf) == source)
  assert(vim.api.nvim_buf_get_name(session.target_buf) == target)
  assert(session.trace.output == "return 42\n")
  assert(session.source_buf ~= unrelated_source and session.target_buf ~= unrelated_target)
  assert(vim.api.nvim_buf_get_lines(unrelated_source, 0, -1, false)[1] == "unrelated source edits")
  assert(vim.api.nvim_buf_get_lines(unrelated_target, 0, -1, false)[1] == "unrelated target edits")
  assert(not vim.uv.fs_stat(target), "opening a diff wrote its missing target")
  sessions.close(session)
  vim.api.nvim_buf_delete(unrelated_source, { force = true })
  vim.api.nvim_buf_delete(unrelated_target, { force = true })
end
print("literal paths: brackets, wildcard characters, dollars, pipes, spaces and unrelated unsaved buffers verified")

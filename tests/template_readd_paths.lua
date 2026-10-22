local view_for_buffer = dofile("tests/helpers/view.lua")
local fixture = vim.fn.getcwd() .. "/tests/fixtures/environment"
local root = vim.fn.tempname() .. " readd paths"
local source_root, destination = root .. "/source", root .. "/destination"
vim.fn.mkdir(source_root, "p")
vim.fn.mkdir(destination, "p")
vim.env.VIMOI_TEST_CONFIG = fixture .. "/empty.toml"
vim.env.VIMOI_TEST_SOURCE = source_root
vim.env.VIMOI_TEST_DESTINATION = destination
vim.opt.swapfile = false
local api = require("vimoi.api")
require("vimoi").setup({ chezmoi_executable = fixture .. "/chezmoi-wrapper.sh" })
local util = require("vimoi.util")
local sessions = require("vimoi.gotmpl.session")
local count = 0
local function files()
  count = count + 1
  local source = source_root .. "/dot_example" .. count .. ".lua.tmpl"
  local target = destination .. "/.example" .. count .. ".lua"
  vim.fn.writefile({ "local value = 1", '{{ "-- dynamic" }}' }, source)
  vim.fn.writefile({ "local value = 2", "-- dynamic" }, target)
  vim.cmd("tabnew")
  return source, target
end
local function complete(source, target)
  local session = assert(view_for_buffer(vim.fn.bufnr(source)))
  assert(session.pending_merge, "opening re-add must wait cancellably for initial rendering")
  assert(vim.wait(5000, function()
    return not session.pending_merge
  end))
  assert(util.buffer_text(session.source_buf) == 'local value = 2\n{{ "-- dynamic" }}\n')
  assert(util.buffer_text(session.target_buf) == "local value = 2\n-- dynamic\n")
  assert(util.read_file(source) == 'local value = 1\n{{ "-- dynamic" }}\n', "re-add saved the source file")
  assert(util.read_file(target) == "local value = 2\n-- dynamic\n")
  return session
end

for _, side in ipairs({ "source", "target" }) do
  local source, target = files()
  vim.cmd.edit(side == "source" and source or target)
  assert(api.readd() == nil)
  local session = complete(source, target)
  local windows = #vim.api.nvim_tabpage_list_wins(0)
  local result = assert(api.readd(side == "source" and source or target))
  assert(result.merged == 0 and #vim.api.nvim_tabpage_list_wins(0) == windows, "existing session was reopened")
  sessions.close(session)
end

-- Explicit paths work from an unrelated buffer; spaces survive Ex argument parsing.
for _, side in ipairs({ "source", "target" }) do
  local source, target = files()
  local path = side == "source" and source or target
  vim.cmd("VimoiReAdd " .. vim.fn.fnameescape(path))
  sessions.close(complete(source, target))
end

-- Loaded, unsaved buffers take priority over disk on both sides.
do
  local source, target = files()
  vim.cmd.edit(source)
  local source_buf = vim.api.nvim_get_current_buf()
  util.set_buffer_text(source_buf, 'local value = 1\n{{ "-- unsaved" }}\n')
  vim.cmd.edit(target)
  util.set_buffer_text(0, "local value = 3\n-- unsaved\n")
  api.readd(source)
  local session = assert(view_for_buffer(source_buf))
  assert(vim.wait(5000, function()
    return not session.pending_merge
  end))
  assert(util.buffer_text(source_buf) == 'local value = 3\n{{ "-- unsaved" }}\n')
  assert(util.read_file(source) == 'local value = 1\n{{ "-- dynamic" }}\n')
  sessions.close(session)
end

-- Cancellation after an automatic open leaves both buffers unchanged.
do
  local source, target = files()
  api.readd(target)
  local session = assert(view_for_buffer(vim.fn.bufnr(source)))
  assert(session.pending_merge)
  vim.fn.maparg("q", "n", false, true).callback()
  assert(vim.wait(5000, function()
    return session.closed
  end))
  assert(util.buffer_text(session.source_buf) == util.read_file(source))
  sessions.close(session)
end

-- A preview can be promoted to a real diff before re-adding its actual target.
do
  local source, target = files()
  api.preview({ source = source })
  local preview = assert(view_for_buffer(vim.fn.bufnr(source)))
  assert(vim.wait(5000, function()
    return preview.trace ~= nil
  end))
  vim.api.nvim_set_current_win(preview.target_win)
  api.readd()
  local session = complete(source, target)
  assert(preview.closed and not session.preview)
  sessions.close(session)
end

-- Unnamed and unmanaged requests must never write or silently re-add.
for _, path in ipairs({ "", root .. "/unmanaged" }) do
  if path == "" then
    vim.cmd.enew()
  else
    vim.fn.writefile({ "target" }, path)
  end
  local before = #vim.api.nvim_tabpage_list_wins(0)
  assert(api.readd(path ~= "" and path or nil) == nil)
  assert(#vim.api.nvim_tabpage_list_wins(0) == before, "invalid request opened a diff")
end
vim.fn.delete(root, "rf")

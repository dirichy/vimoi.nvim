vim.opt.swapfile = false
local fixture = vim.fn.getcwd() .. "/tests/fixtures/environment"
vim.env.VIMOI_TEST_CONFIG = fixture .. "/empty.toml"
vim.env.VIMOI_TEST_SOURCE = fixture .. "/source"
local api = require("vimoi.api")
require("vimoi").setup({
  chezmoi_executable = fixture .. "/chezmoi-wrapper.sh",
  diagnostics = { enabled = false },
  diff = { validate = true },
})
local sessions = require("vimoi.gotmpl.session")
local util = require("vimoi.util")
local source = vim.api.nvim_create_buf(true, false)
local target = vim.api.nvim_create_buf(true, false)
util.set_buffer_text(source, 'local value = {{ "1" }}\nlocal count = 2\n')
util.set_buffer_text(target, "local value = 1\nlocal count = 3\n")
local notifications = {}
vim.notify = function(message)
  notifications[#notifications + 1] = message
end
local function ready()
  local session = assert(sessions.by_window[vim.api.nvim_get_current_win()])
  assert(
    vim.wait(5000, function()
      return not session.loading
    end, 10),
    "buffer diff did not finish rendering"
  )
  assert(sessions.is_valid(session), table.concat(notifications, "\n"))
  return session
end

-- Identical empty names must not alias the two buffers or an unrelated window.
vim.api.nvim_set_current_buf(source)
assert(api.diff_buffers(0, target, { filetype = "lua" }) == nil)
local session = ready()
assert(session.source_buf == source and session.target_buf == target)
assert(session.source_win ~= session.target_win)
assert(vim.api.nvim_buf_get_name(source) == "" and vim.api.nvim_buf_get_name(target) == "")
assert(vim.bo[source].filetype == "gotmpl" and vim.bo[target].filetype == "lua")
assert(vim.b[source].vimoi_template_filetype == "lua")
assert(assert(vim.treesitter.get_parser(source, "gotmpl")):parse(true))
assert(vim.treesitter.get_parser(source, "gotmpl"):children().lua)
assert(not session.verify_with_cat, "buffer diff must not validate against a disk path")
assert(session.trace.output == "local value = 1\nlocal count = 2\n")
assert(vim.wo[session.source_win].diff and vim.wo[session.target_win].diff)

-- Repeating either entry point reuses the exact buffer identities from either side.
vim.api.nvim_set_current_win(session.target_win)
api.diff()
session = ready()
assert(session.source_buf == source and session.target_buf == target)
assert(not session.verify_with_cat)
assert(#vim.api.nvim_tabpage_list_wins(0) == 2)
api.diff_buffers(source, target)
session = ready()
assert(#vim.api.nvim_tabpage_list_wins(0) == 2)
assert(vim.b[source].vimoi_template_filetype == "lua", "default must inherit the target filetype")

local result = assert(api.readd())
assert(result.merged == 1 and result.skipped == 0)
assert(util.buffer_text(source) == 'local value = {{ "1" }}\nlocal count = 3\n')
assert(util.buffer_text(target) == "local value = 1\nlocal count = 3\n")

-- Buffer edits refresh the rendered diff without a path lookup.
util.set_buffer_text(source, 'local value = {{ "1" }}\nlocal count = 4\n')
vim.api.nvim_exec_autocmds("TextChanged", { buffer = source })
assert(vim.wait(5000, function()
  return session.trace.output == "local value = 1\nlocal count = 4\n"
end, 10))
vim.api.nvim_set_current_win(session.source_win)
vim.api.nvim_win_set_cursor(session.source_win, { 2, 0 })
assert(api.put_hunk())
assert(util.buffer_text(target) == "local value = 1\nlocal count = 4\n")

-- Reject invalid identities before retiring a working view.
api.diff_buffers(source, source)
assert(sessions.is_valid(session))
local deleted = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_delete(deleted, { force = true })
api.diff_buffers(deleted, target)
assert(sessions.is_valid(session))
assert(notifications[#notifications]:find("two loaded buffers", 1, true))

vim.api.nvim_win_close(session.target_win, true)
assert(session.closed and not vim.wo[session.source_win].diff)
assert(vim.api.nvim_buf_is_loaded(source) and vim.api.nvim_buf_is_loaded(target))

-- Named buffers and explicit host overrides use buffer contents, without files.
vim.cmd("tabnew")
local named_source = vim.api.nvim_create_buf(false, true)
local named_target = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_name(named_source, "vimoi-test://source")
vim.api.nvim_buf_set_name(named_target, "vimoi-test://target")
util.set_buffer_text(named_source, "enabled = {{ true }}\n")
util.set_buffer_text(named_target, "enabled = false\n")
vim.bo[named_target].filetype = "lua"
api.diff_buffers(named_source, named_target, { filetype = "toml" })
session = ready()
assert(session.source_buf == named_source and session.target_buf == named_target)
assert(vim.bo[named_target].filetype == "toml")
assert(vim.b[named_source].vimoi_template_filetype == "toml")
assert(not session.verify_with_cat)
assert(session.trace.output == "enabled = true\n")

-- Both buffers can be hidden and have neither names nor filetypes.
vim.cmd("tabnew")
local unrelated = vim.api.nvim_get_current_buf()
local untyped_source = vim.api.nvim_create_buf(false, true)
local untyped_target = vim.api.nvim_create_buf(false, true)
util.set_buffer_text(untyped_source, 'value={{ "A" }}\n')
util.set_buffer_text(untyped_target, "value=B\n")
api.diff_buffers(untyped_source, untyped_target)
session = ready()
assert(session.source_buf == untyped_source and session.target_buf == untyped_target)
assert(session.source_buf ~= unrelated and session.target_buf ~= unrelated)
assert(vim.bo[untyped_source].filetype == "gotmpl")
assert(vim.bo[untyped_target].filetype == "")
assert(session.trace.output == "value=A\n")
assert(util.buffer_text(unrelated) == "\n", "opening a buffer pair modified unrelated content")

vim.api.nvim_set_current_win(session.target_win)
api.preview()
session = ready()
assert(session.preview and session.source_buf == untyped_source)
assert(util.buffer_text(session.target_buf) == "value=A\n", "preview rendered the unnamed target instead of source")
api.diff_buffers(untyped_source, untyped_target)
session = ready()
assert(not session.preview and session.target_buf == untyped_target)
print("buffer diff: unnamed identities, host type, rendering, re-add, put/get, refresh, reuse, and cleanup verified")

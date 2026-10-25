vim.opt.swapfile = false
local fixture = vim.fn.getcwd() .. "/tests/fixtures/environment"
vim.env.VIMOI_TEST_CONFIG = fixture .. "/empty.toml"
vim.env.VIMOI_TEST_SOURCE = fixture .. "/source"
local api = require("vimoi.api")
require("vimoi").setup({ chezmoi_executable = fixture .. "/chezmoi-wrapper.sh", diagnostics = { enabled = false } })
local source = fixture .. "/source/dot_diff_target.tmpl"
local target = vim.env.VIMOI_TEST_DESTINATION .. "/.diff_target"
local sessions = require("vimoi.compare")
local function ready()
  local session = assert(sessions.by_window[vim.api.nvim_get_current_win()])
  assert(vim.wait(5000, function()
    return not session.loading
  end))
  assert(sessions.is_valid(session))
  return session
end
assert(api.diff({ source = source, target = target }) == nil, "public diff leaked an internal session")
ready()
assert(api.diff_files(source, target) == nil, "public diff_files leaked an internal session")
ready()
assert(api.preview() == nil, "public preview leaked an internal session")
local preview = ready()
assert(preview.preview and vim.bo[preview.target_buf].readonly)
print("public API: interactive view operations do not expose internal session handles")

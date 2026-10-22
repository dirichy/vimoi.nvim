vim.opt.swapfile = false
local fixture = vim.fn.getcwd() .. "/tests/fixtures/environment"
local root = vim.fn.tempname() .. " horizontal views"
local source_root, target_root = root .. "/source", root .. "/target"
vim.fn.mkdir(source_root, "p")
vim.fn.mkdir(target_root, "p")
vim.env.VIMOI_TEST_CONFIG = fixture .. "/empty.toml"
vim.env.VIMOI_TEST_SOURCE = source_root
vim.env.VIMOI_TEST_DESTINATION = target_root
local source, target = source_root .. "/dot_demo.tmpl", target_root .. "/.demo"
vim.fn.writefile({ "value={{ 1 }}" }, source)
vim.fn.writefile({ "value=2" }, target)
local api = require("vimoi.api")
api.setup({
  chezmoi_executable = fixture .. "/chezmoi-wrapper.sh",
  split = "horizontal",
  diagnostics = { enabled = false },
})
local sessions = require("vimoi.gotmpl.session")
local function await()
  local session = assert(sessions.by_window[vim.api.nvim_get_current_win()])
  assert(vim.wait(5000, function()
    return not session.loading
  end))
  assert(sessions.is_valid(session))
  return session
end
vim.cmd.edit(target)
api.diff()
local session = await()
assert(vim.fn.winlayout()[1] == "col", "diff did not split horizontally")
assert(vim.api.nvim_win_get_position(session.source_win)[1] < vim.api.nvim_win_get_position(session.target_win)[1])
api.preview()
session = await()
assert(vim.fn.winlayout()[1] == "col" and #vim.api.nvim_tabpage_list_wins(0) == 2)

-- Reconfiguration affects newly created splits; reusing a pair never rearranges it.
api.setup({ split = "vertical", diagnostics = { enabled = false } })
api.diff()
await()
assert(vim.fn.winlayout()[1] == "col")
vim.cmd("tabnew")
api.preview({ source = source })
await()
assert(vim.fn.winlayout()[1] == "row")

-- Ordinary native diff shares the same split option.
api.setup({ split = "horizontal", diagnostics = { enabled = false } })
vim.cmd("tabnew")
local plain_source, plain_target = source_root .. "/plain", target_root .. "/plain"
vim.fn.writefile({ "before" }, plain_source)
vim.fn.writefile({ "after" }, plain_target)
api.diff_files(plain_source, plain_target)
assert(vim.fn.winlayout()[1] == "col" and vim.wo.diff)
local before = vim.deepcopy(require("vimoi").config)
assert(not pcall(api.setup, vim.json.decode('{"split":"diagonal"}')))
assert(vim.deep_equal(before, require("vimoi").config), "invalid split option changed the active configuration")
print("horizontal views: diff, preview, plain diff, reuse, and runtime configuration verified")

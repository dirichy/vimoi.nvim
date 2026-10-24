local util = require("vimoi.util")
local calls = 0
local first_argument
local initialize = util.once(function(value)
  calls = calls + 1
  first_argument = value
end)
initialize("first")
initialize("second")
assert(calls == 1)
assert(first_argument == "first")

local api = require("vimoi.api")
assert(vim.fn.exists(":VimoiDiff") == 0, "loading the API must not register commands before setup")
local vimoi = require("vimoi")
local fixture = vim.fn.getcwd() .. "/tests/fixtures/environment"
vim.env.VIMOI_TEST_CONFIG = fixture .. "/empty.toml"
vim.env.VIMOI_TEST_SOURCE = fixture .. "/source"
vimoi.setup({ chezmoi_executable = fixture .. "/chezmoi-wrapper.sh" })
assert(vim.fn.exists(":VimoiDiff") == 2)
assert(vim.fn.exists(":VimoiDiffPut") == 2)
assert(vim.fn.exists(":VimoiDiffGet") == 2)
assert(vim.fn.exists(":VimoiDiffApply") == 0)
assert(type(api.put_hunk) == "function" and type(api.get_hunk) == "function")
assert(api.apply_hunk == nil)
assert(vim.fn.exists(":VimoiReAdd") == 2)
assert(vim.fn.exists(":VimoiPreview") == 2)
assert(package.loaded["vimoi.goto"] == nil)
assert(package.loaded["vimoi.blink"] == nil)
assert(package.loaded["vimoi.highlight"] ~= nil)
assert(package.loaded["vimoi.gotmpl"] == nil)

local groups = { "vimoi-cli-cache", "vimoi-highlight", "vimoi-buffers" }
for _, group in ipairs(groups) do
  assert(#vim.api.nvim_get_autocmds({ group = group }) > 0, group .. " registered no autocommands")
end

local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_win_set_buf(0, buf)
vim.bo[buf].filetype = "gotmpl"
assert(package.loaded["vimoi.goto"] == nil, "goto should remain unloaded until a mapping is used")
assert(package.loaded["vimoi.api"] == api)
assert(vim.fn.maparg("gf", "n", false, true).desc == "Open chezmoi path under cursor")
assert(package.loaded["vimoi.blink"] == nil)
assert(vim.wait(1000, function()
  return vim.b[buf].vimoi_template_configured == true
end))

vim.cmd("edit " .. vim.fn.fnameescape(vim.fn.getcwd() .. "/tests/fixtures/environment/source/.chezmoiroot"))
assert(vim.b.vimoi_gf ~= true, ".chezmoiroot should use native gf")

vim.cmd("edit " .. vim.fn.fnameescape(vim.fn.getcwd() .. "/tests/fixtures/environment/source/symlink_example"))
assert(vim.b.vimoi_gf == true, "symlink_example did not attach gf")
assert(package.loaded["vimoi.goto"] == nil, "opening symlink source should not load goto")

-- Runtime options can be reset; omitted setup-time process/watch/map settings persist.
local original_config = vim.deepcopy(vimoi.config)
vimoi.setup({ completion = { enabled = false }, diff = { validate = false } })
assert(not vimoi.config.completion.enabled and vimoi.config.diff.validate == false)
assert(vimoi.config.chezmoi_executable == original_config.chezmoi_executable)
vimoi.setup()
assert(vimoi.config.completion.enabled and vimoi.config.diff.validate == true)
for _, opts in ipairs({
  { chezmoi_executable = "different" },
  { watch = { buffer_write_fallback = false } },
  { keymaps = { goto_file = false } },
}) do
  local before = vim.deepcopy(vimoi.config)
  local ok, err = pcall(vimoi.setup, opts)
  assert(not ok and err:find("cannot change after setup", 1, true))
  assert(vim.deep_equal(before, vimoi.config), "rejected configuration was published")
end

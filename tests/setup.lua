local util = require("vimoi.core.util")
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

-- Strict wrappers reject duplicates; failed initialization remains retryable.
local attempts = 0
local strict = util.once(function(fail)
  attempts = attempts + 1
  if fail then
    error("initialization failed")
  end
end, { repeat_error = "already initialized" })
assert(not pcall(strict, true) and attempts == 1)
assert(pcall(strict, false) and attempts == 2)
local strict_ok, strict_error = pcall(strict, false)
assert(not strict_ok and strict_error == "already initialized" and attempts == 2)

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
assert(package.loaded["vimoi.editor.goto"] == nil)
assert(package.loaded["vimoi.blink"] == nil)
assert(package.loaded["vimoi.editor.highlight"] ~= nil)
assert(package.loaded["vimoi.compare"] == nil)

local groups = { "vimoi-cli-cache", "vimoi-highlight", "vimoi-buffers" }
for _, group in ipairs(groups) do
  assert(#vim.api.nvim_get_autocmds({ group = group }) > 0, group .. " registered no autocommands")
end

local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_win_set_buf(0, buf)
vim.bo[buf].filetype = "gotmpl"
assert(package.loaded["vimoi.editor.goto"] == nil, "goto should remain unloaded until a mapping is used")
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
assert(package.loaded["vimoi.editor.goto"] == nil, "opening symlink source should not load goto")

-- A second setup is rejected before changing configuration or registrations.
local original_config = vim.deepcopy(vimoi.config)
local original_autocmds = #vim.api.nvim_get_autocmds({})
for _, opts in ipairs({
  {},
  { completion = { enabled = false }, render = { validate = false } },
  { chezmoi_executable = "different" },
  { watch = { buffer_write_fallback = false } },
  { keymaps = { goto_file = false } },
}) do
  local ok, err = pcall(vimoi.setup, opts)
  assert(not ok and err:find("restart Neovim", 1, true))
  assert(vim.deep_equal(original_config, vimoi.config), "rejected configuration was published")
  assert(#vim.api.nvim_get_autocmds({}) == original_autocmds, "repeated setup installed callbacks")
end
assert(not pcall(vimoi.setup), "setup without options must also reject reinitialization")

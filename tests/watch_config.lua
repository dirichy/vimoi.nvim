local cli = require("vimoi.core.cli")
local watch = require("vimoi.core.watch")
local test_root = vim.fn.tempname() .. " watch config"
local source_root = test_root .. "/source"
local include_dir = source_root .. "/includes/nested"
local config_path = test_root .. "/config.toml"
vim.fn.mkdir(include_dir, "p")
vim.fn.writefile({ "# config" }, config_path)
local include_file = include_dir .. "/part"
vim.fn.writefile({ "before" }, include_file)

local rules = { { pattern = "/includes/", scope = "templates", watch = "tree" } }
local options = { source_root = source_root, config_path = config_path, rules = rules, buffer_write_fallback = true }
local snapshot = vim.deepcopy(options)
watch.setup(options)
assert(vim.deep_equal(options, snapshot), "setup must not insert config rules into caller options")
assert(#vim.api.nvim_get_autocmds({ group = "vimoi-cli-cache", event = "VimLeavePre" }) == 0)

local generation = cli.context_generation
vim.fn.writefile({ "after" }, include_file)
assert(
  vim.wait(2000, function()
    return cli.context_generation > generation
  end, 20),
  "custom tree rule was not registered"
)

-- Supplied source rules replace the defaults; the exact config rule remains.
generation = cli.context_generation
vim.api.nvim_exec_autocmds("BufWritePost", {
  pattern = source_root .. "/.chezmoitemplates/ignored",
  modeline = false,
})
assert(cli.context_generation == generation)
vim.api.nvim_exec_autocmds("BufWritePost", { pattern = config_path, modeline = false })
assert(cli.context_generation == generation + 1)

-- Repeated setup is still one-shot and must not replace the selected options.
watch.setup({ source_root = test_root .. "/unused", config_path = test_root .. "/unused.toml" })
generation = cli.context_generation
vim.api.nvim_exec_autocmds("BufWritePost", { pattern = include_file, modeline = false })
assert(cli.context_generation == generation + 1)
assert(vim.deep_equal(options, snapshot))

vim.fn.delete(test_root, "rf")
print("watch config: table options, rule overrides, immutable input, and one-shot setup verified")

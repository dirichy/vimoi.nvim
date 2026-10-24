local util = require("vimoi.util")
local root = vim.fn.getcwd()
local home = assert(vim.uv.os_homedir())

assert(util.normalize_path("./lua/../doc/vimoi.txt") == root .. "/doc/vimoi.txt")
assert(util.normalize_path(root .. "/lua/../../" .. vim.fs.basename(root) .. "/doc") == root .. "/doc")
assert(util.normalize_path("~/chezmoi/../config.toml") == home .. "/config.toml")
assert(util.normalize_path("../config.toml") == vim.fs.dirname(root) .. "/config.toml")

-- Dollar signs are literal even if an environment variable of the same name exists.
local previous_root = vim.env.VIMOI_TEST_PATH_ROOT
vim.env.VIMOI_TEST_PATH_ROOT = root
for _, name in ipairs({ "$VIMOI_TEST_PATH_ROOT", "${VIMOI_TEST_PATH_ROOT}", "literal$HOME", "trailing$" }) do
  assert(util.normalize_path(name .. "/lua/../doc") == root .. "/" .. name .. "/doc")
  assert(util.normalize_path(root .. "/" .. name) == root .. "/" .. name)
end
assert(util.normalize_path("~/$VIMOI_TEST_PATH_ROOT") == home .. "/$VIMOI_TEST_PATH_ROOT")
-- Callers can explicitly read environment variables when constructing paths.
assert(util.normalize_path(vim.env.VIMOI_TEST_PATH_ROOT .. "/lua/../doc") == root .. "/doc")
vim.env.VIMOI_TEST_PATH_ROOT = previous_root

-- A normalized absolute path remains stable after the working directory changes.
local path = util.normalize_path("./doc/vimoi.txt")
vim.api.nvim_set_current_dir(home)
assert(util.normalize_path(path) == path)
vim.api.nvim_set_current_dir(root)

-- Indexed positions must match the original scanner at every byte boundary,
-- including newline, EOF, multibyte characters, and empty text.
for _, text in ipairs({ "", "one", "a\n", "\n\n", "中文\r\nsecond\nlast" }) do
  local starts = util.line_starts(text)
  for byte = 0, #text do
    local row, col = util.byte_to_position(text, byte)
    local indexed_row, indexed_col = util.byte_to_position(text, byte, starts)
    assert(row == indexed_row and col == indexed_col)
  end
end

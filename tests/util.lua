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

-- Guards preserve callback arguments/results, evaluate validity at delivery,
-- and route stale results to the supplied policy without swallowing errors.
local valid, calls, failures = true, 0, 0
local guarded = util.guard(function(...)
  calls = calls + 1
  local args = vim.F.pack_len(...)
  assert(args.n == 3 and args[1] == "result" and args[2] == nil and args[3] == 7)
  return "accepted", nil, 9, nil
end, {
  is_valid = function()
    return valid
  end,
  on_fail = function()
    failures = failures + 1
    return "discarded"
  end,
})
local result = vim.F.pack_len(guarded("result", nil, 7))
assert(result.n == 4 and result[1] == "accepted" and result[2] == nil and result[3] == 9)
valid = false
assert(guarded("old", nil, 0) == "discarded" and calls == 1 and failures == 1)
assert(util.guard(function()
  error("stale callback ran")
end, {
  is_valid = function()
    return false
  end,
})() == nil)
valid = true
assert(guarded("result", nil, 7) == "accepted" and calls == 2)
for _, callback in ipairs({
  util.guard(function()
    error("callback failure")
  end, {
    is_valid = function()
      return true
    end,
  }),
  util.guard(function() end, {
    is_valid = function()
      error("validation failure")
    end,
  }),
  util.guard(function() end, {
    is_valid = function()
      return false
    end,
    on_fail = function()
      error("failure policy error")
    end,
  }),
}) do
  assert(not pcall(callback), "guard must not hide errors")
end

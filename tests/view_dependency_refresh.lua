vim.opt.swapfile = false
local fixture = vim.fn.getcwd() .. "/tests/fixtures/environment"
local root = vim.fn.tempname() .. " view dependencies"
local source_root, target_root = root .. "/source", root .. "/target"
local shared = source_root .. "/.chezmoitemplates/value"
vim.fn.mkdir(vim.fs.dirname(shared), "p")
vim.fn.mkdir(target_root, "p")
local source, target = source_root .. "/dot_demo.tmpl", target_root .. "/.demo"
vim.fn.writefile({ '{{ includeTemplate "value" . }}' }, source)
vim.fn.writefile({ "one" }, shared)
vim.fn.writefile({ "keep target edits" }, target)
vim.env.VIMOI_TEST_CONFIG = fixture .. "/empty.toml"
vim.env.VIMOI_TEST_SOURCE = source_root
vim.env.VIMOI_TEST_DESTINATION = target_root
local api = require("vimoi.api")
require("vimoi").setup({
  chezmoi_executable = fixture .. "/chezmoi-wrapper.sh",
  diagnostics = { enabled = false },
  watch = { buffer_write_fallback = true },
})
local sessions = require("vimoi.compare")
local util = require("vimoi.core.util")
api.preview({ source = source })
local preview = assert(sessions.by_window[vim.api.nvim_get_current_win()])
assert(vim.wait(5000, function()
  return not preview.loading
end))
vim.cmd("tabnew")
api.diff_files(source, target)
local diff = assert(sessions.by_window[vim.api.nvim_get_current_win()])
assert(vim.wait(5000, function()
  return not diff.loading
end))
util.set_buffer_text(diff.target_buf, "unsaved target edits\n")

local function await(value)
  assert(
    vim.wait(5000, function()
      local state = require("vimoi.render").get(preview.source_buf)
      return state.map ~= nil
        and not state.error
        and preview.map == state.map
        and diff.map == state.map
        and util.buffer_text(preview.target_buf):find(value, 1, true) ~= nil
    end),
    "open views did not refresh to " .. value
  )
  assert(sessions.is_valid(preview) and sessions.is_valid(diff))
  assert(util.buffer_text(diff.target_buf) == "unsaved target edits\n")
  assert(vim.fn.readfile(target)[1] == "keep target edits", "dependency refresh wrote a real target")
end

-- A real :write in another tab invalidates once through the existing watch rules.
vim.cmd("tabnew")
vim.cmd.edit(vim.fn.fnameescape(shared))
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "two" })
vim.cmd("write")
await("two")

-- External edits and atomic replacement use the same invalidation/refresh path.
vim.fn.writefile({ "three" }, shared .. ".new")
assert(vim.uv.fs_rename(shared .. ".new", shared))
await("three")
local previous = util.buffer_text(preview.target_buf)
vim.fn.writefile({ "{{ if" }, shared)
assert(
  vim.wait(5000, function()
    return preview.preview_error ~= nil
  end),
  "invalid include did not mark the preview stale"
)
assert(util.buffer_text(preview.target_buf) == previous)
vim.fn.writefile({ "recovered" }, shared)
await("recovered")
assert(preview.preview_error == nil)

-- Closing views leaves the source renderer alive for rendered highlighting.
require("vimoi.core.cli").invalidate("templates")
sessions.close(preview)
sessions.close(diff)
vim.fn.writefile({ "closed" }, shared)
vim.wait(300, function()
  return false
end)
assert(vim.wait(5000, function()
  return util.buffer_text(preview.target_buf) == "closed\n\n"
end))
assert(preview.closed and diff.closed)
print("view dependencies: saves, external edits, multiple tabs, stale recovery, target protection and close verified")

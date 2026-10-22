local fixture = vim.fn.getcwd() .. "/tests/fixtures/environment"
local root = vim.fn.tempname() .. " plain readd"
local source_root, destination = root .. "/source", root .. "/destination"
vim.fn.mkdir(source_root, "p")
vim.fn.mkdir(destination, "p")
vim.env.VIMOI_TEST_CONFIG = fixture .. "/empty.toml"
vim.env.VIMOI_TEST_SOURCE = source_root
vim.env.VIMOI_TEST_DESTINATION = destination
vim.opt.swapfile = false
vim.opt.hidden = true
local api = require("vimoi.api")
api.setup({ chezmoi_executable = fixture .. "/chezmoi-wrapper.sh" })
local util = require("vimoi.util")
---@diagnostic disable: duplicate-set-field -- Plain files must never use template rendering.
local source_map = require("vimoi.gotmpl.source_map")
source_map.trace = function()
  error("plain re-add attempted template rendering")
end
source_map.trace_async = source_map.trace
local count = 0
local function files(before, after)
  count = count + 1
  local source = source_root .. "/private_dot_example[" .. count .. "].txt"
  local target = destination .. "/.example[" .. count .. "].txt"
  vim.fn.writefile(vim.split(before, "\n", { plain = true }), source, "b")
  if after then
    vim.fn.writefile(vim.split(after, "\n", { plain = true }), target, "b")
  end
  vim.cmd("tabnew")
  return source, target
end

-- Both current-buffer sides and explicit paths share the same operation.
for _, side in ipairs({ "source", "target", "explicit_source", "explicit_target", "command" }) do
  local before, after = "old\nkeep\nlast\n", "new\nkeep\nadded\nlast\n"
  local source, target = files(before, after)
  if side == "source" or side == "target" then
    vim.cmd.edit(vim.fn.fnameescape(side == "source" and source or target))
  end
  local source_buf = vim.fn.bufadd(source)
  vim.fn.bufload(source_buf)
  local namespace = vim.api.nvim_create_namespace("plain-readd-test")
  local mark = vim.api.nvim_buf_set_extmark(source_buf, namespace, 1, 1, {})
  local result
  if side == "command" then
    vim.cmd("VimoiReAdd " .. vim.fn.fnameescape(target))
  else
    result = assert(api.readd(side == "explicit_source" and source or side == "explicit_target" and target or nil))
    assert(result.merged == 2 and result.skipped == 0 and #result.reasons == 0)
  end
  assert(util.buffer_text(source_buf) == after)
  assert(vim.deep_equal(vim.api.nvim_buf_get_extmark_by_id(source_buf, namespace, mark, {}), { 1, 1 }))
  assert(util.read_file(source) == before and util.read_file(target) == after, "re-add wrote to disk")
  assert(#vim.api.nvim_tabpage_list_wins(0) == 2, "plain re-add did not open a native diff")
  local no_changes = assert(api.readd())
  assert(no_changes.merged == 0 and #vim.api.nvim_tabpage_list_wins(0) == 2, "repeat re-add opened extra windows")
  vim.api.nvim_buf_call(source_buf, function()
    vim.cmd("silent undo")
    assert(util.buffer_text(source_buf) == before, "re-add edits were not one undo step")
    vim.cmd("silent redo")
    assert(util.buffer_text(source_buf) == after)
  end)
end

-- Unsaved text on both sides takes priority over disk, including after an ordinary diff opens.
do
  local source, target = files("source on disk\n", "target on disk\n")
  vim.cmd.edit(vim.fn.fnameescape(source))
  local source_buf = vim.api.nvim_get_current_buf()
  util.set_buffer_text(source_buf, "unsaved source\n")
  vim.cmd.edit(vim.fn.fnameescape(target))
  util.set_buffer_text(0, "unsaved target\n")
  api.diff()
  assert(api.readd().merged == 1)
  assert(util.buffer_text(source_buf) == "unsaved target\n")
  assert(util.read_file(source) == "source on disk\n" and util.read_file(target) == "target on disk\n")
end

for _, texts in ipairs({
  { "first\nsecond\n", "first\n" },
  { "old\n", "new" },
  { "same\n", "same" },
  { "same", "same\n" },
  { "old", "new\n" },
  { "old\n", "" },
  { "", "new\n" },
  { "你好\nkeep\n世界\n", "再见\nkeep\n{{ literal text }}\n" },
}) do
  local source, target = files(texts[1], texts[2])
  assert(api.readd(target))
  local source_buf, target_buf = vim.fn.bufadd(source), vim.fn.bufadd(target)
  assert(util.buffer_text(source_buf) == util.buffer_text(target_buf), vim.inspect(texts))
  assert(vim.bo[source_buf].endofline == vim.bo[target_buf].endofline)
  assert(util.read_file(source) == texts[1] and util.read_file(target) == texts[2])
end

-- Missing targets cannot be interpreted as empty content and erase the source.
do
  local source, target = files("must remain\n")
  local windows = #vim.api.nvim_tabpage_list_wins(0)
  assert(api.readd(target) == nil)
  assert(util.buffer_text(vim.fn.bufadd(source)) == "must remain\n")
  assert(#vim.api.nvim_tabpage_list_wins(0) == windows)
end

-- A loaded new target is valid, and an unmodifiable source stays untouched.
do
  local source, target = files("must remain\n")
  vim.cmd.edit(vim.fn.fnameescape(target))
  util.set_buffer_text(0, "new target\n")
  assert(api.readd().merged == 1)
  local source_buf = vim.fn.bufadd(source)
  vim.bo[source_buf].modifiable = false
  util.set_buffer_text(vim.fn.bufadd(target), "cannot overwrite\n")
  assert(api.readd() == nil)
  assert(util.buffer_text(source_buf) == "new target\n")
end

-- Encoded source types must not be replaced with ordinary target text.
for _, name in ipairs({ "encrypted_dot_secret", "create_encrypted_dot_secret", "symlink_dot_link", "modify_dot_modify" }) do
  local source = source_root .. "/" .. name
  vim.fn.writefile({ "encoded source" }, source)
  vim.fn.writefile({ "target text" }, destination .. "/." .. name:match("dot_(.+)$"))
  assert(api.readd(source) == nil, "special source type was treated as plain text: " .. name)
  assert(util.read_file(source) == "encoded source\n")
  local buf = vim.fn.bufadd(source)
  assert(not vim.api.nvim_buf_is_loaded(buf) or util.buffer_text(buf) == "encoded source\n")
end
vim.fn.delete(root, "rf")
print("plain re-add: paths, unsaved buffers, undo, Unicode, EOF, missing target and buffer protection verified")

---@diagnostic disable: duplicate-set-field -- Count actual invalidations from real saves.
local cli = require("vimoi.cli")
local original_invalidate = cli.invalidate
local test_root = vim.fn.tempname() .. " watch saves"
local source_root = test_root .. "/source"
local template_dir = source_root .. "/.chezmoitemplates"
local template_file = template_dir .. "/part"
local config_path = test_root .. "/config.toml"
vim.fn.mkdir(template_dir, "p")
vim.fn.writefile({ "before" }, template_file)
vim.fn.writefile({ "# config" }, config_path)

local raw_events, buffer_saves, buffer_invalidations, fs_invalidations = 0, 0, 0, 0
local saving = false
cli.invalidate = function(scope)
  if saving then
    buffer_invalidations = buffer_invalidations + 1
  else
    fs_invalidations = fs_invalidations + 1
  end
  return original_invalidate(scope)
end
local probe = assert(vim.uv.new_fs_event())
assert(probe:start(template_dir, {}, function(err)
  assert(not err, err)
  raw_events = raw_events + 1
end))
vim.api.nvim_create_autocmd("BufWritePre", {
  callback = function()
    saving = true
  end,
})
require("vimoi.watch").setup({ source_root = source_root, config_path = config_path })
vim.api.nvim_create_autocmd("BufWritePost", {
  callback = function()
    buffer_saves = buffer_saves + 1
    saving = false
  end,
})

vim.o.swapfile = false
vim.o.undofile = false
vim.o.backup = false
vim.cmd("edit " .. vim.fn.fnameescape(template_file))
for _, mode in ipairs({ "in-place", "atomic" }) do
  vim.o.writebackup = mode == "atomic"
  vim.o.backupcopy = mode == "atomic" and "no" or "yes"
  vim.wait(80, function()
    return false
  end, 10)
  raw_events, buffer_saves, buffer_invalidations, fs_invalidations = 0, 0, 0, 0
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { mode })
  vim.cmd("silent write")
  assert(vim.wait(2000, function()
    return raw_events > 0 and fs_invalidations > 0
  end, 10))
  vim.wait(80, function()
    return false
  end, 10)
  assert(buffer_saves == 1)
  assert(buffer_invalidations == 0, "auto fallback must not duplicate a healthy directory watcher")
  print(
    ("%s save: raw fs events=%d; BufWritePost=%d; invalidations: buffer=%d, watcher=%d"):format(
      mode,
      raw_events,
      buffer_saves,
      buffer_invalidations,
      fs_invalidations
    )
  )
end
probe:stop()
probe:close()
cli.invalidate = original_invalidate
vim.fn.delete(test_root, "rf")

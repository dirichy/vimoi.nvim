vim.opt.swapfile = false
vim.opt.hidden = true
local fixture = vim.fn.getcwd() .. "/tests/fixtures/environment"
local root = vim.fn.tempname() .. " files"
local source = root .. "/source"
vim.fn.mkdir(source .. "/dot_config", "p")
vim.fn.writefile({ "plain" }, source .. "/dot_a space|name")
vim.fn.writefile({ "newline" }, source .. "/dot_line\nbreak")
vim.fn.writefile({ "config" }, source .. "/dot_config/app")
vim.fn.writefile({ "ignored" }, source .. "/ignored")
vim.fn.writefile({ "ignored" }, source .. "/.chezmoiignore")
vim.fn.writefile({ "a space|name" }, source .. "/symlink_link")
vim.env.VIMOI_TEST_CONFIG = fixture .. "/empty.toml"
vim.env.VIMOI_TEST_SOURCE = source
vim.env.VIMOI_TEST_DESTINATION = root .. "/target"
require("vimoi").setup({ chezmoi_executable = fixture .. "/chezmoi-wrapper.sh" })
local api = require("vimoi.api")
local original_select = vim.ui.select
local paths, options, choose
local function select(items, opts, callback)
  paths, options, choose = items, opts, callback
end
vim.ui.select = select
local function picker()
  paths, options, choose = nil, nil, nil
  vim.cmd("VimoiFiles")
  assert(
    vim.wait(5000, function()
      return choose ~= nil
    end),
    "managed-files picker timed out"
  )
end

picker()
assert(#paths == 4, vim.inspect(paths))
assert(vim.tbl_contains(paths, source .. "/symlink_link"))
assert(vim.tbl_contains(paths, source .. "/dot_line\nbreak"))
assert(options.format_item(source .. "/dot_a space|name") == "dot_a space|name")
assert(not options.format_item(source .. "/dot_line\nbreak"):find("\n", 1, true))
local before = vim.api.nvim_get_current_buf()
choose(nil)
assert(vim.api.nvim_get_current_buf() == before, "dismissing the picker changed buffers")

picker()
choose(source .. "/dot_a space|name")
assert(vim.api.nvim_buf_get_name(0) == source .. "/dot_a space|name")
assert(package.loaded["vimoi.compare"] == nil, "file browsing loaded views")
picker()
choose(source .. "/dot_line\nbreak")
assert(vim.api.nvim_buf_get_name(0) == source .. "/dot_line\nbreak")

-- Late selections must not replace a different buffer or discard edited text.
picker()
vim.cmd("enew")
before = vim.api.nvim_get_current_buf()
choose(paths[1])
assert(vim.api.nvim_get_current_buf() == before)
picker()
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "unsaved" })
choose(paths[1])
assert(vim.api.nvim_get_current_buf() == before and vim.bo.modified)

local notices = {}
local notify = vim.notify
local function record_notice(message)
  notices[#notices + 1] = message
end
vim.notify = record_notice
vim.opt.hidden = false
picker()
choose(paths[1])
assert(vim.api.nvim_get_current_buf() == before and vim.bo.modified)
assert(notices[#notices]:find("E37", 1, true))
vim.opt.hidden = true

-- Every invocation refreshes the list, with an explicit empty-list message.
vim.fn.writefile({ "new" }, source .. "/dot_new")
picker()
assert(#paths == 5 and vim.tbl_contains(paths, source .. "/dot_new"))
vim.fn.writefile({ "*" }, source .. "/.chezmoiignore")
local count = #notices
api.files()
assert(vim.wait(5000, function()
  return #notices > count
end))
assert(notices[#notices]:find("no managed files", 1, true))
vim.ui.select, vim.notify = original_select, notify
print("files: CLI filtering, literal paths, cancel, fresh lists and native edit protections verified")

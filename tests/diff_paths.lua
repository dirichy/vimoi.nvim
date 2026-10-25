local view_for_buffer = dofile("tests/helpers/view.lua")
local root = vim.fn.getcwd()
local fixture = root .. "/tests/fixtures/environment"
local destination = vim.env.VIMOI_TEST_DESTINATION
local wrapper = fixture .. "/chezmoi-wrapper.sh"
local template_source = fixture .. "/source/dot_diff_target.tmpl"
local template_target = destination .. "/.diff_target"

vim.env.VIMOI_TEST_CONFIG = fixture .. "/empty.toml"
vim.env.VIMOI_TEST_SOURCE = fixture .. "/source"
vim.env.VIMOI_TEST_DESTINATION = destination
vim.opt.swapfile = false
require("vimoi").setup({ chezmoi_executable = wrapper, render = { validate = false } })

vim.cmd("edit " .. vim.fn.fnameescape(template_source))
vim.api.nvim_buf_set_lines(0, 1, 2, false, { "timeout = 19" })
local original_source_buf = vim.api.nvim_get_current_buf()
vim.cmd("VimoiDiff")
dofile("tests/helpers/diff.lua")()
assert(#vim.api.nvim_list_wins() == 2)
assert(assert(view_for_buffer(original_source_buf)).target_buf)
assert(vim.api.nvim_buf_get_name(assert(view_for_buffer(original_source_buf)).target_buf) == template_target)
assert(vim.bo[original_source_buf].filetype == "gotmpl")

vim.cmd("tabnew")
local plain_source = fixture .. "/source/dot_plain"
local plain_target = destination .. "/.plain"
vim.cmd("edit " .. vim.fn.fnameescape(plain_source))
vim.api.nvim_buf_set_lines(0, 0, 1, false, { "plain = unsaved source" })
vim.cmd("VimoiDiff")
dofile("tests/helpers/diff.lua")()
assert(#vim.api.nvim_tabpage_list_wins(0) == 2)
local plain_source_buf = vim.fn.bufnr(plain_source)
local plain_target_buf = vim.fn.bufnr(plain_target)
assert(plain_source_buf >= 0 and plain_target_buf >= 0)
local source_win, target_win
for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
  if vim.api.nvim_win_get_buf(win) == plain_source_buf then
    source_win = win
  elseif vim.api.nvim_win_get_buf(win) == plain_target_buf then
    target_win = win
  end
end
assert(source_win and target_win)
assert(vim.wo[source_win].diff and vim.wo[target_win].diff)
assert(vim.wo[source_win].scrollbind and vim.wo[target_win].scrollbind)
assert(vim.wo[source_win].cursorbind and vim.wo[target_win].cursorbind)
assert(vim.b[plain_source_buf].vimoi_template_language == nil)
assert(vim.api.nvim_buf_get_lines(plain_source_buf, 0, 1, false)[1] == "plain = unsaved source")

vim.cmd("tabnew")
vim.cmd("edit " .. vim.fn.fnameescape(plain_target))
vim.cmd("VimoiDiff")
dofile("tests/helpers/diff.lua")()
assert(#vim.api.nvim_tabpage_list_wins(0) == 2)
for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
  assert(vim.wo[win].diff)
end

-- Filetype detection and diff dispatch agree on extensionless/special templates.
local special_root = vim.fn.tempname()
for _, name in ipairs({ ".chezmoiignore", ".chezmoiremove", ".chezmoiexternal.toml", ".chezmoitemplates/snippet" }) do
  local source = special_root .. "/" .. name
  local target = vim.fn.tempname()
  vim.fn.mkdir(vim.fs.dirname(source), "p")
  vim.fn.writefile({ '{{ "rendered" }}' }, source)
  vim.fn.writefile({ "changed" }, target)
  vim.cmd("tabnew")
  require("vimoi.api").diff_files(source, target)
  dofile("tests/helpers/diff.lua")()
  local session = view_for_buffer(vim.fn.bufnr(source))
  assert(
    session and assert(require("vimoi.render").snapshot(session.source_buf)).output == "rendered\n",
    name .. " opened as plain diff"
  )
end

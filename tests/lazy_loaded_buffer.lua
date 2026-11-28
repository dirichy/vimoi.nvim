-- Late setup attaches existing gotmpl buffers directly, without replaying FileType.
local fixture = vim.fn.getcwd() .. "/tests/fixtures/environment"
vim.env.VIMOI_TEST_CONFIG = fixture .. "/empty.toml"
vim.env.VIMOI_TEST_SOURCE = fixture .. "/source"
local buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(buf)
vim.api.nvim_buf_set_name(buf, fixture .. "/source/dot_diff_target.tmpl")
vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.fn.readfile(fixture .. "/source/dot_diff_target.tmpl"))
local events = 0
vim.api.nvim_create_autocmd("FileType", {
  pattern = "gotmpl",
  callback = function()
    events = events + 1
  end,
})
vim.bo[buf].filetype = "gotmpl"
assert(events == 1)
require("vimoi").setup({
  chezmoi_executable = fixture .. "/chezmoi-wrapper.sh",
  chezmoi_source_dir = fixture .. "/source",
  chezmoi_config_path = fixture .. "/empty.toml",
})
assert(vim.b[buf].vimoi_gf == true)
assert(vim.wait(5000, function()
  local state = require("vimoi.render").get(buf)
  return vim.b[buf].vimoi_template_configured == true and state.map ~= nil and not state.error and not state.request
end))
assert(events == 1, "late setup must not replay FileType")

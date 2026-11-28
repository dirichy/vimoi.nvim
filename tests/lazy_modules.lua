-- Native ftdetect owns registration; on_detect must run before user FileType parsers.
local fixture = vim.fn.getcwd() .. "/tests/fixtures/environment"
local filetype_loaded = package.loaded["vim.filetype"]
local early = 0
vim.api.nvim_create_autocmd("FileType", {
  pattern = "gotmpl",
  callback = function(args)
    early = early + 1
    assert(vim.tbl_contains(vim.treesitter.query.list_directives(), "vimoi-target-language!"))
    vim.treesitter.start(args.buf, "gotmpl")
    assert(vim.treesitter.get_parser(args.buf, "gotmpl")):parse(true)
  end,
})
vim.env.VIMOI_TEST_CONFIG = fixture .. "/empty.toml"
vim.env.VIMOI_TEST_SOURCE = fixture .. "/source"
require("vimoi").setup({
  chezmoi_executable = fixture .. "/chezmoi-wrapper.sh",
  chezmoi_source_dir = fixture .. "/source",
  chezmoi_config_path = fixture .. "/empty.toml",
  diagnostics = { enabled = false },
  highlight = { mode = "injection" },
})
for _, name in ipairs({
  "vimoi.core.watch",
  "vimoi.core.job",
  "vimoi.render",
  "vimoi.render.source_map",
  "vimoi.editor.highlight",
  "vimoi.editor.host_highlight",
}) do
  assert(package.loaded[name] == nil, "blank setup loaded " .. name)
end
assert(package.loaded["vim.filetype"] == filetype_loaded, "setup eagerly loaded Neovim filetype tables")
vim.cmd("filetype plugin on")
local source = fixture .. "/source/dot_diff_target.tmpl"
local ft, on_detect = vim.filetype.match({ filename = source })
assert(ft == "gotmpl" and type(on_detect) == "function")
assert(package.loaded["vimoi.editor.highlight"] == nil, "classification must not initialize highlighting")
vim.api.nvim_set_hl(0, "VimoiTemplateAction", { bg = "#123456" })
vim.cmd.edit(vim.fn.fnameescape(source))
assert(early == 1, "native detection must emit FileType once")
assert(vim.wait(1000, function()
  return vim.b.vimoi_template_configured == true
end))
assert(vim.api.nvim_get_hl(0, { name = "VimoiTemplateAction", link = false }).bg == 0x123456)
assert(package.loaded["vimoi.core.job"] and package.loaded["vimoi.editor.highlight"])
assert(package.loaded["vimoi.render"] == nil and package.loaded["vimoi.editor.host_highlight"] == nil)

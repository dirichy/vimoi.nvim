---@diagnostic disable: duplicate-set-field -- Count real subprocesses across startup and source activation.
vim.cmd("filetype plugin on")
local fixture = vim.fn.getcwd() .. "/tests/fixtures/environment"
local source = fixture .. "/source"
vim.env.VIMOI_TEST_CONFIG = fixture .. "/empty.toml"
vim.env.VIMOI_TEST_SOURCE = source
local calls = {}
local new_fs_event, handles = vim.uv.new_fs_event, 0
vim.uv.new_fs_event = function(...)
  handles = handles + 1
  return new_fs_event(...)
end
local system = vim.system
vim.system = function(argv, ...)
  assert(argv[2] == "--config" and argv[4] == "--source" and argv[5] == source)
  assert(argv[6] ~= "source-path", "configured source paths must never be queried")
  calls[argv[6]] = (calls[argv[6]] or 0) + 1
  return system(argv, ...)
end
require("vimoi").setup({
  chezmoi_source_dir = source,
  chezmoi_config_path = fixture .. "/empty.toml",
  chezmoi_executable = fixture .. "/chezmoi-wrapper.sh",
  diagnostics = { enabled = false },
  highlight = { mode = "disabled" },
})
assert(next(calls) == nil and handles == 0, "setup must not start processes or filesystem watches")
assert(package.loaded["vimoi.core.cli"] and not package.loaded["vimoi.render"])
assert(not package.loaded["vimoi.core.watch"] and not package.loaded["vimoi.editor.highlight"])
assert(vim.fn.exists(":VimoiToggle") == 2)
assert(vim.filetype.match({ filename = source .. "/dot_diff_target.tmpl" }) == "gotmpl")
assert(next(calls) == nil, "filename classification must not invoke chezmoi")
vim.cmd.edit(vim.fn.fnameescape(source .. "-other/dot_plain"))
assert(next(calls) == nil and handles == 0, "opening a sibling directory must not start queries or watches")
vim.cmd.edit(vim.fn.fnameescape(source .. "/dot_plain"))
assert(calls["execute-template"] == nil and calls["target-path"] == 1 and handles > 0)
local active_handles = handles
assert(package.loaded["vimoi.core.watch"] and not package.loaded["vimoi.render"])
vim.cmd.edit(vim.fn.fnameescape(source .. "/dot_diff_target.tmpl"))
assert(vim.wait(1000, function()
  return vim.b.vimoi_template_configured == true
end))
assert(vim.bo.filetype == "gotmpl" and vim.b.vimoi_gf == true)
assert(
  calls["execute-template"] == nil and calls["target-path"] == 1,
  "source opens must reuse the existing path cache"
)
local destination = require("vimoi.api").toggle()
assert(destination == vim.env.VIMOI_TEST_DESTINATION .. "/.diff_target")
assert(calls["execute-template"] == nil and calls["target-path"] == 1)
assert(handles == active_handles, "cache hits must not rebuild watchers")
vim.uv.new_fs_event = new_fs_event
vim.system = system

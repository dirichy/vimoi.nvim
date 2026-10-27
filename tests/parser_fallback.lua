---@diagnostic disable: duplicate-set-field -- Exercise the real missing-gotmpl path without disabling host parsers.
local renderer = require("vimoi.render.source_map")
local await = dofile("tests/helpers/await.lua")
local root = vim.fn.tempname()
vim.fn.mkdir(root .. "/source/.chezmoitemplates", "p")
vim.fn.mkdir(root .. "/target", "p")
vim.fn.writefile({ "external={{ .enabled }}" }, root .. "/source/.chezmoitemplates/external")
vim.fn.writefile({
  "sourceDir = " .. vim.json.encode(root .. "/source"),
  "destDir = " .. vim.json.encode(root .. "/target"),
  "[data]",
  "enabled = true",
}, root .. "/config.toml")
require("vimoi").setup({ chezmoi_config_path = root .. "/config.toml", diagnostics = { host = false } })
local corpus = dofile("tests/fixtures/sentinel_cases.lua")
local expected = {}
for index, case in ipairs(corpus) do
  expected[index] = assert(await(renderer.trace, case[2], case[3]))
end
local get_parser, get_string_parser = vim.treesitter.get_parser, vim.treesitter.get_string_parser
local add_language = vim.treesitter.language.add
vim.treesitter.get_parser = function(buf, language, ...)
  if language == "gotmpl" then
    return nil
  end
  return get_parser(buf, language, ...)
end
vim.treesitter.get_string_parser = function(text, language, ...)
  if language == "gotmpl" then
    return nil
  end
  return get_string_parser(text, language, ...)
end
vim.treesitter.language.add = function(language, ...)
  if language == "gotmpl" then
    return nil, "test: no gotmpl parser"
  end
  return add_language(language, ...)
end
for index, case in ipairs(corpus) do
  local actual = assert(await(renderer.trace, case[2], case[3]))
  assert(vim.deep_equal(actual, expected[index]), vim.inspect({ case[1], actual, expected[index] }))
end
-- Reuse the independent chezmoi oracle for escaped/static write-back candidates.
dofile("tests/static_merge_inference.lua")

local api, util = require("vimoi.api"), require("vimoi.core.util")
local views = require("vimoi.compare")
local source = vim.api.nvim_create_buf(true, false)
local target = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(source)
util.set_buffer_text(source, 'local value = {{ "1" }}\nlocal count = 2\n')
util.set_buffer_text(target, "local value = 1\nlocal count = 3\n")
api.diff_buffers(source, target, { filetype = "lua" })
local view = assert(views.by_window[vim.api.nvim_get_current_win()])
assert(vim.wait(5000, function()
  return not view.loading
end))
assert(views.is_valid(view))
assert(require("vimoi.render").get(source).root == nil, "fallback must not emulate a Tree-sitter node")
assert(vim.bo[source].filetype == "gotmpl" and vim.bo[source].syntax == "gotmpl")
local result = assert(api.readd())
assert(result.merged == 1 and result.skipped == 0)
assert(util.buffer_text(source) == 'local value = {{ "1" }}\nlocal count = 3\n')
views.close(view)
vim.api.nvim_set_current_buf(source)
api.preview()
local preview = assert(dofile("tests/helpers/view.lua")(source))
assert(vim.wait(5000, function()
  return not preview.loading
end))
assert(not preview.preview_error, preview.preview_error)
assert(util.buffer_text(preview.target_buf) == "local value = 1\nlocal count = 3\n")

util.set_buffer_text(source, "header\n{{ index (list 1) 5 }}\n")
vim.api.nvim_exec_autocmds("TextChanged", { buffer = source })
assert(vim.wait(5000, function()
  return require("vimoi.render").get(source).error ~= nil
end))
local diagnostics = vim.diagnostic.get(source, { namespace = vim.api.nvim_create_namespace("vimoi-diagnostics") })
assert(#diagnostics == 1 and diagnostics[1].message:find("index out of range", 1, true), vim.inspect(diagnostics))
assert(diagnostics[1].lnum == 1 and diagnostics[1].col == 3, vim.inspect(diagnostics))
-- The collector accepts boundaries; chezmoi still rejects an invalid control expression.
util.set_buffer_text(source, "{{ if true }}")
vim.api.nvim_exec_autocmds("TextChanged", { buffer = source })
assert(vim.wait(5000, function()
  local err = require("vimoi.render").get(source).error
  return err ~= nil and err:find("EOF", 1, true) ~= nil
end))
util.set_buffer_text(source, 'recovered {{ "output" }}')
vim.api.nvim_exec_autocmds("TextChanged", { buffer = source })
assert(vim.wait(5000, function()
  return util.buffer_text(preview.target_buf) == "recovered output" and not preview.preview_error
end))
views.close(preview)
vim.treesitter.get_parser, vim.treesitter.get_string_parser = get_parser, get_string_parser
vim.treesitter.language.add = add_language
vim.fn.delete(root, "rf")
print(("experimental fallback: %d render traces, diff/readd, preview and errors/recovery verified"):format(#corpus))

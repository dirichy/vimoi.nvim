---@diagnostic disable: duplicate-set-field -- Count completion dependencies in an isolated Neovim.
local api = vim.api
local fixture = vim.fn.getcwd() .. "/tests/fixtures/environment"
vim.env.VIMOI_TEST_CONFIG = fixture .. "/empty.toml"
vim.env.VIMOI_TEST_SOURCE = fixture .. "/source"
require("vimoi").setup({ chezmoi_executable = fixture .. "/chezmoi-wrapper.sh" })
local cli = require("vimoi.core.cli")
local source = require("vimoi.blink").new()
local buf = api.nvim_create_buf(false, true)
api.nvim_set_current_buf(buf)
vim.bo[buf].filetype = "gotmpl"
local reads, requests, copies = 0, 0, 0
local get_lines, deepcopy = api.nvim_buf_get_lines, vim.deepcopy
api.nvim_buf_get_lines = function(b, first, last, ...)
  if b == buf and first == 0 and last == -1 then
    reads = reads + 1
  end
  return get_lines(b, first, last, ...)
end
vim.deepcopy = function(value, ...)
  copies = copies + 1
  return deepcopy(value, ...)
end
local data =
  { chezmoi = { sourceDir = cli.source_root, destDir = vim.env.VIMOI_TEST_DESTINATION }, name = "demo", huge = {} }
for i = 1, 10000 do
  data.huge[i] = { value = i }
end
cli.data_async = function(done)
  requests = requests + 1
  done(data)
end
local function complete(text)
  local lines = vim.split(text, "\n", { plain = true })
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  local result
  reads, requests, copies = 0, 0, 0
  source:get_completions({ bufnr = buf, cursor = { #lines, #lines[#lines] } }, function(r)
    result = r.items
  end)
  assert(vim.wait(1000, function()
    return result ~= nil
  end))
  return result
end
local bad = {}
for _, text in ipairs({
  '{{ printf ".na',
  '{{ printf "$na',
  '{{ printf "if',
  "{{ printf `foo .na",
  '{{ printf "include \\"pay',
}) do
  if #complete(text) > 0 then
    bad[#bad + 1] = text
  end
end
local fields = complete("{{\n .na")
local field_reads, field_copies = reads, copies
complete('{{ printf "hello')
local unused_requests = requests
print(vim.json.encode({
  string_false_positives = bad,
  field_full_reads = field_reads,
  field_deepcopies = field_copies,
  unneeded_requests = unused_requests,
}))
assert(#bad == 0, "completion leaked into quoted strings")
assert(#fields == 1 and fields[1].label == "name")
assert(field_reads == 0 and field_copies == 0, "field completion copied/read unrelated data")
assert(unused_requests == 0, "ordinary string requested data")
local first = complete("{{ incl")
first[1].label = "changed by consumer"
assert(complete("{{ incl")[1].label ~= "changed by consumer", "static candidates shared mutable responses")
print("completion audit: quoted strings, bounded reads, copy isolation and data request routing verified")

complete('{{ include "pay')
assert(requests == 0, "include path requested data")
complete('{{ template "sni')
assert(requests == 0, "template path requested data")
local parser = vim.treesitter.get_parser
vim.treesitter.get_parser = function()
  return nil
end
for _, text in ipairs({ '{{ printf "{{ .na', '{{ printf "}} .na', "{{/* if" }) do
  assert(#complete(text) == 0, text)
  assert(requests == 0)
end
vim.treesitter.get_parser = parser
local overlay = cli.data_for_completion(data, buf)
assert(overlay ~= data and overlay.huge == data.huge)
local counterpart = cli.counterpart_path
cli.counterpart_path = function()
  return "/tmp/vimoi-audit-target"
end
api.nvim_buf_set_name(buf, cli.source_root .. "/dot_audit.tmpl")
local managed = cli.data_for_completion(data, buf)
assert(managed.chezmoi ~= data.chezmoi and managed.huge == data.huge)
assert(managed.chezmoi.command == "cat" and managed.chezmoi.sourceFile == "dot_audit.tmpl")
assert(data.chezmoi.command == nil and data.chezmoi.sourceFile == nil)
cli.counterpart_path = counterpart

-- Unlike a current-window-only probe, Blink's supplied buffer/cursor is authoritative.
local other = api.nvim_create_buf(false, true)
api.nvim_set_current_buf(other)
local noncurrent = complete('{{ printf "}}" .na')
assert(#noncurrent == 1 and noncurrent[1].label == "name")
assert(noncurrent[1].textEdit.range.start.line == 0)
assert(noncurrent[1].textEdit.range.start.character == #'{{ printf "}}" .')
assert(#complete("{{ include `pay") > 0 and requests == 0)
vim.treesitter.get_parser = function()
  return nil
end
local fallback = complete('{{ printf "}}" .na')
assert(#fallback == 1 and fallback[1].label == "name")
assert(#complete('{{- include "pay') > 0 and requests == 0)
vim.treesitter.get_parser = parser
api.nvim_set_current_buf(buf)
print("reference review: noncurrent buffers, closed strings and path-string exceptions verified")

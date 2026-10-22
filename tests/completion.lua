vim.opt.runtimepath:prepend(vim.fn.getcwd())

local root = vim.fn.getcwd()
local fixture = root .. "/tests/fixtures/environment"
vim.env.VIMOI_TEST_CONFIG = fixture .. "/empty.toml"
vim.env.VIMOI_TEST_SOURCE = fixture .. "/source"

local api = require("vimoi.api")
api.setup({ chezmoi_executable = fixture .. "/chezmoi-wrapper.sh" })
local source = require("vimoi.blink").new()
require("vimoi.cli").invalidate()

local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_win_set_buf(0, buf)
vim.bo[buf].filetype = "gotmpl"

local function labels(line)
  local lines = vim.split(line, "\n", { plain = true })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  local result
  source:get_completions({ bufnr = buf, cursor = { #lines, #lines[#lines] } }, function(response)
    assert(not response.is_incomplete_forward and not response.is_incomplete_backward)
    result = response.items
  end)
  assert(
    vim.wait(5000, function()
      return result ~= nil
    end),
    "completion timed out"
  )
  local found = {}
  for _, item in ipairs(result) do
    found[item.label] = item
  end
  return found
end

local Kind = vim.lsp.protocol.CompletionItemKind
assert(labels("{{ if")["if"].kind == Kind.Keyword)
assert(labels("{{ templ").template.kind == Kind.Keyword)
assert(labels("{{ incl").include.kind == Kind.Function)
assert(labels("{{ includeT").includeTemplate.kind == Kind.Function)
assert(labels("{{ quo").quote.kind == Kind.Function)
assert(labels("{{ quoteL").quoteList.kind == Kind.Function)
assert(labels("{{ .chezmoi.ho").homeDir.kind == Kind.Field)
assert(labels('{{ include "pay')["payload.txt"].kind == Kind.File)
assert(labels('{{ include ".')[".chezmoitemplates/"].kind == Kind.Folder)
assert(labels('{{ template "sni').snippet.kind == Kind.File)
assert(vim.tbl_isempty(labels("plain text")))

-- Outside actions, complete whole blocks as native LSP snippets.
local snippet_items = labels("")
for _, name in ipairs({ "if", "ifelse", "range", "with", "define", "block", "comment" }) do
  local item = assert(snippet_items[name], name)
  assert(item.kind == Kind.Snippet and item.insertTextFormat == vim.lsp.protocol.InsertTextFormat.Snippet)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "  " })
  vim.api.nvim_win_set_cursor(0, { 1, 2 })
  vim.snippet.expand(item.textEdit.newText)
  local tree = assert(vim.treesitter.get_parser(buf, "gotmpl")):parse(true)[1]
  assert(not tree:root():has_error(), name .. " expanded to invalid template syntax")
  assert(not table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"):find("${", 1, true))
  vim.snippet.stop()
end
local if_snippet = labels("  if")["if"]
assert(if_snippet.textEdit.range.start.character == 2 and if_snippet.textEdit.range["end"].character == 4)
assert(labels("{{ end }} if")["if"].kind == Kind.Snippet)
assert(vim.tbl_isempty(labels("{{/* if")), "snippets appeared inside a template comment")
assert(vim.tbl_isempty(labels('{{ printf "if')), "snippets appeared inside an action string")

-- Incomplete multiline actions and braces inside strings are still actions.
assert(labels("{{\n .chezmoi.ho").homeDir)
assert(labels('{{ printf "}}" .chezmoi.ho').homeDir)
assert(labels('{{ include\n "pay')["payload.txt"])
assert(vim.tbl_isempty(labels("{{/* comment .chezmoi.ho */}}")))
assert(not labels("{{ $x := $reference }}{{ $ref")["$reference"])
assert(not labels("{{ if true }}{{ $hidden := 1 }}{{ end }}{{ $hid")["$hidden"])
assert(not labels("{{ if true }}{{ $branch := 1 }}{{ else }}{{ $bra")["$branch"])
assert(labels("{{ if $condition := true }}{{ else }}{{ $con")["$condition"])
assert(labels("{{ range $i, $value := . }}{{ $val")["$value"])
assert(not labels('{{ $outer := . }}{{ define "inner" }}{{ $out')["$outer"])
assert(labels("{{ $outer := . }}{{ with . }}{{ $out")["$outer"])

vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
  "{{ $path := .chezmoi.homeDir }}",
  "{{ $pa",
})
local variables
source:get_completions({ bufnr = buf, cursor = { 2, 7 } }, function(response)
  variables = response.items
end)
assert(vim.wait(5000, function()
  return variables ~= nil
end))
assert(variables[1].label == "$path")
assert(variables[1].kind == Kind.Variable)

-- Editing a declaration must not make that incomplete declaration complete
-- itself. Variables declared before it remain available.
vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
  "{{ $path := .chezmoi.homeDir }}",
  "{{ $partial := $path }}",
})
local declaration_items
source:get_completions({ bufnr = buf, cursor = { 2, 5 } }, function(response)
  declaration_items = response.items
end)
assert(vim.wait(5000, function()
  return declaration_items ~= nil
end))
local declaration_labels = {}
for _, item in ipairs(declaration_items) do
  declaration_labels[item.label] = true
end
assert(not declaration_labels["$partial"])
assert(declaration_labels["$path"])

assert(source:enabled())
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "{{ incl" })
local response
source:get_completions({ bufnr = buf, cursor = { 1, 7 } }, function(value)
  response = value
end)
assert(vim.wait(5000, function()
  return response ~= nil
end))
assert(#response.items > 0)

-- Cancel one pending request without suppressing another request sharing the data lookup.
local cli = require("vimoi.cli")
cli.invalidate("data")
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "{{ .chezmoi.ho" })
local cancelled_called = false
local live_response
local cancel = source:get_completions({ bufnr = buf, cursor = { 1, 13 } }, function()
  cancelled_called = true
end)
source:get_completions({ bufnr = buf, cursor = { 1, 13 } }, function(value)
  live_response = value
end)
cancel()
assert(vim.wait(5000, function()
  return live_response ~= nil
end))
assert(not cancelled_called and #live_response.items > 0)

-- Invalidating an in-flight lookup yields an empty response, preserving the blink callback contract.
cli.invalidate("data")
local invalidated_response
source:get_completions({ bufnr = buf, cursor = { 1, 13 } }, function(value)
  invalidated_response = value
end)
cli.invalidate("data")
assert(vim.wait(5000, function()
  return invalidated_response ~= nil
end))
assert(#invalidated_response.items == 0)

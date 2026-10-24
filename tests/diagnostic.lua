---@diagnostic disable: duplicate-set-field -- Observe diagnostic publications and real CLI executions.
local fixture = vim.fn.getcwd() .. "/tests/fixtures/environment"
vim.env.VIMOI_TEST_CONFIG = fixture .. "/empty.toml"
vim.env.VIMOI_TEST_SOURCE = fixture .. "/source"
vim.opt.swapfile = false
require("vimoi").setup({ chezmoi_executable = fixture .. "/chezmoi-wrapper.sh" })
assert(require("vimoi").config.diagnostics.enabled, "diagnostics must default to enabled")
local cli, util = require("vimoi.cli"), require("vimoi.util")
local namespace = vim.api.nvim_create_namespace("vimoi-diagnostics")
local runs, publications = 0, 0
local original_run, original_set = cli.run, vim.diagnostic.set
local last_args
cli.run = function(args, opts)
  if args[1] == "execute-template" then
    runs, last_args = runs + 1, args
  end
  return original_run(args, opts)
end
vim.diagnostic.set = function(ns, ...)
  if ns == namespace then
    publications = publications + 1
  end
  return original_set(ns, ...)
end
local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(buf)
vim.api.nvim_buf_set_name(buf, vim.fn.tempname() .. ".yaml.tmpl")
vim.bo[buf].filetype = "gotmpl"
local function change(text, event)
  local before = publications
  util.set_buffer_text(buf, text)
  vim.api.nvim_exec_autocmds(event or "TextChangedI", { buffer = buf })
  assert(
    vim.wait(5000, function()
      return publications > before
    end, 5),
    "diagnostic was not published"
  )
  return vim.diagnostic.get(buf, { namespace = namespace })
end

-- Parser errors have source ranges immediately and need no external process.
local diagnostics = change("head\n{{ if true }}\nbody\n")
assert(#diagnostics > 0 and runs == 0)
assert(diagnostics[1].source == "vimoi" and diagnostics[1].severity == vim.diagnostic.severity.ERROR)
assert(diagnostics[1].message:sub(1, 9) == "[gotmpl] ")

-- Host-language syntax errors are outside this namespace; plain literal text
-- needs no process and clears the preceding template syntax error.
diagnostics = change("broken_yaml: [\n")
assert(#diagnostics == 0 and runs == 0)

-- Neovim uses TextChangedP while its native completion popup is visible.
-- A previously valid buffer must gain diagnostics on this editing path too.
diagnostics = change("{{ if true }}", "TextChangedP")
assert(#diagnostics > 0 and runs == 0)
diagnostics = change("literal again\n", "TextChangedP")
assert(#diagnostics == 0 and runs == 0)

-- A zero-based Go byte column is mapped through the exact tag's skeleton offset.
local source = "title: 中文\n{{ if true }}\n键: {{ index (list 1) 5 }}\n{{ end }}\n"
diagnostics = change(source)
assert(#diagnostics == 1 and runs == 1, vim.inspect(diagnostics))
assert(diagnostics[1].lnum == 2 and diagnostics[1].col == #"键: {{ ", vim.inspect(diagnostics))
assert(diagnostics[1].message:find("index out of range", 1, true))
assert(diagnostics[1].message:sub(1, 9) == "[gotmpl] ")
local before = runs
diagnostics = change("# added\n# another\n" .. source:gsub("title: 中文", "title: 更长的静态文本"))
assert(runs == before, "static edits must reuse cached failures")
assert(diagnostics[1].lnum == 4 and diagnostics[1].col == #"键: {{ ")

-- Multiline tags retain their internal line/column offsets, including UTF-8.
diagnostics = change('header\n{{ printf "中文" |\n index (list 1) 5\n}}\n')
assert(#diagnostics == 1 and diagnostics[1].lnum == 2 and diagnostics[1].col == 1, vim.inspect(diagnostics))

-- Undefined functions have only a line number. Do not match quoted names in
-- preceding tags, even when all those tags share one skeleton line.
diagnostics = change('{{ printf "notAFunction" }}\n{{ if true }}\n{{ notAFunction . }}\n{{ end }}\n')
assert(#diagnostics == 1 and diagnostics[1].lnum == 2 and diagnostics[1].col == 3, vim.inspect(diagnostics))
assert(diagnostics[1].message:find('function "notAFunction" not defined', 1, true))
diagnostics = change('{{ printf "ok" }}\n{{ $missing }}\n')
assert(#diagnostics == 1 and diagnostics[1].lnum == 1, vim.inspect(diagnostics))

-- Opaque bodies still retain exact internal runtime and parse-error locations.
for _, keyword in ipairs({ "define", "block" }) do
  local argument = keyword == "block" and " ." or ""
  local opening = "{{ " .. keyword .. ' "item"' .. argument .. " }}"
  local ending = '\n{{ end }}\n{{ template "item" . }}\n'
  diagnostics = change("header\n" .. opening .. "\n键: {{ index (list 1) 5 }}" .. ending)
  assert(#diagnostics == 1 and diagnostics[1].lnum == 2 and diagnostics[1].col == #"键: {{ ", vim.inspect(diagnostics))
  diagnostics = change("header\n" .. opening .. "\n{{ notAFunction . }}" .. ending)
  assert(#diagnostics == 1 and diagnostics[1].lnum == 2 and diagnostics[1].col == 3, vim.inspect(diagnostics))
end

-- Recovery clears errors. Repeated/trimmed literal changes reuse successes.
diagnostics = change("{{ range (list 1 2) -}}\n item={{ . }}\n{{- end }}\n")
assert(#diagnostics == 0)
before = runs
diagnostics = change("{{ range (list 1 2) -}}\n longer item={{ . }}\n{{- end }}\n")
assert(#diagnostics == 0 and runs == before)

-- Dependency invalidation rechecks without a buffer edit; path-only invalidation does not.
local runs_before_invalidation = runs
before = publications
cli.invalidate("templates")
assert(vim.wait(5000, function()
  return publications > before
end, 5))
assert(runs == runs_before_invalidation + 1)
local after_invalidation = runs
assert(after_invalidation > 0)
local processed = false
cli.invalidate("paths")
vim.defer_fn(function()
  processed = true
end, 400)
assert(vim.wait(1000, function()
  return processed
end, 5))
assert(runs == after_invalidation)

-- Init-only functions are checked with --init, without prompting in a false branch.
vim.api.nvim_buf_set_name(buf, vim.fn.tempname() .. "/.chezmoi.toml.tmpl")
diagnostics = change('{{ if false }}{{ promptStringOnce . "key" "Question" }}{{ end }}\n')
assert(#diagnostics == 0 and last_args[2] == "--init")

-- Disable at runtime clears this namespace and detaches future buffers.
require("vimoi").setup({ diagnostics = { enabled = false }, highlight = { mode = "disabled" } })
assert(#vim.diagnostic.get(buf, { namespace = namespace }) == 0)
before = runs
util.set_buffer_text(buf, "{{ invalidAfterDisable . }}")
vim.api.nvim_exec_autocmds("TextChangedI", { buffer = buf })
processed = false
vim.defer_fn(function()
  processed = true
end, 400)
assert(vim.wait(1000, function()
  return processed
end, 5))
assert(runs == before and #vim.diagnostic.get(buf, { namespace = namespace }) == 0)

-- Re-enable attaches buffers that were already open.
before = publications
require("vimoi").setup({ diagnostics = { enabled = true } })
assert(vim.wait(5000, function()
  return publications > before
end, 5))
assert(#vim.diagnostic.get(buf, { namespace = namespace }) == 1)
vim.api.nvim_buf_delete(buf, { force = true })
cli.run, vim.diagnostic.set = original_run, original_set
print(
  "diagnostics: syntax/runtime positions, UTF-8, multiline tags, cache, dependencies, init and configuration verified"
)

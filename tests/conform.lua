---@diagnostic disable: duplicate-set-field -- Simulate a missing parser without hiding production diagnostics.
local formatter = require("vimoi.conform")
local util = require("vimoi.core.util")
assert(not package.loaded.conform, "loading the adapter must not require Conform")
local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(buf)
vim.bo[buf].filetype = "gotmpl"
vim.bo[buf].shiftwidth = 2
local source = "{{if true}}\ntext\n{{range (list 1)}}\nvalue={{ . }}\n{{end}}\n{{end}}"
local expected = "{{ if true}}\ntext\n{{   range (list 1)}}\nvalue={{ . }}\n{{   end}}\n{{ end}}"
local trimmed = "\t{{- if true }}\ntext\n{{-   range (list 1) }}\nvalue={{ . }}\n{{-   end }}\n {{- end }}"
local trimmed_expected = "{{- if true }}\ntext\n  {{- range (list 1) }}\nvalue={{ . }}\n  {{- end }}\n{{- end }}"
local indented = "{{if true}}\n {{range (list 1)}}\nvalue={{ . }}\n\t{{end}}\n{{end}}"
local indented_expected = "{{ if true}}\n {{  range (list 1)}}\nvalue={{ . }}\n\t{{ end}}\n{{ end}}"
local actions = '{{if true}}prefix\n{{$x := "ok"}} suffix\n{{$x}}tail{{"untouched"}}\n{{end}}suffix'
local actions_expected = '{{ if true}}prefix\n{{   $x := "ok"}} suffix\n{{   $x}}tail{{"untouched"}}\n{{ end}}suffix'
util.set_buffer_text(buf, "unrelated buffer text")
local tick = vim.api.nvim_buf_get_changedtick(buf)
for _, case in ipairs({
  { source, expected },
  { trimmed, trimmed_expected },
  { indented, indented_expected },
  { actions, actions_expected },
}) do
  for _, suffix in ipairs({ "", "\n", "\n\n" }) do
    local lines = vim.split(case[1] .. suffix, "\n", { plain = true })
    local original = vim.deepcopy(lines)
    local calls = 0
    formatter.format(formatter, { shiftwidth = 2, buf = buf }, lines, function(err, result)
      calls = calls + 1
      assert(not err, err)
      assert(table.concat(assert(result), "\n") == case[2] .. suffix)
    end)
    assert(calls == 1 and vim.deep_equal(lines, original))
    assert(vim.api.nvim_buf_get_changedtick(buf) == tick, "adapter changed the buffer")
  end
end
-- Tab display width must come from ctx.buf, not whichever buffer is current.
local context_buf = vim.api.nvim_create_buf(false, true)
vim.bo[context_buf].tabstop = 8
vim.bo[context_buf].vartabstop = "3,5"
local context_calls = 0
formatter.format(formatter, { shiftwidth = 4, buf = context_buf }, {
  "{{if true}}",
  "\t{{range (list 1)}}",
  "\t{{end}}",
  "{{end}}",
}, function(err, result)
  context_calls = context_calls + 1
  assert(not err, err)
  assert(table.concat(assert(result), "\n") == "{{ if true}}\n\t{{  range (list 1)}}\n\t{{  end}}\n{{ end}}")
end)
assert(context_calls == 1 and vim.api.nvim_buf_get_changedtick(buf) == tick)
local function expect_error(source_text, message)
  local calls = 0
  formatter.format(formatter, { shiftwidth = 2, buf = buf }, { source_text }, function(err, result)
    calls = calls + 1
    assert(err and err:find(message, 1, true) and not result, tostring(err))
  end)
  assert(calls == 1 and vim.api.nvim_buf_get_changedtick(buf) == tick)
end
expect_error("{{if}}", "parse errors")
local get_parser = vim.treesitter.get_string_parser
vim.treesitter.get_string_parser = function()
  error("missing parser")
end
expect_error(source, "requires the gotmpl")
vim.treesitter.get_string_parser = get_parser

-- Optional real integration: VIMOI_TEST_CONFORM=/path/to/conform.nvim.
-- The core suite tests the callback contract without making Conform mandatory.
if not vim.env.VIMOI_TEST_CONFORM then
  print("Conform adapter: snapshot input, no mutation, newline preservation and error callbacks verified")
  return
end
vim.opt.runtimepath:append(vim.env.VIMOI_TEST_CONFORM)
---@type { setup: fun(opts: table), format: fun(opts: table, callback: fun(err: string?, changed: boolean?)): boolean }
local conform = require("conform")
conform.setup({
  formatters_by_ft = { gotmpl = { "vimoi" } },
  formatters = {
    vimoi = formatter,
    wrap = {
      inherit = false,
      format = function(_, _, lines, callback)
        local wrapped = vim.list_extend({ "{{if true}}" }, lines)
        wrapped[#wrapped + 1] = "{{end}}"
        callback(nil, wrapped)
      end,
    },
  },
  format_on_save = function(buffer)
    if vim.b[buffer].test_format_on_save then
      return { lsp_format = "never" }
    end
  end,
  notify_on_error = false,
})
local function format(opts)
  local finished, error_message, changed = false, nil, nil
  assert(
    conform.format(vim.tbl_extend("force", { quiet = true, lsp_format = "never" }, opts or {}), function(err, did_edit)
      error_message, changed, finished = err, did_edit, true
    end)
  )
  assert(vim.wait(2000, function()
    return finished
  end))
  return error_message, changed
end

for _, case in ipairs({
  { source, expected },
  { trimmed, trimmed_expected },
  { indented, indented_expected },
  { actions, actions_expected },
}) do
  for _, suffix in ipairs({ "", "\n", "\n\n" }) do
    util.set_buffer_text(buf, case[1] .. suffix)
    assert(not format({ dry_run = true }))
    assert(util.buffer_text(buf) == case[1] .. suffix, "dry run changed text")
    assert(not format({ async = true }))
    assert(util.buffer_text(buf) == case[2] .. suffix)
    local err, changed = format()
    assert(not err and not changed, "formatting must be idempotent")
  end
end

util.set_buffer_text(buf, source)
assert(not format({ range = { start = { 3, 0 }, ["end"] = { 3, 20 } } }))
assert(util.buffer_text(buf) == source:gsub("{{range", "{{   range"), "range formatting changed other lines")
util.set_buffer_text(buf, trimmed)
assert(not format({ range = { start = { 3, 0 }, ["end"] = { 3, 24 } } }))
assert(
  util.buffer_text(buf) == "\t{{- if true }}\ntext\n  {{- range (list 1) }}\nvalue={{ . }}\n{{-   end }}\n {{- end }}"
)

-- Conform must pass the preceding formatter's result, rather than rereading buf.
util.set_buffer_text(buf, "{{range (list 1)}}\n{{end}}")
assert(not format({ formatters = { "wrap", "vimoi" } }))
assert(util.buffer_text(buf) == "{{ if true}}\n{{   range (list 1)}}\n{{   end}}\n{{ end}}")

util.set_buffer_text(buf, "{{if}}")
local err, changed = format()
assert(err and not changed and util.buffer_text(buf) == "{{if}}", tostring(err))
local path = vim.fn.tempname() .. ".tmpl"
vim.api.nvim_buf_set_name(buf, path)
vim.bo[buf].buftype = ""
vim.b[buf].test_format_on_save = true
util.set_buffer_text(buf, source .. "\n")
vim.cmd.write()
assert(table.concat(vim.fn.readfile(path), "\n") .. "\n" == expected .. "\n")
vim.fn.delete(path)
print("Conform integration: dry run, async, range, chained formatters, errors, newlines and format on save verified")

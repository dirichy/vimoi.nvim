---@diagnostic disable: duplicate-set-field -- Observe errors and simulate a missing optional parser.
local api = require("vimoi.api")
local util = require("vimoi.core.util")
local run_async = dofile("tests/helpers/await.lua")
local cli = require("vimoi.core.cli")
local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(buf)
vim.bo[buf].shiftwidth = 2
vim.bo[buf].swapfile = false

local function check(source, expected)
  util.set_buffer_text(buf, source)
  local changed = api.format()
  assert(changed == (source ~= expected))
  assert(util.buffer_text(buf) == expected, vim.inspect({ actual = util.buffer_text(buf), expected = expected }))
  assert(api.format(buf) == false, "formatting must be idempotent")
  local before, err = run_async(cli.execute_template, source, { cache = false })
  assert(before, err)
  local after, after_error = run_async(cli.execute_template, expected, { cache = false })
  assert(after, after_error)
  assert(before == after, "formatting changed rendered output")
end

-- Exercise every branch and empty/repeated loops with an independent real renderer.
for _, condition in ipairs({ "true", "false" }) do
  for _, other in ipairs({ "true", "false" }) do
    for _, items in ipairs({ "(list)", '(list "甲" "乙")' }) do
      local source = "{{if "
        .. condition
        .. "}}\n"
        .. "{{range "
        .. items
        .. "}}\n"
        .. "{{if true}}\nvalue={{ . }}\n{{else}}\nunused\n{{end}}\n"
        .. "{{else}}\nempty\n{{end}}\n"
        .. "{{else if "
        .. other
        .. "}}\n"
        .. '{{with "fallback"}}\n{{ . }}\n{{end}}\n{{else}}\nnone\n{{end}}\n'
      local expected = "{{ if "
        .. condition
        .. "}}\n"
        .. "{{   range "
        .. items
        .. "}}\n"
        .. "{{     if true}}\nvalue={{ . }}\n{{     else}}\nunused\n{{     end}}\n"
        .. "{{   else}}\nempty\n{{   end}}\n"
        .. "{{ else if "
        .. other
        .. "}}\n"
        .. '{{   with "fallback"}}\n{{     . }}\n{{   end}}\n{{ else}}\nnone\n{{ end}}\n'
      check(source, expected)
    end
  end
end

check(
  "外部空白 \t\n  {{-\tif true -}}\n\t{{- range (list 1 2) }}\n值={{ . }}\n{{- end -}}\n {{- end }}  \n尾\n",
  "外部空白 \t\n{{- if true -}}\n  {{- range (list 1 2) }}\n值={{ . }}\n  {{- end -}}\n{{- end }}  \n尾\n"
)
-- Left trim permits external indentation; right trim alone does not. Preserve
-- existing external whitespace on non-left-trim tags, and never change newlines.
check(
  " \t{{- if true }}\n\t{{ range (list 1) -}}\n{{-     if true }}\nvalue\n {{-     else }}\nunused\n{{-     end }}\n \t{{ end -}}\n\t{{- end }}",
  "{{- if true }}\n\t{{ range (list 1) -}}\n    {{- if true }}\nvalue\n    {{- else }}\nunused\n    {{- end }}\n \t{{ end -}}\n{{- end }}"
)
for _, condition in ipairs({ "true", "false" }) do
  for _, other in ipairs({ "true", "false" }) do
    for _, items in ipairs({ "(list)", '(list "甲" "乙")' }) do
      check(
        "{{- if "
          .. condition
          .. " }}\n"
          .. "{{- range "
          .. items
          .. " }}\nvalue={{ . }}\n{{- else }}\nempty\n{{- end }}\n"
          .. "{{- else if "
          .. other
          .. " }}\n"
          .. '{{- with "fallback" }}\n{{ . }}\n{{- end }}\n{{- else }}\nnone\n{{- end }}',
        "{{- if "
          .. condition
          .. " }}\n"
          .. "  {{- range "
          .. items
          .. " }}\nvalue={{ . }}\n  {{- else }}\nempty\n  {{- end }}\n"
          .. "{{- else if "
          .. other
          .. " }}\n"
          .. '  {{- with "fallback" }}\n{{     . }}\n  {{- end }}\n{{- else }}\nnone\n{{- end }}'
      )
    end
  end
end
check(
  '{{- define "part" }}\n{{- if true }}\npart\n{{- end }}\n{{- end }}\n{{- block "other" . }}\n{{- with . }}\nbody\n{{- end }}\n{{- end }}\n{{ template "part" . }}',
  '{{- define "part" }}\n  {{- if true }}\npart\n  {{- end }}\n{{- end }}\n{{- block "other" . }}\n  {{- with . }}\nbody\n  {{- end }}\n{{- end }}\n{{ template "part" . }}'
)
check(
  '{{define "part"}}\n{{if true}}\npart\n{{end}}\n{{end}}\n{{block "other" .}}\n{{with .}}\nbody\n{{end}}\n{{end}}\n{{template "part" .}}',
  '{{ define "part"}}\n{{   if true}}\npart\n{{   end}}\n{{ end}}\n{{ block "other" .}}\n{{   with .}}\nbody\n{{   end}}\n{{ end}}\n{{ template "part" .}}'
)

-- Blocks opened after host text still contribute to the depth of following lines.
check(
  "prefix{{if true}}\n{{range (list 1)}}\n{{end}}\n{{end}}suffix",
  "prefix{{if true}}\n{{   range (list 1)}}\n{{   end}}\n{{ end}}suffix"
)
-- Only the leading tag is indented; trailing text and later tags on the same
-- line stay byte-identical, including tags nested or closed on that line.
check(
  '{{if true}}prefix{{range (list 1)}}\n{{$x := "ok"}} value={{$x}}\n {{- if true }}inline{{else}}other{{end}}\n{{.}}tail{{end}}\n{{end}}suffix',
  '{{ if true}}prefix{{range (list 1)}}\n{{     $x := "ok"}} value={{$x}}\n    {{- if true }}inline{{else}}other{{end}}\n{{     .}}tail{{end}}\n{{ end}}suffix'
)
check(
  '{{if true}}\n\t{{printf "%s" "甲"}}tail{{"乙"}}\n{{-3}}suffix\n{{/* unchanged */}}tail\n{{- /* trimmed */}}tail\n{{end}}',
  '{{ if true}}\n\t{{ printf "%s" "甲"}}tail{{"乙"}}\n{{   -3}}suffix\n{{/* unchanged */}}tail\n  {{- /* trimmed */}}tail\n{{ end}}'
)
-- Same-line end/else still delimit the AST body. They must not leak that
-- body's indentation into following lines, even though those tags are skipped.
for _, condition in ipairs({ "true", "false" }) do
  check(
    "{{if "
      .. condition
      .. '}}A{{else}}B{{end}}\n{{"outside"}}\n'
      .. "{{if "
      .. condition
      .. '}}\n{{"inner"}}{{else}}{{"other"}}{{end}}\n{{"after"}}',
    "{{ if "
      .. condition
      .. '}}A{{else}}B{{end}}\n{{ "outside"}}\n'
      .. "{{ if "
      .. condition
      .. '}}\n{{   "inner"}}{{else}}{{"other"}}{{end}}\n{{ "after"}}'
  )
end
-- Internal indentation fills only the part not supplied by existing external
-- indentation. The mandatory separating space does not count toward depth.
check(
  "    {{if true}}\n {{range (list 1)}}\n   {{if true}}\nvalue\n     {{else}}\nunused\n    {{end}}\n  {{end}}\n {{end}}",
  "    {{ if true}}\n {{  range (list 1)}}\n   {{  if true}}\nvalue\n     {{ else}}\nunused\n    {{ end}}\n  {{ end}}\n {{ end}}"
)
check(
  "{{- if true }}\n{{-   range (list 1) }}\n  {{\t\tif true}}\nvalue\n  {{\tend}}\n{{-   end }}\n{{- end }}",
  "{{- if true }}\n  {{- range (list 1) }}\n  {{   if true}}\nvalue\n  {{   end}}\n  {{- end }}\n{{- end }}"
)
vim.bo[buf].tabstop = 2
check(
  "{{if true}}\n\t{{range (list 1)}}\n\t {{if true}}\nvalue\n \t{{end}}\n\t {{end}}\n{{end}}",
  "{{ if true}}\n\t{{ range (list 1)}}\n\t {{  if true}}\nvalue\n \t{{   end}}\n\t {{ end}}\n{{ end}}"
)
vim.bo[buf].tabstop = 8
vim.bo[buf].shiftwidth = 4
vim.bo[buf].vartabstop = "2,3"
check(
  "{{if true}}\n\t{{range (list 1)}}\n\t\t{{if true}}\nvalue\n\t\t{{end}}\n\t{{end}}\n{{end}}",
  "{{ if true}}\n\t{{   range (list 1)}}\n\t\t{{    if true}}\nvalue\n\t\t{{    end}}\n\t{{   end}}\n{{ end}}"
)
vim.bo[buf].shiftwidth = 2
vim.bo[buf].vartabstop = ""

local opaque = "{{/* {{if true}}\n{{end}} */}}\n"
  .. "{{- /* trim comment */ -}}\n"
  .. "{{ $s := `{{if true}}\n{{end}}` }}\n"
  .. '{{ printf "%s" "{{if true}}" }}\n'
  .. "{{if\n true}}\ntext\n{{end}}\n"
  .. '{{if eq $s "other"}}\nunused\n{{end}}\n'
  .. "{{-3}}\n"
check(
  opaque,
  "{{/* {{if true}}\n{{end}} */}}\n"
    .. "{{- /* trim comment */ -}}\n"
    .. "{{ $s := `{{if true}}\n{{end}}` }}\n"
    .. '{{ printf "%s" "{{if true}}" }}\n'
    .. "{{if\n true}}\ntext\n{{ end}}\n"
    .. '{{ if eq $s "other"}}\nunused\n{{ end}}\n'
    .. "{{ -3}}\n"
)
check("", "")
-- Every standalone action participates, not just block delimiters. Ordinary
-- actions directly in an if/range body must sit inside that block's level.
for _, condition in ipairs({ "true", "false" }) do
  check(
    "{{- if "
      .. condition
      .. " }}\n"
      .. '{{$name := "甲"}}\n{{- $items := list 1 2 }}\n{{- range $items }}\n'
      .. '{{$name}}\n{{- printf "%d" . }}\n {{/* unchanged */}}\n   {{- /* trimmed comment */}}\n'
      .. "{{- if eq . 1 }}\n{{continue}}\n{{- else }}\n{{break}}\n{{- end }}\n{{- end }}\n"
      .. '{{- else }}\n{{printf "%s" "{{ fake }}"}}\n{{- end }}',
    "{{- if "
      .. condition
      .. " }}\n"
      .. '{{   $name := "甲"}}\n  {{- $items := list 1 2 }}\n  {{- range $items }}\n'
      .. '{{     $name}}\n    {{- printf "%d" . }}\n {{/* unchanged */}}\n    {{- /* trimmed comment */}}\n'
      .. "    {{- if eq . 1 }}\n{{       continue}}\n    {{- else }}\n{{       break}}\n    {{- end }}\n  {{- end }}\n"
      .. '{{- else }}\n{{   printf "%s" "{{ fake }}"}}\n{{- end }}'
  )
end
check(
  '{{define "part"}}\n{{.}}\n{{end}}\n{{if true}}\n{{template "part" "ok"}}\n{{else if false}}\n{{"other"}}\n{{else}}\n{{nil}}\n{{end}}',
  '{{ define "part"}}\n{{   .}}\n{{ end}}\n{{ if true}}\n{{   template "part" "ok"}}\n{{ else if false}}\n{{   "other"}}\n{{ else}}\n{{   nil}}\n{{ end}}'
)
-- No fake actions inside raw strings, no new trim on negative literals, and no
-- indentation inserted before untrimmed comments (which would break Go syntax).
check(
  '{{if true}}\n{{-3}}\n{{printf "%s" `{{if false}}`}}\n{{/* keep */}}\n{{- /* trim */ -}}\n{{end}}',
  '{{ if true}}\n{{   -3}}\n{{   printf "%s" `{{if false}}`}}\n{{/* keep */}}\n  {{- /* trim */ -}}\n{{ end}}'
)
-- Tree-sitter treats an unmatched end as an identifier; this is not Go validation.
util.set_buffer_text(buf, "{{end}}")
assert(api.format() == true and util.buffer_text(buf) == "{{ end}}")
check(
  "{{if true}}\r\n{{range (list 1)}}\r\n{{end}}\r\n{{end}}\r\n",
  "{{ if true}}\r\n{{   range (list 1)}}\r\n{{   end}}\r\n{{ end}}\r\n"
)
check(
  "\t{{- if true }}\r\n{{- range (list 1) }}\r\n{{- end }}\r\n {{- end }}\r\n",
  "{{- if true }}\r\n  {{- range (list 1) }}\r\n  {{- end }}\r\n{{- end }}\r\n"
)

vim.bo[buf].shiftwidth = 0
vim.bo[buf].tabstop = 4
check(
  "{{if true}}\n{{range (list 1)}}\n{{end}}\n{{end}}",
  "{{ if true}}\n{{     range (list 1)}}\n{{     end}}\n{{ end}}"
)

local errors = {}
local notify = vim.notify
vim.notify = function(message)
  errors[#errors + 1] = message
end
for _, source in ipairs({ "{{if true}}", "{{if}}\n{{end}}", '{{ "unterminated }}', "{{/* unclosed }}" }) do
  util.set_buffer_text(buf, source)
  assert(api.format() == nil)
  assert(util.buffer_text(buf) == source)
end
util.set_buffer_text(buf, "{{if true}}\n{{end}}")
local original = util.buffer_text(buf)
local get_parser = vim.treesitter.get_string_parser
vim.treesitter.get_string_parser = function()
  error("missing parser")
end
assert(api.format() == nil and util.buffer_text(buf) == original)
vim.treesitter.get_string_parser = get_parser
vim.bo[buf].readonly = true
assert(api.format() == nil and util.buffer_text(buf) == original)
vim.bo[buf].readonly = false
vim.bo[buf].modifiable = false
assert(api.format() == nil and util.buffer_text(buf) == original)
vim.bo[buf].modifiable = true
assert(#errors == 7, vim.inspect(errors))
vim.notify = notify

-- The command shares the API, edits one undo step, and never writes the file.
require("vimoi.api").register()
local path = vim.fn.tempname() .. ".tmpl"
vim.fn.writefile({ "{{if true}}", "{{range (list 1)}}", "{{end}}", "{{end}}" }, path)
vim.cmd.edit(path)
local saved = util.buffer_text(0)
vim.bo.shiftwidth = 2
vim.cmd.VimoiFormat()
assert(util.buffer_text(0) == "{{ if true}}\n{{   range (list 1)}}\n{{   end}}\n{{ end}}\n")
assert(vim.bo.modified and table.concat(vim.fn.readfile(path), "\n") .. "\n" == saved)
vim.cmd.undo()
assert(util.buffer_text(0) == saved)
vim.cmd.redo()
assert(api.format() == false)
vim.fn.delete(path)
print("template formatting: nested controls, output equivalence, opaque syntax, errors, undo and command verified")

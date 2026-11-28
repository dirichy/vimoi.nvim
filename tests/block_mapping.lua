local map_objects = dofile("tests/helpers/map_objects.lua")
local map = require("vimoi.render.source_map")
local cli = require("vimoi.core.cli")
local diff = require("vimoi.compare.diff_hunks")
local merge = require("vimoi.merge.plan")
local await = dofile("tests/helpers/await.lua")
cli.setup(
  "chezmoi",
  vim.fn.getcwd() .. "/tests/fixtures/environment/empty.toml",
  vim.fn.getcwd() .. "/tests/fixtures/environment/source"
)

local function trace(source, expected)
  local result = assert(await(map.trace, source))
  local direct = assert(await(cli.execute_template, source, { cache = false }))
  assert(
    result.output == direct and result.output == expected,
    vim.inspect({ source, result.output, direct, expected })
  )
  return result
end

local nested = trace(
  '{{ block "outer" . }}A{{ block "middle" . }}B{{ block "inner" . }}C{{ end }}D{{ end }}E{{ end }}|{{ template "inner" . }}',
  "ABCDE|C"
)
assert(not nested.skeleton:find("\255h", 1, true), "ordinary blocks must use ordinary sentinels")
assert(#map_objects.tags(nested) == 7, "nonempty block bodies must remain visible in the source map")
local texts = {}
for _, part in ipairs(map_objects.literals(nested)) do
  if part.text ~= "" then
    texts[#texts + 1] = part.text
  end
  if part.text == "C" then
    assert(#part.occurrences == 2)
  end
end
assert(vim.deep_equal(texts, { "A", "B", "C", "D", "E", "|" }))
local inherited = trace(
  '{{ define "outer" }}A{{ block "inner" . }}B{{ end }}C{{ end }}{{ template "outer" . }}|{{ template "inner" . }}',
  "ABC|B"
)
assert(#map_objects.tags(inherited) == 3, "define must retain its opaque body")
for _, part in ipairs(map_objects.literals(inherited)) do
  assert(part.text ~= "A" and part.text ~= "B" and part.text ~= "C")
end

-- A block body executed once is ordinary editable source text.
local single = trace('head{{ block "item" . }}old{{ end }}tail', "headoldtail")
local plan = merge.plan(single, "headnewtail", diff.compute("headnewtail", single))
assert(#plan.edits == 1 and #plan.skipped == 0 and #plan.choices == 0)
local candidate, err, edits = merge.apply_source_edits(single, plan.edits)
assert(candidate, err)
assert(candidate == 'head{{ block "item" . }}new{{ end }}tail')
assert(assert(map.rebuild_after_edits(single, candidate, edits)).output == "headnewtail")
-- Changing only one execution of a shared block still requires a manual edit.
local repeated = trace('{{ block "item" . }}old{{ end }}|{{ template "item" . }}', "old|old")
local partial = merge.plan(repeated, "old|new", diff.compute("old|new", repeated))
assert(#partial.edits == 0 and #partial.choices == 0 and #partial.skipped > 0)

-- Empty Go definitions must remain empty, including transparent blocks and
-- blocks nested inside an opaque define. Sentinels would change overrides.
local empty_bodies = { "", " \t\r\n\v\f", "{{/* empty */}}", " \n{{/* empty */}}\t" }
for _, code in ipairs({ 0x85, 0xA0, 0x1680, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000 }) do
  empty_bodies[#empty_bodies + 1] = vim.fn.nr2char(code)
end
for code = 0x2000, 0x200A do
  empty_bodies[#empty_bodies + 1] = vim.fn.nr2char(code)
end
for _, empty in ipairs(empty_bodies) do
  for _, keyword in ipairs({ "define", "block" }) do
    local argument = keyword == "block" and " ." or ""
    local source = "{{ "
      .. keyword
      .. ' "slot"'
      .. argument
      .. " }}"
      .. empty
      .. '{{ end }}{{ define "slot" }}WIN{{ end }}{{ template "slot" . }}'
    trace(source, keyword == "block" and "WINWIN" or "WIN")
  end
  trace(
    '{{ define "outer" }}A{{ block "inner" . }}'
      .. empty
      .. '{{ end }}C{{ end }}{{ define "inner" }}X{{ end }}{{ template "outer" . }}|{{ template "inner" . }}',
    "AXC|X"
  )
end
-- These adjacent code points are text, not Go whitespace. They must remain
-- transparent, and the cached skeleton must survive a normal literal edit.
for _, code in ipairs({ 0x84, 0x86, 0x167F, 0x1681, 0x200B, 0x2027, 0x202A, 0x2060, 0x3001 }) do
  local text = vim.fn.nr2char(code)
  local source = '{{ block "slot" . }}' .. text .. "{{ end }}"
  local nonempty = trace(source, text)
  assert(#map_objects.tags(nonempty) == 2 and map_objects.literals(nonempty)[2].text == text)
  local edited = source:gsub(text, "body", 1)
  assert(assert(map.rebuild(nonempty, edited)).output == "body")
end
for _, keyword in ipairs({ "define", "block" }) do
  local argument = keyword == "block" and " ." or ""
  local opening = "{{ " .. keyword .. ' "slot"' .. argument .. " }}"
  local ending = '{{ end }}{{ template "slot" . }}'
  local nonempty = opening .. "body" .. ending
  local full = trace(nonempty, keyword == "block" and "bodybody" or "body")
  local empty = opening .. " " .. ending
  assert(not map.rebuild(full, empty), "becoming empty must invalidate the rendered skeleton")
  local blank = trace(empty, keyword == "block" and "  " or " ")
  assert(not map.rebuild(blank, nonempty), "becoming nonempty must invalidate the rendered skeleton")
end
print("block mapping: transparent nesting, opaque define bodies, static merge, repeated calls, and empty overrides")

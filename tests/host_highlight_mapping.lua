---@diagnostic disable: duplicate-set-field -- Capture the real provider for deterministic viewport checks.
local api, util = vim.api, require("vimoi.util")
local namespace = api.nvim_create_namespace("vimoi-host-highlight")
local provider
local emitted = {}
local original_extmark = api.nvim_buf_set_extmark
api.nvim_buf_set_extmark = function(buffer, ns, row, col, opts)
  local id = original_extmark(buffer, ns, row, col, opts)
  if ns == namespace then
    emitted[buffer .. ":" .. id] = vim.deepcopy(opts)
  end
  return id
end
local original_provider = api.nvim_set_decoration_provider
api.nvim_set_decoration_provider = function(ns, callbacks)
  if ns == namespace then
    provider = callbacks
  end
  return original_provider(ns, callbacks)
end
require("vimoi.host_highlight")
api.nvim_set_decoration_provider = original_provider
require("vimoi").setup({ diagnostics = { enabled = false }, highlight = { mode = "rendered" } })
local source_map = require("vimoi.gotmpl.source_map")
local await = dofile("tests/helpers/await.lua")
local buf = api.nvim_create_buf(true, false)
api.nvim_set_current_buf(buf)
local win = api.nvim_get_current_win()
local checked, bytes_checked, nonmonotonic = 0, 0, 0

-- Independent oracle: native captures over the complete rendered document,
-- intersected by a brute-force walk of each literal's first output occurrence.
-- Do not use production rendered_regions, viewport queries, or binary searches.
local function expected(trace, language, first, last)
  local output = api.nvim_create_buf(false, true)
  util.set_buffer_text(output, trace.output)
  local parser = assert(vim.treesitter.get_parser(output, language))
  parser:parse(true)
  local result = {}
  local function paint(a, b, name, priority)
    for byte = math.max(a, first), math.min(b, last) - 1 do
      result[byte .. ":" .. name .. ":" .. priority] = true
    end
  end
  for _, part in ipairs(trace.literal_parts) do
    if #part.output_ranges == 0 then
      paint(part.source.start_byte, part.source.end_byte, "Comment", vim.hl.priorities.treesitter)
    end
  end
  parser:for_each_tree(function(tree, language_tree)
    local lang = language_tree:lang()
    local query = vim.treesitter.query.get(lang, "highlights")
    if not query then
      return
    end
    for capture, node, metadata in query:iter_captures(tree:root(), output, 0, -1) do
      local name = query.captures[capture]
      if name:sub(1, 1) ~= "_" then
        local range = vim.treesitter.get_range(node, output, metadata[capture])
        local priority = tonumber(metadata.priority or (metadata[capture] or {}).priority)
          or vim.hl.priorities.treesitter
        if name == "nospell" then
          priority = priority + 1
        end
        for _, included in ipairs(tree:included_ranges(true)) do
          for _, part in ipairs(trace.literal_parts) do
            local occurrence = part.output_ranges[1]
            if occurrence then
              local a = math.max(range[3], included[3], occurrence.start_byte)
              local b = math.min(range[6], included[6], occurrence.end_byte)
              local offset = part.source.start_byte - occurrence.start_byte
              paint(a + offset, b + offset, "@" .. name .. "." .. lang, priority)
            end
          end
        end
      end
    end
  end)
  api.nvim_buf_delete(output, { force = true })
  return result
end

local function check(label, text, language)
  util.set_buffer_text(buf, text)
  require("vimoi.highlight").configure_template_buffer(buf, language)
  local trace = assert(await(source_map.trace, text, { buf = buf }))
  require("vimoi.gotmpl.session").update(buf, trace)
  local previous = -1
  for _, part in ipairs(trace.literal_parts) do
    local occurrence = part.output_ranges[1]
    if occurrence and #part.text > 0 then
      if occurrence.start_byte < previous then
        nonmonotonic = nonmonotonic + 1
      end
      previous = occurrence.start_byte
    end
  end
  local starts = util.line_starts(text)
  local count = api.nvim_buf_line_count(buf)
  local viewports = { { 0, count - 1 } }
  for row = count - 1, 0, -1 do
    viewports[#viewports + 1] = { row, row }
  end
  for _, viewport in ipairs(viewports) do
    local first, last = starts[viewport[1] + 1] or #text, starts[viewport[2] + 2] or #text
    provider.on_win("win", win, buf, viewport[1], viewport[2])
    local actual = {}
    -- nvim_buf_get_extmarks only reports the final group of a highlight stack;
    -- compare the actual API inputs to retain every native capture/priority.
    for _, mark in ipairs(api.nvim_buf_get_extmarks(buf, namespace, 0, -1, { details = true })) do
      local opts = assert(emitted[buf .. ":" .. mark[1]])
      if not mark[4].invalid then
        local a = starts[mark[2] + 1] + mark[3]
        local b = starts[opts.end_row + 1] + opts.end_col
        assert(a >= first and b <= last, label .. ": capture escaped viewport")
        for _, tag in ipairs(trace.template_tags) do
          assert(b <= tag.start_byte or a >= tag.end_byte, label .. ": capture crossed an opaque tag/action")
        end
        local groups = type(opts.hl_group) == "table" and opts.hl_group or { opts.hl_group }
        for _, group in ipairs(groups) do
          for byte = a, b - 1 do
            actual[byte .. ":" .. group .. ":" .. opts.priority] = true
          end
        end
      end
    end
    local native = expected(trace, language, first, last)
    assert(vim.deep_equal(actual, native), vim.inspect({ label, viewport, actual = actual, expected = native }))
    checked, bytes_checked = checked + 1, bytes_checked + vim.tbl_count(native)
  end
  return trace
end

local cases = {
  { "adjacent dynamic actions", '{{ "local x = " }}{{ "1" }}\nlocal text = "世界"\n', "lua" },
  { "dynamic string delimiters", '{{ "local x = \\"" }}世界{{ "\\"" }}\n', "lua" },
  {
    "skipped and empty branches",
    "{{ if false }}ignored{{ else if true }}local x = 1{{ else }}other{{ end }}\n{{ range list }}skipped{{ end }}\n",
    "lua",
  },
  {
    "nested loops and empty slots",
    "{{ range list 1 2 }}{{ range list 1 2 }}local x = {{ . }};{{ end }}\n{{ end }}",
    "lua",
  },
  {
    "nonmonotonic first occurrences",
    "{{ range list 1 2 }}\n{{ if eq . 2 }}local second = 2\n{{ end }}{{ if eq . 1 }}local first = 1\n{{ end }}{{ end }}",
    "lua",
  },
  {
    "break and continue",
    "{{ range list 1 2 3 }}{{ if eq . 1 }}{{ continue }}{{ end }}local x = {{ . }}\n{{ if eq . 2 }}{{ break }}{{ end }}{{ end }}",
    "lua",
  },
  {
    "inconsistent execution contexts",
    '{{ range $i := list 1 2 }}{{ if eq $i 1 }}--{{ else }}local x = "{{ end }}same{{ if eq $i 2 }}"{{ end }}\n{{ end }}',
    "lua",
  },
  {
    "definition calls with intervening text",
    '{{ define "item" }}local x = {{ . }}\n{{ end }}\nlocal before = 0\n{{ template "item" 1 }}local middle = "世界"\n{{ template "item" 2 }}local after = true\n',
    "lua",
  },
  {
    "out-of-order definition calls",
    '{{ define "a" }}local a = 1\n{{ end }}{{ define "b" }}local b = 2\n{{ end }}{{ template "b" . }}local middle = 3\n{{ template "a" . }}local after = 4\n',
    "lua",
  },
  {
    "block and repeated calls",
    '{{ block "item" . }}local x = 1\n{{ end }}local middle = "hello"\n{{ template "item" . }}local after = 2\n',
    "lua",
  },
  { "trim and unicode", 'local x = "{{- if true -}}\n世界{{- else -}}skipped{{- end -}}\n"\n', "lua" },
  {
    "YAML multiline capture",
    'message: "{{ "A" }}\n  世界\n  {{ "B" }}"\nnext: {{ if true }}true{{ else }}false{{ end }}\n',
    "yaml",
  },
  {
    "JSON loop fragments",
    '[{{ range $i, $v := list "a" "b" }}{{ if $i }},{{ end }}{"name":"{{ $v }}"}{{ end }}]\n',
    "json",
  },
  { "TOML dynamic key and string", '{{ "[settings]" }}\n{{ "key" }} = "世界"\nenabled = {{ true }}\n', "toml" },
  { "shell heredoc", 'cat <<EOF\n{{ "dynamic" }}\n世界\nEOF\necho "{{ "value" }}"\n', "bash" },
  {
    "HTML injected JavaScript",
    '<script>\nconst value = "{{ "dynamic" }}世界";\n</script>\n<p>{{ "hello" }}text</p>\n',
    "html",
  },
  { "Markdown injected Lua", '# header\n```lua\nlocal value = "{{ "dynamic" }}世界"\n```\ntext\n', "markdown" },
}
for _, case in ipairs(cases) do
  check(unpack(case))
end
-- Alternate execution order and output length while reusing the same source
-- buffer, native output parser, and already-painted viewports.
for _, order in ipairs({ "1 2", "2 1", "2", "1", "1 2 3", "" }) do
  for _, quote in ipairs({ '"', "'" }) do
    check(
      "changed iteration order " .. order .. quote,
      "{{ range list "
        .. order
        .. " }}\n{{ if eq . 2 }}local second = "
        .. quote
        .. "世界"
        .. quote
        .. "\n{{ end }}{{ if eq . 1 }}local first = 1\n{{ end }}{{ end }}\nlocal tail = true\n",
      "lua"
    )
  end
end
assert(nonmonotonic > 0, "test fixtures did not exercise nonmonotonic first occurrences")

-- Two windows own separate viewport caches for one source/output pair.
check("multiwindow baseline", 'local a = "one"\nlocal b = "two"\nlocal c = "three"\n', "lua")
provider.on_win("win", win, buf, 0, 0)
local first_marks = api.nvim_buf_get_extmarks(buf, namespace, 0, -1, {})
assert(#first_marks > 0)
vim.cmd("vsplit")
local peer = api.nvim_get_current_win()
provider.on_win("win", peer, buf, 2, 2)
assert(#api.nvim_buf_get_extmarks(buf, namespace, 0, -1, {}) > #first_marks)
api.nvim_win_close(peer, true)
local retained = api.nvim_buf_get_extmarks(buf, namespace, 0, -1, {})
assert(vim.deep_equal(first_marks, retained), "closing another viewport removed the original window's marks")
api.nvim_buf_delete(buf, { force = true })
api.nvim_buf_set_extmark = original_extmark
print(
  ("rendered mappings: %d viewports, %d byte/capture checks, %d nonmonotonic first occurrences"):format(
    checked,
    bytes_checked,
    nonmonotonic
  )
)

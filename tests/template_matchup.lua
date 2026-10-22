-- Query captures are the optional vim-matchup integration contract; no key override.
local original_mapping = vim.fn.maparg("%", "n", false, true)
local query = assert(vim.treesitter.query.get("gotmpl", "matchup"))
local text = table.concat({
  "{{- if true }}",
  "{{ range . }}{{ continue }}{{ break }}{{ else }}empty{{ end }}",
  "{{ else if false }}",
  "{{ else if true }}",
  "{{ else }}",
  "{{ end -}}",
  "{{ with . }}{{ else with . }}{{ else }}empty{{ end }}",
  '{{ define "name" }}body{{ end }}',
  '{{ block "body" . }}body{{ end }}',
}, "\n")
local parser = vim.treesitter.get_string_parser(text, "gotmpl")
local root = parser:parse()[1]:root()
assert(not root:has_error())
local captures = {}
for id, node in query:iter_captures(root, text, 0, -1) do
  local name = query.captures[id]
  captures[name] = captures[name] or {}
  captures[name][#captures[name] + 1] = vim.treesitter.get_node_text(node, text)
end
for name, expected in pairs({
  ["open.if"] = { "if" },
  ["mid.if.1"] = { "else", "if", "else", "if", "else" },
  ["close.if"] = { "end" },
  ["open.range"] = { "range" },
  ["mid.range.1"] = { "else" },
  ["mid.range.2"] = { "break" },
  ["mid.range.3"] = { "continue" },
  ["close.range"] = { "end" },
  ["open.with"] = { "with" },
  ["mid.with.1"] = { "else", "with", "else" },
  ["close.with"] = { "end" },
  ["open.define"] = { "define" },
  ["close.define"] = { "end" },
  ["open.block"] = { "block" },
  ["close.block"] = { "end" },
}) do
  assert(vim.deep_equal(captures[name], expected), name .. ": " .. vim.inspect(captures[name]))
end
for _, kind in ipairs({ "if", "range", "with", "define", "block" }) do
  assert(#captures["scope." .. kind] == 1)
end
local middle_clauses = {}
for _, match in query:iter_matches(root, text, 0, -1) do
  for id, nodes in pairs(match) do
    if query.captures[id] == "mid.if.1" or query.captures[id] == "mid.with.1" then
      local _, _, start_byte = nodes[1]:start()
      local _, _, end_byte = nodes[#nodes]:end_()
      middle_clauses[#middle_clauses + 1] = text:sub(start_byte + 1, end_byte)
    end
  end
end
assert(vim.deep_equal(middle_clauses, { "else if", "else if", "else", "else with", "else" }))
assert(vim.deep_equal(vim.fn.maparg("%", "n", false, true), original_mapping))
print("template matchup: nested scopes, trim, else chains, loop controls and definitions verified")

local source_map = require("vimoi.gotmpl.source_map")
local util = require("vimoi.util")
local merge_plan = require("vimoi.gotmpl.merge_plan")
local buffer_edits = require("vimoi.gotmpl.buffer_edits")
local checked = 0

local function check(source, edits)
  local updated, err, escaped_edits = merge_plan.apply_source_edits(assert(source_map.parse(source)), edits)
  assert(updated, err)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].undolevels = -1
  util.set_buffer_text(buf, source)
  vim.bo[buf].undolevels = 1000
  local original_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  buffer_edits.apply(buf, source, updated, escaped_edits)
  assert(
    util.buffer_text(buf) == updated,
    vim.inspect({ source, edits, expected = updated, actual = util.buffer_text(buf) })
  )
  vim.api.nvim_buf_call(buf, function()
    vim.cmd("silent undo")
    -- Native undo restores lines, not the endofline option (the previous full-write path did the same).
    assert(
      vim.deep_equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), original_lines),
      vim.inspect({ source, edits, undo = util.buffer_text(buf) })
    )
    vim.cmd("silent redo")
    assert(util.buffer_text(buf) == updated, "redo did not restore the entire merge")
  end)
  vim.api.nvim_buf_delete(buf, { force = true })
  checked = checked + 1
end

-- Every insertion/replacement/deletion boundary, including the logical final newline.
for _, source in ipairs({ "", "a", "abc\n", "a\nb\n", "a\n\n", "\n", "你\r\n好" }) do
  for first = 0, #source do
    for last = first, #source do
      for _, replacement in ipairs({ "", "X", "\n", "\n\n", "中文", "line\nnext\n", "{{", "{" }) do
        if first ~= last or replacement ~= "" then
          check(source, { { start_byte = first, end_byte = last, replacement = replacement } })
        end
      end
    end
  end
end

-- Disjoint edits change offsets and may turn the old final newline into an interior newline.
for _, suffix in ipairs({ "", "tail", "tail\n", "\n" }) do
  check("head\nmiddle\nend\n", {
    { start_byte = 0, end_byte = 4, replacement = "longer head" },
    { start_byte = 5, end_byte = 11, replacement = "" },
    { start_byte = 16, end_byte = 16, replacement = suffix },
  })
end
check("abc\n", {
  { start_byte = 1, end_byte = 2, replacement = "long\ntext" },
  { start_byte = 3, end_byte = 4, replacement = "" },
  { start_byte = 4, end_byte = 4, replacement = "tail\n" },
})
check("a\nb\n", {
  { start_byte = 0, end_byte = 2, replacement = "longer\n" },
  { start_byte = 2, end_byte = 4, replacement = "" },
})
for _, second_end in ipairs({ 1, 2 }) do
  check("abcd\n", {
    { start_byte = 1, end_byte = 1, replacement = "X" },
    { start_byte = 1, end_byte = second_end, replacement = "Y" },
  })
end

math.randomseed(20261020)
local replacements = { "", "long", "x\n", "中文", "\n", "\r\n" }
for _ = 1, 500 do
  local source = ("first\n中文\nlast"):rep(math.random(1, 3)) .. (math.random(0, 1) == 1 and "\n" or "")
  local edits, cursor = {}, 0
  for _ = 1, 4 do
    if cursor > #source then
      break
    end
    local first = math.random(cursor, #source)
    local last = math.random(first, math.min(first + 3, #source))
    edits[#edits + 1] = {
      start_byte = first,
      end_byte = last,
      replacement = replacements[math.random(#replacements)],
    }
    cursor = math.max(last, first + 1)
  end
  check(source, edits)
end

-- Edits must not move extmarks in untouched lines or on untouched parts of the same line.
local source = "header\nleft=abcd; keep=untouched; right=wxyz\nfooter\n"
local left = assert(source:find("abcd", 1, true)) - 1
local right = assert(source:find("wxyz", 1, true)) - 1
local edits = {
  { start_byte = left + 1, end_byte = left + 2, replacement = "INSERT" },
  { start_byte = right + 1, end_byte = right + 2, replacement = "Y" },
}
local updated, err, escaped_edits = merge_plan.apply_source_edits(assert(source_map.parse(source)), edits)
assert(updated, err)
local buf = vim.api.nvim_create_buf(false, true)
util.set_buffer_text(buf, source)
local namespace = vim.api.nvim_create_namespace("vimoi-local-write")
local mark = vim.api.nvim_buf_set_extmark(buf, namespace, 1, 20, {})
local changes = {}
vim.api.nvim_buf_attach(buf, false, {
  on_lines = function(_, _, _, first, last)
    changes[#changes + 1] = { first, last }
  end,
})
buffer_edits.apply(buf, source, updated, escaped_edits)
assert(vim.deep_equal(vim.api.nvim_buf_get_extmark_by_id(buf, namespace, mark, {}), { 1, 25 }))
assert(vim.deep_equal(changes, { { 1, 2 }, { 1, 2 } }), "writes touched unrelated lines")
vim.api.nvim_buf_delete(buf, { force = true })
print(("buffer edits: %d text/undo/redo cases, including EOF, Unicode, escaping, and disjoint edits"):format(checked))

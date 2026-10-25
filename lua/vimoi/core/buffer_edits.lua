local M = {}
local util = require("vimoi.core.util")

---@class VimoiBufferEdit: VimoiByteRange
---@field replacement string

---Find separate line changes, then trim unchanged bytes inside each hunk.
---@param before string
---@param after string
---@return VimoiBufferEdit[]
function M.diff(before, after)
  local before_starts, after_starts = util.line_starts(before), util.line_starts(after)
  local hunks = assert(vim.text.diff(before, after, { result_type = "indices" }))
  ---@cast hunks integer[][]
  local edits = {}
  for _, hunk in ipairs(hunks) do
    local first, last = util.line_range(before, before_starts, hunk[1], hunk[2])
    local new_first, new_last = util.line_range(after, after_starts, hunk[3], hunk[4])
    local offset, finish, replacement =
      util.changed_bytes(before:sub(first + 1, last), after:sub(new_first + 1, new_last))
    edits[#edits + 1] = { start_byte = first + offset, end_byte = first + finish, replacement = replacement }
  end
  return edits
end

---Apply byte edits without replacing untouched buffer text; join them into one undo step.
---The caller provides matching original/result snapshots and handles any template escaping.
---@param buf integer
---@param source string Original buffer snapshot, including its final newline.
---@param updated string Result snapshot, including its final newline.
---@param edits VimoiBufferEdit[] Sorted by ascending byte offset; non-overlapping.
function M.apply(buf, source, updated, edits)
  local source_end = #source - (source:sub(-1) == "\n" and 1 or 0)
  local endofline = updated:sub(-1) == "\n"
  local updated_end = #updated - (endofline and 1 or 0)
  local buffer_edits, byte_delta = {}, 0
  for _, edit in ipairs(edits) do
    if edit.end_byte >= source_end then
      -- Neovim stores the final newline as an option, not an extra buffer row.
      -- Combine edits touching that boundary into one physical suffix replacement.
      local start_byte = math.min(edit.start_byte, source_end, updated_end - byte_delta)
      -- Deleting the last line may move a preceding newline into the endofline option.
      while #buffer_edits > 0 and buffer_edits[#buffer_edits].end_byte > start_byte do
        local previous = table.remove(buffer_edits)
        byte_delta = byte_delta - #previous.replacement + (previous.end_byte - previous.start_byte)
        start_byte = math.min(previous.start_byte, source_end, updated_end - byte_delta)
      end
      buffer_edits[#buffer_edits + 1] = {
        start_byte = start_byte,
        end_byte = source_end,
        replacement = updated:sub(start_byte + byte_delta + 1, updated_end),
      }
      break
    end
    buffer_edits[#buffer_edits + 1] = edit
    byte_delta = byte_delta + #edit.replacement - (edit.end_byte - edit.start_byte)
  end

  local line_starts = util.line_starts(source)
  vim.api.nvim_buf_call(buf, function()
    for index = #buffer_edits, 1, -1 do
      local edit = buffer_edits[index]
      local start_row, start_col = util.byte_to_position(source, edit.start_byte, line_starts)
      local end_row, end_col = util.byte_to_position(source, edit.end_byte, line_starts)
      if index < #buffer_edits then
        vim.cmd("undojoin")
      end
      local lines = vim.split(edit.replacement, "\n", { plain = true })
      if start_col == 0 and end_col == 0 and (edit.replacement == "" or edit.replacement:sub(-1) == "\n") then
        table.remove(lines)
        vim.api.nvim_buf_set_lines(buf, start_row, end_row, false, lines)
      else
        vim.api.nvim_buf_set_text(buf, start_row, start_col, end_row, end_col, lines)
      end
    end
    vim.bo[buf].endofline = endofline
  end)
end

return M

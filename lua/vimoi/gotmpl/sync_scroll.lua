local M = {}
local util = require("vimoi.util")
local rendered_regions = require("vimoi.gotmpl.source_map").rendered_regions

-- Translate between target, rendered output, and source line numbers before moving
-- the peer window. Native scrollbind only understands equal line numbers.
local function target_to_rendered_line(session, line)
  local line_delta = 0
  for _, hunk in ipairs(session.hunks) do
    if line < hunk.target_start_line then
      break
    end
    if hunk.target_line_count > 0 and line < hunk.target_start_line + hunk.target_line_count then
      if hunk.rendered_line_count == 0 then
        return math.max(1, hunk.rendered_start_line)
      end
      return hunk.rendered_start_line + math.min(line - hunk.target_start_line, hunk.rendered_line_count - 1)
    end
    line_delta = line_delta + hunk.target_line_count - hunk.rendered_line_count
  end
  return math.max(1, line - line_delta)
end

local function rendered_to_target_line(session, line)
  local line_delta = 0
  for _, hunk in ipairs(session.hunks) do
    if line < hunk.rendered_start_line then
      break
    end
    if hunk.rendered_line_count == 0 and line == hunk.rendered_start_line then
      break
    end
    if hunk.rendered_line_count > 0 and line < hunk.rendered_start_line + hunk.rendered_line_count then
      if hunk.target_line_count == 0 then
        return math.max(1, hunk.target_start_line)
      end
      return hunk.target_start_line + math.min(line - hunk.rendered_start_line, hunk.target_line_count - 1)
    end
    line_delta = line_delta + hunk.target_line_count - hunk.rendered_line_count
  end
  return math.max(1, line + line_delta)
end

local function rendered_to_source_line(session, rendered_line)
  local rendered_line_starts = util.line_starts(session.trace.output)
  local line_start_byte = rendered_line_starts[rendered_line] or #session.trace.output
  local nearest_source_anchor
  for _, literal_part in ipairs(session.trace.literal_parts) do
    for _, output_range in ipairs(literal_part.output_ranges) do
      if line_start_byte >= output_range.start_byte and line_start_byte < output_range.end_byte then
        local offset = math.min(
          line_start_byte - output_range.start_byte,
          literal_part.source.end_byte - literal_part.source.start_byte
        )
        local row = util.byte_to_position(session.source_text, literal_part.source.start_byte + offset)
        return row + 1
      end
      local distance =
        math.min(math.abs(line_start_byte - output_range.start_byte), math.abs(line_start_byte - output_range.end_byte))
      if not nearest_source_anchor or distance < nearest_source_anchor.distance then
        nearest_source_anchor = { distance = distance, source_byte = literal_part.source.start_byte }
      end
    end
  end
  for _, region in ipairs(rendered_regions(session.trace)) do
    local output_range = region.output_range
    if line_start_byte >= output_range.start_byte and line_start_byte < output_range.end_byte then
      local offset =
        math.min(line_start_byte - output_range.start_byte, region.source.end_byte - region.source.start_byte)
      local row = util.byte_to_position(session.source_text, region.source.start_byte + offset)
      return row + 1
    end
  end
  local row =
    util.byte_to_position(session.source_text, nearest_source_anchor and nearest_source_anchor.source_byte or 0)
  return row + 1
end

local function target_to_source_line(session, line)
  for _, hunk in ipairs(session.hunks) do
    if
      hunk.target_line_count > 0
      and line >= hunk.target_start_line
      and line < hunk.target_start_line + hunk.target_line_count
    then
      if hunk.rendered_line_count == 0 and #hunk.source_ranges > 0 then
        local row = util.byte_to_position(session.source_text, hunk.source_ranges[1].start_byte)
        return row + 1
      end
      break
    end
  end
  return rendered_to_source_line(session, target_to_rendered_line(session, line))
end

local function source_to_rendered_line(session, source_line)
  local source_starts = util.line_starts(session.source_text)
  local line_start_byte = source_starts[source_line] or #session.source_text
  local current_target_line = vim.api.nvim_win_get_cursor(session.target_win)[1]
  local current_rendered_line = target_to_rendered_line(session, current_target_line)
  local candidates = {}
  for _, literal_part in ipairs(session.trace.literal_parts) do
    if line_start_byte >= literal_part.source.start_byte and line_start_byte < literal_part.source.end_byte then
      local offset = math.min(
        line_start_byte - literal_part.source.start_byte,
        literal_part.source.end_byte - literal_part.source.start_byte
      )
      for _, output_range in ipairs(literal_part.output_ranges) do
        local rendered_byte = math.min(output_range.start_byte + offset, output_range.end_byte)
        local row = util.byte_to_position(session.trace.output, rendered_byte)
        candidates[#candidates + 1] = row + 1
      end
    end
  end
  if #candidates == 0 then
    for _, region in ipairs(rendered_regions(session.trace)) do
      local source = region.source
      if line_start_byte >= source.start_byte and line_start_byte < source.end_byte then
        local row = util.byte_to_position(session.trace.output, region.output_range.start_byte)
        candidates[1] = row + 1
        break
      end
    end
  end
  local selected = candidates[1] or 1
  for _, candidate in ipairs(candidates) do
    if math.abs(candidate - current_rendered_line) < math.abs(selected - current_rendered_line) then
      selected = candidate
    end
  end
  return selected
end

local function align_cursor_screen_row(win, line, screen_row)
  line = math.max(1, math.min(line, vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(win))))
  vim.api.nvim_win_call(win, function()
    vim.api.nvim_win_set_cursor(win, { line, 0 })
    vim.cmd("normal! zt")
    local ctrl_y = vim.api.nvim_replace_termcodes("<C-y>", true, false, true)
    local ctrl_e = vim.api.nvim_replace_termcodes("<C-e>", true, false, true)
    for _ = 1, vim.api.nvim_win_get_height(win) * 2 do
      local current_screen_row = vim.fn.winline()
      if current_screen_row == screen_row then
        break
      end
      vim.cmd("normal! " .. (current_screen_row < screen_row and ctrl_y or ctrl_e))
      if vim.fn.winline() == current_screen_row then
        break
      end
    end
    -- Near a file boundary, <C-e>/<C-y> may move the cursor because the
    -- viewport cannot scroll any farther. View alignment is best effort, but
    -- the semantic line mapping must never be changed by that adjustment.
    vim.api.nvim_win_set_cursor(win, { line, 0 })
  end)
end

function M.sync(session, active_win)
  if
    session.closed
    or session.preview_error
    or not session.trace
    or session.syncing
    or not vim.api.nvim_win_is_valid(active_win)
  then
    return
  end
  local is_source = active_win == session.source_win
  if not is_source and active_win ~= session.target_win then
    return
  end
  session.syncing = true
  local active_line = vim.api.nvim_win_get_cursor(active_win)[1]
  local screen_row = vim.api.nvim_win_call(active_win, vim.fn.winline)
  local other_win, other_line
  if is_source then
    other_win = session.target_win
    other_line = rendered_to_target_line(session, source_to_rendered_line(session, active_line))
  else
    other_win = session.source_win
    other_line = target_to_source_line(session, active_line)
  end
  if vim.api.nvim_win_is_valid(other_win) then
    align_cursor_screen_row(other_win, other_line, screen_row)
  end
  session.syncing = false
end

function M.corresponding_line(session, active_win, line)
  if active_win == session.source_win then
    return session.target_win, rendered_to_target_line(session, source_to_rendered_line(session, line))
  end
  return session.source_win, target_to_source_line(session, line)
end

return M

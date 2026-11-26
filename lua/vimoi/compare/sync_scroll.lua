local M = {}
local source_map = require("vimoi.render.source_map")

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
  local line_start_byte = source_map.position_to_byte(session.map, "output", rendered_line - 1)
    or session.map.output_size
  local source_byte = source_map.approximate_source_position(session.map, line_start_byte)
  return source_map.byte_to_position(session.map, "source", source_byte) + 1
end

local function target_to_source_line(session, line)
  for _, hunk in ipairs(session.hunks) do
    if
      hunk.target_line_count > 0
      and line >= hunk.target_start_line
      and line < hunk.target_start_line + hunk.target_line_count
    then
      if hunk.rendered_line_count == 0 and #hunk.source_ranges > 0 then
        local row = source_map.byte_to_position(session.map, "source", hunk.source_ranges[1].start_byte)
        return row + 1
      end
      break
    end
  end
  return rendered_to_source_line(session, target_to_rendered_line(session, line))
end

local function source_to_rendered_range(session, source_line)
  local line_start_byte, line_end_byte = source_map.line_range(session.map, "source", source_line - 1, 1)
  local first, last, literal = source_map.first_output_span(session.map, line_start_byte)
  if not first or not last then
    return 1, 0
  end
  -- Literal text maps byte for byte; action expansions retain their full span.
  if literal then
    last = math.min(last, first + line_end_byte - line_start_byte)
  end
  local row = source_map.byte_to_position(session.map, "output", first)
  local end_row = last > first and source_map.byte_to_position(session.map, "output", last - 1) + 1 or row
  return row + 1, end_row
end

-- Use the first execution of a source range, then project it to target.
---@param session VimoiTemplateView
---@param source_line integer
---@return integer first One-based target row.
---@return integer last Less than first when the selected range has no output.
function M.target_range(session, source_line)
  local cached = session.cursor_range
  if cached and cached.source_line == source_line and cached.map == session.map and cached.hunks == session.hunks then
    return cached.first, cached.last
  end
  local rendered_first, rendered_last = source_to_rendered_range(session, source_line)
  local first = rendered_to_target_line(session, rendered_first)
  local last = first - 1
  if rendered_last >= rendered_first then
    last = rendered_to_target_line(session, rendered_last)
    -- A changed hunk can expand the chosen rendered range into more target
    -- lines; exact line-by-line attribution is unavailable inside that hunk.
    for _, hunk in ipairs(session.hunks) do
      if
        hunk.rendered_line_count > 0
        and hunk.target_line_count > 0
        and rendered_first < hunk.rendered_start_line + hunk.rendered_line_count
        and rendered_last >= hunk.rendered_start_line
      then
        first = math.min(first, hunk.target_start_line)
        last = math.max(last, hunk.target_start_line + hunk.target_line_count - 1)
      end
    end
  end
  session.cursor_range = {
    source_line = source_line,
    map = session.map,
    hunks = session.hunks,
    first = first,
    last = last,
  }
  return first, last
end

local function source_to_target_line(session, source_line)
  local first, last = M.target_range(session, source_line)
  return last >= first and math.floor((first + last) / 2) or first
end

function M.sync(session, active_win)
  if
    session.closed
    or session.preview_error
    or not session.map
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
  local active_top = vim.api.nvim_win_call(active_win, vim.fn.winsaveview).topline
  local other_win, other_line
  if is_source then
    other_win = session.target_win
    other_line = source_to_target_line(session, active_line)
  else
    other_win = session.source_win
    other_line = target_to_source_line(session, active_line)
  end
  if vim.api.nvim_win_is_valid(other_win) then
    other_line = math.max(1, math.min(other_line, vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(other_win))))
    vim.api.nvim_win_set_cursor(other_win, { other_line, 0 })
    -- Preserve a logical line offset; folds, wrapping and file edges use native behavior.
    vim.api.nvim_win_call(other_win, function()
      vim.fn.winrestview({ topline = math.max(1, other_line - (active_line - active_top)) })
    end)
    vim.api.nvim__redraw({ win = other_win, valid = false })
  end
  session.syncing = false
end

function M.corresponding_line(session, active_win, line)
  if active_win == session.source_win then
    return session.target_win, source_to_target_line(session, line)
  end
  return session.source_win, target_to_source_line(session, line)
end

return M

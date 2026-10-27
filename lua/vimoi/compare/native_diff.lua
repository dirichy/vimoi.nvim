-- Adapt source-mapped template hunks to Neovim's native diff protocol.
local M = {}
local util = require("vimoi.core.util")
local sync_scroll = require("vimoi.compare.sync_scroll")

---Line ranges use the same vim.text.diff convention as VimoiDiffHunk.
---@class VimoiNativeDiffHunk
---@field source_start_line integer
---@field source_line_count integer
---@field target_start_line integer
---@field target_line_count integer

-- Delegate unrelated diff windows and restore the user's handler after the last view.
local diffexpr_dispatcher = "v:lua.require'vimoi.compare'._diffexpr()"
---@type string?
local previous_diffexpr

---@param source_starts integer[]
---@param ranges VimoiDiffRange[]
local function source_line_range(source_starts, ranges)
  if #ranges == 0 then
    return 0, 0
  end
  local start_byte = ranges[1].start_byte
  local end_byte = ranges[1].end_byte
  for index = 2, #ranges do
    start_byte = math.min(start_byte, ranges[index].start_byte)
    end_byte = math.max(end_byte, ranges[index].end_byte)
  end
  local start_row, start_col = util.byte_to_position(nil, start_byte, source_starts)
  local end_row, end_col = util.byte_to_position(nil, end_byte, source_starts)
  if start_byte == end_byte then
    if start_col == 0 then
      return start_row, 0
    end
    return start_row + 1, 1
  end
  local end_exclusive = end_row + (end_col > 0 and 1 or 0)
  return start_row + 1, math.max(1, end_exclusive - start_row)
end

---@param map VimoiOutputMap
---@param hunks VimoiDiffHunk[]
---@return VimoiNativeDiffHunk[]
local function projected_hunks(map, hunks)
  local result = {}
  for _, hunk in ipairs(hunks) do
    local source_start_line, source_line_count = source_line_range(map.source_starts, hunk.source_ranges)
    result[#result + 1] = {
      source_start_line = source_start_line,
      source_line_count = source_line_count,
      target_start_line = hunk.target_start_line,
      target_line_count = hunk.target_line_count,
    }
  end
  return result
end

local function projected_unified_diff(original_text, modified_text, hunks, reverse)
  local original_lines = util.text_lines(original_text)
  local modified_lines = util.text_lines(modified_text)
  local output = { "--- input", "+++ new" }
  for _, hunk in ipairs(hunks) do
    local original_start_line = reverse and hunk.target_start_line or hunk.source_start_line
    local original_line_count = reverse and hunk.target_line_count or hunk.source_line_count
    local modified_start_line = reverse and hunk.source_start_line or hunk.target_start_line
    local modified_line_count = reverse and hunk.source_line_count or hunk.target_line_count
    output[#output + 1] = ("@@ -%s +%s @@"):format(
      ("%d,%d"):format(original_start_line, original_line_count),
      ("%d,%d"):format(modified_start_line, modified_line_count)
    )
    for line = original_start_line, original_start_line + original_line_count - 1 do
      output[#output + 1] = "-" .. (original_lines[line] or "")
    end
    for line = modified_start_line, modified_start_line + modified_line_count - 1 do
      output[#output + 1] = "+" .. (modified_lines[line] or "")
    end
  end
  return table.concat(output, "\n") .. "\n"
end

local function write_diff(path, output)
  local lines = vim.split(output, "\n", { plain = true })
  if lines[#lines] == "" then
    table.remove(lines)
  end
  vim.fn.writefile(lines, path)
end

---@param sessions table<integer, VimoiTemplateView> Window registry owned by compare/init.lua.
function M.diffexpr(sessions)
  local original_text = util.read_file(vim.v.fname_in) or ""
  local modified_text = util.read_file(vim.v.fname_new) or ""
  local visited = {}
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local session = sessions[win]
    if session and not visited[session] then
      visited[session] = true
      if
        not session.preview
        and session.map
        and vim.api.nvim_buf_is_valid(session.source_buf)
        and vim.api.nvim_buf_is_valid(session.target_buf)
      then
        local source = util.buffer_text(session.source_buf)
        local modified = util.buffer_text(session.target_buf)
        if original_text == source and modified_text == modified then
          write_diff(
            vim.v.fname_out,
            projected_unified_diff(original_text, modified_text, session.projected_hunks or {}, false)
          )
          return
        end
        if original_text == modified and modified_text == source then
          write_diff(
            vim.v.fname_out,
            projected_unified_diff(original_text, modified_text, session.projected_hunks or {}, true)
          )
          return
        end
      end
    end
  end
  if previous_diffexpr and previous_diffexpr ~= "" then
    local ok = pcall(vim.fn.eval, previous_diffexpr)
    if ok then
      return
    end
  end
  local fallback = util.diff(original_text, modified_text, {
    result_type = "unified",
    ctxlen = 0,
    algorithm = "histogram",
  })
  assert(type(fallback) == "string")
  write_diff(vim.v.fname_out, fallback)
end

local function install_diffexpr_dispatcher()
  if vim.o.diffexpr ~= diffexpr_dispatcher then
    previous_diffexpr = vim.o.diffexpr
    vim.o.diffexpr = diffexpr_dispatcher
  end
end

---@param sessions table<integer, VimoiTemplateView>
function M.restore_diffexpr_if_unused(sessions)
  for _, session in pairs(sessions) do
    if not session.preview then
      return
    end
  end
  if vim.o.diffexpr == diffexpr_dispatcher then
    vim.o.diffexpr = previous_diffexpr or ""
  end
end

---@param session VimoiTemplateView
function M.update(session)
  session.projected_hunks = projected_hunks(assert(session.map), session.hunks)
  install_diffexpr_dispatcher()
  local ok, error_message = pcall(function()
    vim.api.nvim_win_call(session.source_win, function()
      if not vim.wo[session.source_win].diff then
        vim.cmd("diffthis")
      end
    end)
    vim.api.nvim_win_call(session.target_win, function()
      if not vim.wo[session.target_win].diff then
        vim.cmd("diffthis")
      end
      -- Completion may run while the user is in another tab. Update this diff
      -- in its own window without changing the user's active tab/window.
      vim.cmd("diffupdate")
    end)
  end)
  for _, win in ipairs({ session.source_win, session.target_win }) do
    if vim.api.nvim_win_is_valid(win) then
      vim.wo[win].scrollbind = false
      vim.wo[win].cursorbind = false
    end
  end
  if not ok then
    error(error_message)
  end
end

local function hunk_contains_line(start, count, line)
  if count == 0 then
    return line == math.max(1, start) or line == start + 1
  end
  return line >= start and line < start + count
end

---@param session VimoiTemplateView
---@param buf integer
---@param line integer One-based line at the time the user requested the merge.
---@return VimoiDiffHunk?
function M.hunk_at(session, buf, line)
  local projected = session.projected_hunks or projected_hunks(assert(session.map), session.hunks)
  for index, native in ipairs(projected) do
    local start = buf == session.source_buf and native.source_start_line or native.target_start_line
    local count = buf == session.source_buf and native.source_line_count or native.target_line_count
    if hunk_contains_line(start, count, line) then
      return session.hunks[index]
    end
  end
end

---Apply a fold command in both mapped diff windows.
---@param session VimoiTemplateView
---@param command string
function M.fold(session, command)
  local active_win = vim.api.nvim_get_current_win()
  local active_line = vim.api.nvim_win_get_cursor(active_win)[1]
  local other_win, other_line = sync_scroll.corresponding_line(session, active_win, active_line)
  if not vim.tbl_contains(require("vimoi").fold_commands, command) then
    return util.notify("unsupported fold command: " .. command, "diff", vim.log.levels.ERROR)
  end

  vim.api.nvim_win_call(active_win, function()
    vim.cmd("normal! " .. command)
  end)
  if not vim.api.nvim_win_is_valid(other_win) then
    return
  end
  vim.api.nvim_win_call(other_win, function()
    if command ~= "zR" and command ~= "zM" then
      local count = vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(other_win))
      vim.api.nvim_win_set_cursor(other_win, { math.max(1, math.min(other_line, count)), 0 })
    end
    local mirrored = command
    if command == "za" or command == "zA" then
      local active_closed = vim.api.nvim_win_call(active_win, function()
        return vim.fn.foldclosed(active_line) ~= -1
      end)
      mirrored = active_closed and (command == "zA" and "zC" or "zc") or (command == "zA" and "zO" or "zo")
    end
    vim.cmd("silent! normal! " .. mirrored)
  end)
  sync_scroll.sync(session, active_win)
end

return M

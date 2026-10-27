local M = {}

-- Neovim 0.12 renamed vim.diff to vim.text.diff.
---@diagnostic disable-next-line: deprecated -- Neovim 0.11 compatibility.
M.diff = vim.text.diff or vim.diff

---Notify with a vimoi prefix and an optional feature label.
---@param message string
---@param prefix? string Optional label following "vimoi"; nil or empty omits it.
---@param level? integer Defaults to vim.log.levels.INFO.
function M.notify(message, prefix, level)
  local title = prefix and prefix ~= "" and "vimoi " .. prefix or "vimoi"
  vim.notify(title .. ": " .. message, level or vim.log.levels.INFO)
end

---Await an asynchronous result inside an explicitly started coroutine.
---The editor's normal input/event loop keeps running while the caller is suspended.
---@param start fun(done: function)
---@return any ...
function M.await(start)
  local thread = assert(coroutine.running(), "long-running commands require an asynchronous workflow")
  local done, values = false, { n = 0 }
  start(function(...)
    if done then
      return
    end
    done, values = true, { n = select("#", ...), ... }
    if coroutine.status(thread) == "suspended" then
      local ok, err = coroutine.resume(thread, ...)
      if not ok then
        error(err, 0)
      end
    end
  end)
  if done then
    return unpack(values, 1, values.n)
  end
  return coroutine.yield()
end

---Start an imperative workflow that may await modal commands.
---@param work function
---@param ... any Arguments passed to the workflow.
---@return any ... Immediate results, or nil while work is suspended.
function M.async(work, ...)
  local result = vim.F.pack_len(coroutine.resume(coroutine.create(work), ...))
  if not result[1] then
    error(result[2], 0)
  end
  return unpack(result, 2, result.n)
end

---Return a normalized absolute path, expanding ~ and preserving literal $ characters.
---This is lexical normalization; symlinks are not resolved.
---@param path string
---@return string
function M.normalize_path(path)
  return vim.fs.normalize(vim.fs.abspath(path), { expand_env = false })
end

---Wrap initialization so it runs only once. A failed call may be retried.
---@param initialize fun(...)
---@param opts? { repeat_error?: string } Report the supplied error instead of skipping repeated calls.
---@return fun(...)
function M.once(initialize, opts)
  local initialized = false
  return function(...)
    if initialized then
      if opts and opts.repeat_error then
        error(opts.repeat_error, 0)
      end
      return
    end
    initialize(...)
    initialized = true
  end
end

---@param path string
---@return string? content
---@return string? error
function M.read_file(path)
  local file_descriptor, open_error = vim.uv.fs_open(path, "r", 438)
  if not file_descriptor then
    return nil, open_error
  end
  local file_stat, stat_error = vim.uv.fs_fstat(file_descriptor)
  if not file_stat then
    vim.uv.fs_close(file_descriptor)
    return nil, stat_error
  end
  local data, read_error = vim.uv.fs_read(file_descriptor, file_stat.size, 0)
  vim.uv.fs_close(file_descriptor)
  return data, read_error
end

---@param buf integer
---@return string
function M.buffer_text(buf)
  local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  return vim.bo[buf].endofline and text .. "\n" or text
end

---@param buf integer
---@param text string
function M.set_buffer_text(buf, text)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, M.text_lines(text))
  vim.bo[buf].endofline = text:sub(-1) == "\n"
end

---Convert a zero-based byte offset to a zero-based row and byte column.
---@param text string? Not needed when line_start_bytes is supplied.
---@param byte integer
---@param line_start_bytes? integer[] Cached line starts for repeated position lookups.
---@return integer row
---@return integer col
function M.byte_to_position(text, byte, line_start_bytes)
  if line_start_bytes then
    local first, last = 1, #line_start_bytes
    while first < last do
      local middle = math.ceil((first + last) / 2)
      if line_start_bytes[middle] <= byte then
        first = middle
      else
        last = middle - 1
      end
    end
    return first - 1, byte - line_start_bytes[first]
  end
  local text_before_position = assert(text):sub(1, byte)
  local _, row = text_before_position:gsub("\n", "\n")
  local last_newline = text_before_position:match(".*()\n") or 0
  return row, byte - last_newline
end

---@param text string
---@return integer[]
function M.line_starts(text)
  local result = { 0 }
  local cursor = 1
  while true do
    local newline = text:find("\n", cursor, true)
    if not newline then
      return result
    end
    result[#result + 1] = newline
    cursor = newline + 1
  end
end

---@param text string
---@return string[]
function M.text_lines(text)
  local lines = vim.split(text, "\n", { plain = true })
  if text:sub(-1) == "\n" then
    table.remove(lines)
  end
  return lines
end

---@param text string
---@param line_start_bytes integer[]
---@param start_line integer one-based line number, as returned by vim.text.diff
---@param count integer
---@return integer start_byte
---@return integer end_byte
function M.line_range(text, line_start_bytes, start_line, count)
  if count == 0 then
    local byte = line_start_bytes[start_line + 1] or #text
    return byte, byte
  end
  return line_start_bytes[start_line] or #text, line_start_bytes[start_line + count] or #text
end

---Return the smallest changed byte range and its replacement text.
---@param before string
---@param after string
---@return integer start_byte
---@return integer end_byte
---@return string replacement
function M.changed_bytes(before, after)
  local common_prefix_bytes = 0
  local limit = math.min(#before, #after)
  while common_prefix_bytes < limit and before:byte(common_prefix_bytes + 1) == after:byte(common_prefix_bytes + 1) do
    common_prefix_bytes = common_prefix_bytes + 1
  end
  local common_suffix_bytes = 0
  while
    common_suffix_bytes < #before - common_prefix_bytes
    and common_suffix_bytes < #after - common_prefix_bytes
    and before:byte(#before - common_suffix_bytes) == after:byte(#after - common_suffix_bytes)
  do
    common_suffix_bytes = common_suffix_bytes + 1
  end
  return common_prefix_bytes,
    #before - common_suffix_bytes,
    after:sub(common_prefix_bytes + 1, #after - common_suffix_bytes)
end

return M

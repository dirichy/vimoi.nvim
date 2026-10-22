local M = {}
local util = require("vimoi.util")
local cli = require("vimoi.cli")
local filetype = require("vimoi.filetype")

local function is_absolute(path)
  return path:sub(1, 1) == "/" or path:match("^%a:[/\\]") ~= nil or path:match("^[/\\][/\\]") ~= nil
end

local function load_path_roots()
  local data, data_error = cli.data()
  if not data then
    return nil, data_error
  end
  return {
    source_dir = util.normalize_path(data.chezmoi.sourceDir),
    dest_dir = util.normalize_path(data.chezmoi.destDir),
  }
end

local function template_string_value(node, buf)
  local text = vim.treesitter.get_node_text(node, buf)
  local quote = text:sub(1, 1)
  if (quote ~= '"' and quote ~= "`") or text:sub(-1) ~= quote then
    return nil
  end
  text = text:sub(2, -2)
  if quote == '"' then
    text = text:gsub('\\"', '"'):gsub("\\\\", "\\")
  end
  return text
end

local function template_reference(buf, row, col)
  local ok, parser = pcall(vim.treesitter.get_parser, buf, "gotmpl")
  if not ok or not parser then
    return nil
  end
  local tree = parser:parse()[1]
  local node = tree and tree:root():named_descendant_for_range(row, col, row, col)
  if not node then
    return nil
  end
  while node and node:type() ~= "interpreted_string_literal" and node:type() ~= "raw_string_literal" do
    node = node:parent()
  end
  if not node then
    return nil
  end
  local referenced_path = template_string_value(node, buf)
  local parent = node:parent()
  if not referenced_path or not parent then
    return nil
  end
  if parent:type() == "template_action" then
    local name_node = parent:field("name")[1]
    return name_node and name_node:id() == node:id() and "template" or nil, referenced_path
  end
  if parent:type() ~= "argument_list" or not parent:parent() or parent:parent():type() ~= "function_call" then
    return nil
  end
  local call = parent:parent()
  local first_argument = parent:named_child(0)
  if not first_argument or first_argument:id() ~= node:id() then
    return nil
  end
  local function_node = call and call:field("function")[1]
  local name = function_node and vim.treesitter.get_node_text(function_node, buf)
  if name == "include" or name == "includeTemplate" or name == "glob" then
    return name, referenced_path
  end
end

local function find_template_paths(source_dir, name)
  local result = {}
  for _, directory in ipairs(cli.template_directories(source_dir)) do
    local candidate = vim.fs.joinpath(directory, name)
    if vim.uv.fs_stat(candidate) then
      result[#result + 1] = candidate
    end
  end
  table.sort(result)
  return result
end

local function resolve_relative_path(base, path)
  local expanded_ok, expanded = pcall(vim.fn.expand, path)
  if expanded_ok and type(expanded) == "string" then
    path = expanded
  end
  return util.normalize_path(is_absolute(path) and path or vim.fs.joinpath(base, path))
end

local function prefer_source_path(target)
  local source_root = cli.source_root
  if source_root and vim.fs.relpath(source_root, target) ~= nil then
    return target
  end
  local source, source_error = cli.counterpart_path(target)
  if not source then
    return nil, source_error
  end
  if source ~= "" and vim.uv.fs_stat(source) then
    return source
  end
  return target
end

local function prefer_source_paths(targets)
  local result = {}
  local seen = {}
  for _, target in ipairs(targets) do
    local path, path_error = prefer_source_path(target)
    if not path then
      return nil, path_error
    end
    if not seen[path] then
      seen[path] = true
      result[#result + 1] = path
    end
  end
  return result
end

local function path_under_cursor(buf, row, col)
  local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
  col = col + 1
  local start_col = col
  while start_col > 1 and not line:sub(start_col - 1, start_col - 1):match("[%s\"'`]") do
    start_col = start_col - 1
  end
  local end_col = col
  while end_col <= #line and not line:sub(end_col, end_col):match("[%s\"'`]") do
    end_col = end_col + 1
  end
  return line:sub(start_col, end_col - 1):gsub("^[!]+", "")
end

local function split_path_location(path)
  local filename, line, col = path:match("^(.-):(%d+):(%d+)$")
  if not filename then
    filename, line = path:match("^(.-):(%d+)$")
  end
  if not filename or filename == "" then
    return path
  end
  return filename, { line = tonumber(line), col = tonumber(col) }
end

---@param buf? integer
---@param row? integer zero-based
---@param col? integer zero-based
---@param line_numbers? boolean
---@return string[]? paths
---@return string? error
---@return { line: integer, col: integer? }? location
function M.resolve(buf, row, col, line_numbers)
  buf = buf or vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  row = row or cursor[1] - 1
  col = col or cursor[2]

  local reference_type, referenced_path = template_reference(buf, row, col)
  local location
  if line_numbers and referenced_path then
    referenced_path, location = split_path_location(referenced_path)
  end
  local file_path = vim.api.nvim_buf_get_name(buf)
  local path_kind = filetype.path_kind(file_path)
  local roots
  if reference_type or path_kind == "target_patterns" then
    local roots_error
    roots, roots_error = load_path_roots()
    if not roots then
      return nil, roots_error
    end
  end
  if reference_type == "template" or reference_type == "includeTemplate" then
    local paths = find_template_paths(roots.source_dir, referenced_path)
    return #paths > 0 and paths or nil, nil, location
  elseif reference_type == "include" then
    local path = resolve_relative_path(roots.source_dir, referenced_path)
    return vim.uv.fs_stat(path) and { path } or nil, nil, location
  elseif reference_type == "glob" then
    local pattern = resolve_relative_path(roots.dest_dir, referenced_path)
    local paths = vim.fn.glob(pattern, false, true)
    if #paths == 0 then
      return nil
    end
    local sources, sources_error = prefer_source_paths(paths)
    return sources, sources_error, location
  end

  local path = path_under_cursor(buf, row, col)
  if line_numbers then
    path, location = split_path_location(path)
  end
  if path_kind == "target_patterns" then
    local pattern = resolve_relative_path(roots.dest_dir, path)
    local paths = vim.fn.glob(pattern, false, true)
    if #paths == 0 then
      return nil
    end
    local sources, sources_error = prefer_source_paths(paths)
    return sources, sources_error, location
  elseif path_kind == "symlink_target" then
    local target, target_error = cli.counterpart_path(file_path)
    if not target then
      return nil, target_error
    end
    local link_target = resolve_relative_path(vim.fs.dirname(vim.trim(target)), path)
    if not vim.uv.fs_stat(link_target) then
      return nil
    end
    local source, source_error = prefer_source_path(link_target)
    return source and { source } or nil, source_error, location
  end

  if path:sub(1, 7) == "file://" then
    local uri_ok, uri_path = pcall(vim.uri_to_fname, path)
    if uri_ok and vim.uv.fs_stat(uri_path) then
      return { util.normalize_path(uri_path) }, nil, location
    end
  end
  local expanded_ok, expanded = pcall(vim.fn.expand, path)
  if expanded_ok and type(expanded) == "string" then
    path = expanded
  end
  if is_absolute(path) and vim.uv.fs_stat(path) then
    return { util.normalize_path(path) }, nil, location
  end
end

---@param opts? { line?: boolean }
function M.open(opts)
  opts = opts or {}
  local win, buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
  local changedtick = vim.api.nvim_buf_get_changedtick(buf)
  local function is_valid()
    return vim.api.nvim_win_is_valid(win)
      and vim.api.nvim_get_current_win() == win
      and vim.api.nvim_win_get_buf(win) == buf
      and vim.api.nvim_buf_get_changedtick(buf) == changedtick
  end
  local paths, resolve_error, location = M.resolve(nil, nil, nil, opts.line)
  if not is_valid() then
    return
  end
  if not paths then
    if resolve_error then
      util.notify(resolve_error, "gf", vim.log.levels.WARN)
      return
    end
    local ok, native_error = pcall(function()
      vim.cmd(opts.line and "normal! gF" or "normal! gf")
    end)
    if not ok then
      local message = tostring(native_error):gsub("^Vim%(normal%):", "")
      util.notify(message, "gf", vim.log.levels.WARN)
    end
    return
  end
  local function open(path)
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    if location then
      local last_line = vim.api.nvim_buf_line_count(0)
      local line = math.max(1, math.min(location.line, last_line))
      local text = vim.api.nvim_buf_get_lines(0, line - 1, line, false)[1] or ""
      local col = math.max(0, math.min((location.col or 1) - 1, #text))
      vim.api.nvim_win_set_cursor(0, { line, col })
    end
  end
  if #paths == 1 then
    open(paths[1])
    return
  end
  vim.ui.select(
    paths,
    { prompt = "Vimoi path:" },
    util.guard(function(path)
      if path then
        open(path)
      end
    end, { is_valid = is_valid })
  )
end

return M

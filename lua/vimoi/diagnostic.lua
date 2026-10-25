local M = {}
local util = require("vimoi.util")
local namespace = vim.api.nvim_create_namespace("vimoi-diagnostics")

local sessions = require("vimoi.gotmpl.session")

local host_namespace = vim.api.nvim_create_namespace("vimoi-host-diagnostics")

---@class VimoiHostDiagnostic
---@field output_buf integer Shared rendered buffer receiving native diagnostics.
---@field map VimoiOutputMap
---@field filetype string Host filetype of this snapshot.
---@field jobs { cancel: fun(self: table) }[] nvim-lint processes owned by this snapshot.

---@type table<integer, VimoiHostDiagnostic>
local host_buffers = {}

---@param buf integer
---@param detach? boolean Stop native LSP attachments when disabling host diagnostics.
function M.clear_host(buf, detach)
  local state = host_buffers[buf]
  vim.diagnostic.reset(host_namespace, buf)
  if state then
    for _, job in ipairs(state.jobs) do
      job:cancel()
    end
    state.jobs = {}
    if detach then
      host_buffers[buf] = nil
      if vim.api.nvim_buf_is_valid(state.output_buf) then
        vim.bo[state.output_buf].buftype = "nofile"
        for _, client in ipairs(vim.lsp.get_clients({ bufnr = state.output_buf })) do
          vim.lsp.buf_detach_client(state.output_buf, client.id)
        end
      end
    end
  end
end

---@param map VimoiOutputMap
---@param diagnostics vim.Diagnostic[]
---@param filetype string
---@return vim.Diagnostic[]
local function project(map, diagnostics, filetype)
  local projected, seen = {}, {}
  local regions = map.regions
  local output_starts = map.output_starts
  local source_starts = map.source_starts
  for _, diagnostic in ipairs(diagnostics) do
    local first_line = output_starts[diagnostic.lnum + 1]
    local last_line = output_starts[(diagnostic.end_lnum or diagnostic.lnum) + 1]
    if first_line and last_line then
      local first = math.min(first_line + diagnostic.col, map.output_size)
      local last = math.max(first, math.min(last_line + (diagnostic.end_col or diagnostic.col), map.output_size))
      local source_first, source_last
      local generated = false
      for _, region in ipairs(regions) do
        local a, b = region.output_range.start_byte, region.output_range.end_byte
        local overlaps = first < b and last > a
          or (first == last and first >= a and (first < b or first == map.output_size and first == b and a < b))
        if overlaps and region.kind ~= "ambiguous" then
          local start_byte, end_byte = region.source.start_byte, region.source.end_byte
          if region.kind == "static" or region.kind == "repeated" then
            start_byte = start_byte + math.max(first - a, 0)
            end_byte = region.source.start_byte + math.min(last - a, b - a)
          else
            generated = true
          end
          source_first = math.min(source_first or start_byte, start_byte)
          source_last = math.max(source_last or end_byte, end_byte)
        end
      end
      if source_first and source_last then
        if source_first == map.source_size and map.source_eol then
          source_first = math.max(source_first - 1, 0)
        end
        local item = vim.deepcopy(diagnostic)
        item.lnum, item.col = util.byte_to_position(nil, source_first, source_starts)
        item.end_lnum, item.end_col = util.byte_to_position(nil, source_last, source_starts)
        item.bufnr, item.namespace = nil, nil
        item.message = ("[host:%s] %s"):format(filetype, item.message)
        if generated then
          item.message = item.message .. " (template-generated output)"
        end
        local key = ("%d:%d:%s:%s:%s:%s"):format(
          source_first,
          source_last,
          item.source or "",
          item.severity,
          item.code or "",
          item.message
        )
        if not seen[key] then
          seen[key] = true
          projected[#projected + 1] = item
        end
      end
    end
  end
  return projected
end

vim.api.nvim_create_autocmd("DiagnosticChanged", {
  group = vim.api.nvim_create_augroup("vimoi-host-diagnostics", { clear = true }),
  callback = function(args)
    local source = vim.b[args.buf].vimoi_output_source
    local state = source and host_buffers[source]
    if
      not state
      or state.output_buf ~= args.buf
      or not vim.api.nvim_buf_is_loaded(source)
      or vim.bo[source].filetype ~= "gotmpl"
      or not sessions.is_current(source, state.map)
    then
      return
    end
    vim.diagnostic.set(host_namespace, source, project(state.map, vim.diagnostic.get(args.buf), state.filetype))
  end,
})

---@param buf integer
---@param map VimoiOutputMap
local function update_host(buf, map)
  local filetype = vim.b[buf].vimoi_template_filetype
  if not filetype or filetype == "" or filetype == "gotmpl" or filetype == "template" then
    M.clear_host(buf, true)
    return
  end
  local rendered = sessions.get(buf).buf
  local previous = host_buffers[buf]
  if previous and previous.map == map and previous.filetype == filetype and previous.output_buf == rendered then
    return
  end
  M.clear_host(buf, vim.bo[rendered].filetype ~= filetype)
  local state = {
    output_buf = rendered,
    map = map,
    filetype = filetype,
    jobs = {},
  }
  host_buffers[buf] = state
  -- Native LSP requires a normal buffer. Keep its identity and let didChange
  -- replace diagnostics as it does for an ordinary edited file.
  local activate = vim.bo[rendered].buftype ~= ""
  vim.bo[rendered].buftype = ""
  if vim.bo[rendered].filetype ~= filetype then
    vim.bo[rendered].filetype = filetype
  elseif activate then
    vim.api.nvim_exec_autocmds("FileType", { buffer = rendered })
  end
  -- Source-only changes can move mappings without changing output. LSP then
  -- sends no didChange/result, so reproject its retained diagnostics now.
  vim.diagnostic.set(host_namespace, buf, project(map, vim.diagnostic.get(rendered), filetype))
  local ok, lint = pcall(require, "lint")
  if not ok then
    return
  end
  vim.api.nvim_buf_call(rendered, function()
    local names = lint.linters_by_ft[filetype] or {}
    for _, name in ipairs(names) do
      local started, job = pcall(function()
        local linter = lint.linters[name]
        linter = type(linter) == "function" and linter() or vim.deepcopy(linter)
        if not linter or not linter.stdin then
          return
        end
        linter.name = name
        return lint.lint(linter)
      end)
      if started and job then
        state.jobs[#state.jobs + 1] = job
      elseif not started then
        util.notify(tostring(job), "diagnostic", vim.log.levels.WARN)
      end
    end
  end)
end

---@param node TSNode
---@param message string
---@return vim.Diagnostic
local function node_diagnostic(node, message)
  local row, col, end_row, end_col = node:range()
  return {
    lnum = row,
    col = col,
    end_lnum = end_row,
    end_col = end_col,
    severity = vim.diagnostic.severity.ERROR,
    source = "vimoi",
    message = "[gotmpl] " .. message,
  }
end

-- Walk only error-bearing branches. Parser recovery can wrap an entire block
-- in ERROR; prefer its more specific descendants when they exist.
---@param node TSNode
---@param diagnostics vim.Diagnostic[]
local function syntax_errors(node, diagnostics)
  if node:missing() then
    diagnostics[#diagnostics + 1] = node_diagnostic(node, "Missing " .. node:type())
    return
  end
  if not node:has_error() then
    return
  end
  local before = #diagnostics
  for child in node:iter_children() do
    syntax_errors(child, diagnostics)
  end
  if node:type() == "ERROR" and #diagnostics == before then
    diagnostics[#diagnostics + 1] = node_diagnostic(node, "Invalid Go template syntax")
  end
end

---@param state VimoiSourceSession
---@return vim.Diagnostic?
local function render_error(buf, state)
  local source, root = util.buffer_text(buf), assert(state.root)
  local err = assert(state.error)
  local line, column, message = err:match("template: stdin:(%d+):(%d+):%s*(.*)")
  if not line then
    line, message = err:match("template: stdin:(%d+):%s*(.*)")
  end
  if not line then
    return
  end
  local starts = util.line_starts(assert(state.skeleton))
  local first = starts[tonumber(line)]
  if not first then
    return
  end
  local last = starts[tonumber(line) + 1] or #assert(state.skeleton) + 1
  -- Go template execution errors use one-based lines but ZERO-based byte columns.
  local byte = column and first + tonumber(column)
  local candidates = {}
  for _, tag in ipairs(assert(state.error_tags)) do
    local start_byte = assert(tag.skeleton_start_byte)
    local end_byte = start_byte + #tag.text
    if byte and byte >= start_byte and byte < end_byte then
      local source_byte = tag.start_byte + byte - start_byte
      local row, col = util.byte_to_position(source, source_byte)
      local node = root:named_descendant_for_range(row, col, row, col)
      local diagnostic = node_diagnostic(node or root, assert(message))
      diagnostic.lnum, diagnostic.col = row, col
      local _, _, node_end = (node or root):end_()
      if not node or node_end > tag.end_byte then
        diagnostic.end_lnum, diagnostic.end_col = row, col + 1
      end
      return diagnostic
    end
    if not byte and start_byte < last and end_byte > first then
      candidates[#candidates + 1] = tag
    end
  end
  if byte then
    return
  end

  -- Parse errors often have only a line number. Match the named function or
  -- variable in syntax, so an earlier quoted string cannot steal its location.
  local name = message:match('function "([^"]+)" not defined') or message:match('undefined variable "([^"]+)"')
  if name then
    local function find(node)
      local identifier
      if node:type() == "function_call" then
        identifier = node:field("function")[1]
      elseif name:sub(1, 1) == "$" then
        identifier = node
      end
      if identifier and vim.treesitter.get_node_text(identifier, source) == name then
        local _, _, identifier_byte = identifier:start()
        for _, tag in ipairs(candidates) do
          if identifier_byte >= tag.start_byte and identifier_byte < tag.end_byte then
            return identifier
          end
        end
      end
      for child in node:iter_children() do
        local found = find(child)
        if found then
          return found
        end
      end
    end
    local found = find(root)
    if found then
      return node_diagnostic(found, message)
    end
  end
  if #candidates == 1 then
    local tag = candidates[1]
    local row, col = util.byte_to_position(source, tag.start_byte)
    local end_row, end_col = util.byte_to_position(source, tag.end_byte)
    local diagnostic = node_diagnostic(root, message)
    diagnostic.lnum, diagnostic.col = row, col
    diagnostic.end_lnum, diagnostic.end_col = end_row, end_col
    return diagnostic
  end
end

---@param buf integer
function M.update(buf)
  local state = sessions.get(buf)
  local config = require("vimoi").config.diagnostics
  local diagnostics = {}
  if state.root and state.root:has_error() then
    syntax_errors(state.root, diagnostics)
  elseif state.error then
    local diagnostic = state.error_tags and render_error(buf, state)
    if diagnostic then
      diagnostics[1] = diagnostic
    elseif not state.reported then
      state.reported = true
      util.notify(state.error, "diagnostic", vim.log.levels.WARN)
    end
  end
  vim.diagnostic.set(namespace, buf, diagnostics)
  if config.host and not state.error and state.map then
    update_host(buf, state.map)
  elseif host_buffers[buf] then
    M.clear_host(buf)
  end
end

---Clear this module's diagnostics and invalidate outstanding host checks.
---@param buf integer
---@param detach? boolean Detach native host providers when their consumer stops.
function M.clear(buf, detach)
  vim.diagnostic.reset(namespace, buf)
  M.clear_host(buf, detach)
end

return M

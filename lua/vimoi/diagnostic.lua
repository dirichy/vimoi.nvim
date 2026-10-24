local M = {}
local util = require("vimoi.util")
local namespace = vim.api.nvim_create_namespace("vimoi-diagnostics")

local sessions = require("vimoi.gotmpl.session")

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
    require("vimoi.host_diagnostic").update(buf, state.map)
  elseif package.loaded["vimoi.host_diagnostic"] then
    require("vimoi.host_diagnostic").clear(buf)
  end
end

---Clear this module's diagnostics and invalidate outstanding host checks.
---@param buf integer
---@param detach? boolean Detach native host providers when their consumer stops.
function M.clear(buf, detach)
  vim.diagnostic.reset(namespace, buf)
  if package.loaded["vimoi.host_diagnostic"] then
    require("vimoi.host_diagnostic").clear(buf, detach)
  end
end

return M

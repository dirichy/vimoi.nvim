local M = {}
local util = require("vimoi.util")
local cli = require("vimoi.cli")
local namespace = vim.api.nvim_create_namespace("vimoi-diagnostics")

---@class VimoiDiagnosticBuffer
---@field check? function Guard-owned debounced computation and result publication.
---@field tick? integer Buffer version represented by prepared/root.
---@field root? TSNode
---@field prepared? VimoiPreparedTrace
---@field skeleton? string
---@field init? boolean
---@field context_generation? integer
---@field result? { error?: string, reported?: boolean, rendered_skeleton?: string } Cached success or failure for the current skeleton/context.
---@field request? table Identity of the current asynchronous request.
---@field job? VimoiCommand
---@field prepare_error? string

---@type table<integer, VimoiDiagnosticBuffer>
local buffers = {}
local enabled, host_enabled, rendered_enabled

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

---@param state VimoiDiagnosticBuffer
---@return vim.Diagnostic?
local function render_error(state)
  local prepared, root = assert(state.prepared), assert(state.root)
  local err = assert(assert(state.result).error)
  local line, column, message = err:match("template: stdin:(%d+):(%d+):%s*(.*)")
  if not line then
    line, message = err:match("template: stdin:(%d+):%s*(.*)")
  end
  if not line then
    return
  end
  local starts = util.line_starts(prepared.skeleton)
  local first = starts[tonumber(line)]
  if not first then
    return
  end
  local last = starts[tonumber(line) + 1] or #prepared.skeleton + 1
  -- Go template execution errors use one-based lines but ZERO-based byte columns.
  local byte = column and first + tonumber(column)
  local candidates = {}
  for _, tag in ipairs(prepared.template_tags) do
    local start_byte = assert(tag.skeleton_start_byte)
    local end_byte = start_byte + #tag.text
    if byte and byte >= start_byte and byte < end_byte then
      local source_byte = tag.start_byte + byte - start_byte
      local row, col = util.byte_to_position(prepared.source, source_byte)
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
      if identifier and vim.treesitter.get_node_text(identifier, prepared.source) == name then
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
    local row, col = util.byte_to_position(prepared.source, tag.start_byte)
    local end_row, end_col = util.byte_to_position(prepared.source, tag.end_byte)
    local diagnostic = node_diagnostic(root, message)
    diagnostic.lnum, diagnostic.col = row, col
    diagnostic.end_lnum, diagnostic.end_col = end_row, end_col
    return diagnostic
  end
end

---@param buf integer
---@param state VimoiDiagnosticBuffer
local function publish(buf, state)
  local result = assert(state.result)
  local diagnostic = result.error and render_error(state)
  if enabled then
    vim.diagnostic.set(namespace, buf, diagnostic and { diagnostic } or {})
  end
  if (host_enabled or rendered_enabled) and not result.error then
    local trace = require("vimoi.gotmpl.source_map").restore(assert(state.prepared), result.rendered_skeleton)
    if trace then
      if host_enabled then
        require("vimoi.host_diagnostic").update(buf, trace)
      end
      if rendered_enabled then
        require("vimoi.host_highlight").update(buf, trace)
      end
    end
  end
  if enabled and result.error and not diagnostic and not result.reported then
    result.reported = true
    util.notify(result.error, "diagnostic", vim.log.levels.WARN)
  end
end

---@param state VimoiDiagnosticBuffer
local function cancel_request(state)
  state.request = nil
  if state.job then
    state.job.cancel()
    state.job = nil
  end
end

---@param buf integer
---@param state VimoiDiagnosticBuffer
---@return { tick: integer, diagnostics?: vim.Diagnostic[] }?
local function check(buf, state)
  local source = util.buffer_text(buf)
  local ok, parser = pcall(vim.treesitter.get_parser, buf, "gotmpl")
  if not ok or not parser then
    if not state.prepare_error then
      state.prepare_error = tostring(parser)
      util.notify("gotmpl parser is required; run :checkhealth vimoi", "diagnostic", vim.log.levels.WARN)
    end
    return
  end
  local tree = parser:parse()[1]
  local root = tree and tree:root()
  if not root then
    return
  end
  if root:has_error() then
    cancel_request(state)
    local diagnostics = {}
    syntax_errors(root, diagnostics)
    return { tick = vim.api.nvim_buf_get_changedtick(buf), diagnostics = diagnostics }
  end
  local filetype = require("vimoi.filetype")
  local init = filetype.init_template_names[vim.fs.basename(vim.api.nvim_buf_get_name(buf))] == true
  local prepared, prepare_error = require("vimoi.gotmpl.source_map").prepare(source, { buf = buf, init = init })
  if not prepared then
    cancel_request(state)
    if state.prepare_error ~= prepare_error then
      state.prepare_error = prepare_error
      util.notify(assert(prepare_error), "diagnostic", vim.log.levels.WARN)
    end
    return
  end
  state.prepare_error = nil
  state.prepared, state.root, state.tick = prepared, root, vim.api.nvim_buf_get_changedtick(buf)
  if
    state.skeleton ~= prepared.skeleton
    or state.init ~= init
    or state.context_generation ~= cli.context_generation
  then
    cancel_request(state)
    state.result = nil
    state.skeleton, state.init, state.context_generation = prepared.skeleton, init, cli.context_generation
  end
  if #prepared.template_tags == 0 or prepared.output ~= nil then
    cancel_request(state)
    -- With no user actions, expand literal sentinels without executing the
    -- context prelude. It has no output and must not become literal text.
    state.result = { rendered_skeleton = prepared.rendered_skeleton or prepared.skeleton:sub(#prepared.prefix + 1) }
  end
  if state.result then
    return { tick = state.tick }
  end
  if state.request then
    return
  end
  local request, context_generation = {}, cli.context_generation
  state.request = request
  local rendered_skeleton, err = util.await(function(done)
    local job = cli.execute_template(prepared.skeleton, { init = init, cache = true, callback = done })
    ---@cast job VimoiCommand?
    state.job = job
  end)
  -- Always retire this request before the guard decides whether to publish.
  -- An old completion must never clear a newer request's state.
  if buffers[buf] ~= state or state.request ~= request then
    return
  end
  local cancelled = state.job and state.job.cancelled
  state.job, state.request = nil, nil
  if cancelled or context_generation ~= cli.context_generation then
    return
  end
  state.result = { error = err, rendered_skeleton = rendered_skeleton }
  return { tick = state.tick }
end

---@param buf integer
local function request_check(buf)
  local state = buffers[buf]
  if state then
    vim.diagnostic.reset(namespace, buf)
    if package.loaded["vimoi.host_diagnostic"] then
      require("vimoi.host_diagnostic").clear(buf)
    end
    assert(state.check)()
  end
end

local function detach(buf)
  local state = buffers[buf]
  if state then
    buffers[buf] = nil
    cancel_request(state)
    vim.diagnostic.reset(namespace, buf)
    if package.loaded["vimoi.host_diagnostic"] then
      require("vimoi.host_diagnostic").clear(buf)
    end
    if package.loaded["vimoi.host_highlight"] then
      require("vimoi.host_highlight").clear(buf)
    end
  end
end

---Apply the runtime switch and attach to existing/future gotmpl buffers.
function M.setup()
  local requested = require("vimoi").config.diagnostics.enabled
  local requested_host = requested and require("vimoi").config.diagnostics.host
  local requested_rendered = require("vimoi").config.highlight.mode == "rendered"
  if enabled == requested and host_enabled == requested_host and rendered_enabled == requested_rendered then
    return
  end
  if rendered_enabled and not requested_rendered and package.loaded["vimoi.host_highlight"] then
    for buf in pairs(buffers) do
      require("vimoi.host_highlight").clear(buf)
    end
  end
  enabled = requested
  host_enabled = requested_host
  rendered_enabled = requested_rendered
  local group = vim.api.nvim_create_augroup("vimoi-diagnostics", { clear = true })
  if not enabled and not rendered_enabled then
    for buf in pairs(buffers) do
      detach(buf)
    end
    return
  end
  local function attach(buf)
    if not buffers[buf] then
      local state = {}
      buffers[buf] = state
      state.check = util.guard(function()
        return check(buf, state)
      end, {
        delay = 300,
        allow_parallel = true,
        is_valid = function()
          return buffers[buf] == state and vim.api.nvim_buf_is_loaded(buf)
        end,
        should_retry = function(result)
          return result ~= nil and result.tick ~= vim.api.nvim_buf_get_changedtick(buf)
        end,
        on_result = function(result)
          if not result then
            return
          end
          if result.diagnostics then
            if enabled then
              vim.diagnostic.set(namespace, buf, result.diagnostics)
            end
          else
            publish(buf, state)
          end
        end,
      })
    end
    request_check(buf)
  end
  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    callback = function(args)
      if vim.bo[args.buf].filetype == "gotmpl" then
        attach(args.buf)
      else
        detach(args.buf)
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "TextChangedP", "BufWritePost", "BufFilePost" }, {
    group = group,
    callback = function(args)
      request_check(args.buf)
    end,
  })
  vim.api.nvim_create_autocmd({ "BufUnload", "BufWipeout" }, {
    group = group,
    callback = function(args)
      detach(args.buf)
    end,
  })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "VimoiHostFiletypeChanged",
    callback = function(args)
      if package.loaded["vimoi.host_highlight"] then
        require("vimoi.host_highlight").clear(args.data.buf)
      end
      request_check(args.data.buf)
    end,
  })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "VimoiCacheInvalidated",
    callback = function()
      for buf in pairs(buffers) do
        request_check(buf)
      end
    end,
  })
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].filetype == "gotmpl" then
      attach(buf)
    end
  end
end

return M

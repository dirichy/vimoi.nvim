-- Run configured host providers on immutable rendered snapshots, then project
-- their native diagnostics back onto the editable template.
local M = {}
local util = require("vimoi.util")
local source_map = require("vimoi.gotmpl.source_map")
local cli = require("vimoi.cli")
local namespace = vim.api.nvim_create_namespace("vimoi-host-diagnostics")

---@class VimoiHostDiagnostic
---@field source_buf integer
---@field shadow integer Hidden normal buffer so native LSP activation can run.
---@field tick integer
---@field context_generation integer
---@field trace VimoiSourceMapTrace
---@field filetype string Host filetype of this snapshot.
---@field jobs { cancel: fun(self: table) }[] nvim-lint processes owned by this snapshot.

---@type table<integer, VimoiHostDiagnostic>
local buffers = {}
---@type table<integer, VimoiHostDiagnostic>
local shadows = {}

---@param buf integer
function M.clear(buf)
  local state = buffers[buf]
  buffers[buf] = nil
  vim.diagnostic.reset(namespace, buf)
  if state then
    shadows[state.shadow] = nil
    for _, job in ipairs(state.jobs) do
      job:cancel()
    end
    if vim.api.nvim_buf_is_valid(state.shadow) then
      vim.api.nvim_buf_delete(state.shadow, { force = true })
    end
  end
end

---@param trace VimoiSourceMapTrace
---@param diagnostics vim.Diagnostic[]
---@param filetype string
---@return vim.Diagnostic[]
local function project(trace, diagnostics, filetype)
  local projected, seen = {}, {}
  local regions = source_map.rendered_regions(trace)
  local output_starts = util.line_starts(trace.output)
  local source_starts = util.line_starts(trace.source)
  for _, diagnostic in ipairs(diagnostics) do
    local first_line = output_starts[diagnostic.lnum + 1]
    local last_line = output_starts[(diagnostic.end_lnum or diagnostic.lnum) + 1]
    if first_line and last_line then
      local first = math.min(first_line + diagnostic.col, #trace.output)
      local last = math.max(first, math.min(last_line + (diagnostic.end_col or diagnostic.col), #trace.output))
      local source_first, source_last
      local generated = false
      for _, region in ipairs(regions) do
        local a, b = region.output_range.start_byte, region.output_range.end_byte
        local overlaps = first < b and last > a
          or (first == last and first >= a and (first < b or first == #trace.output and first == b and a < b))
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
        if source_first == #trace.source and trace.source:sub(-1) == "\n" then
          source_first = math.max(source_first - 1, 0)
        end
        local item = vim.deepcopy(diagnostic)
        item.lnum, item.col = util.byte_to_position(trace.source, source_first, source_starts)
        item.end_lnum, item.end_col = util.byte_to_position(trace.source, source_last, source_starts)
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
    local state = shadows[args.buf]
    if
      not state
      or not vim.api.nvim_buf_is_loaded(state.source_buf)
      or vim.bo[state.source_buf].filetype ~= "gotmpl"
      or vim.api.nvim_buf_get_changedtick(state.source_buf) ~= state.tick
      or cli.context_generation ~= state.context_generation
    then
      return
    end
    vim.diagnostic.set(namespace, state.source_buf, project(state.trace, vim.diagnostic.get(args.buf), state.filetype))
  end,
})

---@param buf integer
---@param trace VimoiSourceMapTrace
function M.update(buf, trace)
  M.clear(buf)
  local filetype = vim.b[buf].vimoi_template_filetype
  if not filetype or filetype == "" or filetype == "gotmpl" or filetype == "template" then
    return
  end
  local source_path = vim.api.nvim_buf_get_name(buf)
  if source_path:match("^%a[%w+.-]*://") then
    source_path = "" -- Virtual buffers have no filesystem location for root discovery.
  end
  local target_path = source_path ~= "" and cli.counterpart_path(source_path) or nil
  local path = target_path and target_path ~= "" and target_path or source_path:gsub("%.tmpl$", "")
  local directory = path ~= "" and vim.fs.dirname(path) or vim.fn.getcwd()
  local basename = path ~= "" and vim.fs.basename(path) or ("buffer." .. filetype)
  local shadow = vim.api.nvim_create_buf(false, false)
  local state = {
    source_buf = buf,
    shadow = shadow,
    tick = vim.api.nvim_buf_get_changedtick(buf),
    context_generation = cli.context_generation,
    trace = trace,
    filetype = filetype,
    jobs = {},
  }
  buffers[buf], shadows[shadow] = state, state
  -- A fresh URI per snapshot prevents late provider results from being applied
  -- against a different render. Keep the real parent for project discovery.
  vim.bo[shadow].swapfile = false
  vim.bo[shadow].undofile = false
  vim.bo[shadow].bufhidden = "hide"
  vim.api.nvim_buf_set_name(shadow, directory .. "/.vimoi-" .. shadow .. "-" .. basename)
  vim.b[shadow].vimoi_diagnostic_source = buf
  vim.b[shadow].vimoi_target_path = target_path
  util.set_buffer_text(shadow, trace.output)
  vim.bo[shadow].modified = false
  vim.bo[shadow].readonly = true
  vim.bo[shadow].modifiable = false
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = shadow,
    callback = function()
      util.notify("rendered diagnostic buffers cannot be saved", "diagnostic", vim.log.levels.ERROR)
    end,
  })
  -- FileType activates already enabled LSP configurations through Neovim's
  -- native machinery, including the user's root discovery and on_attach hooks.
  vim.bo[shadow].filetype = filetype
  local ok, lint = pcall(require, "lint")
  if not ok then
    return
  end
  vim.api.nvim_buf_call(shadow, function()
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

return M

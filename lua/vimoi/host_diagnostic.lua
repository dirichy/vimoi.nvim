-- Run configured host providers on the shared rendered buffer, then project
-- their native diagnostics back onto the editable template.
local M = {}
local util = require("vimoi.util")
local sessions = require("vimoi.gotmpl.session")
local namespace = vim.api.nvim_create_namespace("vimoi-host-diagnostics")

---@class VimoiHostDiagnostic
---@field output_buf integer Shared rendered buffer receiving native diagnostics.
---@field map VimoiOutputMap
---@field filetype string Host filetype of this snapshot.
---@field jobs { cancel: fun(self: table) }[] nvim-lint processes owned by this snapshot.

---@type table<integer, VimoiHostDiagnostic>
local buffers = {}

---@param buf integer
---@param detach? boolean Stop native LSP attachments when disabling host diagnostics.
function M.clear(buf, detach)
  local state = buffers[buf]
  vim.diagnostic.reset(namespace, buf)
  if state then
    for _, job in ipairs(state.jobs) do
      job:cancel()
    end
    state.jobs = {}
    if detach then
      buffers[buf] = nil
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
    local state = source and buffers[source]
    if
      not state
      or state.output_buf ~= args.buf
      or not vim.api.nvim_buf_is_loaded(source)
      or vim.bo[source].filetype ~= "gotmpl"
      or not sessions.is_current(source, state.map)
    then
      return
    end
    vim.diagnostic.set(namespace, source, project(state.map, vim.diagnostic.get(args.buf), state.filetype))
  end,
})

---@param buf integer
---@param map VimoiOutputMap
function M.update(buf, map)
  local filetype = vim.b[buf].vimoi_template_filetype
  if not filetype or filetype == "" or filetype == "gotmpl" or filetype == "template" then
    M.clear(buf, true)
    return
  end
  local rendered = sessions.get(buf).buf
  local previous = buffers[buf]
  if previous and previous.map == map and previous.filetype == filetype and previous.output_buf == rendered then
    return
  end
  M.clear(buf, vim.bo[rendered].filetype ~= filetype)
  local state = {
    output_buf = rendered,
    map = map,
    filetype = filetype,
    jobs = {},
  }
  buffers[buf] = state
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
  vim.diagnostic.set(namespace, buf, project(map, vim.diagnostic.get(rendered), filetype))
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

return M

local M = {}
local util = require("vimoi.util")
local cli = require("vimoi.cli")
local views = require("vimoi.gotmpl.view")
local native_diff = require("vimoi.gotmpl.native_diff")

-- Native diffexpr dispatches using the lifecycle owner's single shared registry.
function M._diffexpr()
  return native_diff.diffexpr(views.by_window)
end

---Apply a fold command in both windows of the current diff session.
---@param command string
function M.fold(command)
  local session = views.by_window[vim.api.nvim_get_current_win()]
  if session and not views.is_valid(session) then
    views.close(session)
  end
  if not session or session.closed or session.preview then
    return util.notify("current buffer is not in a vimoi diff session", "diff", vim.log.levels.ERROR)
  end
  if not session.map then
    return util.notify("template is still rendering", "diff", vim.log.levels.WARN)
  end
  return native_diff.fold(session, command)
end

local function loaded_buffer(path)
  -- bufnr(path) also accepts patterns: file[1] can alias an unrelated file1 buffer.
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.api.nvim_buf_get_name(buf) == path then
      return buf
    end
  end
end

-- Reuse the owned pair first, then already visible buffers in the current tab.
-- Only create a split when one side has no window; never replace an unrelated peer.
---@param source string|integer Path or buffer number.
---@param target string|integer Path or buffer number.
---@param source_win? integer
---@param target_win? integer
local function open_windows(source, target, source_win, target_win)
  local split = require("vimoi").config.split == "horizontal" and "split" or "vsplit"
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local buf = vim.api.nvim_win_get_buf(win)
    local path = vim.api.nvim_buf_get_name(buf)
    if not views.by_window[win] and (buf == source or path == source) then
      source_win = source_win or win
    elseif not views.by_window[win] and (buf == target or path == target) then
      target_win = target_win or win
    end
  end
  local function show(value, win)
    vim.api.nvim_set_current_win(win)
    if type(value) == "number" then
      vim.api.nvim_win_set_buf(win, value)
    elseif value ~= "" then
      local buf = loaded_buffer(value)
      if buf then
        vim.api.nvim_win_set_buf(win, buf)
      else
        vim.cmd("edit " .. vim.fn.fnameescape(value))
      end
    end
    return vim.api.nvim_get_current_buf()
  end
  local source_buf, target_buf
  if source_win then
    source_buf = show(source, source_win)
    if not target_win then
      vim.cmd("rightbelow " .. split)
      target_win = vim.api.nvim_get_current_win()
    end
    target_buf = show(target, target_win)
  else
    target_win = target_win or vim.api.nvim_get_current_win()
    target_buf = show(target, target_win)
    vim.cmd(split)
    source_win = vim.api.nvim_get_current_win()
    source_buf = show(source, source_win)
  end
  vim.api.nvim_set_current_win(source_win)
  return source_buf, source_win, target_buf, target_win
end

---@param opts? { source?: string, target?: string, source_buf?: integer, target_buf?: integer, filetype?: string, validate?: boolean, preview?: boolean }
function M.open(opts)
  opts = opts or {}
  local preview = opts.preview == true
  local started = vim.uv.hrtime()
  local source_buf, target_buf = opts.source_buf, opts.target_buf
  local buffer_pair = source_buf ~= nil or target_buf ~= nil
  if buffer_pair then
    vim.validate("source_buf", source_buf, "number")
    vim.validate("target_buf", target_buf, "number")
    vim.validate("filetype", opts.filetype, "string", true)
    source_buf = source_buf == 0 and vim.api.nvim_get_current_buf() or source_buf
    target_buf = target_buf == 0 and vim.api.nvim_get_current_buf() or target_buf
    if not vim.api.nvim_buf_is_loaded(source_buf) or not vim.api.nvim_buf_is_loaded(target_buf) then
      return util.notify("diff_buffers requires two loaded buffers", "diff", vim.log.levels.ERROR)
    end
    if source_buf == target_buf then
      return util.notify("source and target must be different buffers", "diff", vim.log.levels.ERROR)
    end
  end
  ---@type VimoiTemplateView?
  local previous = views.by_window[vim.api.nvim_get_current_win()]
  if previous and not views.is_valid(previous) then
    views.close(previous)
    previous = nil
  end
  local current_path = vim.api.nvim_buf_get_name(0)
  local config = require("vimoi").config
  local source_path = opts.source and util.normalize_path(opts.source)
  local target_path = opts.target and util.normalize_path(opts.target)
  local path_lookup_ms = 0
  if buffer_pair then
    ---@cast source_buf integer
    ---@cast target_buf integer
    source_path = vim.api.nvim_buf_get_name(source_buf)
    target_path = vim.api.nvim_buf_get_name(target_buf)
  elseif preview then
    source_path = source_path or (previous and vim.api.nvim_buf_get_name(previous.source_buf)) or current_path
    if previous and not opts.source then
      source_buf = previous.source_buf
    end
  elseif not source_path or not target_path then
    if previous and not previous.preview and not opts.source and not opts.target then
      source_path, target_path =
        vim.api.nvim_buf_get_name(previous.source_buf), vim.api.nvim_buf_get_name(previous.target_buf)
      source_buf, target_buf = previous.source_buf, previous.target_buf
      buffer_pair = previous.buffer_pair == true
    else
      local before_path_lookup = vim.uv.hrtime()
      local resolve_error
      source_path, target_path, resolve_error = cli.resolve_paths(
        source_path or target_path or (previous and vim.api.nvim_buf_get_name(previous.source_buf)) or current_path
      )
      path_lookup_ms = (vim.uv.hrtime() - before_path_lookup) / 1e6
      if not source_path then
        return util.notify(assert(resolve_error), "diff", vim.log.levels.ERROR)
      end
    end
  end
  ---@cast source_path string
  local requested_buf = source_buf
    or (source_path == "" and vim.api.nvim_get_current_buf() or loaded_buffer(source_path))
  if preview and previous and previous.preview and vim.api.nvim_buf_get_name(previous.source_buf) == source_path then
    vim.api.nvim_set_current_win(previous.source_win)
    if not previous.loading then
      views.schedule_refresh(previous)
    end
    return previous
  end

  -- Resolve/read before retiring a working view, so failures leave it usable.
  local template = buffer_pair or require("vimoi.filetype").is_template(source_path)
  if not preview and template and not requested_buf then
    local source, read_error = util.read_file(source_path)
    if not source then
      return util.notify(
        ("cannot read source template %s: %s"):format(source_path, read_error),
        "diff",
        vim.log.levels.ERROR
      )
    end
  end
  local source_win, target_win
  if previous then
    source_win, target_win = previous.source_win, previous.target_win
    views.close(previous)
  elseif source_path == "" and not source_buf then
    source_win = vim.api.nvim_get_current_win()
  end
  if preview then
    source_buf = source_buf or requested_buf or vim.fn.bufadd(source_path)
    vim.fn.bufload(source_buf)
    target_buf = require("vimoi.gotmpl.session").get(source_buf).buf
    target_path = vim.api.nvim_buf_get_name(target_buf)
  end
  ---@cast target_path string
  source_buf, source_win, target_buf, target_win =
    open_windows(source_buf or source_path, target_buf or target_path, source_win, target_win)
  local target_filetype = opts.filetype or vim.bo[target_buf].filetype
  if buffer_pair and opts.filetype then
    vim.bo[target_buf].filetype = opts.filetype
  end
  if not preview and not template then
    if target_filetype ~= "" then
      vim.bo[source_buf].filetype = target_filetype
    end
    for _, win in ipairs({ source_win, target_win }) do
      vim.api.nvim_win_call(win, function()
        vim.cmd("diffthis")
      end)
    end
    return
  end
  if preview then
    target_filetype = require("vimoi.filetype").host_filetype(source_path, source_buf) or ""
    vim.bo[target_buf].filetype = target_filetype
  elseif target_filetype == "" then
    target_filetype = require("vimoi.filetype").host_filetype(target_path, target_buf) or ""
  end
  require("vimoi.highlight").configure_template_buffer(source_buf, target_filetype)
  local validate = not preview and opts.validate
  if validate == nil then
    validate = config.diff.validate
  end
  if buffer_pair then
    validate = false -- Buffers need not correspond to managed files on disk.
  end

  ---@type VimoiTemplateView
  local session = {
    session = require("vimoi.gotmpl.session").get(source_buf),
    preview = preview,
    buffer_pair = buffer_pair,
    keymaps = {},
    hunks = {},
    source_buf = source_buf,
    target_buf = target_buf,
    source_win = source_win,
    target_win = target_win,
    verify_with_cat = validate,
  }
  views.attach(session)
  ---@type VimoiOpenProfile
  local profile = {
    mode = preview and "preview" or "diff",
    open_ui_ms = (vim.uv.hrtime() - started) / 1e6,
    path_lookup_ms = path_lookup_ms,
    render_ms = 0,
    validation_ms = 0,
  }
  views.start_initial_render(session, profile, started)
  return session
end

---Render the current or explicit source buffer alongside a read-only scratch result.
---@param opts? VimoiPreviewOptions
function M.preview(opts)
  return M.open(vim.tbl_extend("force", opts or {}, { preview = true }))
end

return M

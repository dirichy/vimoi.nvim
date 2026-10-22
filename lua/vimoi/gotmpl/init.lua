local M = {}
local util = require("vimoi.util")
local cli = require("vimoi.cli")
local sessions = require("vimoi.gotmpl.session")
local native_diff = require("vimoi.gotmpl.native_diff")

-- Native diffexpr dispatches using the lifecycle owner's single shared registry.
function M._diffexpr()
  return native_diff.diffexpr(sessions.by_window)
end

---Apply a fold command in both windows of the current diff session.
---@param command string
function M.fold(command)
  local session = sessions.by_window[vim.api.nvim_get_current_win()]
  if session and not sessions.is_valid(session) then
    sessions.close(session)
  end
  if not session or session.closed or session.preview then
    return util.notify("current buffer is not in a vimoi diff session", "diff", vim.log.levels.ERROR)
  end
  if not session.trace then
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
local function open_windows(source_path, target_path, source_win, target_win)
  local split = require("vimoi").config.split == "horizontal" and "split" or "vsplit"
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local path = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win))
    if not sessions.by_window[win] and path == source_path then
      source_win = source_win or win
    elseif not sessions.by_window[win] and path == target_path then
      target_win = target_win or win
    end
  end
  local function show(path, win)
    vim.api.nvim_set_current_win(win)
    if path ~= "" then
      local buf = loaded_buffer(path)
      if buf then
        vim.api.nvim_win_set_buf(win, buf)
      else
        vim.cmd("edit " .. vim.fn.fnameescape(path))
      end
    end
    return vim.api.nvim_get_current_buf()
  end
  local source_buf, target_buf
  if source_win then
    source_buf = show(source_path, source_win)
    if not target_win then
      vim.cmd("rightbelow " .. split)
      target_win = vim.api.nvim_get_current_win()
    end
    target_buf = show(target_path, target_win)
  else
    target_win = target_win or vim.api.nvim_get_current_win()
    target_buf = show(target_path, target_win)
    vim.cmd(split)
    source_win = vim.api.nvim_get_current_win()
    source_buf = show(source_path, source_win)
  end
  vim.api.nvim_set_current_win(source_win)
  return source_buf, source_win, target_buf, target_win
end

---@param opts? { source?: string, target?: string, validate?: boolean, preview?: boolean }
function M.open(opts)
  opts = opts or {}
  local preview = opts.preview == true
  local started = vim.uv.hrtime()
  ---@type VimoiTemplateSession?
  local previous = sessions.by_window[vim.api.nvim_get_current_win()]
  if previous and not sessions.is_valid(previous) then
    sessions.close(previous)
    previous = nil
  end
  local current_path = vim.api.nvim_buf_get_name(0)
  local config = require("vimoi").config
  local source_path = opts.source and util.normalize_path(opts.source)
  local target_path = opts.target and util.normalize_path(opts.target)
  local path_lookup_ms = 0
  if preview then
    source_path = source_path or (previous and previous.source_path) or current_path
  elseif not source_path or not target_path then
    if previous and not previous.preview and not opts.source and not opts.target then
      source_path, target_path = previous.source_path, previous.target_path
    else
      local before_path_lookup = vim.uv.hrtime()
      local resolve_error
      source_path, target_path, resolve_error =
        cli.resolve_paths(source_path or target_path or (previous and previous.source_path) or current_path)
      path_lookup_ms = (vim.uv.hrtime() - before_path_lookup) / 1e6
      if not source_path then
        return util.notify(assert(resolve_error), "diff", vim.log.levels.ERROR)
      end
    end
  end
  ---@cast source_path string
  local requested_buf = source_path == "" and vim.api.nvim_get_current_buf() or loaded_buffer(source_path)
  if preview and previous and previous.preview and previous.source_path == source_path then
    vim.api.nvim_set_current_win(previous.source_win)
    if not previous.loading then
      sessions.schedule_refresh(previous)
    end
    return previous
  end

  -- Resolve/read before retiring a working view, so failures leave it usable.
  local template = require("vimoi.filetype").is_template(source_path)
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
    sessions.close(previous)
  elseif source_path == "" then
    source_win = vim.api.nvim_get_current_win()
  end
  if preview then
    local output = vim.api.nvim_create_buf(false, true)
    target_path = "vimoi://preview/" .. output .. "/" .. (vim.fs.basename(source_path) or "template")
    vim.api.nvim_buf_set_name(output, target_path)
    vim.bo[output].bufhidden = "wipe"
    vim.bo[output].undolevels = -1
    vim.bo[output].readonly = true
    vim.bo[output].modifiable = false
  end
  ---@cast target_path string
  local source_buf, target_buf
  source_buf, source_win, target_buf, target_win = open_windows(source_path, target_path, source_win, target_win)
  local target_filetype = vim.bo[target_buf].filetype
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
  local init = require("vimoi.filetype").init_template_names[vim.fs.basename(source_path)] == true
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
  local modified = util.buffer_text(target_buf)

  ---@type VimoiTemplateSession
  local session = {
    preview = preview,
    keymaps = {},
    hunks = {},
    source_text = util.buffer_text(source_buf),
    target_text = modified,
    source_buf = source_buf,
    target_buf = target_buf,
    source_win = source_win,
    target_win = target_win,
    source_path = source_path,
    target_path = target_path,
    is_init_template = init,
    verify_with_cat = validate,
  }
  sessions.attach(session)
  ---@type VimoiOpenProfile
  local profile = {
    mode = preview and "preview" or "diff",
    open_ui_ms = (vim.uv.hrtime() - started) / 1e6,
    path_lookup_ms = path_lookup_ms,
    render_ms = 0,
    validation_ms = 0,
  }
  sessions.start_initial_render(session, profile, started)
  return session
end

---Render the current or explicit source buffer alongside a read-only scratch result.
---@param opts? VimoiPreviewOptions
function M.preview(opts)
  return M.open(vim.tbl_extend("force", opts or {}, { preview = true }))
end

return M

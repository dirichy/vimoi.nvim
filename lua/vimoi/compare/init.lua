-- Open and own source/target views; shared rendering belongs to render/init.lua.
local M = {}
local util = require("vimoi.core.util")
local cli = require("vimoi.core.cli")
local diff_hunks = require("vimoi.compare.diff_hunks")
local native_diff = require("vimoi.compare.native_diff")
local sessions = require("vimoi.render")
local sync_scroll = require("vimoi.compare.sync_scroll")

---@class VimoiSessionKeymap
---@field buf integer
---@field lhs string
---@field callback function
---@field previous? table Original buffer-local maparg() dictionary, restored via mapset().

---@class VimoiTemplateView
---@field session VimoiSourceSession Source owner; windows are borrowed views.
---@field target_tick? integer Buffer version represented by the current mapping.
---@field cursor_range? { source_line: integer, map: VimoiOutputMap, hunks: VimoiDiffHunk[], first: integer, last: integer }
---@field map? VimoiOutputMap Mapping adopted by this view; absent before initialization.
---@field hunks VimoiDiffHunk[] Changes from rendered output to the real target.
---@field projected_hunks? VimoiNativeDiffHunk[] Projected hunks consumed by the global diffexpr.
---@field source_buf integer
---@field target_buf integer
---@field source_win integer
---@field target_win integer
---@field buffer_pair? boolean Explicit buffer pair with no disk validation.
---@field validate? boolean Explicit source-session validation override.
---@field preview boolean True for a read-only rendered-output peer instead of a real target.
---@field preview_error? string The visible output is stale while rendering is invalid.
---@field keymaps VimoiSessionKeymap[] Original buffer mappings replaced for this view.
---@field closed? boolean
---@field syncing? boolean Prevents recursive cursor/scroll events.
---@field loading? boolean Initial rendering is pending.
---@field stop_updates? fun(cancel_render?: boolean) Live output registration.
---@field augroup? integer Per-view autocmd group, removed on close.

-- A view belongs to two windows; the same buffers may appear in other views.
---@type table<integer, VimoiTemplateView>
M.by_window = {}

---Check that the borrowed windows still display this view’s buffers.
---Text snapshots and rendering-context versions are checked by each operation.
---@param view VimoiTemplateView
---@return boolean
function M.is_valid(view)
  if view.closed then
    return false
  end
  for _, side in ipairs({ "source", "target" }) do
    local buf, win = view[side .. "_buf"], view[side .. "_win"]
    if M.by_window[win] ~= view or not vim.api.nvim_win_is_valid(win) or vim.api.nvim_win_get_buf(win) ~= buf then
      return false
    end
  end
  return true
end

---Return the current valid view, retiring stale window bindings.
---@return VimoiTemplateView?
function M.current()
  local view = M.by_window[vim.api.nvim_get_current_win()]
  if view and not M.is_valid(view) then
    M.close(view)
    return
  end
  return view
end

-- Status and cursor-line decorations are ephemeral and scoped to the owning window,
-- so a second view of the same source buffer cannot erase or inherit them.
local status_namespace = vim.api.nvim_create_namespace("vimoi-view-status")
vim.api.nvim_set_decoration_provider(status_namespace, {
  on_win = function(_, win, buf, top, bottom)
    local view = M.by_window[win]
    if not view or view.closed then
      return false
    end
    if view.loading and win == view.source_win then
      vim.api.nvim_buf_set_extmark(buf, status_namespace, 0, 0, {
        virt_text = { { "  Rendering chezmoi template…", "Comment" } },
        virt_text_pos = "eol",
        ephemeral = true,
      })
    elseif view.preview_error and win == view.target_win then
      vim.api.nvim_buf_set_extmark(buf, status_namespace, 0, 0, {
        virt_lines = { { { "Preview out of date: " .. view.preview_error:gsub("\n", " "), "ErrorMsg" } } },
        virt_lines_above = true,
        ephemeral = true,
      })
    end
    local mode = vim.fn.mode(1):sub(1, 1)
    if
      win == view.target_win
      and vim.api.nvim_get_current_win() == view.source_win
      and view.map
      and not view.loading
      and not view.preview_error
      and vim.wo[view.source_win].cursorline
      and vim.wo[view.source_win].cursorlineopt ~= "number"
      and mode ~= "v"
      and mode ~= "V"
      and mode ~= "\22"
      and view.map.tick == vim.api.nvim_buf_get_changedtick(view.source_buf)
      and view.target_tick == vim.api.nvim_buf_get_changedtick(view.target_buf)
    then
      local line = vim.api.nvim_win_get_cursor(view.source_win)[1]
      local first, last = sync_scroll.target_range(view, line)
      if last <= first then
        return false
      end
      first = math.max(first, top + 1)
      last = math.min(last, bottom + 1, vim.api.nvim_buf_line_count(buf))
      if first <= last then
        vim.api.nvim_buf_set_extmark(buf, status_namespace, first - 1, 0, {
          end_row = last,
          end_col = 0,
          hl_group = "CursorLine",
          hl_eol = true,
          priority = vim.hl.priorities.user,
          ephemeral = true,
        })
      end
    end
    return false
  end,
})

local function redraw(view)
  for _, win in ipairs({ view.source_win, view.target_win }) do
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim__redraw({ win = win, valid = false })
    end
  end
end

local function set_loading(view, loading)
  view.loading = loading
  redraw(view)
end

-- Failed previews retain the last good output until rendering recovers.
local function set_preview_error(view, message)
  view.preview_error = message
  redraw(view)
end

-- Snacks exposes only a buffer-wide switch. Shared buffers keep it disabled
-- until their last view closes, then recover the original value.
---@type table<integer, { users: integer, value: any }>
local scroll_settings = {}

-- Update the cached texts, source map, and native diff as one unit.
local function update_session(view)
  local map = view.session.map
  local target_tick = vim.api.nvim_buf_get_changedtick(view.target_buf)
  if view.map == map and view.target_tick == target_tick and not view.preview_error then
    return true
  end
  view.map, view.target_tick = map, target_tick
  -- Preview's target is the rendered output, so it has no target-side changes.
  view.hunks = view.preview and {}
    or diff_hunks.compute(util.buffer_text(view.target_buf), assert(sessions.snapshot(view.source_buf)))
  if view.preview then
    set_preview_error(view, nil)
    sync_scroll.sync(view, vim.api.nvim_get_current_win())
    return true
  end
  local ok, native_error = pcall(native_diff.update, view)
  if not ok then
    return nil, native_error
  end
  return true
end

---Refresh the view from an already rendered source snapshot; never run a process here.
---@param view VimoiTemplateView
---@param trace VimoiSourceMapTrace
---@return boolean?
---@return string? error
function M.refresh(view, trace)
  if not M.is_valid(view) then
    M.close(view)
    return nil, "diff/preview view no longer matches its original buffers and windows"
  end
  local state = sessions.update(view.source_buf, trace)
  if sessions.is_current(view.source_buf, state.map) then
    return update_session(view)
  end
  return true
end

local function apply_refresh(view)
  local ok, native_error = update_session(view)
  if not ok then
    util.notify(
      "cannot update view: " .. tostring(native_error),
      view.preview and "preview" or "diff",
      vim.log.levels.ERROR
    )
  end
end

---@param view VimoiTemplateView
function M.refresh_target(view)
  if not M.is_valid(view) then
    return M.close(view)
  end
  if sessions.is_current(view.source_buf, view.map) then
    apply_refresh(view)
  end
end

-- Session mappings temporarily shadow buffer-local user mappings; native mapset restores them.
local function set_session_keymap(view, buf, lhs, callback, desc)
  local previous = vim.api.nvim_buf_call(buf, function()
    return vim.fn.maparg(lhs, "n", false, true)
  end)
  view.keymaps[#view.keymaps + 1] = {
    buf = buf,
    lhs = lhs,
    callback = callback,
    previous = previous.buffer == 1 and previous or nil,
  }
  vim.keymap.set("n", lhs, callback, { buffer = buf, desc = desc })
end

-- Buffer-local maps must follow focus because Neovim has no window-local maps.
-- Leave other views (including previews) and ordinary windows with their own maps.
---@param view VimoiTemplateView
local function restore_keymaps(view)
  for _, mapping in ipairs(view.keymaps) do
    if vim.api.nvim_buf_is_valid(mapping.buf) then
      vim.api.nvim_buf_call(mapping.buf, function()
        local current = vim.fn.maparg(mapping.lhs, "n", false, true)
        if current.buffer == 1 and current.callback == mapping.callback then
          vim.keymap.del("n", mapping.lhs, { buffer = mapping.buf })
          if mapping.previous then
            vim.fn.mapset("n", false, mapping.previous)
          end
        end
      end)
    end
  end
  view.keymaps = {}
end

---@param view VimoiTemplateView
local function configure_window_keymaps(view)
  restore_keymaps(view)
  local win = vim.api.nvim_get_current_win()
  if view.closed or view.preview or M.by_window[win] ~= view then
    return
  end
  local buf = vim.api.nvim_win_get_buf(win)
  local api = require("vimoi.api")
  local keymaps = require("vimoi").config.keymaps
  for name, command in pairs(require("vimoi").fold_commands) do
    local lhs = keymaps[name]
    if lhs and lhs ~= "" then
      set_session_keymap(view, buf, lhs, function()
        api.fold(command)
      end, "Synchronize chezmoi diff fold " .. command)
    end
  end
  local in_source = win == view.source_win
  if keymaps.diff_get and keymaps.diff_get ~= "" then
    set_session_keymap(
      view,
      buf,
      keymaps.diff_get,
      api.get_hunk,
      in_source and "Get chezmoi target hunk into source template" or "Get rendered hunk into chezmoi target"
    )
  end
  if keymaps.diff_put and keymaps.diff_put ~= "" then
    set_session_keymap(
      view,
      buf,
      keymaps.diff_put,
      api.put_hunk,
      in_source and "Put rendered hunk into chezmoi target" or "Put chezmoi target hunk into source template"
    )
  end
end

---@param view VimoiTemplateView
function M.close(view)
  if view.closed then
    return
  end
  view.closed = true
  view.session.views[view] = nil
  if view.stop_updates then
    view.stop_updates()
  end
  set_loading(view, false)
  for _, win in ipairs({ view.source_win, view.target_win }) do
    if M.by_window[win] == view then
      M.by_window[win] = nil
    end
  end
  if view.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, view.augroup)
  end
  restore_keymaps(view)
  for _, buf in ipairs({ view.source_buf, view.target_buf }) do
    local setting = scroll_settings[buf]
    setting.users = setting.users - 1
    if setting.users == 0 then
      if vim.api.nvim_buf_is_valid(buf) then
        if setting.value == vim.NIL then
          vim.b[buf].snacks_scroll = nil
        else
          vim.b[buf].snacks_scroll = setting.value
        end
      end
      scroll_settings[buf] = nil
    end
  end
  for _, win in ipairs({ view.source_win, view.target_win }) do
    local expected_buf = win == view.source_win and view.source_buf or view.target_buf
    if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == expected_buf and vim.wo[win].diff then
      vim.api.nvim_win_call(win, function()
        vim.cmd("diffoff")
      end)
    end
  end
  native_diff.restore_diffexpr_if_unused(M.by_window)
  vim.api.nvim_exec_autocmds(
    "User",
    { pattern = "VimoiViewClosed", data = { source_win = view.source_win, target_win = view.target_win } }
  )
end

---Register the opened pair and own everything that close must undo.
---@param view VimoiTemplateView
function M.attach(view)
  local source_buf, target_buf = view.source_buf, view.target_buf
  local source_win, target_win = view.source_win, view.target_win
  local preview = view.preview
  -- Reopening either window replaces that pair without retiring other views.
  for _, win in ipairs({ source_win, target_win }) do
    if M.by_window[win] then
      M.close(M.by_window[win])
    end
  end
  -- A split inherits window options, including an older native diff. Do not
  -- expose ordinary template-vs-target highlights while the new map is pending.
  for _, win in ipairs({ source_win, target_win }) do
    if vim.wo[win].diff then
      vim.api.nvim_win_call(win, function()
        vim.cmd("diffoff")
      end)
    end
  end
  view.session.views[view] = true
  M.by_window[source_win] = view
  M.by_window[target_win] = view
  set_loading(view, true)
  for _, buf in ipairs({ source_buf, target_buf }) do
    local setting = scroll_settings[buf]
    if not setting then
      setting = { users = 0, value = vim.b[buf].snacks_scroll }
      if setting.value == nil then
        setting.value = vim.NIL
      end
      scroll_settings[buf] = setting
    end
    setting.users = setting.users + 1
    vim.b[buf].snacks_scroll = false
  end
  local refresh_group = vim.api.nvim_create_augroup("vimoi-view-" .. source_win .. "-" .. target_win, { clear = true })
  view.augroup = refresh_group
  vim.api.nvim_create_autocmd("OptionSet", {
    group = refresh_group,
    pattern = { "cursorline", "cursorlineopt" },
    callback = function()
      redraw(view)
    end,
  })
  vim.api.nvim_create_autocmd("ModeChanged", {
    group = refresh_group,
    callback = function()
      redraw(view)
    end,
  })
  for _, buf in ipairs({ source_buf, target_buf }) do
    vim.api.nvim_create_autocmd("BufWinLeave", {
      group = refresh_group,
      buffer = buf,
      callback = function()
        local win = vim.api.nvim_get_current_win()
        if win == source_win or win == target_win then
          M.close(view)
        end
      end,
    })
    if not preview and buf == target_buf then
      vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
        group = refresh_group,
        buffer = buf,
        callback = function()
          if not view.closed and view.map then
            M.refresh_target(view)
          end
        end,
      })
    end
    vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
      group = refresh_group,
      buffer = buf,
      callback = function()
        if view.syncing then
          return
        end
        local active_win = vim.api.nvim_get_current_win()
        vim.schedule(function()
          sync_scroll.sync(view, active_win)
        end)
      end,
    })
  end
  vim.api.nvim_create_autocmd("WinScrolled", {
    group = refresh_group,
    callback = function()
      if view.syncing then
        return
      end
      local active_win = vim.api.nvim_get_current_win()
      if active_win == view.source_win or active_win == view.target_win then
        vim.schedule(function()
          sync_scroll.sync(view, active_win)
        end)
      end
    end,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = refresh_group,
    callback = function(args)
      local closed_win = tonumber(args.match)
      if closed_win == view.source_win or closed_win == view.target_win then
        M.close(view)
      end
    end,
  })
  vim.api.nvim_create_autocmd("WinEnter", {
    group = refresh_group,
    callback = function()
      if M.by_window[vim.api.nvim_get_current_win()] == view then
        configure_window_keymaps(view)
        redraw(view)
      end
    end,
  })
  vim.api.nvim_create_autocmd("WinLeave", {
    group = refresh_group,
    callback = function()
      if M.by_window[vim.api.nvim_get_current_win()] == view then
        restore_keymaps(view)
        redraw(view)
      end
    end,
  })
  configure_window_keymaps(view)
end

---Use one subscription for both initialization and subsequent updates.
---@param view VimoiTemplateView
function M.start_initial_render(view)
  local source_buf, preview = view.source_buf, view.preview
  view.stop_updates = sessions.register(source_buf, function(rendered, err)
    if not M.is_valid(view) then
      return M.close(view)
    end
    local map = not err and rendered and rendered.map or nil
    local initializing = view.loading
    if err or not map then
      if preview then
        set_loading(view, false)
        set_preview_error(view, err)
      elseif initializing then
        M.close(view)
      end
      if initializing then
        util.notify(err, preview and "preview" or "diff", vim.log.levels.ERROR)
      end
      return
    end
    if not initializing then
      if view.map ~= map or view.preview_error then
        apply_refresh(view)
      end
      return
    end
    local updated, update_error = update_session(view)
    set_loading(view, false)
    if not updated then
      M.close(view)
      util.notify(
        "cannot initialize view: " .. tostring(update_error),
        preview and "preview" or "diff",
        vim.log.levels.ERROR
      )
      return
    end
    if not preview and #view.hunks == 0 then
      util.notify("target matches rendered template", "diff")
    end
  end, { validate = view.validate, target = view.validate and vim.api.nvim_buf_get_name(view.target_buf) or nil })
end

-- Native diffexpr dispatches using the lifecycle owner's single shared registry.
function M._diffexpr()
  return native_diff.diffexpr(M.by_window)
end

---Apply a fold command in both windows of the current diff session.
---@param command string
function M.fold(command)
  local session = M.current()
  if not session or session.preview then
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
    if not M.by_window[win] and (buf == source or path == source) then
      source_win = source_win or win
    elseif not M.by_window[win] and (buf == target or path == target) then
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
  vim.validate("validate", opts.validate, "boolean", true)
  local preview = opts.preview == true
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
  local previous = M.current()
  local current_path = vim.api.nvim_buf_get_name(0)
  local source_path = opts.source and util.normalize_path(opts.source)
  local target_path = opts.target and util.normalize_path(opts.target)
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
      local resolve_error
      source_path, target_path, resolve_error = cli.resolve_paths(
        source_path or target_path or (previous and vim.api.nvim_buf_get_name(previous.source_buf)) or current_path
      )
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
      M.refresh_target(previous)
    end
    return previous
  end

  -- Resolve/read before retiring a working view, so failures leave it usable.
  local template = buffer_pair or require("vimoi.core.source").is_template(source_path)
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
    M.close(previous)
  elseif source_path == "" and not source_buf then
    source_win = vim.api.nvim_get_current_win()
  end
  if preview then
    source_buf = source_buf or requested_buf or vim.fn.bufadd(source_path)
    vim.fn.bufload(source_buf)
    target_buf = require("vimoi.render").get(source_buf).buf
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
    target_filetype = require("vimoi.editor.filetype").host_filetype(source_path, source_buf) or ""
    vim.bo[target_buf].filetype = target_filetype
  elseif target_filetype == "" then
    target_filetype = require("vimoi.editor.filetype").host_filetype(target_path, target_buf) or ""
  end
  require("vimoi.editor.highlight").configure_template_buffer(source_buf, target_filetype)
  local validate = opts.validate
  if buffer_pair then
    validate = false -- Buffers need not correspond to managed files on disk.
  end

  ---@type VimoiTemplateView
  local session = {
    session = require("vimoi.render").get(source_buf),
    preview = preview,
    buffer_pair = buffer_pair,
    keymaps = {},
    hunks = {},
    source_buf = source_buf,
    target_buf = target_buf,
    source_win = source_win,
    target_win = target_win,
    validate = validate,
  }
  M.attach(session)
  M.start_initial_render(session)
  return session
end

---Render the current or explicit source buffer alongside a read-only scratch result.
---@param opts? VimoiPreviewOptions
function M.preview(opts)
  return M.open(vim.tbl_extend("force", opts or {}, { preview = true }))
end

return M

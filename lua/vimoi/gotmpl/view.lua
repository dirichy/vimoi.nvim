-- Attach window views to a source session; keep only target and window state here.
local M = {}
local util = require("vimoi.util")
local diff_hunks = require("vimoi.gotmpl.diff_hunks")
local native_diff = require("vimoi.gotmpl.native_diff")
local sessions = require("vimoi.gotmpl.session")
local sync_scroll = require("vimoi.gotmpl.sync_scroll")

---@class VimoiSessionKeymap
---@field buf integer
---@field lhs string
---@field callback function
---@field previous? table Original buffer-local maparg() dictionary, restored via mapset().

---@class VimoiTemplateView
---@field session VimoiSourceSession Source owner; windows are borrowed views.
---@field target_tick? integer Buffer version represented by the current mapping.
---@field cursor_range? { source_line: integer, target_line: integer, map: VimoiOutputMap, hunks: VimoiDiffHunk[], first: integer, last: integer }
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

---@class VimoiOpenProfile
---@field mode "preview"|"diff"
---@field open_ui_ms number
---@field path_lookup_ms number
---@field render_ms number Accumulates initial rendering and retries.
---@field validation_ms number
---@field diff_ms? number
---@field preview_write_ms? number
---@field total_ms? number Present after a successful initial render.

---@type VimoiOpenProfile?
M.last_profile = nil

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
---@param profile VimoiOpenProfile
---@param opened_at integer Opening start time from vim.uv.hrtime().
function M.start_initial_render(view, profile, opened_at)
  M.last_profile = nil
  local source_buf, preview = view.source_buf, view.preview
  local started_at = vim.uv.hrtime()
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
    profile.validation_ms = rendered.validation_started
        and rendered.validation_started >= started_at
        and rendered.validation_ms
      or 0
    profile.render_ms = (vim.uv.hrtime() - started_at) / 1e6 - profile.validation_ms
    local before_view_update = vim.uv.hrtime()
    local updated, update_error = update_session(view)
    profile[preview and "preview_write_ms" or "diff_ms"] = (vim.uv.hrtime() - before_view_update) / 1e6
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
    profile.total_ms = (vim.uv.hrtime() - opened_at) / 1e6
    M.last_profile = profile
    if not preview and #view.hunks == 0 then
      util.notify("target matches rendered template", "diff")
    end
  end, { validate = view.validate, target = view.validate and vim.api.nvim_buf_get_name(view.target_buf) or nil })
end

return M

-- Own template-view state, refreshes, and the resources released when a pair closes.
local M = {}
local util = require("vimoi.util")
local cli = require("vimoi.cli")
local diff_hunks = require("vimoi.gotmpl.diff_hunks")
local native_diff = require("vimoi.gotmpl.native_diff")
local buffer_edits = require("vimoi.gotmpl.buffer_edits")
local source_map = require("vimoi.gotmpl.source_map")
local sync_scroll = require("vimoi.gotmpl.sync_scroll")

---@class VimoiSessionKeymap
---@field buf integer
---@field lhs string
---@field callback function
---@field previous? table Original buffer-local maparg() dictionary, restored via mapset().

---@class VimoiPendingMerge
---@field complete fun() Resume only while the waiting window is still active.
---@field cancel fun() Release the wait window without writing either buffer.

---@class VimoiTemplateSession
---@field source_text string Cached template buffer text.
---@field target_text string Cached target buffer text.
---@field trace? VimoiSourceMapTrace Absent until the initial asynchronous render finishes.
---@field hunks VimoiDiffHunk[] Changes from rendered output to target_text.
---@field projected_hunks? VimoiNativeDiffHunk[] Projected hunks consumed by the global diffexpr.
---@field source_buf integer
---@field target_buf integer
---@field source_win integer
---@field target_win integer
---@field source_path string Opening path snapshot; empty for an unnamed source buffer.
---@field target_path string Opening path snapshot; empty for an unnamed target, or the preview scratch URI.
---@field buffer_pair? boolean Explicit buffer pair with no disk validation.
---@field verify_with_cat boolean Whether the first diff render must match chezmoi cat.
---@field is_init_template boolean
---@field preview boolean True for a read-only rendered-output peer instead of a real target.
---@field preview_error? string The visible output is stale while rendering is invalid.
---@field keymaps VimoiSessionKeymap[] Original buffer mappings replaced for this session.
---@field refresh_later? fun(generation: integer) Debounced refresh owned by util.guard.
---@field refresh_generation? integer Invalidates queued refreshes and stale async renders.
---@field pending_merge? VimoiPendingMerge Explicit merge waiting in a cancellable window.
---@field closed? boolean
---@field syncing? boolean Prevents recursive cursor/scroll events.
---@field loading? boolean Initial rendering is pending.
---@field render_job? VimoiCommand Current render/validation process, cancellable by a blocking transfer.
---@field augroup? integer Per-session autocmd group, removed on close.

-- A view belongs to two windows; the same buffers may appear in other views.
---@type table<integer, VimoiTemplateSession>
M.by_window = {}

---Check that this session still owns its original buffers, windows, and paths.
---Text snapshots and rendering-context versions are checked by each operation.
---@param session VimoiTemplateSession
---@return boolean
function M.is_valid(session)
  if session.closed then
    return false
  end
  for _, side in ipairs({ "source", "target" }) do
    local buf, win = session[side .. "_buf"], session[side .. "_win"]
    if
      M.by_window[win] ~= session
      or not vim.api.nvim_buf_is_valid(buf)
      or not vim.api.nvim_win_is_valid(win)
      or vim.api.nvim_win_get_buf(win) ~= buf
      or vim.api.nvim_buf_get_name(buf) ~= session[side .. "_path"]
    then
      return false
    end
  end
  return true
end

-- Loading/error decorations are ephemeral and scoped to the owning window,
-- so a second view of the same source buffer cannot erase or inherit them.
local status_namespace = vim.api.nvim_create_namespace("vimoi-view-status")
vim.api.nvim_set_decoration_provider(status_namespace, {
  on_win = function(_, win, buf)
    local session = M.by_window[win]
    if not session or session.closed then
      return false
    end
    if session.loading and win == session.source_win then
      vim.api.nvim_buf_set_extmark(buf, status_namespace, 0, 0, {
        virt_text = { { "  Rendering chezmoi template…", "Comment" } },
        virt_text_pos = "eol",
        ephemeral = true,
      })
    elseif session.preview_error and win == session.target_win then
      vim.api.nvim_buf_set_extmark(buf, status_namespace, 0, 0, {
        virt_lines = { { { "Preview out of date: " .. session.preview_error:gsub("\n", " "), "ErrorMsg" } } },
        virt_lines_above = true,
        ephemeral = true,
      })
    end
    return false
  end,
})

local function redraw(session)
  for _, win in ipairs({ session.source_win, session.target_win }) do
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim__redraw({ win = win, valid = false })
    end
  end
end

local function set_loading(session, loading)
  session.loading = loading
  redraw(session)
end

-- Failed previews retain the last good output until rendering recovers.
local function set_preview_error(session, message)
  session.preview_error = message
  redraw(session)
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
local function update_session(session, source, modified, trace)
  if session.preview then
    if modified ~= trace.output then
      local first, last, replacement = util.changed_bytes(modified, trace.output)
      vim.bo[session.target_buf].readonly = false
      vim.bo[session.target_buf].modifiable = true
      local ok, write_error = pcall(buffer_edits.apply, session.target_buf, modified, trace.output, {
        { start_byte = first, end_byte = last, replacement = replacement },
      })
      vim.bo[session.target_buf].modifiable = false
      vim.bo[session.target_buf].readonly = true
      vim.bo[session.target_buf].modified = false
      if not ok then
        return nil, write_error
      end
    end
    session.source_text, session.target_text, session.trace = source, trace.output, trace
    session.hunks = {} -- Rendered-output coordinates are the base coordinates used by sync_scroll.sync.
    set_preview_error(session, nil)
    sync_scroll.sync(session, vim.api.nvim_get_current_win())
    return true
  end
  session.source_text = source
  session.target_text = modified
  session.trace = trace
  session.hunks = diff_hunks.compute(modified, trace)
  local ok, native_error = pcall(native_diff.update, session)
  if not ok then
    return nil, native_error
  end
  return true
end

---Refresh the view from an already rendered source snapshot; never run a process here.
---@param session VimoiTemplateSession
---@param trace VimoiSourceMapTrace
---@return boolean?
---@return string? error
function M.refresh(session, trace)
  if not M.is_valid(session) then
    M.close(session)
    return nil, "diff/preview session no longer matches its original buffers and windows"
  end
  return update_session(session, util.buffer_text(session.source_buf), util.buffer_text(session.target_buf), trace)
end

local function apply_refresh(session, source, modified, trace)
  local ok, native_error = update_session(session, source, modified, trace)
  if not ok then
    if session.preview then
      set_preview_error(session, tostring(native_error))
    end
    util.notify(
      "cannot update view: " .. tostring(native_error),
      session.preview and "preview" or "diff",
      vim.log.levels.ERROR
    )
  end
end

---@class VimoiViewRefresh
---@field context_generation integer
---@field source string
---@field modified string
---@field trace? VimoiSourceMapTrace
---@field error? string

---@param session VimoiTemplateSession
function M.schedule_refresh(session)
  session.refresh_generation = (session.refresh_generation or 0) + 1
  if session.render_job then
    session.render_job.cancel()
    session.render_job = nil
  end
  if not session.refresh_later then
    session.refresh_later = util.guard(function(generation)
      ---@type VimoiViewRefresh
      local result = {
        context_generation = cli.context_generation,
        source = util.buffer_text(session.source_buf),
        modified = util.buffer_text(session.target_buf),
      }
      result.trace = session.trace and source_map.rebuild(session.trace, result.source, session.source_buf)
      if not result.trace then
        result.trace, result.error = util.await(function(done)
          session.render_job = source_map.trace_async(result.source, {
            init = session.is_init_template,
            buf = session.source_buf,
          }, done)
        end)
        if generation == session.refresh_generation then
          session.render_job = nil
        end
      end
      return result
    end, {
      delay = 120,
      allow_parallel = true,
      is_valid = function(generation)
        return generation == session.refresh_generation and M.is_valid(session)
      end,
      on_fail = function()
        if not M.is_valid(session) then
          M.close(session)
        end
      end,
      should_retry = function(result)
        return result.context_generation ~= cli.context_generation
          or (
            result.trace ~= nil
            and (
              util.buffer_text(session.source_buf) ~= result.source
              or util.buffer_text(session.target_buf) ~= result.modified
            )
          )
      end,
      on_result = function(result)
        if result.trace then
          apply_refresh(session, result.source, result.modified, result.trace)
        else
          if session.preview then
            set_preview_error(session, result.error)
          end
          util.notify(
            "cannot refresh template after buffer change: " .. tostring(result.error),
            session.preview and "preview" or "diff",
            vim.log.levels.ERROR
          )
        end
      end,
    })
  end
  session.refresh_later(session.refresh_generation)
end

-- Session mappings temporarily shadow buffer-local user mappings; native mapset restores them.
local function set_session_keymap(session, buf, lhs, callback, desc)
  local previous = vim.api.nvim_buf_call(buf, function()
    return vim.fn.maparg(lhs, "n", false, true)
  end)
  session.keymaps[#session.keymaps + 1] = {
    buf = buf,
    lhs = lhs,
    callback = callback,
    previous = previous.buffer == 1 and previous or nil,
  }
  vim.keymap.set("n", lhs, callback, { buffer = buf, desc = desc })
end

local function configure_fold_mappings(session, buf)
  local mappings = {
    fold_open = "zo",
    fold_close = "zc",
    fold_toggle = "za",
    fold_open_recursive = "zO",
    fold_close_recursive = "zC",
    fold_toggle_recursive = "zA",
    fold_open_all = "zR",
    fold_close_all = "zM",
  }
  local config = require("vimoi").config.keymaps
  for name, command in pairs(mappings) do
    local keymap = config[name]
    if keymap and keymap ~= "" then
      local fold_command = command
      set_session_keymap(session, buf, keymap, function()
        require("vimoi.api").fold(fold_command)
      end, "Synchronize chezmoi diff fold " .. fold_command)
    end
  end
end

-- Buffer-local maps must follow focus because Neovim has no window-local maps.
-- Leave other views (including previews) and ordinary windows with their own maps.
---@param session VimoiTemplateSession
local function restore_keymaps(session)
  for _, mapping in ipairs(session.keymaps) do
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
  session.keymaps = {}
end

---@param session VimoiTemplateSession
local function configure_window_keymaps(session)
  restore_keymaps(session)
  local win = vim.api.nvim_get_current_win()
  if session.closed or session.preview or M.by_window[win] ~= session then
    return
  end
  local buf = vim.api.nvim_win_get_buf(win)
  configure_fold_mappings(session, buf)
  local api = require("vimoi.api")
  local keymaps = require("vimoi").config.keymaps
  local in_source = win == session.source_win
  if keymaps.diff_get and keymaps.diff_get ~= "" then
    set_session_keymap(
      session,
      buf,
      keymaps.diff_get,
      api.get_hunk,
      in_source and "Get chezmoi target hunk into source template" or "Get rendered hunk into chezmoi target"
    )
  end
  if keymaps.diff_put and keymaps.diff_put ~= "" then
    set_session_keymap(
      session,
      buf,
      keymaps.diff_put,
      api.put_hunk,
      in_source and "Put rendered hunk into chezmoi target" or "Put chezmoi target hunk into source template"
    )
  end
end

---@param session VimoiTemplateSession
function M.close(session)
  if session.closed then
    return
  end
  session.closed = true
  if session.render_job then
    session.render_job.cancel()
  end
  local pending_merge = session.pending_merge
  session.pending_merge = nil
  if pending_merge then
    pending_merge.cancel()
  end
  set_loading(session, false)
  session.refresh_generation = (session.refresh_generation or 0) + 1
  for _, win in ipairs({ session.source_win, session.target_win }) do
    if M.by_window[win] == session then
      M.by_window[win] = nil
    end
  end
  if session.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, session.augroup)
  end
  restore_keymaps(session)
  for _, buf in ipairs({ session.source_buf, session.target_buf }) do
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
  for _, win in ipairs({ session.source_win, session.target_win }) do
    local expected_buf = win == session.source_win and session.source_buf or session.target_buf
    if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == expected_buf and vim.wo[win].diff then
      vim.api.nvim_win_call(win, function()
        vim.cmd("diffoff")
      end)
    end
  end
  native_diff.restore_diffexpr_if_unused(M.by_window)
end

---Register the opened pair and own everything that close must undo.
---@param session VimoiTemplateSession
function M.attach(session)
  local source_buf, target_buf = session.source_buf, session.target_buf
  local source_win, target_win = session.source_win, session.target_win
  local preview = session.preview
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
  M.by_window[source_win] = session
  M.by_window[target_win] = session
  set_loading(session, true)
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
  session.augroup = refresh_group
  vim.api.nvim_create_autocmd("User", {
    group = refresh_group,
    pattern = "VimoiCacheInvalidated",
    callback = function()
      -- The initial-render guard already retries context changes. Afterwards,
      -- refresh through the same debounce/validity checks as source edits.
      if not session.loading then
        M.schedule_refresh(session)
      end
    end,
  })
  for _, buf in ipairs({ source_buf, target_buf }) do
    vim.api.nvim_create_autocmd("BufWinLeave", {
      group = refresh_group,
      buffer = buf,
      callback = function()
        local win = vim.api.nvim_get_current_win()
        if win == source_win or win == target_win then
          M.close(session)
        end
      end,
    })
    if not preview or buf == source_buf then
      vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
        group = refresh_group,
        buffer = buf,
        callback = function()
          if not session.closed and (session.trace or (preview and not session.loading)) then
            M.schedule_refresh(session)
          end
        end,
      })
    end
    vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
      group = refresh_group,
      buffer = buf,
      callback = function()
        if session.syncing then
          return
        end
        local active_win = vim.api.nvim_get_current_win()
        vim.schedule(function()
          sync_scroll.sync(session, active_win)
        end)
      end,
    })
  end
  vim.api.nvim_create_autocmd("WinScrolled", {
    group = refresh_group,
    callback = function()
      if session.syncing then
        return
      end
      local active_win = vim.api.nvim_get_current_win()
      if active_win == session.source_win or active_win == session.target_win then
        vim.schedule(function()
          sync_scroll.sync(session, active_win)
        end)
      end
    end,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = refresh_group,
    callback = function(args)
      local closed_win = tonumber(args.match)
      if closed_win == session.source_win or closed_win == session.target_win then
        M.close(session)
      end
    end,
  })
  vim.api.nvim_create_autocmd("WinEnter", {
    group = refresh_group,
    callback = function()
      if M.by_window[vim.api.nvim_get_current_win()] == session then
        configure_window_keymaps(session)
      end
    end,
  })
  vim.api.nvim_create_autocmd("WinLeave", {
    group = refresh_group,
    callback = function()
      if M.by_window[vim.api.nvim_get_current_win()] == session then
        restore_keymaps(session)
      end
    end,
  })
  configure_window_keymaps(session)
end

---@class VimoiInitialRender
---@field source string
---@field context_generation integer
---@field trace? VimoiSourceMapTrace
---@field error? string

---Start the first asynchronous render after the pair is visible; retries keep the same timing profile.
---@param session VimoiTemplateSession
---@param profile VimoiOpenProfile
---@param opened_at integer Opening start time from vim.uv.hrtime().
function M.start_initial_render(session, profile, opened_at)
  M.last_profile = nil
  local source_buf, target_buf = session.source_buf, session.target_buf
  local preview = session.preview
  -- Target edits remain valid: read their latest text only when updating the view.
  ---@param result VimoiInitialRender
  local function should_retry(result)
    return util.buffer_text(source_buf) ~= result.source or cli.context_generation ~= result.context_generation
  end
  util.guard(function()
    ---@type VimoiInitialRender
    local result = { source = util.buffer_text(source_buf), context_generation = cli.context_generation }
    local before_render = vim.uv.hrtime()
    result.trace, result.error = util.await(function(done)
      session.render_job = source_map.trace_async(result.source, {
        init = session.is_init_template,
        buf = source_buf,
      }, done)
    end)
    session.render_job = nil
    profile.render_ms = profile.render_ms + (vim.uv.hrtime() - before_render) / 1e6

    -- Do not start an extra process for an obsolete render. The guard retries
    -- changed source/context, and closes a session whose windows no longer match.
    if
      result.trace
      and session.verify_with_cat
      and not session.is_init_template
      and M.is_valid(session)
      and not should_retry(result)
    then
      local before_validation = vim.uv.hrtime()
      local real_base, base_error = util.await(function(done)
        session.render_job = cli.run({ "cat", session.target_path }, {
          text = false,
          callback = function(output, err)
            done(output, err)
          end,
        })
      end)
      session.render_job = nil
      profile.validation_ms = profile.validation_ms + (vim.uv.hrtime() - before_validation) / 1e6
      if not real_base then
        result.trace, result.error = nil, base_error
      elseif result.trace.output ~= real_base then
        result.trace = nil
        result.error = "sentinel rendering differs from `chezmoi cat`; this template uses an unsupported render context"
      end
    end
    return result
  end, {
    -- Schedule even cache hits so both windows appear before parsing/rendering.
    delay = 0,
    is_valid = function()
      return M.is_valid(session)
    end,
    on_fail = function()
      M.close(session)
    end,
    should_retry = should_retry,
    on_result = function(result)
      if not result.trace then
        if preview then
          set_loading(session, false)
          set_preview_error(session, result.error)
        else
          M.close(session)
        end
        util.notify(result.error, preview and "preview" or "diff", vim.log.levels.ERROR)
        return
      end
      local before_view_update = vim.uv.hrtime()
      local updated, update_error = update_session(session, result.source, util.buffer_text(target_buf), result.trace)
      profile[preview and "preview_write_ms" or "diff_ms"] = (vim.uv.hrtime() - before_view_update) / 1e6
      set_loading(session, false)
      if not updated then
        M.close(session)
        util.notify(
          "cannot initialize view: " .. tostring(update_error),
          preview and "preview" or "diff",
          vim.log.levels.ERROR
        )
        return
      end
      profile.total_ms = (vim.uv.hrtime() - opened_at) / 1e6
      M.last_profile = profile
      if not preview and #session.hunks == 0 then
        util.notify("target matches rendered template", "diff")
      end
      local pending_merge = session.pending_merge
      session.pending_merge = nil
      if pending_merge then
        pending_merge.complete()
      end
    end,
  })()
end

return M

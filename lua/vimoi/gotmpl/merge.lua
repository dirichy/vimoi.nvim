-- Transfer rendered hunks to target, or map target edits back into source.
local M = {}
local util = require("vimoi.util")
local job = require("vimoi.job")
local cli = require("vimoi.cli")
local views = require("vimoi.gotmpl.view")
local native_diff = require("vimoi.gotmpl.native_diff")
local buffer_edits = require("vimoi.gotmpl.buffer_edits")
local merge_plan = require("vimoi.gotmpl.merge_plan")
local source_map = require("vimoi.gotmpl.source_map")
local sessions = require("vimoi.gotmpl.session")

-- This operation owns both subscriptions; the view stores no merge continuation.
---@param view VimoiTemplateView
local function wait_for_render(view)
  return job.wait("Waiting for template rendering…", function(finish, cancel)
    local changed = vim.api.nvim_create_autocmd("User", {
      pattern = "VimoiViewClosed",
      callback = function(args)
        if args.data.source_win ~= view.source_win or args.data.target_win ~= view.target_win then
          return
        end
        cancel(false)
      end,
    })
    local stop = sessions.register(view.source_buf, function(state, err)
      if not views.is_valid(view) then
        cancel(false)
      else
        finish(state and sessions.snapshot(view.source_buf), err)
      end
    end, { once = true })
    return function(cancel_render)
      vim.api.nvim_del_autocmd(changed)
      stop(cancel_render)
      if cancel_render and view.loading then
        views.close(view)
      end
    end
  end)
end

---@param trace VimoiSourceMapTrace
---@param choice VimoiMergeChoice
---@return VimoiMergeEdit[]
local function choice_candidates(trace, choice)
  local candidates = {}
  for _, edit in ipairs(choice.candidates) do
    local source, _, source_edits = merge_plan.apply_source_edits(trace, { edit })
    local predicted = source and source_map.rebuild_after_edits(trace, source, source_edits)
    local expected = trace.output:sub(1, edit.rendered_start_byte)
      .. edit.replacement
      .. trace.output:sub(edit.rendered_end_byte + 1)
    if predicted and predicted.output == expected then
      local row, col = util.byte_to_position(trace.source, edit.start_byte)
      if edit.end_byte > edit.start_byte then
        edit.label = ("line %d:%d  replace %q with %q"):format(
          row + 1,
          col + 1,
          trace.source:sub(edit.start_byte + 1, edit.end_byte),
          edit.replacement
        )
      else
        local line = util.text_lines(trace.source)[row + 1] or ""
        edit.label = ("line %d:%d  %s▸%s"):format(row + 1, col + 1, line:sub(1, col), line:sub(col + 1))
      end
      candidates[#candidates + 1] = edit
    end
  end
  return candidates
end

---@param trace VimoiSourceMapTrace
---@param choices VimoiMergeChoice[]
---@param check fun(): boolean
---@return VimoiMergeEdit[]? selected Nil if the operation became invalid while selecting.
---@return VimoiSkippedHunk[] skipped
local function select_choices(trace, choices, check)
  local selected, skipped = {}, {}
  for _, choice in ipairs(choices) do
    local candidates = choice_candidates(trace, choice)
    local item = candidates[1]
    if #candidates > 1 then
      item = util.await(function(done)
        vim.ui.select(candidates, {
          prompt = "Choose where to insert the target hunk in the chezmoi template:",
          format_item = function(candidate)
            return candidate.label
          end,
        }, done)
      end)
      if not check() then
        return nil, skipped
      end
    end
    if item then
      selected[#selected + 1] = item
    else
      skipped[#skipped + 1] = {
        hunk = choice.hunk,
        reason = #candidates == 0 and "no static placement produces the requested result"
          or "insertion choice cancelled",
      }
    end
  end
  return selected, skipped
end

---@param mode "put"|"get"|"readd"
local function merge(mode)
  local requested_buf = vim.api.nvim_get_current_buf()
  local requested_line = vim.api.nvim_win_get_cursor(0)[1]
  local session = views.by_window[vim.api.nvim_get_current_win()]
  if session and not views.is_valid(session) then
    views.close(session)
  end
  if not session or session.closed or session.preview then
    return util.notify("current buffer is not in a vimoi diff session", "diff", vim.log.levels.ERROR)
  end
  -- Resolve direction before rendering can move focus to a wait window.
  local to_target = (mode == "put" and requested_buf == session.source_buf)
    or (mode == "get" and requested_buf == session.target_buf)
  -- Every deferred stage belongs to this exact session, source, target, and
  -- rendering context. A later choice must never operate on newer buffer text.
  local source_path = vim.api.nvim_buf_get_name(session.source_buf)
  local target_path = vim.api.nvim_buf_get_name(session.target_buf)
  local source_text = util.buffer_text(session.source_buf)
  local target_text = util.buffer_text(session.target_buf)
  local context_generation = cli.context_generation
  local function check()
    if
      views.is_valid(session)
      and vim.api.nvim_buf_get_name(session.source_buf) == source_path
      and vim.api.nvim_buf_get_name(session.target_buf) == target_path
      and cli.context_generation == context_generation
      and util.buffer_text(session.source_buf) == source_text
      and util.buffer_text(session.target_buf) == target_text
    then
      return true
    end
    if not views.is_valid(session) then
      views.close(session)
    end
    util.notify("session, buffers, or rendering context changed; merge cancelled", "diff", vim.log.levels.WARN)
    return false
  end
  local function report_error(message)
    return util.notify(
      "cannot " .. ({ put = "put this hunk: ", get = "get this hunk: ", readd = "re-add template: " })[mode] .. message,
      "diff",
      vim.log.levels.ERROR
    )
  end
  local trace = sessions.rebuild(session.source_buf)
  if not trace then
    local completed, rendered, render_error = wait_for_render(session)
    if not completed then
      return
    end
    if not rendered then
      return report_error(tostring(render_error))
    end
    trace = rendered
  end
  if not check() then
    return
  end
  local refreshed, refresh_error = views.refresh(session, trace)
  if not refreshed then
    return report_error(tostring(refresh_error))
  end
  local hunks = session.hunks
  if mode ~= "readd" then
    local hunk = native_diff.hunk_at(session, requested_buf, requested_line)
    if not hunk then
      return report_error("cursor is not on a diff hunk")
    end
    hunks = { hunk }
  end
  if to_target then
    local hunk = hunks[1]
    local rendered_start, rendered_end =
      util.line_range(trace.output, util.line_starts(trace.output), hunk.rendered_start_line, hunk.rendered_line_count)
    local target_start, target_end =
      util.line_range(target_text, util.line_starts(target_text), hunk.target_start_line, hunk.target_line_count)
    -- Native diff copies source lines, which contain template actions. Copy
    -- this hunk's rendered bytes instead, narrowing the write to changed bytes.
    local first, last, replacement = util.changed_bytes(
      target_text:sub(target_start + 1, target_end),
      trace.output:sub(rendered_start + 1, rendered_end)
    )
    local edit = {
      start_byte = target_start + first,
      end_byte = target_start + last,
      replacement = replacement,
    }
    local updated = target_text:sub(1, edit.start_byte) .. replacement .. target_text:sub(edit.end_byte + 1)
    buffer_edits.apply(session.target_buf, target_text, updated, { edit })
    local refreshed_target, target_error = views.refresh(session, trace)
    if not refreshed_target then
      return report_error("target was updated, but refreshing the diff failed: " .. tostring(target_error))
    end
    util.notify("copied rendered hunk into target", "diff")
    return true
  end
  local plan = merge_plan.plan(trace, target_text, hunks)
  if mode ~= "readd" and #plan.skipped > 0 then
    return report_error(plan.skipped[1].reason or "unknown mapping")
  end
  if not check() then
    return
  end
  local selected, choice_skipped = select_choices(trace, plan.choices, check)
  if not selected then
    return
  end
  local skipped = vim.list_extend(vim.deepcopy(plan.skipped), choice_skipped)
  if mode ~= "readd" and #skipped > 0 then
    util.notify("insertion choice cancelled; source was not changed", "diff", vim.log.levels.WARN)
    return false
  end
  local edits = vim.list_extend(vim.deepcopy(plan.edits), selected)
  local merged_hunks, skipped_hunks = {}, {}
  for _, edit in ipairs(edits) do
    merged_hunks[edit.hunk.id] = true
  end
  for _, item in ipairs(skipped) do
    skipped_hunks[item.hunk.id] = true
  end
  local merged_count, skipped_count = vim.tbl_count(merged_hunks), vim.tbl_count(skipped_hunks)
  if #edits == 0 then
    if mode ~= "readd" then
      return report_error("no byte edits found")
    end
    util.notify(("no hunks merged; %d require manual editing"):format(skipped_count), "diff", vim.log.levels.WARN)
    return { merged = 0, skipped = skipped_count, reasons = skipped }
  end
  local candidate, candidate_error, source_edits = merge_plan.apply_source_edits(trace, edits)
  if not candidate then
    return report_error(tostring(candidate_error))
  end
  local candidate_trace, trace_error = source_map.rebuild_after_edits(trace, candidate, source_edits)
  if not candidate_trace then
    return report_error("cannot infer static edit: " .. tostring(trace_error))
  end
  buffer_edits.apply(session.source_buf, source_text, candidate, source_edits)
  local updated, update_error = views.refresh(session, candidate_trace)
  if not updated then
    return util.notify(
      "source was updated, but refreshing the diff failed: " .. tostring(update_error),
      "diff",
      vim.log.levels.ERROR
    )
  end
  if mode ~= "readd" then
    util.notify("merged target hunk into source template", "diff")
    return true
  else
    util.notify(
      ("re-added %d hunks; %d require manual editing"):format(merged_count, skipped_count),
      "diff",
      skipped_count > 0 and vim.log.levels.WARN or vim.log.levels.INFO
    )
    return { merged = merged_count, skipped = skipped_count, reasons = skipped }
  end
end

---Put the current hunk into the peer window; rendering/choices may be asynchronous.
---@return boolean?
function M.put_hunk()
  return util.async(merge, "put")
end

---Get the peer hunk into the current window; rendering/choices may be asynchronous.
---@return boolean?
function M.get_hunk()
  return util.async(merge, "get")
end

---Re-add all target hunks in the current template diff.
---@return VimoiReAddResult?
function M.readd()
  return util.async(merge, "readd")
end

return M

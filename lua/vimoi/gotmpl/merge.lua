-- Transfer rendered hunks to target, or map target edits back into source.
local M = {}
local util = require("vimoi.util")
local job = require("vimoi.job")
local cli = require("vimoi.cli")
local sessions = require("vimoi.gotmpl.session")
local native_diff = require("vimoi.gotmpl.native_diff")
local buffer_edits = require("vimoi.gotmpl.buffer_edits")
local merge_plan = require("vimoi.gotmpl.merge_plan")
local source_map = require("vimoi.gotmpl.source_map")

-- Wait for the view's render using the same modal progress UI as commands.
---@param session VimoiTemplateSession
---@param validity VimoiGuardOptions
---@param resume function
---@return function complete
local function wait_for_render(session, validity, resume)
  if session.pending_merge then
    session.pending_merge.cancel()
  end
  resume = util.guard(resume, validity)
  local active, pending = true, nil
  ---@type VimoiProgress
  local progress
  local function cancel()
    if not active then
      return
    end
    active = false
    if session.pending_merge == pending then
      session.pending_merge = nil
    end
    session.refresh_generation = (session.refresh_generation or 0) + 1
    progress.cancel()
    if session.render_job then
      -- Abandoning an explicit modal wait kills the command, including any
      -- automatic diagnostic subscriber; merely closing a view releases its caller.
      if session.render_job.progress then
        session.render_job.progress.cancel()
      else
        session.render_job.cancel()
      end
    end
    -- A queued first render has no process yet. Retire it before it can start.
    if session.loading then
      sessions.close(session)
    end
  end
  progress = job.progress("Waiting for template rendering…", "modal", cancel)
  local function complete(...)
    if not active then
      return
    end
    active = false
    if session.pending_merge == pending then
      session.pending_merge = nil
    end
    if progress.finish() then
      return resume(...)
    end
  end
  pending = { cancel = cancel, complete = complete }
  session.pending_merge = pending
  return complete
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
---@param validity VimoiGuardOptions
---@param callback fun(selected: VimoiMergeEdit[], skipped: VimoiSkippedHunk[])
local function select_choices(trace, choices, validity, callback)
  local selected, skipped = {}, {}
  local select_next
  select_next = util.guard(function(index)
    local choice = choices[index]
    if not choice then
      return callback(selected, skipped)
    end
    local candidates = choice_candidates(trace, choice)
    local choose = util.guard(function(item)
      if item then
        selected[#selected + 1] = item
      else
        skipped[#skipped + 1] = {
          hunk = choice.hunk,
          reason = #candidates == 0 and "no static placement produces the requested result"
            or "insertion choice cancelled",
        }
      end
      select_next(index + 1)
    end, validity)
    if #candidates < 2 then
      choose(candidates[1])
    else
      vim.ui.select(candidates, {
        prompt = "Choose where to insert the target hunk in the chezmoi template:",
        format_item = function(item)
          return item.label
        end,
      }, choose)
    end
  end, validity)
  select_next(1)
end

---@param mode "put"|"apply"|"readd"
local function merge(mode)
  local requested_buf = vim.api.nvim_get_current_buf()
  local requested_line = vim.api.nvim_win_get_cursor(0)[1]
  local session = sessions.by_window[vim.api.nvim_get_current_win()]
  if session and not sessions.is_valid(session) then
    sessions.close(session)
  end
  if not session or session.closed or session.preview then
    return util.notify("current buffer is not in a vimoi diff session", "diff", vim.log.levels.ERROR)
  end
  -- Every deferred stage belongs to this exact session, source, target, and
  -- rendering context. A later choice must never operate on newer buffer text.
  local source_text = util.buffer_text(session.source_buf)
  local target_text = util.buffer_text(session.target_buf)
  local context_generation = cli.context_generation
  local cancelled = false
  local result
  local validity = {
    is_valid = function()
      return not cancelled
        and sessions.is_valid(session)
        and cli.context_generation == context_generation
        and util.buffer_text(session.source_buf) == source_text
        and util.buffer_text(session.target_buf) == target_text
    end,
    on_fail = function()
      if cancelled then
        return
      end
      cancelled = true
      if not sessions.is_valid(session) then
        sessions.close(session)
      end
      util.notify("session, buffers, or rendering context changed; merge cancelled", "diff", vim.log.levels.WARN)
    end,
  }
  local function report_error(message)
    return util.notify(
      "cannot "
        .. ({ put = "put this hunk: ", apply = "apply this hunk: ", readd = "re-add template: " })[mode]
        .. message,
      "diff",
      vim.log.levels.ERROR
    )
  end
  local transfer_hunks = util.guard(function(trace)
    session.refresh_generation = (session.refresh_generation or 0) + 1
    local refreshed, refresh_error = sessions.refresh(session, trace)
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
    if mode == "apply" then
      local hunk = hunks[1]
      local rendered_start, rendered_end = util.line_range(
        trace.output,
        util.line_starts(trace.output),
        hunk.rendered_start_line,
        hunk.rendered_line_count
      )
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
      session.refresh_generation = (session.refresh_generation or 0) + 1
      local refreshed_target, target_error = sessions.refresh(session, trace)
      if not refreshed_target then
        return report_error("target was updated, but refreshing the diff failed: " .. tostring(target_error))
      end
      result = true
      util.notify("applied rendered hunk to target", "diff")
      return
    end
    local plan = merge_plan.plan(trace, target_text, hunks)
    if mode == "put" and #plan.skipped > 0 then
      return report_error(plan.skipped[1].reason or "unknown mapping")
    end
    local selected, skipped = {}, vim.deepcopy(plan.skipped)
    local infer_and_apply = util.guard(function()
      if mode == "put" and #skipped > 0 then
        result = false
        return util.notify("insertion choice cancelled; source was not changed", "diff", vim.log.levels.WARN)
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
        if mode == "put" then
          return report_error("no byte edits found")
        end
        result = { merged = 0, skipped = skipped_count, reasons = skipped }
        return util.notify(
          ("no hunks merged; %d require manual editing"):format(skipped_count),
          "diff",
          vim.log.levels.WARN
        )
      end
      local candidate, candidate_error = merge_plan.prepare_candidate(trace, edits)
      if not candidate then
        return report_error(tostring(candidate_error))
      end
      local candidate_trace, trace_error =
        source_map.rebuild_after_edits(trace, candidate.source_text, candidate.source_edits)
      if not candidate_trace then
        return report_error("cannot infer static edit: " .. tostring(trace_error))
      end
      buffer_edits.apply(session.source_buf, source_text, candidate.source_text, candidate.source_edits)
      session.refresh_generation = (session.refresh_generation or 0) + 1
      local updated, update_error = sessions.refresh(session, candidate_trace)
      if not updated then
        return util.notify(
          "source was updated, but refreshing the diff failed: " .. tostring(update_error),
          "diff",
          vim.log.levels.ERROR
        )
      end
      if mode == "put" then
        result = true
        util.notify("put hunk into source template", "diff")
      else
        result = { merged = merged_count, skipped = skipped_count, reasons = skipped }
        util.notify(
          ("re-added %d hunks; %d require manual editing"):format(merged_count, skipped_count),
          "diff",
          skipped_count > 0 and vim.log.levels.WARN or vim.log.levels.INFO
        )
      end
    end, validity)

    select_choices(trace, plan.choices, validity, function(choices, choice_skipped)
      selected = choices
      vim.list_extend(skipped, choice_skipped)
      infer_and_apply()
    end)
  end, validity)
  local refresh_trace = util.guard(function()
    local trace = source_map.rebuild(session.trace, source_text, session.source_buf)
    if trace then
      transfer_hunks(trace)
    else
      local complete = wait_for_render(session, validity, function(rendered, render_error)
        if not rendered then
          return report_error(tostring(render_error))
        end
        transfer_hunks(rendered)
      end)
      session.render_job =
        source_map.trace_async(source_text, { init = session.is_init_template, buf = session.source_buf }, complete)
    end
  end, validity)
  if session.trace then
    refresh_trace()
  else
    wait_for_render(session, validity, refresh_trace)
  end
  return result
end

---Put the requested hunk; nil means an asynchronous render or choice is pending.
---@return boolean?
function M.put_hunk()
  return merge("put")
end

---Apply one rendered hunk to target; nil means rendering is pending or failed.
---@return boolean?
function M.apply_hunk()
  return merge("apply")
end

---Re-add all target hunks in the current template diff.
---@return VimoiReAddResult?
function M.readd()
  return merge("readd")
end

return M

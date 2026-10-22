local M = {}
local util = require("vimoi.util")
local diff_hunks = require("vimoi.gotmpl.diff_hunks")
local changed_bytes = util.changed_bytes

-- Merge planning locates static edits and ambiguous placements; source_map
-- reconstructs their output using the existing execution snapshot.

---An unescaped replacement with byte ranges in both the template source and its rendered output.
---@class VimoiMergeEdit: VimoiBufferEdit
---@field start_byte integer Zero-based, inclusive template-source offset.
---@field end_byte integer Exclusive template-source offset.
---@field rendered_start_byte integer Zero-based, inclusive rendered-output offset.
---@field rendered_end_byte integer Exclusive rendered-output offset.
---@field hunk VimoiDiffHunk Original line hunk, retained when isolated into byte edits.
---@field label? string Display text added when presenting an insertion choice.

---@class VimoiMergeChoice
---@field hunk VimoiDiffHunk
---@field candidates VimoiMergeEdit[] Proposed source placements, locally checked before selection.

---@class VimoiSkippedHunk
---@field hunk VimoiDiffHunk
---@field reason? string

---A plan contains only proposed placements; it does not construct the final template.
---@class VimoiMergePlan
---@field edits VimoiMergeEdit[] Automatic placements, ordered by source byte offset.
---@field choices VimoiMergeChoice[] Placements requiring a selection before writing.
---@field skipped VimoiSkippedHunk[]

local function static_source_range(hunk)
  if #hunk.source_ranges ~= 1 then
    return nil, "hunk does not have one exact source range"
  end
  local range = hunk.source_ranges[1]
  if range.kind ~= "static" then
    return nil, ("hunk maps to %s template content"):format(range.kind)
  end
  return range
end

local function insertion_source_range(hunk)
  local anchor
  local has_static = false
  for _, range in ipairs(hunk.source_ranges) do
    -- A non-empty projected range means a template action lies between two
    -- possible insertion anchors. They render identically now but may land on
    -- different sides of an if/range when its value changes.
    if range.start_byte ~= range.end_byte then
      return nil, "insertion is on a template block or static-region boundary"
    end
    if anchor ~= nil and anchor ~= range.start_byte then
      return nil, "insertion has multiple possible source anchors"
    end
    anchor = range.start_byte
    if range.kind == "repeated" or range.kind == "ambiguous" then
      return nil, ("insertion maps to %s template content"):format(range.kind)
    end
    has_static = has_static or range.kind == "static"
  end
  if anchor ~= nil and has_static then
    return { start_byte = anchor, end_byte = anchor, kind = "static" }
  end
  return nil, "insertion is on a template block or static-region boundary"
end

-- Match whole syntax tags and intervening whitespace, never braces inside a
-- quoted string. The trace owns both tag boundaries and control classification.
local function preceding_tag(trace, byte)
  for index = #trace.template_tags, 1, -1 do
    local tag = trace.template_tags[index]
    if tag.end_byte <= byte then
      if not trace.source:sub(tag.end_byte + 1, byte):find("%S") then
        return tag, index
      end
      return
    end
  end
end

local function control_choice_anchors(trace, hunk, allow_static_ranges)
  local anchors, seen = {}, {}
  local has_control = false
  for _, range in ipairs(hunk.source_ranges) do
    if range.kind == "repeated" or range.kind == "ambiguous" then
      return nil
    end
    if range.start_byte ~= range.end_byte then
      if range.kind == "static" and allow_static_ranges then
        -- A line hunk may include unchanged static text beside an insertion.
      elseif range.kind ~= "dynamic" then
        return nil
      else
        local byte, count = range.start_byte, 0
        for _, tag in ipairs(trace.template_tags) do
          if tag.start_byte >= range.start_byte and tag.end_byte <= range.end_byte then
            if not tag.control or trace.source:sub(byte + 1, tag.start_byte):find("%S") then
              return nil
            end
            byte, count = tag.end_byte, count + 1
          end
        end
        if count == 0 or trace.source:sub(byte + 1, range.end_byte):find("%S") then
          return nil
        end
        has_control = true
      end
    end
    for _, byte in ipairs({ range.start_byte, range.end_byte }) do
      if not seen[byte] then
        seen[byte] = true
        anchors[#anchors + 1] = byte
      end
    end
  end
  if not has_control or #anchors < 2 then
    return nil
  end
  table.sort(anchors)
  local tag = preceding_tag(trace, anchors[1])
  if tag and tag.control == "if" and not seen[tag.start_byte] then
    table.insert(anchors, 1, tag.start_byte)
  end
  return anchors
end

local function empty_if_choice_anchors(trace, anchor)
  local last, index = preceding_tag(trace, anchor)
  if not last or last.control ~= "end" or index < 2 then
    return nil
  end
  local first = trace.template_tags[index - 1]
  if first.control == "if" and not trace.source:sub(first.end_byte + 1, last.start_byte):find("%S") then
    return { first.start_byte, last.start_byte, anchor }
  end
end

local function adjacent_control_boundary_anchors(trace, anchor)
  local tag = preceding_tag(trace, anchor)
  return tag and tag.control and { tag.start_byte, anchor } or nil
end

---@param modified string
---@param trace VimoiSourceMapTrace
---@param hunk VimoiDiffHunk
---@return VimoiMergeEdit?
---@return string? error
local function insertion_edit(modified, trace, hunk)
  local range, range_error = insertion_source_range(hunk)
  if not range then
    return nil, range_error
  end
  local replacement_start, replacement_end =
    util.line_range(modified, util.line_starts(modified), hunk.target_start_line, hunk.target_line_count)
  local rendered_start_byte, rendered_end_byte =
    util.line_range(trace.output, util.line_starts(trace.output), hunk.rendered_start_line, hunk.rendered_line_count)
  return {
    start_byte = range.start_byte,
    end_byte = range.end_byte,
    rendered_start_byte = rendered_start_byte,
    rendered_end_byte = rendered_end_byte,
    replacement = modified:sub(replacement_start + 1, replacement_end),
    hunk = hunk,
  }
end

---Apply sorted, non-overlapping edits from right to left; offset locates a source substring.
---@param text string
---@param edits VimoiBufferEdit[] Ascending offsets, including insertion order at equal anchors.
---@param offset? integer
---@return string
local function apply_edits(text, edits, offset)
  offset = offset or 0
  for index = #edits, 1, -1 do
    local edit = edits[index]
    text = text:sub(1, edit.start_byte - offset) .. edit.replacement .. text:sub(edit.end_byte - offset + 1)
  end
  return text
end

-- Apply all edits in a literal slot before escaping. This also catches braces
-- joined by deletion or by several adjacent edits, without boundary heuristics.
-- Scan the combined edited span plus one unchanged byte on either side. Old
-- literal text cannot contain {{, so only those neighbours can form a new pair.
---@param parts VimoiTemplateParts
---@param edits VimoiBufferEdit[] Unescaped source replacements.
---@return string? source
---@return string? error
---@return VimoiBufferEdit[] source_edits Ascending offsets; empty on failure.
local function apply_source_edits(parts, edits)
  local source = parts.source
  local ordered, order = vim.deepcopy(edits), {}
  for index, edit in ipairs(ordered) do
    order[edit] = index
  end
  table.sort(ordered, function(a, b)
    if a.start_byte == b.start_byte then
      return a.end_byte < b.end_byte or (a.end_byte == b.end_byte and order[a] < order[b])
    end
    return a.start_byte < b.start_byte
  end)
  for index = 2, #ordered do
    if ordered[index].start_byte < ordered[index - 1].end_byte then
      return nil, "source edits overlap", {}
    end
  end
  local source_edits, edit_index = {}, 1
  for index = 1, #parts.literal_parts do
    local previous_tag, following_tag = parts.template_tags[index - 1], parts.template_tags[index]
    local start_byte = previous_tag and previous_tag.end_byte or 0
    local end_byte = following_tag and following_tag.start_byte or #source
    local slot_edits = {}
    while ordered[edit_index] and ordered[edit_index].start_byte <= end_byte do
      local edit = ordered[edit_index]
      if edit.start_byte < start_byte or edit.end_byte > end_byte then
        return nil, "source edit crosses a template tag", {}
      end
      slot_edits[#slot_edits + 1] = {
        start_byte = edit.start_byte - start_byte,
        end_byte = edit.end_byte - start_byte,
        replacement = edit.replacement,
      }
      edit_index = edit_index + 1
    end
    if #slot_edits > 0 then
      local scan_start = math.max(0, slot_edits[1].start_byte - 1)
      local scan_end = math.min(end_byte - start_byte, slot_edits[#slot_edits].end_byte + 1)
      local before = source:sub(start_byte + scan_start + 1, start_byte + scan_end)
      local after = apply_edits(before, slot_edits, scan_start)
      local touches_tag = following_tag and start_byte + scan_end == end_byte
      local trailing_brace = touches_tag and after:sub(-1) == "{"
      if trailing_brace or after:find("{{", 1, true) then
        -- Escape entire brace runs so no leftover brace can join an inserted tag.
        after = after:gsub("{{+", '{{ "%0" }}')
        if touches_tag and after:sub(-1) == "{" then
          after = after:sub(1, -2) .. '{{ "{" }}'
        end
        local first, old_end, replacement = changed_bytes(before, after)
        source_edits[#source_edits + 1] = {
          start_byte = start_byte + scan_start + first,
          end_byte = start_byte + scan_start + old_end,
          replacement = replacement,
        }
      else
        -- Ordinary edits keep their disjoint writes and untouched extmarks/folds.
        for _, edit in ipairs(slot_edits) do
          source_edits[#source_edits + 1] = {
            start_byte = start_byte + edit.start_byte,
            end_byte = start_byte + edit.end_byte,
            replacement = edit.replacement,
          }
        end
      end
    end
  end
  if edit_index <= #ordered then
    return nil, "source edit is outside the template", {}
  end
  local updated = apply_edits(source, source_edits)
  return updated, nil, source_edits
end

-- Neovim's diff is line-oriented. Encode each byte as a short line, but only after
-- removing the common prefix/suffix so ordinary edits stay small. The result
-- is a real sequence of disjoint byte edits, including several on one line.
local function byte_edits(before, after, rendered_start_byte)
  local prefix, old_end, replacement = changed_bytes(before, after)
  if prefix == old_end and replacement == "" then
    return {}
  end
  local old_middle = before:sub(prefix + 1, old_end)
  local new_middle = replacement
  local function encode_bytes_as_lines(bytes)
    local lines = {}
    for index = 1, #bytes do
      lines[index] = ("%02x\n"):format(bytes:byte(index))
    end
    return table.concat(lines)
  end
  local byte_hunks = vim.text.diff(encode_bytes_as_lines(old_middle), encode_bytes_as_lines(new_middle), {
    result_type = "indices",
    algorithm = "myers",
  })
  assert(type(byte_hunks) == "table")
  local edits = {}
  for _, item in ipairs(byte_hunks) do
    local old_offset = item[1] - (item[2] > 0 and 1 or 0)
    local new_offset = item[3] - (item[4] > 0 and 1 or 0)
    edits[#edits + 1] = {
      start_byte = rendered_start_byte + prefix + old_offset,
      end_byte = rendered_start_byte + prefix + old_offset + item[2],
      replacement = new_middle:sub(new_offset + 1, new_offset + item[4]),
    }
  end
  return edits
end

---@param trace VimoiSourceMapTrace
---@param modified string
---@param hunk VimoiDiffHunk
---@return VimoiMergeEdit[]
---@return boolean touches_boundary
local function static_byte_edit_candidates(trace, modified, hunk)
  local hunk_rendered_start_byte, hunk_rendered_end_byte =
    util.line_range(trace.output, util.line_starts(trace.output), hunk.rendered_start_line, hunk.rendered_line_count)
  local target_start_byte, target_end_byte =
    util.line_range(modified, util.line_starts(modified), hunk.target_start_line, hunk.target_line_count)
  local before = trace.output:sub(hunk_rendered_start_byte + 1, hunk_rendered_end_byte)
  local after = modified:sub(target_start_byte + 1, target_end_byte)
  local first, old_end, replacement = changed_bytes(before, after)
  local removed_bytes = old_end - first

  local candidates = {}
  -- Repeated bytes can make an edit equivalent at several offsets. Check the
  -- whole equivalent window, including insertions, so a static text edit is
  -- not mistaken for a template-control boundary edit.
  local common_suffix = 0
  while
    common_suffix < math.min(#before, #after)
    and before:byte(#before - common_suffix) == after:byte(#after - common_suffix)
  do
    common_suffix = common_suffix + 1
  end
  local first_offset, last_offset = math.min(first, math.min(#before, #after) - common_suffix), first
  local candidates_by_literal_part = {}
  local touches_boundary = false
  for offset = first_offset, last_offset do
    if before:sub(1, offset) .. replacement .. before:sub(offset + removed_bytes + 1) == after then
      local rendered_start_byte = hunk_rendered_start_byte + offset
      local rendered_end_byte = rendered_start_byte + removed_bytes
      for literal_part_index, literal_part in ipairs(trace.literal_parts) do
        local occurrence = literal_part.output_ranges[1]
        if
          #literal_part.output_ranges == 1
          and rendered_start_byte >= occurrence.start_byte
          and rendered_end_byte <= occurrence.end_byte
        then
          local boundary = removed_bytes == 0
            and (rendered_start_byte == occurrence.start_byte or rendered_start_byte == occurrence.end_byte)
          touches_boundary = touches_boundary or boundary
          local existing = candidates_by_literal_part[literal_part_index]
          if not existing or (existing.boundary and not boundary) then
            local source_start_byte = literal_part.source.start_byte + rendered_start_byte - occurrence.start_byte
            local candidate = {
              start_byte = source_start_byte,
              end_byte = source_start_byte + removed_bytes,
              rendered_start_byte = rendered_start_byte,
              rendered_end_byte = rendered_end_byte,
              replacement = replacement,
              hunk = hunk,
            }
            if existing then
              candidates[existing.index] = candidate
            else
              candidates[#candidates + 1] = candidate
            end
            candidates_by_literal_part[literal_part_index] =
              { index = existing and existing.index or #candidates, boundary = boundary }
          end
        end
      end
    end
  end
  return candidates, touches_boundary
end

-- Plan one isolated byte edit. A static mapping is automatic; a control
-- boundary yields a finite set of placements; anything else stays manual.
---@param modified string
---@param trace VimoiSourceMapTrace
---@param hunk VimoiDiffHunk
---@return VimoiMergePlan
local function plan_isolated_merge(modified, trace, hunk)
  local edits, choices, skipped = {}, {}, {}
  local edit, edit_error
  local anchors
  local byte_edit_candidates
  if hunk.rendered_line_count > 0 then
    _, edit_error = static_source_range(hunk)
    local touches_boundary
    byte_edit_candidates, touches_boundary = static_byte_edit_candidates(trace, modified, hunk)
    if touches_boundary then
      local control_anchors = control_choice_anchors(trace, hunk, true)
      if control_anchors then
        local rendered_start_byte, rendered_end_byte = util.line_range(
          trace.output,
          util.line_starts(trace.output),
          hunk.rendered_start_line,
          hunk.rendered_line_count
        )
        local target_start_byte, target_end_byte =
          util.line_range(modified, util.line_starts(modified), hunk.target_start_line, hunk.target_line_count)
        local offset, _, inserted = changed_bytes(
          trace.output:sub(rendered_start_byte + 1, rendered_end_byte),
          modified:sub(target_start_byte + 1, target_end_byte)
        )
        local seen_anchor = {}
        for _, candidate in ipairs(byte_edit_candidates) do
          seen_anchor[candidate.start_byte] = true
        end
        for _, anchor in ipairs(control_anchors) do
          if not seen_anchor[anchor] then
            seen_anchor[anchor] = true
            byte_edit_candidates[#byte_edit_candidates + 1] = {
              start_byte = anchor,
              end_byte = anchor,
              rendered_start_byte = rendered_start_byte + offset,
              rendered_end_byte = rendered_start_byte + offset,
              replacement = inserted,
              hunk = hunk,
            }
          end
        end
      end
    end
    if #byte_edit_candidates == 1 then
      edit = byte_edit_candidates[1]
    end
  else
    edit, edit_error = insertion_edit(modified, trace, hunk)
  end
  if edit and hunk.rendered_line_count == 0 then
    anchors = empty_if_choice_anchors(trace, edit.start_byte)
      or adjacent_control_boundary_anchors(trace, edit.start_byte)
    if anchors then
      edit = nil
      edit_error = "insertion is adjacent to a template control action"
    end
  end
  if edit then
    edits[#edits + 1] = edit
  elseif byte_edit_candidates and #byte_edit_candidates > 1 then
    choices[#choices + 1] = { hunk = hunk, candidates = byte_edit_candidates }
  else
    local rendered_start_byte, rendered_end_byte =
      util.line_range(trace.output, util.line_starts(trace.output), hunk.rendered_start_line, hunk.rendered_line_count)
    local target_start_byte, target_end_byte =
      util.line_range(modified, util.line_starts(modified), hunk.target_start_line, hunk.target_line_count)
    local replacement
    if hunk.rendered_line_count == 0 then
      anchors = anchors or control_choice_anchors(trace, hunk)
      replacement = modified:sub(target_start_byte + 1, target_end_byte)
    else
      local offset_start, offset_end, inserted = changed_bytes(
        trace.output:sub(rendered_start_byte + 1, rendered_end_byte),
        modified:sub(target_start_byte + 1, target_end_byte)
      )
      if offset_start == offset_end and inserted ~= "" then
        anchors = control_choice_anchors(trace, hunk, true)
        rendered_start_byte = rendered_start_byte + offset_start
        rendered_end_byte = rendered_start_byte
        replacement = inserted
      end
    end
    if anchors then
      local candidates = {}
      for _, anchor in ipairs(anchors) do
        candidates[#candidates + 1] = {
          start_byte = anchor,
          end_byte = anchor,
          rendered_start_byte = rendered_start_byte,
          rendered_end_byte = rendered_end_byte,
          replacement = replacement,
          hunk = hunk,
        }
      end
      choices[#choices + 1] = { hunk = hunk, candidates = candidates }
    else
      skipped[#skipped + 1] = { hunk = hunk, reason = edit_error }
    end
  end

  return { edits = edits, choices = choices, skipped = skipped }
end

---@param trace VimoiSourceMapTrace
---@param modified string
---@param hunks VimoiDiffHunk[]
---@return VimoiMergePlan
local function plan_merge(trace, modified, hunks)
  local edits, choices, skipped = {}, {}, {}
  local rendered_line_starts = util.line_starts(trace.output)
  local target_line_starts = util.line_starts(modified)
  for _, hunk in ipairs(hunks) do
    local rendered_start_byte, rendered_end_byte =
      util.line_range(trace.output, rendered_line_starts, hunk.rendered_start_line, hunk.rendered_line_count)
    local target_start_byte, target_end_byte =
      util.line_range(modified, target_line_starts, hunk.target_start_line, hunk.target_line_count)
    local byte_changes = byte_edits(
      trace.output:sub(rendered_start_byte + 1, rendered_end_byte),
      modified:sub(target_start_byte + 1, target_end_byte),
      rendered_start_byte
    )
    -- Isolating byte edits prevents a line-level hunk from hiding a safe
    -- static change beside an ambiguous template-control insertion.
    for _, byte_change in ipairs(byte_changes) do
      local isolated_target = trace.output:sub(1, byte_change.start_byte)
        .. byte_change.replacement
        .. trace.output:sub(byte_change.end_byte + 1)
      local isolated_hunks = diff_hunks.compute(isolated_target, trace)
      if #isolated_hunks ~= 1 then
        skipped[#skipped + 1] = { hunk = hunk, reason = "byte edit could not be isolated to one diff hunk" }
      else
        local isolated_plan = plan_isolated_merge(isolated_target, trace, isolated_hunks[1])
        for _, edit in ipairs(isolated_plan.edits) do
          edit.hunk = hunk
          edits[#edits + 1] = edit
        end
        for _, choice in ipairs(isolated_plan.choices) do
          choice.hunk = hunk
          for _, candidate in ipairs(choice.candidates) do
            candidate.hunk = hunk
          end
          choices[#choices + 1] = choice
        end
        for _, item in ipairs(isolated_plan.skipped) do
          item.hunk = hunk
          skipped[#skipped + 1] = item
        end
      end
    end
  end

  table.sort(edits, function(a, b)
    return a.start_byte < b.start_byte
  end)
  local non_overlapping_edits = {}
  for _, edit in ipairs(edits) do
    local previous = non_overlapping_edits[#non_overlapping_edits]
    if previous and edit.start_byte < previous.end_byte then
      skipped[#skipped + 1] = { hunk = previous.hunk, reason = "source edits overlap" }
      skipped[#skipped + 1] = { hunk = edit.hunk, reason = "source edits overlap" }
      non_overlapping_edits[#non_overlapping_edits] = nil
    else
      non_overlapping_edits[#non_overlapping_edits + 1] = edit
    end
  end
  return {
    edits = non_overlapping_edits,
    choices = choices,
    skipped = skipped,
  }
end

M.plan = plan_merge

---Construct escaped source writes; source_map infers their actual output.
---@param trace VimoiSourceMapTrace
---@param edits VimoiBufferEdit[]
---@return { source_text: string, source_edits: VimoiBufferEdit[] }?
---@return string? error
function M.prepare_candidate(trace, edits)
  local source, source_error, source_edits = apply_source_edits(trace, edits)
  if not source then
    return nil, source_error
  end
  return { source_text = source, source_edits = source_edits }
end

M.apply_source_edits = apply_source_edits
return M

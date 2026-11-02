local M = {}
local source_map = require("vimoi.render.source_map")
local util = require("vimoi.core.util")

---@class VimoiDiffRange: VimoiByteRange
---@field kind "static"|"repeated"|"dynamic"|"ambiguous"

---Line ranges follow vim.text.diff: one-based starts; an empty range starts at the preceding line (possibly zero).
---@class VimoiDiffHunk
---@field id integer
---@field rendered_start_line integer
---@field rendered_line_count integer
---@field target_start_line integer
---@field target_line_count integer
---@field source_ranges VimoiDiffRange[]
---@field display_ranges VimoiDiffRange[] Changed bytes, or same-line context for a zero-width inline insertion.

-- Zero-width insertion ranges include both adjacent output regions so
-- control boundaries remain explicit choices instead of guessed anchors.
local function intersects(start_a, end_a, start_b, end_b)
  if start_a == end_a then
    return start_a >= start_b and start_a <= end_b
  end
  if start_b == end_b then
    return start_b > start_a and start_b < end_a
  end
  return start_a < end_b and start_b < end_a
end

---@param regions VimoiRenderedRegion[]
---@param start_byte integer
---@param end_byte integer
---@return VimoiDiffRange[]
local function project_range(regions, start_byte, end_byte)
  local projected = {}
  local seen = {}
  -- Keep equal endpoints: insertions can belong to both boundary regions.
  local first, last = 1, #regions
  while first <= last do
    local middle = math.floor((first + last) / 2)
    if regions[middle].output_range.end_byte < start_byte then
      first = middle + 1
    else
      last = middle - 1
    end
  end
  for region_index = first, #regions do
    local region = regions[region_index]
    if region.output_range.start_byte > end_byte then
      break
    end
    if intersects(start_byte, end_byte, region.output_range.start_byte, region.output_range.end_byte) then
      local source_start_byte = region.source.start_byte
      local source_end_byte = region.source.end_byte
      if region.kind == "static" or region.kind == "repeated" then
        local rendered_start_byte = math.max(start_byte, region.output_range.start_byte)
        local rendered_end_byte = math.min(end_byte, region.output_range.end_byte)
        if start_byte == end_byte then
          rendered_start_byte =
            math.min(math.max(start_byte, region.output_range.start_byte), region.output_range.end_byte)
          rendered_end_byte = rendered_start_byte
        end
        source_start_byte = source_start_byte + (rendered_start_byte - region.output_range.start_byte)
        source_end_byte = source_start_byte + (rendered_end_byte - rendered_start_byte)
      end
      local key = ("%d:%d:%s"):format(source_start_byte, source_end_byte, region.kind)
      if not seen[key] then
        seen[key] = true
        projected[#projected + 1] = {
          start_byte = source_start_byte,
          end_byte = source_end_byte,
          kind = region.kind,
        }
      end
    end
  end
  return projected
end

---@param modified string
---@param trace VimoiSourceMapTrace
---@return VimoiDiffHunk[]
function M.compute(modified, trace)
  local raw_hunks = util.diff(trace.output, modified, {
    result_type = "indices",
    algorithm = "histogram",
  })
  assert(type(raw_hunks) == "table")
  local rendered_line_starts = trace.output_starts or util.line_starts(trace.output)
  local target_line_starts = util.line_starts(modified)
  local regions = source_map.rendered_regions(trace)
  local hunks = {}

  for index, raw_hunk in ipairs(raw_hunks) do
    local rendered_start_line, rendered_line_count, target_start_line, target_line_count = unpack(raw_hunk)
    local hunk_rendered_start_byte, hunk_rendered_end_byte =
      util.line_range(trace.output, rendered_line_starts, rendered_start_line, rendered_line_count)
    local target_start_byte, target_end_byte =
      util.line_range(modified, target_line_starts, target_start_line, target_line_count)
    local prefix, old_end = util.changed_bytes(
      trace.output:sub(hunk_rendered_start_byte + 1, hunk_rendered_end_byte),
      modified:sub(target_start_byte + 1, target_end_byte)
    )
    local display_start_byte = hunk_rendered_start_byte + prefix
    local display_end_byte = hunk_rendered_start_byte + old_end
    if display_start_byte == display_end_byte and rendered_line_count > 0 then
      -- An inline insertion has no old bytes. Anchor its display to adjacent
      -- content on the same line, rather than spanning every possible source
      -- placement across zero-output control tags. Merge keeps the full map.
      if display_start_byte > 0 and trace.output:sub(display_start_byte, display_start_byte) ~= "\n" then
        display_start_byte = display_start_byte - 1
      elseif
        display_end_byte < #trace.output and trace.output:sub(display_end_byte + 1, display_end_byte + 1) ~= "\n"
      then
        display_end_byte = display_end_byte + 1
      end
    end
    hunks[#hunks + 1] = {
      id = index,
      rendered_start_line = rendered_start_line,
      rendered_line_count = rendered_line_count,
      target_start_line = target_start_line,
      target_line_count = target_line_count,
      source_ranges = project_range(regions, hunk_rendered_start_byte, hunk_rendered_end_byte),
      display_ranges = project_range(regions, display_start_byte, display_end_byte),
    }
  end
  return hunks
end

return M

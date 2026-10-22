local M = {}
local source_map = require("vimoi.gotmpl.source_map")
local util = require("vimoi.util")

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

---@param modified string
---@param trace VimoiSourceMapTrace
---@return VimoiDiffHunk[]
function M.compute(modified, trace)
  local raw_hunks = vim.text.diff(trace.output, modified, {
    result_type = "indices",
    algorithm = "histogram",
  })
  assert(type(raw_hunks) == "table")
  local rendered_line_starts = util.line_starts(trace.output)
  local regions = source_map.rendered_regions(trace)
  local hunks = {}

  for index, raw_hunk in ipairs(raw_hunks) do
    local rendered_start_line, rendered_line_count, target_start_line, target_line_count = unpack(raw_hunk)
    local hunk_rendered_start_byte, hunk_rendered_end_byte =
      util.line_range(trace.output, rendered_line_starts, rendered_start_line, rendered_line_count)
    local projected = {}
    local seen = {}
    for _, region in ipairs(regions) do
      if
        intersects(
          hunk_rendered_start_byte,
          hunk_rendered_end_byte,
          region.output_range.start_byte,
          region.output_range.end_byte
        )
      then
        local source_start_byte = region.source.start_byte
        local source_end_byte = region.source.end_byte
        if region.kind == "static" or region.kind == "repeated" then
          local rendered_start_byte = math.max(hunk_rendered_start_byte, region.output_range.start_byte)
          local rendered_end_byte = math.min(hunk_rendered_end_byte, region.output_range.end_byte)
          if hunk_rendered_start_byte == hunk_rendered_end_byte then
            rendered_start_byte =
              math.min(math.max(hunk_rendered_start_byte, region.output_range.start_byte), region.output_range.end_byte)
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
    hunks[#hunks + 1] = {
      id = index,
      rendered_start_line = rendered_start_line,
      rendered_line_count = rendered_line_count,
      target_start_line = target_start_line,
      target_line_count = target_line_count,
      source_ranges = projected,
    }
  end
  return hunks
end

return M

-- Object-shaped fixtures keep the range/linear oracle independent of the
-- production query indexes. Counts and occurrences are rebuilt from all output
-- executions, so tests also catch incorrect first/repeated/suffix summaries.
local M = {}
local map = require("vimoi.render.source_map")

function M.literals(trace)
  local parts, ids = {}, {}
  for slot, kind in ipairs(trace.source_types) do
    if kind == map.LITERAL or kind == map.REPEATED then
      local first, last = trace.source_bytes[slot], trace.source_bytes[slot + 1]
      ids[slot] = #parts + 1
      parts[#parts + 1] = {
        source_byte = first,
        text = trace.source:sub(first + 1, last),
        occurrences = {},
      }
    end
  end
  local execution = 0
  for _, slot in ipairs(trace.output_slots or {}) do
    if trace.source_types[slot] ~= map.BOUNDARY then
      execution = execution + 1
      local occurrences = parts[ids[slot]].occurrences
      occurrences[#occurrences + 1] = execution
    end
  end
  return parts
end

function M.tags(trace)
  local tags = {}
  for slot, kind in ipairs(trace.source_types) do
    if kind == map.TAG then
      local flags = trace.trim_flags[slot]
      tags[#tags + 1] = {
        start_byte = trace.source_bytes[slot],
        end_byte = trace.source_bytes[slot + 1],
        text = trace.source:sub(trace.source_bytes[slot] + 1, trace.source_bytes[slot + 1]),
        left_trim = flags % 2 == 1,
        right_trim = flags >= 2,
        skeleton_start_byte = trace.skeleton_starts and trace.skeleton_starts[slot],
      }
    end
  end
  return tags
end

function M.sentinels(trace)
  local ids, count, tokens = {}, 0, {}
  for slot, kind in ipairs(trace.source_types) do
    if kind == map.LITERAL or kind == map.REPEATED then
      count = count + 1
      ids[slot] = count
    end
  end
  for execution, slot in ipairs(trace.output_slots) do
    if trace.source_types[slot] ~= map.BOUNDARY then
      tokens[#tokens + 1] = { literal_id = ids[slot], output_byte = trace.output_bytes[execution] }
    end
  end
  return tokens
end

return M

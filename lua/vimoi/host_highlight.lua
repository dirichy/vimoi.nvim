-- Rendered Tree-sitter captures, drawn on literal template text through source_map.
-- Capture groups, metadata ranges and priorities follow Neovim's highlighter;
-- the parser and queries remain native, only the decoration destination changes.
local M = {}
local api = vim.api
local util = require("vimoi.util")
local namespace = api.nvim_create_namespace("vimoi-host-highlight")

---@class VimoiHostHighlight
---@field trace VimoiSourceMapTrace
---@field parser? vim.treesitter.LanguageTree
---@field output_buf? integer Persistent scratch buffer driving native incremental parsing.
---@field language? string
---@field tick integer
---@field context_generation integer
---@field source_starts integer[]
---@field output_starts integer[]
---@field regions VimoiRenderedRegion[] Exact literal mappings, ordered by output byte.
---@field inactive VimoiByteRange[] Literal source ranges not executed in this snapshot.
---@field generation integer
---@field windows table<integer, table> Persistent decorations owned by each visible window.

---@type table<integer, VimoiHostHighlight>
local buffers = {}

---@param buf integer
---@param cached table
local function clear_window(buf, cached)
  for _, mark in ipairs(cached.marks) do
    api.nvim_buf_del_extmark(buf, namespace, mark.id)
  end
end

api.nvim_create_autocmd("WinClosed", {
  group = api.nvim_create_augroup("vimoi-host-highlight", { clear = true }),
  callback = function(args)
    for buf, state in pairs(buffers) do
      local cached = state.windows[tonumber(args.match)]
      if cached then
        clear_window(buf, cached)
      end
      state.windows[tonumber(args.match)] = nil
    end
  end,
})

---@param buf integer
function M.clear(buf)
  local state = buffers[buf]
  buffers[buf] = nil
  if state then
    api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
    if state.output_buf and api.nvim_buf_is_valid(state.output_buf) then
      api.nvim_buf_delete(state.output_buf, { force = true })
    end
    api.nvim__redraw({ buf = buf, valid = false })
  end
end

---@param state VimoiHostHighlight
---@param top integer
---@param bottom integer End-exclusive source row.
---@return table[]
local function decorations(state, top, bottom)
  local trace = state.trace
  local source_first = state.source_starts[top + 1] or #trace.source
  local source_last = state.source_starts[bottom + 1] or #trace.source
  local visible, ranges = {}, {}
  for _, region in ipairs(state.regions) do
    local first = math.max(source_first, region.source.start_byte)
    local last = math.min(source_last, region.source.end_byte)
    if first < last then
      local output_first = region.output_range.start_byte + first - region.source.start_byte
      local output_last = region.output_range.start_byte + last - region.source.start_byte
      visible[#visible + 1] = { region = region, first = output_first, last = output_last }
      local row = util.byte_to_position(trace.output, output_first, state.output_starts)
      local end_row = util.byte_to_position(trace.output, output_last - 1, state.output_starts) + 1
      local previous = ranges[#ranges]
      if previous and row <= previous[2] then
        previous[2] = math.max(previous[2], end_row)
      else
        ranges[#ranges + 1] = { row, end_row }
      end
    end
  end
  local marks, seen = {}, {}
  for _, range in ipairs(state.inactive) do
    local first = math.max(source_first, range.start_byte)
    local last = math.min(source_last, range.end_byte)
    if first < last then
      local row, col = util.byte_to_position(trace.source, first, state.source_starts)
      local end_row, end_col = util.byte_to_position(trace.source, last, state.source_starts)
      marks[#marks + 1] = {
        row = row,
        col = col,
        opts = {
          end_row = end_row,
          end_col = end_col,
          hl_group = "Comment",
          priority = vim.hl.priorities.treesitter,
        },
      }
    end
  end
  if not state.parser then
    return marks
  end
  state.parser:for_each_tree(function(tree, language_tree)
    local language = language_tree:lang()
    local query = vim.treesitter.query.get(language, "highlights")
    if not query then
      return
    end
    local included = tree:included_ranges(true)
    for _, rows in ipairs(ranges) do
      for capture, node, metadata, match in query:iter_captures(tree:root(), state.output_buf, rows[1], rows[2]) do
        local name = query.captures[capture]
        if name:sub(1, 1) ~= "_" then
          local range = vim.treesitter.get_range(node, state.output_buf, metadata[capture])
          local capture_metadata = metadata[capture] or {}
          local priority = tonumber(metadata.priority or capture_metadata.priority) or vim.hl.priorities.treesitter
          local spell
          if name == "spell" then
            spell = true
          elseif name == "nospell" then
            spell = false
            priority = priority + 1
          end
          local url = capture_metadata.url
          if type(url) == "number" then
            local nodes = match:captures()[url]
            url = nodes and vim.treesitter.get_node_text(nodes[1], state.output_buf, { metadata = metadata[url] })
          end
          for _, included_range in ipairs(included) do
            local first = math.max(range[3], included_range[3])
            local last = math.min(range[6], included_range[6])
            -- Both lists are ordered by output bytes. Skip unrelated literal
            -- slots without scanning the entire source map for every capture.
            local low, high = 1, #visible
            while low <= high do
              local middle = math.floor((low + high) / 2)
              if visible[middle].last <= first then
                low = middle + 1
              else
                high = middle - 1
              end
            end
            for index = low, #visible do
              local part = visible[index]
              if part.first >= last then
                break
              end
              local a, b = math.max(first, part.first), math.min(last, part.last)
              if a < b then
                local offset = part.region.source.start_byte - part.region.output_range.start_byte
                local row, col = util.byte_to_position(trace.source, a + offset, state.source_starts)
                local end_row, end_col = util.byte_to_position(trace.source, b + offset, state.source_starts)
                local mark = {
                  row = row,
                  col = col,
                  opts = {
                    end_row = end_row,
                    end_col = end_col,
                    hl_group = "@" .. name .. "." .. language,
                    priority = priority,
                    spell = spell,
                    conceal = metadata.conceal or capture_metadata.conceal,
                    url = url,
                  },
                }
                -- Equal-priority persistent marks have no query-order tie
                -- breaker. Stack coincident captures in one mark so later
                -- captures (e.g. @property over @variable) reliably win.
                local key = table.concat({
                  a + offset,
                  b + offset,
                  priority,
                  tostring(spell),
                  tostring(mark.opts.conceal),
                  tostring(url),
                }, "\0")
                local previous = seen[key]
                if previous then
                  local groups = previous.opts.hl_group
                  if type(groups) == "string" then
                    groups = { groups }
                  end
                  -- Disjoint query ranges can yield the same capture again.
                  if not vim.list_contains(groups, mark.opts.hl_group) then
                    groups[#groups + 1] = mark.opts.hl_group
                    previous.opts.hl_group = groups
                  end
                else
                  seen[key] = mark
                  marks[#marks + 1] = mark
                end
              end
            end
          end
        end
      end
    end
  end)
  return marks
end

api.nvim_set_decoration_provider(namespace, {
  on_win = function(_, win, buf, top, bottom)
    local state = buffers[buf]
    if not state or require("vimoi").config.highlight.mode ~= "rendered" or vim.bo[buf].filetype ~= "gotmpl" then
      return false
    end
    -- on_win's bottom is inclusive; cache queries until this viewport changes.
    local cached = state.windows[win]
    local current = api.nvim_buf_get_changedtick(buf) == state.tick
      and require("vimoi.cli").context_generation == state.context_generation
    if
      current and (not cached or cached.generation ~= state.generation or cached.top ~= top or cached.bottom ~= bottom)
    then
      local marks = decorations(state, top, bottom + 1)
      -- Install the complete new viewport before retiring the previous result.
      for _, mark in ipairs(marks) do
        mark.opts.right_gravity = false
        mark.opts.end_right_gravity = true
        mark.opts.invalidate = true
        mark.id = api.nvim_buf_set_extmark(buf, namespace, mark.row, mark.col, mark.opts)
      end
      if cached then
        clear_window(buf, cached)
      end
      state.windows[win] = { top = top, bottom = bottom, generation = state.generation, marks = marks }
    end
    -- While rendering is pending, native extmarks keep the last successful
    -- styles and follow source edits without querying stale source coordinates.
    return false
  end,
})

---@param buf integer
---@param trace VimoiSourceMapTrace
function M.update(buf, trace)
  local language = vim.b[buf].vimoi_template_language
  ---@type VimoiHostHighlight?
  local state = buffers[buf]
  if state and state.language ~= language then
    M.clear(buf)
    state = nil
  end
  local output = state and state.output_buf
  local parser = state and state.parser
  if not state and language then
    output = api.nvim_create_buf(false, true)
    vim.bo[output].bufhidden = "hide"
    vim.bo[output].undolevels = -1
    vim.b[output].vimoi_highlight_source = buf
    util.set_buffer_text(output, trace.output)
    parser = vim.treesitter.get_parser(output, language)
  elseif state and output and state.trace.output ~= trace.output then
    local before = state.trace.output
    local edits = require("vimoi.gotmpl.buffer_edits")
    edits.apply(output, before, trace.output, edits.diff(before, trace.output))
  end
  if parser then
    parser:parse(true)
  end
  local inactive = {}
  for _, part in ipairs(trace.literal_parts) do
    if #part.output_ranges == 0 and part.source.start_byte < part.source.end_byte then
      inactive[#inactive + 1] = part.source
    end
  end
  local regions, seen = {}, {}
  for _, region in ipairs(require("vimoi.gotmpl.source_map").rendered_regions(trace)) do
    if region.kind == "static" or region.kind == "repeated" then
      local key = region.source.start_byte .. ":" .. region.source.end_byte
      -- A loop body can have conflicting colors between executions. Use its
      -- first occurrence rather than stacking contradictory decorations.
      if not seen[key] then
        seen[key] = true
        regions[#regions + 1] = region
      end
    end
  end
  buffers[buf] = {
    trace = trace,
    parser = parser,
    output_buf = output,
    language = language,
    generation = state and state.generation + 1 or 1,
    tick = api.nvim_buf_get_changedtick(buf),
    context_generation = require("vimoi.cli").context_generation,
    source_starts = util.line_starts(trace.source),
    output_starts = util.line_starts(trace.output),
    regions = regions,
    inactive = inactive,
    windows = state and state.windows or {},
  }
  -- Wake visible windows so their persistent decorations adopt this snapshot.
  api.nvim__redraw({ buf = buf, valid = false })
end

return M

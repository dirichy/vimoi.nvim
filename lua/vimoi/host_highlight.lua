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
---@field tick integer
---@field context_generation integer
---@field source_starts integer[]
---@field output_starts integer[]
---@field regions VimoiRenderedRegion[] Exact literal mappings, ordered by output byte.
---@field inactive VimoiByteRange[] Literal source ranges not executed in this snapshot.
---@field windows table<integer, table> Viewport decorations, discarded with the snapshot.

---@type table<integer, VimoiHostHighlight>
local buffers = {}

api.nvim_create_autocmd("WinClosed", {
  group = api.nvim_create_augroup("vimoi-host-highlight", { clear = true }),
  callback = function(args)
    for _, state in pairs(buffers) do
      state.windows[tonumber(args.match)] = nil
    end
  end,
})

---@param buf integer
function M.clear(buf)
  local state = buffers[buf]
  buffers[buf] = nil
  if state then
    if state.parser then
      state.parser:destroy()
    end
    vim.cmd.redraw()
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
          ephemeral = true,
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
      for capture, node, metadata, match in query:iter_captures(tree:root(), trace.output, rows[1], rows[2]) do
        local name = query.captures[capture]
        if name:sub(1, 1) ~= "_" then
          local range = vim.treesitter.get_range(node, trace.output, metadata[capture])
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
            url = nodes and vim.treesitter.get_node_text(nodes[1], trace.output, { metadata = metadata[url] })
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
                    ephemeral = true,
                  },
                }
                -- A multiline capture can appear in several disjoint query
                -- ranges. Preserve distinct styles, but draw each result once.
                local key = table.concat({
                  a + offset,
                  b + offset,
                  language,
                  name,
                  priority,
                  tostring(spell),
                  tostring(mark.opts.conceal),
                  tostring(url),
                }, "\0")
                if not seen[key] then
                  seen[key] = true
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
    if
      not state
      or api.nvim_buf_get_changedtick(buf) ~= state.tick
      or require("vimoi.cli").context_generation ~= state.context_generation
      or require("vimoi").config.highlight.mode ~= "rendered"
      or vim.bo[buf].filetype ~= "gotmpl"
    then
      return false
    end
    -- on_win's bottom is inclusive; cache queries until this viewport changes.
    local cached = state.windows[win]
    if not cached or cached.top ~= top or cached.bottom ~= bottom then
      state.windows[win] = { top = top, bottom = bottom, marks = decorations(state, top, bottom + 1) }
    end
    return true
  end,
  on_range = function(_, win, buf, first_row, first_col, last_row, last_col)
    local state = buffers[buf]
    local cached = state and state.windows[win]
    if not cached then
      return
    end
    for _, mark in ipairs(cached.marks) do
      local opts = mark.opts
      if
        (mark.row < last_row or mark.row == last_row and mark.col < last_col)
        and (opts.end_row > first_row or opts.end_row == first_row and opts.end_col > first_col)
      then
        api.nvim_buf_set_extmark(buf, namespace, mark.row, mark.col, opts)
      end
    end
  end,
})

---@param buf integer
---@param trace VimoiSourceMapTrace
function M.update(buf, trace)
  M.clear(buf)
  local language = vim.b[buf].vimoi_template_language
  local parser
  if language then
    parser = vim.treesitter.get_string_parser(trace.output, language)
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
    tick = api.nvim_buf_get_changedtick(buf),
    context_generation = require("vimoi.cli").context_generation,
    source_starts = util.line_starts(trace.source),
    output_starts = util.line_starts(trace.output),
    regions = regions,
    inactive = inactive,
    windows = {},
  }
  vim.cmd.redraw()
end

return M
